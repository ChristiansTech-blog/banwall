#!/usr/bin/env bash
#
# wizard.sh - geführte Ersteinrichtung.
#
# Der Assistent schreibt ausschließlich /etc/banwall/banwall.conf. Er
# verändert das System nicht - das tut erst 'banwall apply'. Diese
# Trennung ist Absicht: Wer sich durch die Fragen klickt, soll danach
# noch einen Trockenlauf ansehen können, bevor irgendetwas passiert.
#
# Jeder Schritt ist eine eigene Funktion, weil die Zusammenfassung am
# Ende zurück in einzelne Schritte springen können muss.

[[ -n "${_BANWALL_WIZARD_LOADED:-}" ]] && return 0
_BANWALL_WIZARD_LOADED=1

# ---------------------------------------------------------------- Layout

_WIZ_BREITE=76

_wiz_breite() {
	local cols
	cols="$(tput cols 2>/dev/null || echo 80)"
	((cols < 60)) && cols=60
	((cols > 100)) && cols=100
	_WIZ_BREITE=$((cols - 4))
}

# Linien werden mit sed gefüllt, nicht mit tr: tr arbeitet byteweise,
# und die Rahmenzeichen sind 3-Byte-UTF-8. Mit tr entsteht Zeichensalat.
_wiz_linie() {
	local zeichen="${1:-─}"
	printf '%*s\n' "$_WIZ_BREITE" '' | sed "s/ /$zeichen/g"
}

# _wiz_titel NUMMER GESAMT TEXT
_wiz_titel() {
	printf '\n%s' "$_C_BLU"
	_wiz_linie '━'
	if [[ -n "${3:-}" ]]; then
		printf '  Schritt %s von %s   %s\n' "$1" "$2" "$3"
	else
		printf '  %s\n' "$1"
	fi
	_wiz_linie '━'
	printf '%s\n' "$_C_RST"
}

# _wiz_absatz TEXT...
# Bricht Fließtext auf die Terminalbreite um. Ohne Umbruch wird ein
# schmales Terminal - und ein Server wird oft aus einem schmalen
# Terminal heraus eingerichtet - unlesbar.
_wiz_absatz() {
	printf '%s\n' "$*" | fold -s -w "$_WIZ_BREITE" | sed 's/^/  /'
}

# _wiz_kasten FARBE MARKE TEXT...
_wiz_kasten() {
	local farbe="$1" marke="$2"
	shift 2
	printf '\n%s  ┌─ %s\n' "$farbe" "$marke"
	printf '%s\n' "$*" | fold -s -w $((_WIZ_BREITE - 4)) | sed "s/^/  │ /"
	printf '  └%s%s\n\n' \
		"$(printf '%*s' $((_WIZ_BREITE - 2)) '' | sed 's/ /─/g')" "$_C_RST"
}

_wiz_hinweis() { _wiz_kasten "$_C_BLU" "Hinweis" "$@"; }
_wiz_warnung() { _wiz_kasten "$_C_YEL" "Achtung" "$@"; }
_wiz_gefahr() { _wiz_kasten "$_C_RED" "Gefahr" "$@"; }
_wiz_gut() { printf '  %s✓%s %s\n' "$_C_GRN" "$_C_RST" "$*"; }
_wiz_schlecht() { printf '  %s✗%s %s\n' "$_C_RED" "$_C_RST" "$*"; }
_wiz_neutral() { printf '  %s·%s %s\n' "$_C_DIM" "$_C_RST" "$*"; }

# --------------------------------------------------------------- Eingabe
#
# Alle Eingaben kommen von /dev/tty, nicht von stdin. Sonst funktioniert
# der Assistent nicht mehr, sobald install.sh selbst aus einer Pipe
# gelesen wird.

# _wiz_frage VARIABLE VORGABE FRAGE
_wiz_frage() {
	local var="$1" vorgabe="$2" frage="$3" eingabe
	printf '\n  %s\n' "$frage"
	if [[ -n "$vorgabe" ]]; then
		printf '  [%s]: ' "$vorgabe"
	else
		printf '  [leer]: '
	fi
	read -r eingabe </dev/tty || eingabe=""
	printf -v "$var" '%s' "${eingabe:-$vorgabe}"
}

# _wiz_jn VARIABLE VORGABE(0|1) FRAGE
_wiz_jn() {
	local var="$1" vorgabe="$2" frage="$3" eingabe hinweis
	if [[ "$vorgabe" == "1" ]]; then hinweis="[J/n]"; else hinweis="[j/N]"; fi
	while true; do
		printf '\n  %s %s: ' "$frage" "$hinweis"
		read -r eingabe </dev/tty || eingabe=""
		case "${eingabe,,}" in
		"") printf -v "$var" '%s' "$vorgabe"; return 0 ;;
		j | ja | y | yes) printf -v "$var" '1'; return 0 ;;
		n | nein | no) printf -v "$var" '0'; return 0 ;;
		*) printf '  %sBitte j oder n eingeben.%s\n' "$_C_YEL" "$_C_RST" ;;
		esac
	done
}

# _wiz_auswahl VARIABLE VORGABE_INDEX FRAGE -- "Beschriftung|Wert" ...
_wiz_auswahl() {
	local var="$1" vorgabe="$2" frage="$3"
	shift 4 # var vorgabe frage --
	local -a optionen=("$@")
	local i eingabe

	printf '\n  %s\n\n' "$frage"
	for i in "${!optionen[@]}"; do
		printf '    %s)  %s\n' "$((i + 1))" "${optionen[$i]%%|*}"
	done

	while true; do
		printf '\n  Auswahl [%s]: ' "$vorgabe"
		read -r eingabe </dev/tty || eingabe=""
		eingabe="${eingabe:-$vorgabe}"
		if [[ "$eingabe" =~ ^[0-9]+$ ]] && ((eingabe >= 1 && eingabe <= ${#optionen[@]})); then
			printf -v "$var" '%s' "${optionen[$((eingabe - 1))]#*|}"
			return 0
		fi
		printf '  %sBitte eine Zahl zwischen 1 und %s eingeben.%s\n' \
			"$_C_YEL" "${#optionen[@]}" "$_C_RST"
	done
}

# _wiz_weiter - Pause, damit ein Hinweis nicht weggescrollt wird.
_wiz_weiter() {
	printf '\n  %s[Enter] zum Fortfahren%s' "$_C_DIM" "$_C_RST"
	read -r </dev/tty || true
	printf '\n'
}

# _wiz_ports_gueltig PORTLISTE
_wiz_ports_gueltig() {
	local p
	for p in $1; do
		[[ "$p" =~ ^[0-9]+$ ]] && ((p >= 1 && p <= 65535)) || return 1
	done
	return 0
}

# -------------------------------------------------------- Systemerkennung
#
# Der Assistent fragt nicht ins Blaue, sondern schaut nach, was auf dem
# Server tatsächlich läuft. Eine Vorgabe, die den laufenden Webserver
# kennt, verhindert mehr Fehlkonfigurationen als jeder Hinweistext.

# _wiz_lauschende_ports PROTOKOLL -> "PORT DIENST" je Zeile
_wiz_lauschende_ports() {
	local proto="$1"
	command -v ss >/dev/null 2>&1 || return 0
	ss -H -lnp "-${proto}" 2>/dev/null |
		awk '{
			split($4, a, ":"); port = a[length(a)]
			if (port ~ /^[0-9]+$/) {
				dienst = "unbekannt"
				if (match($0, /users:\(\("[^"]+/)) {
					dienst = substr($0, RSTART + 9, RLENGTH - 9)
					gsub(/"/, "", dienst)
				}
				print port, dienst
			}
		}' | sort -un -k1,1 | awk '!gesehen[$1]++'
}

_wiz_aktueller_ssh_port() {
	local port=""
	command -v sshd >/dev/null 2>&1 &&
		port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
	[[ -z "$port" ]] && port="$(_wiz_lauschende_ports t | awk '$2 ~ /ssh/ {print $1; exit}')"
	printf '%s' "${port:-22}"
}

# _wiz_key_lage -> setzt WIZ_KEY_USER (Liste) und gibt 0 zurück, wenn
# mindestens ein sudo-Benutzer einen brauchbaren SSH-Key hat.
_wiz_key_lage() {
	local users=() user
	WIZ_KEY_USER=""
	WIZ_SUDO_USER=""

	mapfile -t users < <(_ssh_sudo_users 2>/dev/null)
	WIZ_SUDO_USER="${users[*]}"
	((${#users[@]} == 0)) && return 1

	for user in "${users[@]}"; do
		if _ssh_user_has_key "$user"; then
			WIZ_KEY_USER+="${WIZ_KEY_USER:+ }$user"
		fi
	done
	[[ -n "$WIZ_KEY_USER" ]]
}

_wiz_systemcheck() {
	_wiz_titel "Systemprüfung" "" ""

	local id="unbekannt" version=""
	if [[ -r /etc/os-release ]]; then
		id="$(. /etc/os-release && printf '%s' "${ID:-unbekannt}")"
		version="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
	fi
	if [[ "$id" == "debian" && "$version" == "13" ]]; then
		_wiz_gut "Debian 13 (Trixie) - die getestete Zielplattform"
	elif [[ "$id" == "debian" ]]; then
		_wiz_neutral "Debian $version - getestet ist 13 (Trixie), sollte aber laufen"
	else
		_wiz_schlecht "$id $version - Banwall ist auf Debian ausgelegt"
	fi

	if [[ "$(id -u)" -eq 0 ]]; then
		_wiz_gut "root-Rechte vorhanden"
	else
		_wiz_schlecht "keine root-Rechte - der Assistent kann nichts speichern"
	fi

	if command -v systemctl >/dev/null 2>&1; then
		_wiz_gut "systemd vorhanden"
	else
		_wiz_schlecht "kein systemd gefunden"
	fi

	# Verbindungsweg: wer lokal an der Konsole sitzt, hat ein anderes
	# Risiko als jemand, der über genau die Verbindung eingeloggt ist,
	# die Banwall gleich anfasst.
	if [[ -n "${SSH_CONNECTION:-}" ]]; then
		WIZ_UEBER_SSH=1
		_wiz_neutral "verbunden über SSH von $(awk '{print $1}' <<<"$SSH_CONNECTION")"
	else
		WIZ_UEBER_SSH=0
		_wiz_neutral "lokale Sitzung (keine SSH-Verbindung erkannt)"
	fi

	# SSH-Schlüssel - der wichtigste Punkt der ganzen Prüfung.
	printf '\n'
	if _wiz_key_lage; then
		_wiz_gut "SSH-Key-Login möglich für: $WIZ_KEY_USER"
		WIZ_KEYS_OK=1
	elif [[ -n "$WIZ_SUDO_USER" ]]; then
		_wiz_schlecht "Benutzer mit sudo-Rechten gefunden ($WIZ_SUDO_USER), aber ohne SSH-Key"
		WIZ_KEYS_OK=0
	else
		_wiz_schlecht "kein Benutzer mit sudo-Rechten gefunden"
		WIZ_KEYS_OK=0
	fi

	# Offene Ports
	printf '\n  Aktuell erreichbare Dienste:\n'
	local port dienst leer=1
	while read -r port dienst; do
		[[ -n "$port" ]] || continue
		leer=0
		printf '    %-7s tcp   %s\n' "$port" "$dienst"
	done < <(_wiz_lauschende_ports t)
	while read -r port dienst; do
		[[ -n "$port" ]] || continue
		leer=0
		printf '    %-7s udp   %s\n' "$port" "$dienst"
	done < <(_wiz_lauschende_ports u)
	((leer)) && printf '    (keine gefunden - ist "ss" installiert?)\n'

	if ((WIZ_KEYS_OK == 0)); then
		_wiz_gefahr "Ohne hinterlegten SSH-Key kann Banwall den Passwort-Login nicht abschalten - das würde dich aussperren. Der Assistent lässt Passwort-Logins in diesem Fall an und weist später erneut darauf hin.

So legst du einen Schlüssel an - in einem ZWEITEN Terminal auf deinem Arbeitsplatz, diese Sitzung offen lassen:

  ssh-keygen -t ed25519            # falls noch kein Schlüssel da ist
  ssh-copy-id ${WIZ_SUDO_USER%% *}@$(hostname -I 2>/dev/null | awk '{print $1}')

Danach diesen Assistenten erneut starten: banwall setup"
	fi
}

# --------------------------------------------------------------- Schritte

_WIZ_SCHRITTE=5

_wiz_schritt_firewall() {
	_wiz_titel 1 "$_WIZ_SCHRITTE" "Firewall (nftables)"

	_wiz_absatz "Banwall verbietet eingehende Verbindungen grundsätzlich und erlaubt nur die Ports, die du hier angibst. Ausgehende Verbindungen bleiben unbeschränkt, damit Updates und dein eigener Datenverkehr weiter funktionieren."

	_wiz_gefahr "Der SSH-Port MUSS in dieser Liste stehen. Fehlt er, kommst du nach dem nächsten Neustart nicht mehr auf den Server. Banwall prüft das und bricht sonst ab - verlass dich aber nicht darauf, sondern schau selbst hin."

	printf '  Auf diesem Server lauschen aktuell:\n\n'
	local vorschlag="" port dienst
	while read -r port dienst; do
		[[ -n "$port" ]] || continue
		# Nur auf localhost gebundene Dienste brauchen keine Freigabe -
		# sie sind von außen ohnehin nicht erreichbar. ss zeigt sie
		# trotzdem an, deshalb der Hinweis statt einer Vorauswahl.
		printf '    %-7s %s\n' "$port" "$dienst"
		vorschlag+="${vorschlag:+ }$port"
	done < <(_wiz_lauschende_ports t)

	# Vorschlag eingrenzen: SSH immer, Web wenn erkannt. Alles andere
	# soll bewusst freigegeben werden, nicht aus Versehen.
	local sicher="$WIZ_SSH_PORT"
	local p
	for p in $vorschlag; do
		case "$p" in
		80 | 443) sicher+=" $p" ;;
		esac
	done
	sicher="$(tr ' ' '\n' <<<"$sicher" | sort -un | paste -sd' ' -)"

	_wiz_hinweis "Nur was von außen erreichbar sein muss, gehört in die Liste. Datenbanken, Caches und Verwaltungsoberflächen gehören fast nie dazu - die erreichst du besser über einen SSH-Tunnel."

	while true; do
		_wiz_frage WIZ_TCP_PORTS "$sicher" \
			"Welche TCP-Ports sollen von außen erreichbar sein? (durch Leerzeichen getrennt)"
		if ! _wiz_ports_gueltig "$WIZ_TCP_PORTS"; then
			printf '  %sUngültige Portangabe. Erlaubt sind Zahlen von 1 bis 65535.%s\n' \
				"$_C_RED" "$_C_RST"
			continue
		fi
		# shellcheck disable=SC2086  # Wort-Splitting gewollt: ein Argument je Port
		if ! array_contains "$WIZ_SSH_PORT" $WIZ_TCP_PORTS; then
			printf '  %sDer SSH-Port %s fehlt. Das würde dich aussperren.%s\n' \
				"$_C_RED" "$WIZ_SSH_PORT" "$_C_RST"
			continue
		fi
		break
	done

	while true; do
		_wiz_frage WIZ_UDP_PORTS "$WIZ_UDP_PORTS" \
			"Welche UDP-Ports? (leer lassen, wenn keine - z. B. 51820 für WireGuard)"
		_wiz_ports_gueltig "$WIZ_UDP_PORTS" && break
		printf '  %sUngültige Portangabe.%s\n' "$_C_RED" "$_C_RST"
	done

	_wiz_absatz ""
	_wiz_absatz "Netze mit vollem Zugang umgehen die Portfilterung vollständig und werden von fail2ban nie gesperrt. Sinnvoll für ein Büro-Netz, ein VPN oder ein Monitoring-System."
	_wiz_warnung "Trage hier nur Netze ein, die du selbst kontrollierst. Eine Adresse, die dir nicht dauerhaft gehört - etwa ein wechselnder Heimanschluss - kann später jemand anderem gehören."
	_wiz_frage WIZ_ALLOW_NETS "$WIZ_ALLOW_NETS" \
		"Netze mit vollem Zugang? (z. B. 203.0.113.0/24, leer lassen für keine)"

	_wiz_jn WIZ_ALLOW_PING "$WIZ_ALLOW_PING" \
		"Auf Ping antworten? (empfohlen: ja, erleichtert Fehlersuche und Monitoring)"
	_wiz_jn WIZ_SSH_RATE_LIMIT "$WIZ_SSH_RATE_LIMIT" \
		"Neue SSH-Verbindungen auf 10 pro Minute begrenzen? (bremst Bruteforce)"
}

_wiz_schritt_ssh() {
	_wiz_titel 2 "$_WIZ_SCHRITTE" "SSH-Zugang"

	_wiz_absatz "Das ist der Schritt mit dem größten Risiko. Ein Fehler hier kostet den Zugang zum Server."

	if ((WIZ_KEYS_OK)); then
		_wiz_gut "Key-Login ist möglich für: $WIZ_KEY_USER"
		_wiz_absatz ""
		_wiz_absatz "Damit kannst du Passwort-Logins gefahrlos abschalten. Das ist die wirksamste Einzelmaßnahme gegen Bruteforce-Angriffe: ohne Passwort-Login sind sie schlicht wirkungslos."
	else
		_wiz_gefahr "Es wurde kein Benutzer mit sudo-Rechten UND SSH-Key gefunden. Wenn du Passwort-Logins jetzt abschaltest, kommt niemand mehr auf diesen Server - auch du nicht.

Der Assistent schlägt deshalb vor, Passwort-Logins vorerst anzulassen. Hinterlege einen Schlüssel und starte 'banwall setup' danach erneut."
	fi

	local vorgabe_pw=1 vorgabe_root=1
	((WIZ_KEYS_OK)) || { vorgabe_pw=2; vorgabe_root=3; }

	_wiz_auswahl WIZ_SSH_PASSWORD_AUTH "$vorgabe_pw" \
		"Passwort-Anmeldung über SSH:" -- \
		"abschalten - nur noch Schlüssel (empfohlen)|no" \
		"anlassen - Passwörter bleiben erlaubt (unsicher)|yes"

	if [[ "$WIZ_SSH_PASSWORD_AUTH" == "no" ]] && ((WIZ_KEYS_OK == 0)); then
		_wiz_gefahr "Du schaltest Passwort-Logins ab, obwohl kein Schlüssel gefunden wurde. Banwall wird 'banwall apply' deshalb mit Exit-Code 4 abbrechen und nichts verändern. Das ist der eingebaute Aussperr-Schutz - er greift auch dann, wenn du hier bestätigst."
	fi

	_wiz_auswahl WIZ_SSH_PERMIT_ROOT "$vorgabe_root" \
		"Anmeldung als root über SSH:" -- \
		"verbieten (empfohlen)|no" \
		"nur mit Schlüssel, kein Passwort|prohibit-password" \
		"erlauben (unsicher)|yes"

	_wiz_absatz ""
	_wiz_absatz "Ein anderer SSH-Port verhindert keine gezielten Angriffe, reduziert aber das Grundrauschen automatisierter Scans erheblich."
	_wiz_warnung "Wenn du den Port änderst: die laufende Sitzung bleibt bestehen, aber jeder neue Login braucht 'ssh -p PORT'. Trage den neuen Port unbedingt auch in der Firewall ein - der Assistent fragt danach gleich noch einmal."

	local alter_port="$WIZ_SSH_PORT"
	while true; do
		_wiz_frage WIZ_SSH_PORT "$WIZ_SSH_PORT" "SSH-Port:"
		_wiz_ports_gueltig "$WIZ_SSH_PORT" && break
		printf '  %sUngültige Portangabe.%s\n' "$_C_RED" "$_C_RST"
	done

	# Portwechsel muss in der Firewall nachgezogen werden, sonst schlägt
	# die Validierung später fehl - oder schlimmer, der Zugang fällt weg.
	if [[ "$WIZ_SSH_PORT" != "$alter_port" ]]; then
		WIZ_TCP_PORTS="$(tr ' ' '\n' <<<"$WIZ_TCP_PORTS" |
			grep -vx "$alter_port" | grep -v '^$' | paste -sd' ' -)"
		WIZ_TCP_PORTS="$WIZ_SSH_PORT${WIZ_TCP_PORTS:+ $WIZ_TCP_PORTS}"
		_wiz_hinweis "Die Firewall-Freigabe wurde angepasst: Port $alter_port entfernt, Port $WIZ_SSH_PORT ergänzt. Offene TCP-Ports jetzt: $WIZ_TCP_PORTS"
	fi

	_wiz_absatz ""
	_wiz_frage WIZ_SSH_ALLOW_USERS "$WIZ_SSH_ALLOW_USERS" \
		"Nur bestimmte Benutzer zulassen? (Namen mit Leerzeichen, leer = alle mit Schlüssel)"
}

_wiz_schritt_fail2ban() {
	_wiz_titel 3 "$_WIZ_SCHRITTE" "fail2ban"

	_wiz_absatz "fail2ban liest die Logdateien mit und sperrt Adressen, von denen wiederholt fehlgeschlagene Anmeldungen kommen."
	_wiz_hinweis "Wenn du Passwort-Logins abgeschaltet hast, ist fail2ban nicht mehr die Hauptverteidigung - aber weiterhin nützlich: es hält Logdateien sauber und bremst Angreifer, bevor sie Rechenzeit kosten."

	_wiz_jn WIZ_ENABLE_FAIL2BAN "$WIZ_ENABLE_FAIL2BAN" "fail2ban einrichten?"
	((WIZ_ENABLE_FAIL2BAN)) || return 0

	_wiz_auswahl WIZ_F2B_PROFIL 2 "Wie streng soll gesperrt werden?" -- \
		"nachsichtig - 10 Versuche in 10 Minuten, 1 Stunde Sperre|10|10m|1h" \
		"ausgewogen - 5 Versuche in 10 Minuten, 1 Stunde Sperre (empfohlen)|5|10m|1h" \
		"streng - 3 Versuche in 5 Minuten, 24 Stunden Sperre|3|5m|24h"
	IFS='|' read -r WIZ_F2B_MAXRETRY WIZ_F2B_FINDTIME WIZ_F2B_BANTIME <<<"$WIZ_F2B_PROFIL"

	_wiz_warnung "Auch du kannst dich aussperren, wenn du dich mehrfach vertippst. Die Sperre läuft nach $WIZ_F2B_BANTIME von selbst ab. Netze aus Schritt 1 (voller Zugang) sind davon ausgenommen."

	local webserver_da=0
	_wiz_lauschende_ports t | awk '$1==80 || $1==443 {gefunden=1} END{exit !gefunden}' && webserver_da=1
	if ((webserver_da)); then
		_wiz_hinweis "Auf Port 80 oder 443 läuft ein Dienst. Zusätzliche Jails für nginx und Apache können sinnvoll sein."
	fi
	_wiz_jn WIZ_F2B_WEBSERVER "$webserver_da" \
		"Zusätzliche Regeln für nginx und Apache? (nur sinnvoll, wenn ein Webserver läuft)"
}

_wiz_schritt_updates() {
	_wiz_titel 4 "$_WIZ_SCHRITTE" "Automatische Sicherheitsupdates"

	_wiz_absatz "Banwall richtet unattended-upgrades so ein, dass ausschließlich Sicherheitsaktualisierungen automatisch eingespielt werden. Normale Paketupdates bleiben deine Entscheidung."
	_wiz_hinweis "Das ist bewusst eingeschränkt: Alle Updates automatisch einzuspielen ist ein Verfügbarkeitsrisiko. Ungepatchte Sicherheitslücken sind aber das größere Risiko - deshalb diese Aufteilung."

	_wiz_jn WIZ_ENABLE_UPDATES "$WIZ_ENABLE_UPDATES" "Automatische Sicherheitsupdates einrichten?"
	((WIZ_ENABLE_UPDATES)) || return 0

	_wiz_absatz ""
	_wiz_absatz "Manche Updates - vor allem Kernel-Aktualisierungen - wirken erst nach einem Neustart."
	_wiz_warnung "Automatischer Neustart bedeutet: Der Server kann nachts ohne Vorwarnung neu starten. Dienste, die nicht sauber automatisch hochkommen, sind danach weg. Ohne automatischen Neustart läuft der Server mit dem alten Kernel weiter, bis du selbst neu startest - 'ls /var/run/reboot-required' zeigt, ob das ansteht."

	_wiz_jn WIZ_UPDATES_AUTOREBOOT "$WIZ_UPDATES_AUTOREBOOT" \
		"Automatischen Neustart erlauben, wenn ein Update ihn erfordert?"
	if ((WIZ_UPDATES_AUTOREBOOT)); then
		_wiz_frage WIZ_UPDATES_REBOOT_TIME "$WIZ_UPDATES_REBOOT_TIME" \
			"Zu welcher Uhrzeit darf neu gestartet werden? (HH:MM)"
	fi
}

_wiz_schritt_blocklist() {
	_wiz_titel 5 "$_WIZ_SCHRITTE" "IP-Blocklisten"

	_wiz_absatz "Banwall kann Listen bekannter Angreiferadressen herunterladen und in die Firewall laden. Voreingestellt ist die von IPv64 gepflegte Fassung der blocklist.de-Liste: rund 26.000 Adressen, die durch SSH-, Mail- oder Web-Angriffe auffällig geworden sind."

	_wiz_hinweis "Was du hier einträgst, entscheidet mit, wen dein Server aussperrt. Banwall entfernt aus jeder Liste automatisch: deine eigenen Adressen, die Gegenstelle deiner laufenden SSH-Sitzung, private Netze, Link-Local und CGNAT. Gegen eine schlecht gepflegte Quelle hilft das nur begrenzt - nimm wenige Listen, denen du vertraust.

Die Listen stammen von IPv64.net, das sie aufbereitet und kostenlos bereitstellt; Originalquelle ist blocklist.de. Es gibt keine Verfügbarkeitsgarantie, und IPv64 bittet darum, den Dienst nicht zu überlasten - deshalb ist täglich die Empfehlung."

	_wiz_jn WIZ_ENABLE_BLOCKLIST "$WIZ_ENABLE_BLOCKLIST" "IP-Blocklisten verwenden?"
	((WIZ_ENABLE_BLOCKLIST)) || { WIZ_BLOCKLIST_URLS=""; return 0; }

	local ipv64="https://ipv64.net/blocklists"
	_wiz_auswahl WIZ_BLOCKLIST_URLS 1 "Welche Listen sollen verwendet werden?" -- \
		"blocklist.de über IPv64 - ~26.000 Einzeladressen (empfohlen)|$ipv64/ipv64_blocklist_blocklistde_all.txt" \
		"blocklist.de + Spamhaus DROP - zusätzlich ~1.500 Netze|$ipv64/ipv64_blocklist_blocklistde_all.txt $ipv64/ipv64_blocklist_spamhaus_drop.txt" \
		"IPv64 komplett - ~32.700 Einträge, enthält Netze bis /16|$ipv64/ipv64_blocklist_all.txt" \
		"eigene Quellen angeben|EIGENE"

	if [[ "$WIZ_BLOCKLIST_URLS" == "EIGENE" ]]; then
		while true; do
			_wiz_frage WIZ_BLOCKLIST_URLS "" \
				"URLs der Blocklisten (durch Leerzeichen getrennt, nur https)"
			local url fehler=0
			for url in $WIZ_BLOCKLIST_URLS; do
				[[ "$url" == https://* ]] || {
					printf '  %s%s ist kein https - über http könnte jeder die Liste fälschen.%s\n' \
						"$_C_RED" "$url" "$_C_RST"
					fehler=1
				}
			done
			((fehler)) || [[ -z "$WIZ_BLOCKLIST_URLS" ]] || break
			[[ -z "$WIZ_BLOCKLIST_URLS" ]] && {
				printf '  %sMindestens eine Quelle angeben.%s\n' "$_C_RED" "$_C_RST"
			}
		done
	fi

	if [[ "$WIZ_BLOCKLIST_URLS" == *"ipv64_blocklist_all"* ]]; then
		_wiz_warnung "Die komplette IPv64-Liste enthält ganze Netze bis /16. Damit sperrst du auch Adressen, die selbst nie auffällig geworden sind. Auf einem Server mit Publikumsverkehr kann das echte Nutzer treffen."
	fi

	_wiz_auswahl WIZ_BLOCKLIST_INTERVAL 2 "Wie oft sollen die Listen aktualisiert werden?" -- \
		"stündlich - schnellster Schutz, mehr Last beim Anbieter|hourly" \
		"täglich (empfohlen)|daily" \
		"wöchentlich|weekly"
}

# --------------------------------------------------------- Zusammenfassung

_wiz_zeile() { printf '     %-30s %s\n' "$1" "$2"; }
_wiz_gruppe() { printf '\n  %s%s) %s%s\n' "$_C_BLU" "$1" "$2" "$_C_RST"; }

_wiz_ja_nein() { (($1)) && printf 'ja' || printf 'nein'; }

_wiz_zusammenfassung_zeigen() {
	_wiz_titel "Zusammenfassung" "" ""
	_wiz_absatz "So wird Banwall eingerichtet. Bis hierher wurde nichts verändert."

	_wiz_gruppe 1 "Firewall (nftables)"
	_wiz_zeile "eingehend" "verboten, außer den Ports unten"
	_wiz_zeile "ausgehend" "erlaubt"
	_wiz_zeile "offene TCP-Ports" "${WIZ_TCP_PORTS:-keine}"
	_wiz_zeile "offene UDP-Ports" "${WIZ_UDP_PORTS:-keine}"
	_wiz_zeile "Netze mit vollem Zugang" "${WIZ_ALLOW_NETS:-keine}"
	_wiz_zeile "Ping beantworten" "$(_wiz_ja_nein "$WIZ_ALLOW_PING")"
	_wiz_zeile "SSH-Rate-Limit" "$(_wiz_ja_nein "$WIZ_SSH_RATE_LIMIT")"

	_wiz_gruppe 2 "SSH-Zugang"
	_wiz_zeile "Port" "$WIZ_SSH_PORT"
	if [[ "$WIZ_SSH_PASSWORD_AUTH" == "no" ]]; then
		_wiz_zeile "Passwort-Anmeldung" "abgeschaltet"
	else
		printf '     %-30s %sERLAUBT%s\n' "Passwort-Anmeldung" "$_C_YEL" "$_C_RST"
	fi
	case "$WIZ_SSH_PERMIT_ROOT" in
	no) _wiz_zeile "root-Anmeldung" "verboten" ;;
	prohibit-password) _wiz_zeile "root-Anmeldung" "nur mit Schlüssel" ;;
	yes) printf '     %-30s %sERLAUBT%s\n' "root-Anmeldung" "$_C_YEL" "$_C_RST" ;;
	esac
	_wiz_zeile "zugelassene Benutzer" "${WIZ_SSH_ALLOW_USERS:-alle mit Schlüssel}"

	_wiz_gruppe 3 "fail2ban"
	if ((WIZ_ENABLE_FAIL2BAN)); then
		_wiz_zeile "Sperre nach" "$WIZ_F2B_MAXRETRY Versuchen in $WIZ_F2B_FINDTIME"
		_wiz_zeile "Sperrdauer" "$WIZ_F2B_BANTIME"
		_wiz_zeile "Webserver-Regeln" "$(_wiz_ja_nein "$WIZ_F2B_WEBSERVER")"
	else
		_wiz_zeile "" "wird nicht eingerichtet"
	fi

	_wiz_gruppe 4 "Automatische Sicherheitsupdates"
	if ((WIZ_ENABLE_UPDATES)); then
		_wiz_zeile "Security-Updates" "automatisch"
		if ((WIZ_UPDATES_AUTOREBOOT)); then
			_wiz_zeile "Neustart" "erlaubt um $WIZ_UPDATES_REBOOT_TIME"
		else
			_wiz_zeile "Neustart" "nur von Hand"
		fi
	else
		_wiz_zeile "" "wird nicht eingerichtet"
	fi

	_wiz_gruppe 5 "IP-Blocklisten"
	if ((WIZ_ENABLE_BLOCKLIST)); then
		local url
		local erste=1
		for url in $WIZ_BLOCKLIST_URLS; do
			if ((erste)); then
				_wiz_zeile "Quellen" "${url##*/}"
				erste=0
			else
				_wiz_zeile "" "${url##*/}"
			fi
		done
		_wiz_zeile "Aktualisierung" "$WIZ_BLOCKLIST_INTERVAL"
	else
		_wiz_zeile "" "wird nicht eingerichtet"
	fi

	# Was der Nutzer nach dem Bestätigen wissen muss.
	printf '\n'
	_wiz_linie
	printf '\n  %sWas danach passiert%s\n\n' "$_C_BLU" "$_C_RST"
	_wiz_absatz "Der Assistent speichert diese Einstellungen nach $BANWALL_CONFIG_FILE. Verändert wird das System dadurch noch nicht - das macht erst 'banwall apply'."

	if [[ "$WIZ_SSH_PASSWORD_AUTH" == "no" ]] && ((WIZ_KEYS_OK == 0)); then
		_wiz_gefahr "Passwort-Logins sollen abgeschaltet werden, aber es wurde kein Benutzer mit sudo-Rechten und SSH-Key gefunden. 'banwall apply' wird deshalb mit Exit-Code 4 abbrechen, ohne etwas zu ändern. Hinterlege zuerst einen Schlüssel."
	elif ((WIZ_UEBER_SSH)); then
		_wiz_warnung "Du bist über SSH verbunden - also über genau die Verbindung, die Banwall gleich anfasst. Lass diese Sitzung offen, bis du dich in einem ZWEITEN Terminal erfolgreich neu angemeldet hast:

  ssh -p $WIZ_SSH_PORT ${WIZ_KEY_USER%% *}@$(hostname -I 2>/dev/null | awk '{print $1}')

Klappt das nicht, nimmt 'banwall rollback' in der noch offenen Sitzung alles zurück."
	fi
}

_wiz_zusammenfassung() {
	local auswahl
	while true; do
		_wiz_zusammenfassung_zeigen
		printf '\n'
		_wiz_linie
		printf '\n  Nummer eingeben, um einen Bereich zu ändern.\n'
		printf '  %s[Enter]%s speichern   %sa%s abbrechen\n' \
			"$_C_GRN" "$_C_RST" "$_C_RED" "$_C_RST"
		printf '\n  Auswahl: '
		read -r auswahl </dev/tty || auswahl="a"
		printf '\n'

		case "${auswahl,,}" in
		"") return 0 ;;
		a | abbrechen | q) return 1 ;;
		1) _wiz_schritt_firewall ;;
		2) _wiz_schritt_ssh ;;
		3) _wiz_schritt_fail2ban ;;
		4) _wiz_schritt_updates ;;
		5) _wiz_schritt_blocklist ;;
		*) printf '\n  %sBitte 1 bis 5, [Enter] oder a eingeben.%s\n' "$_C_YEL" "$_C_RST" ;;
		esac
	done
}

# ------------------------------------------------------------- Speichern

_wiz_schreiben() {
	local ziel="$BANWALL_CONFIG_FILE"

	mkdir -p "$(dirname "$ziel")"
	chmod 700 "$(dirname "$ziel")"

	# Bestehende Konfiguration sichern - jemand könnte sie von Hand
	# angepasst haben und die Änderung nach dem Lauf vermissen.
	if [[ -f "$ziel" ]]; then
		local sicherung
		sicherung="${ziel}.$(date +%Y%m%d-%H%M%S).bak"
		cp -a "$ziel" "$sicherung"
		printf '\n  Bisherige Konfiguration gesichert: %s\n' "$sicherung"
	fi

	cat >"$ziel" <<CONF
# $ziel
#
# Erzeugt von 'banwall setup' am $(date '+%d.%m.%Y um %H:%M Uhr').
# Diese Datei kann von Hand bearbeitet werden. Erlaubt sind
# ausschließlich einfache Zuweisungen an BANWALL_*; alles andere lehnt
# Banwall beim Laden ab.
#
# Assistent erneut starten:  banwall setup
# Alle Optionen im Überblick: $BANWALL_SHARE_DIR/banwall.conf.example

# --- Module ---
BANWALL_ENABLE_NFTABLES=1
BANWALL_ENABLE_FAIL2BAN=$WIZ_ENABLE_FAIL2BAN
BANWALL_ENABLE_SSH=1
BANWALL_ENABLE_UPDATES=$WIZ_ENABLE_UPDATES
BANWALL_ENABLE_BLOCKLIST=$WIZ_ENABLE_BLOCKLIST

# --- Firewall ---
BANWALL_TCP_PORTS="$WIZ_TCP_PORTS"
BANWALL_UDP_PORTS="$WIZ_UDP_PORTS"
BANWALL_ALLOW_NETS="$WIZ_ALLOW_NETS"
BANWALL_ALLOW_PING=$WIZ_ALLOW_PING
BANWALL_SSH_RATE_LIMIT=$WIZ_SSH_RATE_LIMIT

# --- SSH ---
BANWALL_SSH_PORT="$WIZ_SSH_PORT"
BANWALL_SSH_PERMIT_ROOT="$WIZ_SSH_PERMIT_ROOT"
BANWALL_SSH_PASSWORD_AUTH="$WIZ_SSH_PASSWORD_AUTH"
BANWALL_SSH_ALLOW_USERS="$WIZ_SSH_ALLOW_USERS"

# --- fail2ban ---
BANWALL_F2B_BANTIME="$WIZ_F2B_BANTIME"
BANWALL_F2B_FINDTIME="$WIZ_F2B_FINDTIME"
BANWALL_F2B_MAXRETRY="$WIZ_F2B_MAXRETRY"
BANWALL_F2B_WEBSERVER=$WIZ_F2B_WEBSERVER

# --- Automatische Updates ---
BANWALL_UPDATES_AUTOREBOOT=$WIZ_UPDATES_AUTOREBOOT
BANWALL_UPDATES_REBOOT_TIME="$WIZ_UPDATES_REBOOT_TIME"

# --- Blocklisten ---
BANWALL_BLOCKLIST_URLS="$WIZ_BLOCKLIST_URLS"
BANWALL_BLOCKLIST_INTERVAL="$WIZ_BLOCKLIST_INTERVAL"
BANWALL_BLOCKLIST_MAX_ENTRIES=200000
BANWALL_BLOCKLIST_MAX_BYTES=20971520
BANWALL_BLOCKLIST_TIMEOUT=30
CONF
	chmod 600 "$ziel"
	chown root:root "$ziel" 2>/dev/null || true

	_wiz_gut "Gespeichert: $ziel"
}

# --------------------------------------------------------------- Ablauf

_wiz_vorgaben() {
	# Bestehende Konfiguration als Ausgangspunkt, sonst die eingebauten
	# Standardwerte. So ist 'banwall setup' auch zum Nachjustieren
	# brauchbar und wirft nicht jedes Mal alles weg.
	WIZ_SSH_PORT="$(_wiz_aktueller_ssh_port)"
	WIZ_TCP_PORTS="${BANWALL_TCP_PORTS:-$WIZ_SSH_PORT}"
	WIZ_UDP_PORTS="${BANWALL_UDP_PORTS:-}"
	WIZ_ALLOW_NETS="${BANWALL_ALLOW_NETS:-}"
	WIZ_ALLOW_PING="${BANWALL_ALLOW_PING:-1}"
	WIZ_SSH_RATE_LIMIT="${BANWALL_SSH_RATE_LIMIT:-1}"
	WIZ_SSH_PERMIT_ROOT="${BANWALL_SSH_PERMIT_ROOT:-no}"
	WIZ_SSH_PASSWORD_AUTH="${BANWALL_SSH_PASSWORD_AUTH:-no}"
	WIZ_SSH_ALLOW_USERS="${BANWALL_SSH_ALLOW_USERS:-}"
	WIZ_ENABLE_FAIL2BAN="${BANWALL_ENABLE_FAIL2BAN:-1}"
	WIZ_F2B_BANTIME="${BANWALL_F2B_BANTIME:-1h}"
	WIZ_F2B_FINDTIME="${BANWALL_F2B_FINDTIME:-10m}"
	WIZ_F2B_MAXRETRY="${BANWALL_F2B_MAXRETRY:-5}"
	WIZ_F2B_WEBSERVER="${BANWALL_F2B_WEBSERVER:-0}"
	WIZ_ENABLE_UPDATES="${BANWALL_ENABLE_UPDATES:-1}"
	WIZ_UPDATES_AUTOREBOOT="${BANWALL_UPDATES_AUTOREBOOT:-0}"
	WIZ_UPDATES_REBOOT_TIME="${BANWALL_UPDATES_REBOOT_TIME:-04:00}"
	WIZ_ENABLE_BLOCKLIST="${BANWALL_ENABLE_BLOCKLIST:-1}"
	WIZ_BLOCKLIST_URLS="${BANWALL_BLOCKLIST_URLS:-}"
	WIZ_BLOCKLIST_INTERVAL="${BANWALL_BLOCKLIST_INTERVAL:-daily}"
	WIZ_KEYS_OK=0
	WIZ_KEY_USER=""
	WIZ_SUDO_USER=""
	WIZ_UEBER_SSH=0
}

_wiz_willkommen() {
	clear 2>/dev/null || true
	printf '\n%s' "$_C_BLU"
	_wiz_linie '━'
	printf '  Banwall %s - Ersteinrichtung\n' "$BANWALL_VERSION"
	_wiz_linie '━'
	printf '%s\n' "$_C_RST"

	_wiz_absatz "Dieser Assistent führt durch die Sicherheitsgrundeinrichtung dieses Servers. Er stellt Fragen zu fünf Bereichen:"
	printf '\n'
	printf '    1  Firewall          welche Ports von außen erreichbar sind\n'
	printf '    2  SSH-Zugang        Passwort-Login, root-Login, Port\n'
	printf '    3  fail2ban          Sperren nach fehlgeschlagenen Anmeldungen\n'
	printf '    4  Updates           automatische Sicherheitsaktualisierungen\n'
	printf '    5  Blocklisten       bekannte Angreiferadressen sperren\n'
	printf '\n'
	_wiz_absatz "Am Ende siehst du eine Zusammenfassung und kannst jeden Bereich noch einmal ändern, bevor irgendetwas gespeichert wird."

	_wiz_hinweis "Der Assistent verändert das System NICHT. Er schreibt nur eine Konfigurationsdatei. Erst 'banwall apply' setzt die Einstellungen um - und auch das kannst du vorher mit 'banwall apply --dry-run' ansehen."

	if [[ -n "${SSH_CONNECTION:-}" ]]; then
		_wiz_warnung "Du arbeitest über SSH. Öffne jetzt ein zweites Terminal zu diesem Server und lass es offen. Falls nach 'banwall apply' etwas schiefgeht, ist das deine Rückfahrkarte - dort nimmt 'banwall rollback' alles zurück."
	fi

	_wiz_weiter
}

_wiz_abschluss() {
	_wiz_titel "Fertig" "" ""
	_wiz_absatz "Die Konfiguration ist gespeichert. Das System ist noch unverändert."
	printf '\n  Nächste Schritte:\n\n'
	printf '    %s1.%s banwall apply --dry-run     ansehen, was passieren würde\n' "$_C_BLU" "$_C_RST"
	printf '    %s2.%s banwall apply               anwenden\n' "$_C_BLU" "$_C_RST"
	printf '    %s3.%s in einem NEUEN Terminal anmelden - bevor du dieses schließt\n' "$_C_BLU" "$_C_RST"
	printf '\n'
	printf '  Weitere Befehle:\n\n'
	printf '    banwall status              zeigt den Ist-Zustand\n'
	printf '    banwall rollback            nimmt alle Änderungen zurück\n'
	printf '    banwall setup               diesen Assistenten erneut starten\n'
	printf '\n'

	local frage_dry frage_apply
	_wiz_jn frage_dry 1 "Jetzt einen Trockenlauf ansehen? (ändert nichts)"
	if ((frage_dry)); then
		printf '\n'
		_wiz_linie
		( BANWALL_DRY_RUN=1 BANWALL_ASSUME_YES=1 cmd_apply ) || true
		_wiz_linie
	fi

	printf '\n'
	_wiz_jn frage_apply 0 "Einstellungen jetzt anwenden? ('banwall apply')"
	if ((frage_apply)); then
		if ((WIZ_UEBER_SSH)); then
			_wiz_warnung "Letzte Erinnerung: Halte diese Sitzung offen und prüfe den Zugang in einem zweiten Terminal, bevor du sie schließt."
			local sicher
			_wiz_jn sicher 0 "Verstanden - anwenden?"
			((sicher)) || { printf '\n  Abgebrochen. Später: banwall apply\n\n'; return 0; }
		fi
		printf '\n'
		cmd_apply
	else
		printf '\n  Nichts angewendet. Wenn du soweit bist: %sbanwall apply%s\n\n' \
			"$_C_GRN" "$_C_RST"
	fi
}

# banwall_wizard_run - Einstiegspunkt für 'banwall setup' und install.sh.
banwall_wizard_run() {
	require_root

	# Ohne Terminal gibt es nichts zu führen. Das ist kein Fehler -
	# automatisierte Installationen legen die Konfigurationsdatei selbst
	# an - aber es muss gesagt werden.
	if [[ ! -r /dev/tty ]] || [[ ! -t 1 ]]; then
		log_warn "Kein Terminal verfügbar - der Einrichtungsassistent wird übersprungen."
		log_info "Konfiguration von Hand anlegen:"
		log_info "  cp $BANWALL_SHARE_DIR/banwall.conf.example $BANWALL_CONFIG_FILE"
		log_info "  chmod 600 $BANWALL_CONFIG_FILE"
		log_info "Oder später in einer interaktiven Sitzung: banwall setup"
		return 0
	fi

	_wiz_breite
	_wiz_vorgaben
	_wiz_willkommen
	_wiz_systemcheck
	_wiz_weiter

	_wiz_schritt_firewall
	_wiz_schritt_ssh
	_wiz_schritt_fail2ban
	_wiz_schritt_updates
	_wiz_schritt_blocklist

	if ! _wiz_zusammenfassung; then
		printf '\n  %sAbgebrochen. Es wurde nichts gespeichert.%s\n\n' "$_C_YEL" "$_C_RST"
		return 1
	fi

	_wiz_schreiben

	# Gegenprüfung: Was der Assistent geschrieben hat, muss auch durch
	# die reguläre Validierung kommen. Sonst hätte der Nutzer eine Datei,
	# die 'banwall apply' beim nächsten Start ablehnt.
	if ! ( config_load ) >/dev/null 2>&1; then
		log_error "Die geschriebene Konfiguration wird von Banwall abgelehnt."
		log_error "Das ist ein Fehler im Assistenten - bitte melden."
		( config_load ) 2>&1 | tail -3
		return 1
	fi
	_wiz_gut "Konfiguration geprüft - gültig"

	_wiz_abschluss
}
