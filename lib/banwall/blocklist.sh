#!/usr/bin/env bash
#
# blocklist.sh - IP-Blocklisten holen, prüfen und in nftables laden.
#
# Die voreingestellte Quelle ist IPv64.net, das verbreitete Blocklisten
# aufbereitet und kostenlos bereitstellt (Originalquelle: blocklist.de).
# Ein kostenloser Dienst ohne Verfügbarkeitsgarantie, der laut AGB nicht
# überlastet werden soll - deshalb die Vorgabe 'daily' mit 30 Minuten
# Streuung im Timer, und deshalb bleibt bei einer nicht erreichbaren
# Quelle der alte Stand stehen, statt es sofort erneut zu versuchen.
#
# Der heikle Teil ist nicht das Herunterladen, sondern das Vertrauen: eine
# fremde Liste bestimmt, wen der Server aussperrt. Steht die eigene
# Adresse drin - versehentlich oder absichtlich - ist der Server weg.
# Deshalb durchläuft jede Liste vier Stufen:
#   1. holen  - nur https, mit Timeout und Größenlimit
#   2. parsen - nur echte IPv4/IPv6-Adressen und CIDR-Präfixe
#   3. filtern- eigene und private Adressen fliegen immer raus
#   4. laden  - atomar; eine leere oder kaputte Liste lässt den alten
#               Stand unangetastet stehen

[[ -n "${_BANWALL_BLOCKLIST_LOADED:-}" ]] && return 0
_BANWALL_BLOCKLIST_LOADED=1

readonly BANWALL_BL_DIR="${BANWALL_STATE_DIR}/blocklists"
readonly BANWALL_BL_SERVICE="banwall-blocklist.service"
readonly BANWALL_BL_TIMER="banwall-blocklist.timer"

# Netze, die niemals gesperrt werden. Loopback, RFC1918, link-local,
# CGNAT und die IPv6-Entsprechungen - eine Liste, die diese enthält,
# ist entweder fehlerhaft oder bösartig.
readonly _BANWALL_BL_NEVER=(
	'^0\.' '^10\.' '^127\.' '^169\.254\.' '^100\.6[4-9]\.' '^100\.[7-9][0-9]\.'
	'^100\.1[01][0-9]\.' '^100\.12[0-7]\.' '^172\.1[6-9]\.' '^172\.2[0-9]\.'
	'^172\.3[01]\.' '^192\.168\.' '^22[4-9]\.' '^2[34][0-9]\.' '^255\.'
	'^::1' '^fe80:' '^fc00:' '^fd'
)

# _bl_local_addresses - alle Adressen dieses Servers plus die Gegenstelle
# der aktuellen SSH-Sitzung. Genau die dürfen nie in einem Set landen.
_bl_local_addresses() {
	ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1
	[[ -n "${SSH_CLIENT:-}" ]] && awk '{print $1}' <<<"$SSH_CLIENT"
	[[ -n "${SSH_CONNECTION:-}" ]] && awk '{print $1}' <<<"$SSH_CONNECTION"
	return 0
}

# _bl_parse - Rohliste auf stdin, gültige Präfixe auf stdout.
# Akzeptiert die verbreiteten Formate (reine IPs, CIDR, Zeilen mit
# angehängtem Kommentar) und verwirft alles andere kommentarlos.
_bl_parse() {
	local family="$1" v4 v6 oktett praefix4

	# Die Oktette müssen einzeln auf 0-255 geprüft werden. Ein simples
	# [0-9]{1,3} hält '999.1.1.1' für gültig - nftables lehnt so einen
	# Eintrag ab und der ganze Block schlägt fehl.
	oktett='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
	praefix4='(3[0-2]|[12]?[0-9])'
	v4="($oktett\.){3}$oktett(/$praefix4)?"

	# Für IPv6 wäre eine vollständige Prüfung unverhältnismäßig lang.
	# Geprüft wird die Grundform und die Präfixlänge 0-128; alles
	# Weitere fängt nftables ab, ohne dass ein Block dabei verloren geht.
	v6='[0-9a-fA-F:]{2,}:[0-9a-fA-F:]*(/(12[0-8]|1[01][0-9]|[1-9]?[0-9]))?'

	# Kommentare ab # oder ; abschneiden, dann erstes Feld nehmen.
	sed -e 's/[#;].*$//' -e 's/\r$//' |
		awk '{print $1}' |
		if [[ "$family" == "4" ]]; then
			grep -Ex "$v4"
		else
			grep -Ex "$v6"
		fi
}

# _bl_filter_safe - entfernt Einträge, die uns selbst treffen würden.
_bl_filter_safe() {
	local pattern tmp_local
	pattern="$(printf '%s|' "${_BANWALL_BL_NEVER[@]}")"
	pattern="${pattern%|}"

	tmp_local="$(mktemp)"
	_bl_local_addresses | sort -u >"$tmp_local"

	grep -Ev "$pattern" |
		grep -vxFf "$tmp_local" || true

	rm -f "$tmp_local"
}

# _bl_fetch URL ZIELDATEI
_bl_fetch() {
	local url="$1" dest="$2"
	log_debug "hole $url"

	# --max-filesize verhindert, dass eine kompromittierte Quelle die
	# Platte füllt; --fail sorgt dafür, dass eine HTML-Fehlerseite
	# nicht als Blocklist durchgeht.
	if ! curl --fail --silent --show-error --location \
		--proto '=https' --tlsv1.2 \
		--max-time "$BANWALL_BLOCKLIST_TIMEOUT" \
		--max-filesize "$BANWALL_BLOCKLIST_MAX_BYTES" \
		--user-agent "banwall/$BANWALL_VERSION" \
		--output "$dest" "$url" 2>/dev/null; then
		log_warn "Quelle nicht erreichbar oder abgelehnt: $url"
		return 1
	fi
	[[ -s "$dest" ]] || { log_warn "Leere Antwort von: $url"; return 1; }
	return 0
}

# Elemente pro nft-Aufruf. 1000 lädt in der Praxis durch; 500 lässt
# Luft für Systeme mit kleinerem net.core.wmem_max und kostet bei einer
# Liste dieser Größe nur Sekundenbruchteile.
readonly _BANWALL_BL_CHUNK=500

# _bl_nft_batch AKTION SET DATEI
# Ruft nft blockweise auf. AKTION ist "add" oder "delete".
_bl_nft_batch() {
	local aktion="$1" set_name="$2" datei="$3"
	local chunkdir zeilen=0 fehler=0 f

	[[ -s "$datei" ]] || return 0
	zeilen="$(wc -l <"$datei")"

	chunkdir="$(mktemp -d)"
	split -l "$_BANWALL_BL_CHUNK" "$datei" "$chunkdir/teil-"

	for f in "$chunkdir"/teil-*; do
		if ! banwall_run nft "$aktion" element inet "$BANWALL_NFT_TABLE" "$set_name" \
			"{ $(paste -sd, - <"$f") }"; then
			fehler=$((fehler + 1))
		fi
	done
	rm -rf "$chunkdir"

	if ((fehler > 0)); then
		# Beim Entfernen ist ein Fehlschlag verkraftbar: dann bleibt eine
		# Adresse länger gesperrt als nötig. Beim Hinzufügen fehlt Schutz.
		if [[ "$aktion" == "delete" ]]; then
			log_warn "$fehler Block/Blöcke beim Entfernen aus $set_name übersprungen."
		else
			log_error "$fehler von $(((zeilen + _BANWALL_BL_CHUNK - 1) / _BANWALL_BL_CHUNK)) Blöcken konnten nicht in $set_name geladen werden."
			return 1
		fi
	fi
	return 0
}

# _bl_load_v4 NEUE_LISTE
# Differenzielles Laden gegen den zuletzt gespeicherten Stand. IPv4-
# Präfixe speichert nftables unverändert, deshalb ist der Vergleich
# zwischen Datei und Set-Inhalt hier verlässlich.
_bl_load_v4() {
	local neu="$1" alt="$BANWALL_BL_DIR/current-v4.txt"
	local hinzu weg

	if [[ ! -s "$alt" ]]; then
		# Erster Lauf oder verlorener Stand: sauber von vorn.
		banwall_run nft flush set inet "$BANWALL_NFT_TABLE" blocklist4 || return 1
		_bl_nft_batch add blocklist4 "$neu" || return 1
		return 0
	fi

	hinzu="$(mktemp)"
	weg="$(mktemp)"
	comm -13 <(sort -u "$alt") <(sort -u "$neu") >"$hinzu"
	comm -23 <(sort -u "$alt") <(sort -u "$neu") >"$weg"
	log_debug "IPv4: $(wc -l <"$hinzu") neu, $(wc -l <"$weg") entfallen"

	# Reihenfolge ist wichtig: erst hinzufügen, dann entfernen.
	local rc=0
	_bl_nft_batch add blocklist4 "$hinzu" || rc=1
	((rc == 0)) && { _bl_nft_batch delete blocklist4 "$weg" || true; }
	rm -f "$hinzu" "$weg"
	return "$rc"
}

# _bl_load_v6 NEUE_LISTE
# IPv6 wird immer vollständig neu geladen. Grund: nftables normalisiert
# Präfixe beim Einfügen (2001:db8::1/64 wird zu 2001:db8::/64), womit
# die gespeicherte Liste nicht mehr zum Set-Inhalt passt - eine Differenz
# darauf würde Einträge löschen, die noch gelten. Die IPv6-Anteile
# gängiger Listen sind klein genug, dass das in eine Transaktion passt.
_bl_load_v6() {
	local neu="$1"
	banwall_run nft flush set inet "$BANWALL_NFT_TABLE" blocklist6 || return 1
	_bl_nft_batch add blocklist6 "$neu" || return 1
	return 0
}

# banwall_blocklist_refresh - ein kompletter Aktualisierungslauf.
# Wird sowohl von 'banwall blocklist-update' als auch vom Timer gerufen.
banwall_blocklist_refresh() {
	# Im Trockenlauf ist curl noch nicht installiert und die
	# nftables-Tabelle noch nicht angelegt, weil vorher nichts wirklich
	# angewendet wurde. Hier zu sterben hiesse, den Trockenlauf genau dort
	# scheitern zu lassen, wo der echte Lauf durchliefe.
	if is_dry_run; then
		local fehlt=()
		command -v curl >/dev/null 2>&1 || fehlt+=("curl")
		command -v nft >/dev/null 2>&1 || fehlt+=("nft")
		nft list table inet "$BANWALL_NFT_TABLE" >/dev/null 2>&1 ||
			fehlt+=("die nftables-Tabelle '$BANWALL_NFT_TABLE'")
		if ((${#fehlt[@]})); then
			local liste
			liste="$(printf '%s, ' "${fehlt[@]}")"
			log_warn "Trockenlauf: ${liste%, } noch nicht vorhanden - der echte Lauf legt das an."
			return 0
		fi
	else
		require_cmd curl "Erst 'banwall apply -m blocklist' - das installiert es."
		require_cmd nft "Erst 'banwall apply -m nftables' - das installiert es."

		nft list table inet "$BANWALL_NFT_TABLE" >/dev/null 2>&1 ||
			die 3 "nftables-Tabelle '$BANWALL_NFT_TABLE' fehlt. Erst 'banwall apply -m nftables'."
	fi

	mkdir -p "$BANWALL_BL_DIR"
	chmod 700 "$BANWALL_BL_DIR"

	local workdir raw url ok=0 failed=0
	workdir="$(mktemp -d)"
	# shellcheck disable=SC2064
	trap "rm -rf '$workdir'" RETURN

	raw="$workdir/raw"
	: >"$raw"

	for url in $BANWALL_BLOCKLIST_URLS; do
		if _bl_fetch "$url" "$workdir/dl"; then
			cat "$workdir/dl" >>"$raw"
			printf '\n' >>"$raw"
			ok=$((ok + 1))
		else
			failed=$((failed + 1))
		fi
	done

	if ((ok == 0)); then
		log_error "Keine einzige Blocklist-Quelle war erreichbar ($failed Fehlschläge)."
		log_error "Der bisherige Stand im nftables-Set bleibt unverändert."
		return 1
	fi
	((failed > 0)) && log_warn "$failed von $((ok + failed)) Quellen nicht erreichbar."

	local v4 v6 n4 n6
	v4="$workdir/v4"
	v6="$workdir/v6"
	_bl_parse 4 <"$raw" | _bl_filter_safe | sort -u >"$v4"
	_bl_parse 6 <"$raw" | _bl_filter_safe | sort -u >"$v6"

	n4="$(wc -l <"$v4")"
	n6="$(wc -l <"$v6")"

	if ((n4 + n6 == 0)); then
		log_error "Nach der Prüfung blieb kein einziger gültiger Eintrag übrig."
		log_error "Wahrscheinlich hat sich das Format einer Quelle geändert."
		log_error "Der bisherige Stand bleibt unverändert."
		return 1
	fi

	# Obergrenze: ein nftables-Set mit Millionen Einträgen frisst
	# Arbeitsspeicher, den ein kleiner vServer nicht hat.
	if ((n4 + n6 > BANWALL_BLOCKLIST_MAX_ENTRIES)); then
		log_error "$((n4 + n6)) Einträge überschreiten das Limit von $BANWALL_BLOCKLIST_MAX_ENTRIES."
		log_error "Entweder BANWALL_BLOCKLIST_MAX_ENTRIES anheben oder Quellen reduzieren."
		return 1
	fi

	# --- Laden ---------------------------------------------------------
	# Eine einzige Transaktion mit allen Elementen wäre atomar, scheitert
	# aber ab etwa 12.000 Einträgen am Netlink-Puffer des Kernels
	# ("Message too long"; net.core.wmem_max ist auf Debian 212992 Bytes).
	# Die IPv64-Liste allein hat über 26.000 - der naive Weg funktioniert
	# mit ihr also nie.
	#
	# Stattdessen wird in Blöcken geladen, und zwar additiv: erst kommen
	# die neuen Adressen dazu, dann fallen die weg, die nicht mehr auf der
	# Liste stehen. So ist das Set zu keinem Zeitpunkt leer. Ein 'flush'
	# mit anschließendem Nachladen hätte für die Dauer des Ladevorgangs
	# jede zuvor gesperrte Adresse durchgelassen.
	if ! _bl_load_v4 "$v4" || ! _bl_load_v6 "$v6"; then
		log_error "Laden der Blocklist fehlgeschlagen. Der alte Stand gilt weiter."
		return 1
	fi

	# Stand für 'banwall status' und zur Fehlersuche aufheben.
	if ! is_dry_run; then
		cp "$v4" "$BANWALL_BL_DIR/current-v4.txt"
		cp "$v6" "$BANWALL_BL_DIR/current-v6.txt"
		date -Iseconds >"$BANWALL_BL_DIR/last-update"
	fi

	# Gemeldet wird der Ist-Stand aus dem Set, nicht die Zahl der
	# gesendeten Einträge: nftables führt überlappende Präfixe zusammen,
	# sodass aus 62 IPv6-Einträgen mit /64 am Ende 43 Netze werden.
	if is_dry_run; then
		log_ok "Blocklist geprüft: $n4 IPv4- und $n6 IPv6-Einträge aus $ok Quelle(n)."
	else
		log_ok "Blocklist geladen: $(banwall_nftables_count_set blocklist4) IPv4- und $(banwall_nftables_count_set blocklist6) IPv6-Einträge im Set (aus $((n4 + n6)) geprüften Zeilen, $ok Quelle(n))."
	fi
	return 0
}

banwall_blocklist_apply() {
	ensure_cmd curl curl "Das Paket curl wird zum Holen der Listen gebraucht."

	# Service und Timer aus den Vorlagen installieren. %i-freie Units,
	# weil es genau eine Blocklist-Konfiguration pro Host gibt.
	local unit
	for unit in "$BANWALL_BL_SERVICE" "$BANWALL_BL_TIMER"; do
		backup_file "/etc/systemd/system/$unit"
	done

	sed -e "s|@INTERVAL@|${BANWALL_BLOCKLIST_INTERVAL}|g" \
		"$BANWALL_SHARE_DIR/systemd/$BANWALL_BL_TIMER" |
		write_file "/etc/systemd/system/$BANWALL_BL_TIMER" 0644

	write_file "/etc/systemd/system/$BANWALL_BL_SERVICE" 0644 \
		<"$BANWALL_SHARE_DIR/systemd/$BANWALL_BL_SERVICE"

	banwall_run systemctl daemon-reload
	service_enable "$BANWALL_BL_TIMER"

	# Einmal sofort laden, damit der Schutz nicht erst beim ersten
	# Timer-Lauf greift.
	banwall_blocklist_refresh || {
		log_warn "Erster Blocklist-Lauf fehlgeschlagen. Der Timer versucht es erneut."
		return 0
	}
}

banwall_blocklist_status() {
	if [[ ! -f "$BANWALL_BL_DIR/last-update" ]]; then
		printf 'noch nie aktualisiert\n'
		return 0
	fi
	local when next
	when="$(cat "$BANWALL_BL_DIR/last-update")"
	next="$(systemctl list-timers --no-pager "$BANWALL_BL_TIMER" 2>/dev/null |
		awk 'NR==2{print $1" "$2}')"
	printf 'letzte Aktualisierung %s, nächste %s\n' "$when" "${next:-unbekannt}"
}

banwall_blocklist_rollback() {
	banwall_run systemctl disable --now "$BANWALL_BL_TIMER" 2>/dev/null || true
	banwall_run rm -f "/etc/systemd/system/$BANWALL_BL_TIMER" \
		"/etc/systemd/system/$BANWALL_BL_SERVICE"
	banwall_run systemctl daemon-reload

	# Sets leeren, falls die Tabelle noch steht (etwa bei -m blocklist).
	if nft list table inet "$BANWALL_NFT_TABLE" >/dev/null 2>&1; then
		banwall_run nft flush set inet "$BANWALL_NFT_TABLE" blocklist4 2>/dev/null || true
		banwall_run nft flush set inet "$BANWALL_NFT_TABLE" blocklist6 2>/dev/null || true
	fi
	log_ok "Blocklist-Timer entfernt und Sets geleert."
}
