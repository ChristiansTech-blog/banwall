#!/usr/bin/env bash
#
# backup.sh - Sicherung geänderter Dateien und Rollback.
#
# Jeder Lauf legt ein eigenes Verzeichnis unter /var/lib/banwall/backups/
# mit Zeitstempel an. Darin liegt der Originalbaum plus ein Manifest, aus
# dem 'banwall rollback' die Pfade wieder herstellt.

[[ -n "${_BANWALL_BACKUP_LOADED:-}" ]] && return 0
_BANWALL_BACKUP_LOADED=1

: "${BANWALL_BACKUP_ROOT:=${BANWALL_STATE_DIR}/backups}"

_BANWALL_BACKUP_DIR=""

backup_begin() {
	is_dry_run && return 0
	_BANWALL_BACKUP_DIR="$BANWALL_BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$_BANWALL_BACKUP_DIR/files"
	chmod 700 "$BANWALL_BACKUP_ROOT" "$_BANWALL_BACKUP_DIR"
	: >"$_BANWALL_BACKUP_DIR/manifest"
	log_debug "Backup-Verzeichnis: $_BANWALL_BACKUP_DIR"
}

backup_current_dir() { printf '%s' "$_BANWALL_BACKUP_DIR"; }

# backup_latest_dir - jüngstes vollständiges Backup. Ohne .complete gilt
# ein Backup als abgebrochen und wird übersprungen, damit ein Rollback
# nie aus einem halben Stand restauriert.
backup_latest_dir() {
	local d
	while IFS= read -r d; do
		[[ -f "$d/.complete" ]] && { printf '%s' "$d"; return 0; }
	done < <(find "$BANWALL_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
		sort -r)
	return 1
}

backup_finish() {
	is_dry_run && return 0
	[[ -n "$_BANWALL_BACKUP_DIR" ]] || return 0
	touch "$_BANWALL_BACKUP_DIR/.complete"
}

# backup_file PFAD
# Sichert eine Datei vor der ersten Änderung. Mehrfachaufrufe im selben
# Lauf sichern nur einmal - sonst überschriebe der zweite Aufruf das
# Original mit der bereits geänderten Fassung.
backup_file() {
	local path="$1"
	is_dry_run && { log_debug "[dry-run] sichere $path"; return 0; }
	[[ -n "$_BANWALL_BACKUP_DIR" ]] || return 0

	local dest="$_BANWALL_BACKUP_DIR/files$path"
	[[ -e "$dest" ]] && return 0

	if [[ ! -e "$path" ]]; then
		# Datei existiert noch nicht: beim Rollback muss sie wieder weg.
		printf 'ABSENT\t%s\n' "$path" >>"$_BANWALL_BACKUP_DIR/manifest"
		return 0
	fi

	mkdir -p "$(dirname "$dest")"
	cp -a "$path" "$dest"
	printf 'FILE\t%s\n' "$path" >>"$_BANWALL_BACKUP_DIR/manifest"
	log_debug "gesichert: $path"
}

backup_restore_files() {
	local dir="$1" kind path restored=0 removed=0
	[[ -f "$dir/manifest" ]] || { log_warn "Kein Manifest in $dir."; return 1; }

	while IFS=$'\t' read -r kind path; do
		[[ -n "$path" ]] || continue
		case "$kind" in
		FILE)
			banwall_run cp -a "$dir/files$path" "$path" && restored=$((restored + 1))
			;;
		ABSENT)
			[[ -e "$path" ]] && banwall_run rm -f "$path" && removed=$((removed + 1))
			;;
		esac
	done <"$dir/manifest"

	log_ok "$restored Datei(en) wiederhergestellt, $removed entfernt."
}
