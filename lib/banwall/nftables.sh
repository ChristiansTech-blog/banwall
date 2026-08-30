#!/usr/bin/env bash
#
# nftables.sh - Basisregelwerk: eingehend verboten, ausgehend erlaubt.
#
# Banwall arbeitet in einer eigenen Tabelle 'inet banwall'. Das ist der
# wesentliche Designentscheid dieses Moduls: /etc/nftables.conf bleibt
# unangetastet, fremde Regelwerke laufen weiter, und ein Rollback ist ein
# einzelnes 'nft delete table'. 'inet' deckt IPv4 und IPv6 in einem
# Regelsatz ab - getrennte ip/ip6-Tabellen wären die häufigste Quelle
# für ein Loch, das nur über v6 offensteht.

[[ -n "${_BANWALL_NFTABLES_LOADED:-}" ]] && return 0
_BANWALL_NFTABLES_LOADED=1

readonly BANWALL_NFT_TABLE="banwall"
readonly BANWALL_NFT_FILE="/etc/banwall/nftables.nft"
readonly BANWALL_NFT_INCLUDE_MARK="# banwall: eingebunden, nicht entfernen"

_nft_port_set() {
	local ports="$1"
	[[ -n "${ports// /}" ]] || return 1
	printf '{ %s }' "$(tr ' ' '\n' <<<"$ports" | grep -v '^$' | paste -sd, -)"
}

banwall_nftables_render() {
	local tcp udp allow_nets=""

	tcp="$(_nft_port_set "$BANWALL_TCP_PORTS")" || tcp=""
	udp="$(_nft_port_set "$BANWALL_UDP_PORTS")" || udp=""
	if [[ -n "${BANWALL_ALLOW_NETS// /}" ]]; then
		allow_nets="$(tr ' ' '\n' <<<"$BANWALL_ALLOW_NETS" | grep -v '^$' | paste -sd, -)"
	fi

	cat <<NFT
#!/usr/sbin/nft -f
# Erzeugt von Banwall - nicht von Hand ändern.
# Änderungen gehören in /etc/banwall/banwall.conf, danach 'banwall apply'.

table inet ${BANWALL_NFT_TABLE} {
	# Sets für die Blocklisten. Sie werden hier leer angelegt, damit die
	# Regeln auch dann laden, wenn das Blocklist-Modul aus ist.
	set blocklist4 {
		type ipv4_addr
		flags interval
	}

	set blocklist6 {
		type ipv6_addr
		flags interval
	}

	chain input {
		type filter hook input priority filter; policy drop;

		# Bestehende Verbindungen zuerst - das ist der häufigste Fall
		# und spart jeder weiteren Regel die Auswertung.
		ct state established,related accept
		ct state invalid drop

		iif lo accept

		# Blocklisten vor allen Erlaubnissen: ein gelisteter Host kommt
		# auch nicht auf einen offenen Port.
		ip saddr @blocklist4 drop
		ip6 saddr @blocklist6 drop
$(if [[ -n "$allow_nets" ]]; then
		printf '\n\t\t# Voller Zugang für BANWALL_ALLOW_NETS\n'
		printf '\t\tip saddr { %s } accept\n' "$allow_nets"
fi)
		# ICMP wird gebraucht: ohne Path-MTU-Discovery brechen große
		# Pakete weg, ohne ND funktioniert IPv6 gar nicht.
		ip protocol icmp icmp type { destination-unreachable, time-exceeded, parameter-problem$(((BANWALL_ALLOW_PING)) && printf ', echo-request')} accept
		ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert$(((BANWALL_ALLOW_PING)) && printf ', echo-request')} accept
$(if ((BANWALL_SSH_RATE_LIMIT)); then
		printf '\n\t\t# Neue SSH-Verbindungen begrenzen. Bremst Bruteforce, bevor\n'
		printf '\t\t# fail2ban überhaupt eine Zeile im Log sieht.\n'
		printf '\t\ttcp dport %s ct state new limit rate 10/minute burst 20 packets accept\n' "$BANWALL_SSH_PORT"
		printf '\t\ttcp dport %s ct state new drop\n' "$BANWALL_SSH_PORT"
fi)
$(if [[ -n "$tcp" ]]; then printf '\t\ttcp dport %s accept\n' "$tcp"; fi)
$(if [[ -n "$udp" ]]; then printf '\t\tudp dport %s accept\n' "$udp"; fi)

		# Was hier ankommt, fällt unter policy drop. Limitiert loggen,
		# damit ein Portscan nicht die Platte füllt.
		limit rate 5/minute burst 10 packets log prefix "banwall-drop: " level info
	}

	chain forward {
		type filter hook forward priority filter; policy drop;
	}

	chain output {
		type filter hook output priority filter; policy accept;
	}
}
NFT
}

banwall_nftables_apply() {
	pkg_install nftables
	require_cmd nft

	mkdir -p "$BANWALL_CONFIG_DIR"
	backup_file "$BANWALL_NFT_FILE"
	backup_file /etc/nftables.conf

	local rendered
	rendered="$(banwall_nftables_render)"

	# Vor dem Schreiben prüfen. Ein Syntaxfehler würde beim nächsten
	# Boot dazu führen, dass nftables.service scheitert - und dann steht
	# der Server ohne Firewall im Netz.
	local tmp
	tmp="$(mktemp)"
	printf '%s\n' "$rendered" >"$tmp"
	if ! nft --check --file "$tmp" 2>/dev/null; then
		local err
		err="$(nft --check --file "$tmp" 2>&1 || true)"
		rm -f "$tmp"
		log_error "Erzeugtes Regelwerk ist ungültig. nft meldet:"
		log_error "$err"
		return 1
	fi
	rm -f "$tmp"

	printf '%s\n' "$rendered" | write_file "$BANWALL_NFT_FILE" 0600

	# Regeln laden. nft -f ist für eine Tabelle atomar: entweder das
	# gesamte Regelwerk gilt oder das alte bleibt stehen.
	run nft --file "$BANWALL_NFT_FILE" ||
		{ log_error "Regelwerk ließ sich nicht laden."; return 1; }

	# Persistenz über nftables.service. Statt die Regeln in
	# /etc/nftables.conf zu kopieren, wird nur eine include-Zeile
	# ergänzt - so bleiben fremde Regeln in der Datei erhalten.
	if [[ ! -f /etc/nftables.conf ]]; then
		printf '#!/usr/sbin/nft -f\nflush ruleset\n' | write_file /etc/nftables.conf 0644
	fi
	if ! grep -qF "$BANWALL_NFT_FILE" /etc/nftables.conf 2>/dev/null; then
		if is_dry_run; then
			log_info "  [dry-run] ergänze include in /etc/nftables.conf"
		else
			printf '\n%s\ninclude "%s"\n' \
				"$BANWALL_NFT_INCLUDE_MARK" "$BANWALL_NFT_FILE" >>/etc/nftables.conf
		fi
	fi

	service_enable nftables
	log_ok "nftables aktiv: eingehend verboten, offene TCP-Ports: ${BANWALL_TCP_PORTS:-keine}"
}

# banwall_nftables_count_set SETNAME - Anzahl der Elemente in einem Set.
# Ausgewertet wird die Textform: die JSON-Ausgabe braucht jq, das auf
# einem frischen Debian nicht installiert ist, und ein grep auf "elem"
# zählt nur den Schlüssel, nicht die Elemente darin.
banwall_nftables_count_set() {
	nft list set inet "$BANWALL_NFT_TABLE" "$1" 2>/dev/null |
		tr -d '\n\t ' |
		sed -n 's/.*elements={\([^}]*\)}.*/\1/p' |
		tr ',' '\n' | grep -c . || true
}

banwall_nftables_status() {
	if ! command -v nft >/dev/null 2>&1; then
		printf 'nftables nicht installiert\n'
		return 0
	fi
	if nft list table inet "$BANWALL_NFT_TABLE" >/dev/null 2>&1; then
		local n4 n6
		n4="$(banwall_nftables_count_set blocklist4)"
		n6="$(banwall_nftables_count_set blocklist6)"
		printf 'Tabelle inet %s geladen, Blocklist %s/%s Einträge (v4/v6)\n' \
			"$BANWALL_NFT_TABLE" "$n4" "$n6"
	else
		printf 'Tabelle inet %s nicht geladen\n' "$BANWALL_NFT_TABLE"
	fi
}

banwall_nftables_rollback() {
	command -v nft >/dev/null 2>&1 || return 0
	if nft list table inet "$BANWALL_NFT_TABLE" >/dev/null 2>&1; then
		run nft delete table inet "$BANWALL_NFT_TABLE"
		log_ok "Tabelle inet $BANWALL_NFT_TABLE entfernt."
	fi
	# /etc/nftables.conf und /etc/banwall/nftables.nft stellt
	# backup_restore_files wieder her.
}
