#!/usr/bin/env bats
# Der Trockenlauf ist ein Sicherheitsversprechen: --dry-run darf das
# System unter keinen Umständen anfassen. Getestet wird das über die
# Stubs - wenn nft oder systemctl im Protokoll auftauchen, ist das
# Versprechen gebrochen.

load helper
setup() { setup_banwall; }

@test "run() führt im Trockenlauf nichts aus" {
	BANWALL_DRY_RUN=1
	run banwall_run nft list ruleset
	[ "$status" -eq 0 ]
	[[ "$output" == *"[dry-run]"* ]]
	! stub_called "nft list ruleset"
}

@test "run() führt außerhalb des Trockenlaufs aus" {
	BANWALL_DRY_RUN=0
	run banwall_run nft list ruleset
	[ "$status" -eq 0 ]
	stub_called "nft list ruleset"
}

@test "write_file schreibt im Trockenlauf keine Datei" {
	BANWALL_DRY_RUN=1
	local target="$BATS_TEST_TMPDIR/soll-nicht-entstehen"
	printf 'inhalt\n' | write_file "$target" 0600
	[ ! -e "$target" ]
}

@test "write_file schreibt mit den geforderten Rechten" {
	BANWALL_DRY_RUN=0
	local target="$BATS_TEST_TMPDIR/datei"
	printf 'inhalt\n' | write_file "$target" 0600
	[ -f "$target" ]
	[ "$(stat -c '%a' "$target")" = "600" ]
	[ "$(cat "$target")" = "inhalt" ]
}

@test "nftables-Modul verändert im Trockenlauf nichts" {
	BANWALL_DRY_RUN=1
	load_module nftables
	config_validate
	banwall_nftables_apply || true
	# --check darf laufen, ein echtes Laden nicht.
	! grep -E '^nft --file /etc/' "$STUB_LOG"
}
