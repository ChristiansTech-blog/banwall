#!/usr/bin/env bats
# Debian 13 startet sshd per Socket-Aktivierung: ssh.service ist zwischen
# zwei Logins inaktiv. Ein blindes 'systemctl reload ssh' scheitert dann
# und hat 'banwall apply' fälschlich als fehlgeschlagen gemeldet - obwohl
# die Härtung vollständig angewendet war. Diese Tests halten den Fall fest.

load helper

setup() {
	setup_banwall
	load_module ssh

	# Eigener systemctl-Stub: der globale kann nur einen Rückgabewert für
	# alle Aufrufe, hier braucht jede Unterfrage eine eigene Antwort.
	LOCAL_STUBS="$BATS_TEST_TMPDIR/stubs-local"
	mkdir -p "$LOCAL_STUBS"
	cat >"$LOCAL_STUBS/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"${STUB_LOG:-/dev/null}"
case "$*" in
cat\ ssh.service)             exit "${FAKE_UNIT_SSH:-0}" ;;
cat\ sshd.service)            exit "${FAKE_UNIT_SSHD:-1}" ;;
is-active\ --quiet\ ssh.service)  exit "${FAKE_SERVICE_ACTIVE:-1}" ;;
is-active\ --quiet\ ssh.socket)   exit "${FAKE_SOCKET_ACTIVE:-1}" ;;
reload\ *)                    printf '%s\n' "${FAKE_RELOAD_ERR:-}" >&2
                              exit "${FAKE_RELOAD_RC:-0}" ;;
*)                            exit 0 ;;
esac
STUB
	chmod +x "$LOCAL_STUBS/systemctl"
	export PATH="$LOCAL_STUBS:$PATH"
}

@test "inaktiver Dienst bei lauschendem ssh.socket ist kein Fehler" {
	export FAKE_SERVICE_ACTIVE=1 FAKE_SOCKET_ACTIVE=0
	run _ssh_reload
	[ "$status" -eq 0 ]
	# Ohne aktiven Dienst darf gar kein reload versucht werden.
	! stub_called "systemctl reload"
}

@test "laufender Dienst wird neu geladen" {
	export FAKE_SERVICE_ACTIVE=0 FAKE_RELOAD_RC=0
	run _ssh_reload
	[ "$status" -eq 0 ]
	stub_called "systemctl reload ssh.service"
}

@test "echter reload-Fehler bricht ab und zeigt die Meldung von systemctl" {
	export FAKE_SERVICE_ACTIVE=0 FAKE_RELOAD_RC=1
	export FAKE_RELOAD_ERR="Job for ssh.service failed"
	run _ssh_reload
	[ "$status" -eq 1 ]
	# Die Ursache muss sichtbar sein, sonst ist der Fehler nicht diagnostizierbar.
	[[ "$output" == *"Job for ssh.service failed"* ]]
}

@test "ohne SSH-Unit wird gewarnt statt abgebrochen" {
	export FAKE_UNIT_SSH=1 FAKE_UNIT_SSHD=1
	run _ssh_reload
	[ "$status" -eq 0 ]
	[[ "$output" == *"Keine SSH-Unit"* ]]
}

@test "im Trockenlauf wird nur angekündigt" {
	export BANWALL_DRY_RUN=1 FAKE_SERVICE_ACTIVE=0
	run _ssh_reload
	[ "$status" -eq 0 ]
	[[ "$output" == *"[dry-run]"* ]]
	! stub_called "systemctl reload ssh.service"
}

@test "sshd.service wird erkannt, wenn ssh.service fehlt" {
	export FAKE_UNIT_SSH=1 FAKE_UNIT_SSHD=0
	run _ssh_unit
	[ "$status" -eq 0 ]
	[ "$output" = "sshd.service" ]
}
