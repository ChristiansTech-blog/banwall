#!/usr/bin/env bash
#
# selfupdate.sh - Banwall selbst auf den aktuellen Stand bringen.
#
# Nur auf Zuruf ('banwall update'), kein Timer: ein Werkzeug, das
# Firewall und SSH-Zugang verwaltet, tauscht sich nicht unbeaufsichtigt
# selbst aus. Und auch der Befehl ändert ausschließlich die
# Programmdateien - angewendet wird erst mit 'banwall apply', genau wie
# bei der Erstinstallation.
#
# Geholt wird der Tarball des Standardbranches. Damit landet jeder
# Commit auf dem Server, auch ein fehlerhafter - deshalb wird der
# heruntergeladene Baum vor dem Einbau geprüft: Struktur vollständig,
# jede Skriptdatei syntaktisch fehlerfrei. Eine Signaturprüfung gibt es
# nicht; das Vertrauen endet bei HTTPS und der Quelle in
# BANWALL_UPDATE_URL.

[[ -n "${_BANWALL_SELFUPDATE_LOADED:-}" ]] && return 0
_BANWALL_SELFUPDATE_LOADED=1

# Obergrenze für den Download. Das Repository liegt bei deutlich unter
# einem Megabyte; alles darüber ist nicht mehr Banwall.
readonly _BANWALL_SU_MAX_BYTES=$((10 * 1024 * 1024))
readonly _BANWALL_SU_TIMEOUT=60

# _su_prefix - Wurzel der laufenden Installation, abgeleitet aus dem
# Bibliothekspfad ($PREFIX/lib/banwall). Nicht fest verdrahtet, damit
# eine Installation mit PREFIX=/opt sich auch selbst aktualisiert.
_su_prefix() { dirname "$(dirname "$BANWALL_LIB_DIR")"; }

# _su_zielpfad RELATIVER_PFAD
# Übersetzt einen Pfad im Quellbaum auf seinen Platz in der
# Installation. Die beiden Layouts unterscheiden sich nur bei share/:
# im Repository liegt es neben lib/, installiert unter share/banwall/.
_su_zielpfad() {
	local rel="$1"
	case "$rel" in
	bin/banwall) printf '%s/bin/banwall\n' "$(_su_prefix)" ;;
	lib/banwall/*) printf '%s/%s\n' "$BANWALL_LIB_DIR" "${rel#lib/banwall/}" ;;
	share/*) printf '%s/%s\n' "$BANWALL_SHARE_DIR" "${rel#share/}" ;;
	*) return 1 ;;
	esac
}

# _su_dateien QUELLBAUM - alle Dateien, die eine Installation ausmacht,
# als Pfade relativ zur Baumwurzel.
_su_dateien() {
	local quelle="$1" pfad
	while IFS= read -r pfad; do
		printf '%s\n' "${pfad#"$quelle"/}"
	done < <(find "$quelle/bin" "$quelle/lib/banwall" "$quelle/share" \
		-type f 2>/dev/null | sort)
}

# _su_fetch URL ZIEL [TIMEOUT] - dieselben Härtungsflags wie beim
# Blocklist-Download. Der Assistent gibt einen kürzeren Timeout mit: dort
# wartet jemand vor dem Bildschirm auf den Start.
_su_fetch() {
	local url="$1" ziel="$2" timeout="${3:-$_BANWALL_SU_TIMEOUT}"
	curl --fail --silent --show-error --location \
		--proto '=https' --tlsv1.2 \
		--max-time "$timeout" \
		--max-filesize "$_BANWALL_SU_MAX_BYTES" \
		--user-agent "banwall/$BANWALL_VERSION" \
		--output "$ziel" "$url"
}

# _su_pruefe_baum VERZEICHNIS
# Ein Branch-Tarball ist ungeprüfter Code. Bevor er die laufende
# Installation ersetzt, muss er wenigstens vollständig und syntaktisch
# heil sein - sonst steht der Server mit einem Banwall da, das sich
# nicht mehr starten lässt.
_su_pruefe_baum() {
	local baum="$1" pflicht datei

	for pflicht in bin/banwall install.sh lib/banwall/common.sh \
		lib/banwall/nftables.sh share/banwall.conf.example; do
		[[ -f "$baum/$pflicht" ]] || {
			log_error "Der geholte Stand ist unvollständig: $pflicht fehlt."
			return 1
		}
	done

	while IFS= read -r datei; do
		bash -n "$datei" 2>/dev/null || {
			log_error "Der geholte Stand enthält einen Syntaxfehler: ${datei#"$baum"/}"
			log_error "Die Installation bleibt unverändert."
			return 1
		}
	done < <(find "$baum/bin" "$baum/lib/banwall" -type f 2>/dev/null
		printf '%s\n' "$baum/install.sh")

	# Eine fremde Version könnte alles Mögliche sein. Die Kennung muss
	# stimmen, sonst wird hier nichts eingebaut.
	grep -q '^BANWALL_VERSION=' "$baum/bin/banwall" || {
		log_error "In bin/banwall des geholten Standes steht keine Version. Kein Banwall?"
		return 1
	}
	return 0
}

# _su_geaendert QUELLBAUM - relative Pfade, die sich vom installierten
# Stand unterscheiden. Verglichen wird gegen die Dateien, die der neue
# Stand mitbringt: eine alte Datei, die es dort nicht mehr gibt, soll
# nicht bei jedem Lauf ein Update vortäuschen.
_su_geaendert() {
	local quelle="$1" rel ziel
	while IFS= read -r rel; do
		ziel="$(_su_zielpfad "$rel")" || continue
		cmp -s "$quelle/$rel" "$ziel" || printf '%s\n' "$rel"
	done < <(_su_dateien "$quelle")
}

# _su_version BAUM - die Versionskennung eines Quellbaums.
_su_version() {
	sed -n 's/^BANWALL_VERSION="\(.*\)"/\1/p' "$1/bin/banwall" | head -n 1
}

# _su_sichern QUELLBAUM - den aktuellen Stand der Dateien wegkopieren,
# die gleich ersetzt werden. Nicht über backup_file: dort liegen die
# Systemänderungen, die 'banwall rollback' zurücknimmt, und die
# Installation gehört nicht dazu.
_su_sichern() {
	local quelle="$1" ziel_dir rel ziel
	ziel_dir="$BANWALL_STATE_DIR/updates/$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$ziel_dir"
	chmod 700 "$BANWALL_STATE_DIR/updates" "$ziel_dir"

	while IFS= read -r rel; do
		ziel="$(_su_zielpfad "$rel")" || continue
		[[ -f "$ziel" ]] || continue
		mkdir -p "$ziel_dir/$(dirname "$rel")"
		cp -p "$ziel" "$ziel_dir/$rel"
	done < <(_su_dateien "$quelle")

	printf '%s\n' "$ziel_dir"
}

# _su_installieren QUELLBAUM
# Der Einbau läuft über das install.sh des NEUEN Standes: wie eine
# Version installiert wird, weiß sie selbst am besten - kommt eine
# Datei hinzu, muss dafür nicht die alte Fassung angepasst werden.
_su_installieren() {
	local quelle="$1" prefix flag
	prefix="$(_su_prefix)"

	# --files-only gibt es erst ab dieser Fassung. Kennt der geholte
	# Stand das Flag nicht, tut --no-wizard dasselbe plus einer
	# Konfigurationsvorlage, die bei einem Update ohnehin schon liegt.
	flag="--files-only"
	grep -q -- '--files-only' "$quelle/install.sh" || flag="--no-wizard"

	banwall_run env \
		PREFIX="$prefix" \
		CONFDIR="$BANWALL_CONFIG_DIR" \
		STATEDIR="$BANWALL_STATE_DIR" \
		bash "$quelle/install.sh" install "$flag"
}

# _su_vorbereiten ARBEITSVERZEICHNIS [TIMEOUT]
# Holt den Stand, packt ihn aus und prüft ihn. Danach liegt der geprüfte
# Baum in ARBEITSVERZEICHNIS/neu. Eigene Funktion, weil der Assistent
# dieselbe Vorarbeit braucht - er fragt beim Start nach einer neueren
# Fassung, bevor er die ersten Fragen stellt.
_su_vorbereiten() {
	local arbeit="$1" timeout="${2:-$_BANWALL_SU_TIMEOUT}"

	_su_fetch "$BANWALL_UPDATE_URL" "$arbeit/banwall.tar.gz" "$timeout" || {
		log_error "Quelle nicht erreichbar: $BANWALL_UPDATE_URL"
		return 1
	}

	mkdir -p "$arbeit/neu"
	# --strip-components=1: GitHub packt alles unter 'banwall-main/'.
	tar -xzf "$arbeit/banwall.tar.gz" -C "$arbeit/neu" --strip-components=1 2>/dev/null || {
		log_error "Der geholte Stand ließ sich nicht auspacken."
		return 1
	}

	_su_pruefe_baum "$arbeit/neu"
}

banwall_selfupdate_run() {
	# Kein starres require_root: gebraucht wird Schreibrecht auf die
	# Installation. Bei den Standardpfaden ist das root, bei
	# PREFIX=$HOME/.local nicht - und genau das verspricht bin/banwall.
	local verzeichnis
	for verzeichnis in "$(_su_prefix)/bin" "$BANWALL_LIB_DIR" \
		"$BANWALL_SHARE_DIR" "$BANWALL_STATE_DIR"; do
		[[ -w "$verzeichnis" ]] ||
			die 3 "Kein Schreibrecht auf $verzeichnis. Bitte mit sudo ausführen: sudo banwall update"
	done

	# Aus dem Git-Checkout heraus wäre ein Selbstupdate ein Griff in
	# den eigenen Arbeitsbaum - dort ist 'git pull' der richtige Weg.
	if [[ -n "${BANWALL_CHECKOUT_DIR:-}" ]]; then
		die 3 "Banwall läuft hier aus dem Git-Checkout ($BANWALL_CHECKOUT_DIR). Dort aktualisiert 'git pull && sudo ./install.sh --no-wizard'."
	fi

	ensure_cmd curl curl "Zum Holen des neuen Standes wird curl gebraucht."
	require_cmd tar "Zum Auspacken des neuen Standes wird tar gebraucht."

	local arbeit
	arbeit="$(mktemp -d)"
	# shellcheck disable=SC2064
	trap "rm -rf '$arbeit'" RETURN

	log_step "Hole den aktuellen Stand von $BANWALL_UPDATE_URL"
	_su_vorbereiten "$arbeit" ||
		die 1 "Der geholte Stand wurde verworfen. Die Installation bleibt unverändert."

	local neue_version geaendert=()
	neue_version="$(_su_version "$arbeit/neu")"
	mapfile -t geaendert < <(_su_geaendert "$arbeit/neu")

	if ((${#geaendert[@]} == 0)); then
		log_ok "Banwall ist auf dem aktuellen Stand (Version $BANWALL_VERSION)."
		return 0
	fi

	if [[ "$neue_version" == "$BANWALL_VERSION" ]]; then
		log_info "Neuer Stand bei gleicher Versionsnummer ($BANWALL_VERSION)."
	else
		log_info "Neuer Stand: Version $neue_version (installiert: $BANWALL_VERSION)"
	fi
	log_info "${#geaendert[@]} Datei(en) ändern sich:"
	local rel
	for rel in "${geaendert[@]}"; do
		log_info "  $rel"
	done

	if is_dry_run; then
		log_info "[dry-run] Es wurde nichts eingebaut."
		return 0
	fi

	confirm "Diesen Stand jetzt installieren?" || {
		log_info "Abgebrochen. Die Installation bleibt unverändert."
		return 0
	}

	local sicherung
	sicherung="$(_su_sichern "$arbeit/neu")"
	log_info "Bisheriger Stand gesichert: $sicherung"

	_su_installieren "$arbeit/neu" ||
		die 1 "Einbau fehlgeschlagen. Der bisherige Stand liegt unter $sicherung."

	log_ok "Banwall $neue_version installiert."
	log_info "Am System hat sich nichts geändert. Wirksam wird der neue Stand mit:"
	log_info "  banwall apply --dry-run   ansehen"
	log_info "  banwall apply             anwenden"
	return 0
}
