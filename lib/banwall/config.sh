#!/usr/bin/env bash
#
# config.sh - Laden und Prüfen von /etc/banwall/banwall.conf.
#
# Die Konfigurationsdatei ist eine Shell-Datei mit KEY=wert und wird
# gesourct. Das ist für ein Bash-Tool die schlankste Lösung, bedeutet
# aber: wer die Datei schreiben darf, führt Code als root aus. Deshalb
# prüft config_load Eigentümer und Rechte, bevor sie geladen wird.
#
# Die Standardwerte weiter unten werden hier nur zugewiesen und in den
# Modulen gelesen - das ist der Zweck der Datei, keine tote Zuweisung.
# shellcheck disable=SC2034

[[ -n "${_BANWALL_CONFIG_LOADED:-}" ]] && return 0
_BANWALL_CONFIG_LOADED=1

: "${BANWALL_CONFIG_FILE:=/etc/banwall/banwall.conf}"
: "${BANWALL_CONFIG_DIR:=/etc/banwall}"

# --- Standardwerte -----------------------------------------------------
#
# Bewusst konservativ: Ohne Konfigurationsdatei macht Banwall nur das,
# was auf jedem Server richtig ist, und lässt SSH offen.

# Module. Jeder Schritt einzeln schaltbar.
BANWALL_ENABLE_NFTABLES=1
BANWALL_ENABLE_FAIL2BAN=1
BANWALL_ENABLE_SSH=1
BANWALL_ENABLE_UPDATES=1
BANWALL_ENABLE_BLOCKLIST=1

# nftables
BANWALL_TCP_PORTS="22"          # eingehend erlaubte TCP-Ports
BANWALL_UDP_PORTS=""            # eingehend erlaubte UDP-Ports
BANWALL_ALLOW_PING=1            # ICMP echo beantworten
BANWALL_ALLOW_NETS=""           # Netze mit vollem Zugang, z. B. Admin-VPN
BANWALL_SSH_RATE_LIMIT=1        # neue SSH-Verbindungen begrenzen

# SSH
BANWALL_SSH_PORT="22"
BANWALL_SSH_PERMIT_ROOT="no"
BANWALL_SSH_PASSWORD_AUTH="no"
BANWALL_SSH_ALLOW_USERS=""      # leer = alle mit gültigem Key

# fail2ban
BANWALL_F2B_BANTIME="1h"
BANWALL_F2B_FINDTIME="10m"
BANWALL_F2B_MAXRETRY="5"
BANWALL_F2B_WEBSERVER=0         # zusätzliche Jails für nginx/apache

# unattended-upgrades
BANWALL_UPDATES_AUTOREBOOT=0
BANWALL_UPDATES_REBOOT_TIME="04:00"

# Blocklisten
# Vorgabe ist die von IPv64 gepflegte Fassung der blocklist.de-Liste:
# rund 26.000 Adressen, die durch SSH-, Mail- und Web-Angriffe auffällig
# geworden sind. Mehrere Quellen werden durch Leerzeichen getrennt.
BANWALL_BLOCKLIST_URLS="https://ipv64.net/blocklists/ipv64_blocklist_blocklistde_all.txt"
BANWALL_BLOCKLIST_INTERVAL="daily"
BANWALL_BLOCKLIST_MAX_ENTRIES=200000
BANWALL_BLOCKLIST_MAX_BYTES=$((20 * 1024 * 1024))
BANWALL_BLOCKLIST_TIMEOUT=30

readonly _BANWALL_BOOL_VARS=(
	BANWALL_ENABLE_NFTABLES BANWALL_ENABLE_FAIL2BAN BANWALL_ENABLE_SSH
	BANWALL_ENABLE_UPDATES BANWALL_ENABLE_BLOCKLIST BANWALL_ALLOW_PING
	BANWALL_SSH_RATE_LIMIT BANWALL_F2B_WEBSERVER BANWALL_UPDATES_AUTOREBOOT
)

config_load() {
	if [[ ! -e "$BANWALL_CONFIG_FILE" ]]; then
		log_warn "Keine Konfiguration unter $BANWALL_CONFIG_FILE - nutze Standardwerte."
		log_warn "Vorlage: $BANWALL_SHARE_DIR/banwall.conf.example"
		config_validate
		return 0
	fi

	[[ -f "$BANWALL_CONFIG_FILE" ]] ||
		die 3 "$BANWALL_CONFIG_FILE ist keine reguläre Datei."

	# Die Datei wird gesourct - im Normalfall als root. Gehört sie jemand
	# anderem oder ist sie für andere schreibbar, wäre das eine
	# Rechteausweitung. Erlaubt ist root oder der ausführende Benutzer
	# selbst; dieselbe Regel wendet OpenSSH auf authorized_keys an. Im
	# Regelbetrieb läuft Banwall als root, dort bleibt nur root übrig.
	local owner perms
	owner="$(stat -c '%u' "$BANWALL_CONFIG_FILE")"
	perms="$(stat -c '%a' "$BANWALL_CONFIG_FILE")"
	if [[ "$owner" != "0" && "$owner" != "$(id -u)" ]]; then
		die 3 "$BANWALL_CONFIG_FILE gehört weder root noch dir (uid $owner). Abbruch."
	fi
	if [[ "${perms: -1}" =~ [2367] || "${perms: -2:1}" =~ [2367] ]]; then
		die 3 "$BANWALL_CONFIG_FILE ist für Gruppe/andere schreibbar ($perms). 'chmod 600' setzen."
	fi

	# Vorprüfung, bevor gesourct wird. config_validate allein genügt hier
	# nicht: sie läuft erst NACH dem Sourcen, und da wäre alles, was in
	# der Datei steht, längst als root ausgeführt worden. Erlaubt sind
	# ausschließlich Zuweisungen an BANWALL_*, Kommentare und Leerzeilen -
	# damit bleibt von der Bequemlichkeit des Sourcens nur das Zuweisen
	# übrig, nicht das Ausführen.
	# Das Muster deckt die GESAMTE Zeile ab, nicht nur ihren Anfang.
	# Sonst käme 'BANWALL_TCP_PORTS="22"; curl ... | sh' durch: die Zeile
	# beginnt mit einer gültigen Zuweisung, und alles dahinter würde beim
	# Sourcen als root ausgeführt.
	#
	# Erlaubt sind genau drei Formen des Werts:
	#   "..."  ohne $ und ohne Backtick (sonst Expansion/Substitution)
	#   '...'  beliebig, weil die Shell darin nichts auswertet
	#   ein einfaches Wort aus Zeichen, die in Ports, Pfaden und URLs
	#   vorkommen - kein ; | & und kein Leerzeichen
	local muster='^[[:space:]]*BANWALL_[A-Z0-9_]+=("[^"$`]*"|'"'"'[^'"'"']*'"'"'|[A-Za-z0-9_.:/,+*@%=?-]*)[[:space:]]*(#.*)?$'
	local zeile nr=0
	while IFS= read -r zeile || [[ -n "$zeile" ]]; do
		nr=$((nr + 1))
		[[ "$zeile" =~ ^[[:space:]]*(#|$) ]] && continue
		[[ "$zeile" =~ $muster ]] ||
			die 3 "$BANWALL_CONFIG_FILE Zeile $nr ist keine einfache BANWALL_-Zuweisung: '${zeile:0:60}'"
	done <"$BANWALL_CONFIG_FILE"

	log_debug "lade Konfiguration: $BANWALL_CONFIG_FILE"
	# shellcheck source=/dev/null
	source "$BANWALL_CONFIG_FILE" ||
		die 3 "$BANWALL_CONFIG_FILE ist syntaktisch fehlerhaft."

	config_validate
}

# config_module_enabled NAME -> 0, wenn das Modul laufen soll.
config_module_enabled() {
	local var="BANWALL_ENABLE_${1^^}"
	[[ "${!var:-0}" == "1" ]]
}

_config_check_ports() {
	local varname="$1" port
	for port in ${!varname}; do
		if [[ ! "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
			die 3 "$varname enthält einen ungültigen Port: '$port' (erlaubt: 1-65535)."
		fi
	done
}

config_validate() {
	local var value

	for var in "${_BANWALL_BOOL_VARS[@]}"; do
		value="${!var:-}"
		[[ "$value" == "0" || "$value" == "1" ]] ||
			die 3 "$var muss 0 oder 1 sein, ist aber '$value'."
	done

	_config_check_ports BANWALL_TCP_PORTS
	_config_check_ports BANWALL_UDP_PORTS
	_config_check_ports BANWALL_SSH_PORT

	[[ "$BANWALL_SSH_PERMIT_ROOT" =~ ^(yes|no|prohibit-password)$ ]] ||
		die 3 "BANWALL_SSH_PERMIT_ROOT muss yes, no oder prohibit-password sein."
	[[ "$BANWALL_SSH_PASSWORD_AUTH" =~ ^(yes|no)$ ]] ||
		die 3 "BANWALL_SSH_PASSWORD_AUTH muss yes oder no sein."

	# Der SSH-Port muss in der Firewall offen sein, sonst sperrt sich der
	# Admin beim nächsten Login aus.
	if ((BANWALL_ENABLE_NFTABLES)) && ((BANWALL_ENABLE_SSH)); then
		# shellcheck disable=SC2086  # Wort-Splitting gewollt: ein Argument je Port
		array_contains "$BANWALL_SSH_PORT" $BANWALL_TCP_PORTS ||
			die 3 "SSH-Port $BANWALL_SSH_PORT fehlt in BANWALL_TCP_PORTS ('$BANWALL_TCP_PORTS'). Das würde dich aussperren."
	fi

	local url
	for url in $BANWALL_BLOCKLIST_URLS; do
		[[ "$url" == https://* ]] ||
			die 3 "Blocklist-URL '$url' ist kein https. Über http könnte jeder die Liste fälschen."
	done

	if ((BANWALL_ENABLE_BLOCKLIST)) && [[ -z "${BANWALL_BLOCKLIST_URLS// /}" ]]; then
		die 3 "Blocklist-Modul aktiviert, aber BANWALL_BLOCKLIST_URLS ist leer."
	fi

	# Das Intervall geht unverändert in OnCalendar=. systemd selbst ist
	# die einzige verlässliche Instanz für diese Syntax - eine eigene
	# Regex würde entweder gültige Ausdrücke ablehnen oder Unsinn
	# durchlassen, der erst beim daemon-reload auffliegt.
	if command -v systemd-analyze >/dev/null 2>&1; then
		systemd-analyze calendar "$BANWALL_BLOCKLIST_INTERVAL" >/dev/null 2>&1 ||
			die 3 "BANWALL_BLOCKLIST_INTERVAL ist kein gültiger systemd-Kalenderausdruck: '$BANWALL_BLOCKLIST_INTERVAL' (z. B. hourly, daily, '*-*-* 03:00:00')."
	else
		[[ "$BANWALL_BLOCKLIST_INTERVAL" =~ ^(hourly|daily|weekly)$ ]] ||
			die 3 "BANWALL_BLOCKLIST_INTERVAL muss hourly, daily oder weekly sein."
	fi

	log_debug "Konfiguration ist gültig."
}
