#!/usr/bin/env bats
# Ohne verlässliches Backup ist 'banwall rollback' ein leeres
# Versprechen. Vor allem der Fall "Datei existierte vorher nicht" wird
# leicht vergessen - beim Rollback muss sie wieder verschwinden.

load helper
setup() {
	setup_banwall
	BANWALL_DRY_RUN=0
	backup_begin
}

@test "sichert eine bestehende Datei im Original" {
	local f="$BATS_TEST_TMPDIR/config"
	printf 'original\n' >"$f"
	backup_file "$f"
	printf 'geändert\n' >"$f"

	backup_finish
	backup_restore_files "$(backup_current_dir)"
	[ "$(cat "$f")" = "original" ]
}

@test "sichert nur beim ersten Aufruf" {
	local f="$BATS_TEST_TMPDIR/config"
	printf 'original\n' >"$f"
	backup_file "$f"
	printf 'geändert\n' >"$f"
	backup_file "$f"          # darf das Original nicht überschreiben

	backup_finish
	backup_restore_files "$(backup_current_dir)"
	[ "$(cat "$f")" = "original" ]
}

@test "entfernt beim Rollback Dateien, die es vorher nicht gab" {
	local f="$BATS_TEST_TMPDIR/neu.conf"
	backup_file "$f"          # existiert noch nicht
	printf 'von banwall angelegt\n' >"$f"

	backup_finish
	backup_restore_files "$(backup_current_dir)"
	[ ! -e "$f" ]
}

@test "unvollständiges Backup wird beim Rollback übersprungen" {
	# backup_begin ohne backup_finish - kein .complete
	run backup_latest_dir
	[ "$status" -ne 0 ]
}
