#!/usr/bin/env bash
# Gemeinsame Hilfen für die bats-Tests.
#
# Kernidee: die Stubs aus tests/stubs/ kommen an den Anfang des PATH.
# Dadurch treffen nft, systemctl und apt-get nie das echte System, und
# die Tests laufen ohne root, ohne Container und ohne Nebenwirkungen.

setup_banwall() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
	export REPO_ROOT
	export PATH="$REPO_ROOT/tests/stubs:$PATH"

	# Aufrufprotokoll der Stubs - darauf werden die Erwartungen geprüft.
	export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
	: >"$STUB_LOG"

	# Alle Pfade in den Test-Tempordner umbiegen.
	export BANWALL_LIB_DIR="$REPO_ROOT/lib/banwall"
	export BANWALL_SHARE_DIR="$REPO_ROOT/share"
	export BANWALL_CONFIG_DIR="$BATS_TEST_TMPDIR/etc"
	export BANWALL_CONFIG_FILE="$BATS_TEST_TMPDIR/etc/banwall.conf"
	export BANWALL_STATE_DIR="$BATS_TEST_TMPDIR/var"
	export BANWALL_BACKUP_ROOT="$BATS_TEST_TMPDIR/var/backups"
	export BANWALL_VERSION="test"
	mkdir -p "$BANWALL_CONFIG_DIR" "$BANWALL_STATE_DIR"

	# shellcheck source=/dev/null
	source "$BANWALL_LIB_DIR/common.sh"
	# shellcheck source=/dev/null
	source "$BANWALL_LIB_DIR/config.sh"
	# shellcheck source=/dev/null
	source "$BANWALL_LIB_DIR/backup.sh"
}

load_module() {
	# shellcheck source=/dev/null
	source "$BANWALL_LIB_DIR/$1.sh"
}

# stub_called MUSTER - stand das Muster im Aufrufprotokoll?
stub_called() { grep -qF "$1" "$STUB_LOG"; }
