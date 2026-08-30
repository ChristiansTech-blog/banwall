#!/usr/bin/env bash
#
# common.sh - Logging, Kommando-Ausführung, Fehlerbehandlung.
#
# Wird von jedem Modul vorausgesetzt. Enthält insbesondere run(), über
# das JEDE verändernde Aktion laufen muss - daran hängt der Dry-run.

# Nur einmal laden.
[[ -n "${_BANWALL_COMMON_LOADED:-}" ]] && return 0
_BANWALL_COMMON_LOADED=1

: "${BANWALL_DRY_RUN:=0}"
: "${BANWALL_VERBOSE:=0}"
: "${BANWALL_ASSUME_YES:=0}"
: "${BANWALL_STATE_DIR:=/var/lib/banwall}"

# Farben nur, wenn wirklich ein Terminal dranhängt. In der CI und in
# Logfiles wären ANSI-Codes nur Rauschen. _C_BLU ist die Akzentfarbe -
# Cyan statt Blau, weil dunkles Blau auf schwarzem Grund kaum lesbar ist.
if [[ -t 2 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
	_C_RED=$'\033[31m'; _C_GRN=$'\033[32m'; _C_YEL=$'\033[33m'
	_C_BLU=$'\033[36m'; _C_DIM=$'\033[2m'; _C_RST=$'\033[0m'
	_C_BOLD=$'\033[1m'
else
	_C_RED=""; _C_GRN=""; _C_YEL=""; _C_BLU=""; _C_DIM=""; _C_RST=""
	_C_BOLD=""
fi

# Alle Logausgaben gehen nach stderr, damit stdout für auswertbare
# Ergebnisse frei bleibt (z. B. 'banwall status' in einer Pipe).
log_info() { printf '%s\n' "$*" >&2; }
log_ok() { printf '%s✓%s %s\n' "$_C_GRN" "$_C_RST" "$*" >&2; }
log_warn() { printf '%sWarnung:%s %s\n' "$_C_YEL" "$_C_RST" "$*" >&2; }
log_error() { printf '%sFehler:%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2; }
log_step() { printf '\n%s==>%s %s\n' "$_C_BLU" "$_C_RST" "$*" >&2; }
log_debug() {
	((BANWALL_VERBOSE)) || return 0
	printf '%s  %s%s\n' "$_C_DIM" "$*" "$_C_RST" >&2
}

# die EXITCODE MELDUNG...
# Bricht mit sprechendem Text und definiertem Exit-Code ab. Konvention:
#   1 = Laufzeitfehler, 2 = Bedienfehler, 3 = nicht erfüllte Vorbedingung,
#   4 = Aussperr-Schutz hat ausgelöst.
die() {
	local rc="$1"
	shift
	log_error "$*"
	exit "$rc"
}

is_dry_run() { ((BANWALL_DRY_RUN)); }

# banwall_run KOMMANDO [ARGS...]
# Einziger erlaubter Weg, das System zu verändern. Im Trockenlauf wird das
# Kommando nur ausgegeben. Dadurch braucht kein Modul eine zweite Code-
# Variante für --dry-run, und es kann auch keine vergessen werden.
#
# Heißt bewusst nicht 'run': bats bringt ein eigenes run() mit, und ein
# gesourctes common.sh würde es überschreiben - dann wäre $status in
# jedem Test leer.
banwall_run() {
	if is_dry_run; then
		printf '%s  [dry-run] %s%s\n' "$_C_DIM" "$*" "$_C_RST" >&2
		return 0
	fi
	log_debug "+ $*"
	"$@"
}

# write_file PFAD MODUS < INHALT
# Schreibt eine Datei atomar (temp + mv) mit gesetzten Rechten. Atomar,
# damit ein Abbruch mitten im Schreiben keine halbe Config hinterlässt -
# eine halbe sshd_config wäre ein Aussperr-Risiko.
write_file() {
	local path="$1" mode="${2:-0644}" content
	content="$(cat)"

	if is_dry_run; then
		printf '%s  [dry-run] schreibe %s (%s, %d Zeilen)%s\n' \
			"$_C_DIM" "$path" "$mode" "$(wc -l <<<"$content")" "$_C_RST" >&2
		return 0
	fi

	local tmp
	tmp="$(mktemp "${path}.banwall.XXXXXX")" || return 1
	printf '%s\n' "$content" >"$tmp"
	chmod "$mode" "$tmp"
	mv -f "$tmp" "$path"
	log_debug "geschrieben: $path"
}

require_root() {
	[[ "$(id -u)" -eq 0 ]] ||
		die 3 "Banwall braucht root-Rechte. Bitte mit sudo ausführen."
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 ||
		die 3 "Kommando '$1' nicht gefunden.${2:+ $2}"
}

# ensure_cmd KOMMANDO PAKET [HINWEIS]
# Fehlendes Kommando nachinstallieren statt daran zu scheitern.
# Nicht 'require_cmd x || pkg_install y' schreiben: require_cmd beendet
# das Programm, der Fallback hinter dem || kommt nie zum Zug.
ensure_cmd() {
	local cmd="$1" pkg="$2" hinweis="${3:-}"
	command -v "$cmd" >/dev/null 2>&1 && return 0

	log_info "Kommando '$cmd' fehlt - installiere Paket '$pkg'."
	pkg_install "$pkg"

	# Im Trockenlauf wurde nichts installiert. Hier trotzdem
	# abzubrechen hiesse, den Trockenlauf genau dort scheitern zu
	# lassen, wo der echte Lauf durchliefe.
	is_dry_run && return 0

	require_cmd "$cmd" "${hinweis:-Das Paket '$pkg' wurde installiert, '$cmd' ist trotzdem nicht da.}"
}

array_contains() {
	local needle="$1" item
	shift
	for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
	return 1
}

# confirm FRAGE
# Rückfrage vor heiklen Schritten. Ohne Terminal (Automatisierung) gilt
# das Fehlen von --yes als Nein, damit ein Cronjob nie blind zuschlägt.
confirm() {
	((BANWALL_ASSUME_YES)) && return 0
	is_dry_run && return 0
	if [[ ! -t 0 ]]; then
		log_error "Rückfrage nötig, aber kein Terminal verfügbar: $1"
		log_error "Mit --yes bestätigen, wenn das beabsichtigt ist."
		return 1
	fi
	local answer
	read -r -p "$1 [j/N] " answer </dev/tty
	[[ "$answer" =~ ^[jJyY]$ ]]
}

# pkg_install PAKET...
# Installiert nur, was fehlt - das hält wiederholte Läufe schnell und
# vermeidet ungewollte Upgrades laufender Dienste.
pkg_install() {
	local missing=() pkg
	for pkg in "$@"; do
		dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null |
			grep -q "^install ok installed$" || missing+=("$pkg")
	done
	((${#missing[@]})) || { log_debug "Pakete bereits installiert: $*"; return 0; }

	log_info "Installiere: ${missing[*]}"
	banwall_run env DEBIAN_FRONTEND=noninteractive apt-get update -qq ||
		die 1 "'apt-get update' fehlgeschlagen. Netzwerk oder Paketquellen prüfen."
	banwall_run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" ||
		die 1 "Installation fehlgeschlagen: ${missing[*]}"
}

# service_enable DIENST - aktivieren und starten, idempotent.
service_enable() {
	banwall_run systemctl enable --now "$1" ||
		die 1 "Dienst '$1' ließ sich nicht aktivieren. 'systemctl status $1' zeigt mehr."
}

service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# preflight_checks - alles, was ohne passende Umgebung sinnlos wäre.
preflight_checks() {
	[[ "$(uname -s)" == "Linux" ]] || die 3 "Banwall läuft nur unter Linux."

	if [[ -r /etc/os-release ]]; then
		# shellcheck disable=SC1091
		local id version_id
		id="$(. /etc/os-release && printf '%s' "${ID:-}")"
		version_id="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
		if [[ "$id" != "debian" ]]; then
			log_warn "Nicht-Debian-System erkannt ($id). Banwall ist auf Debian 13 getestet."
		elif [[ -n "$version_id" && "$version_id" != "13" ]]; then
			log_warn "Debian $version_id erkannt. Getestet ist Debian 13 (Trixie)."
		fi
	fi

	require_cmd systemctl "Banwall setzt systemd voraus."
	require_cmd apt-get "Banwall setzt ein Debian-Paketsystem voraus."
}
