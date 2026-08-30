#!/usr/bin/env bats
# Der wichtigste Test des Projekts. Der Aussperr-Schutz ist das einzige,
# was zwischen 'banwall apply' und einem unerreichbaren Server steht -
# und ein Fehler darin fällt im Betrieb erst auf, wenn es zu spät ist.

load helper

setup() {
	setup_banwall
	load_module ssh

	# Nachgebaute Rechtelage: eigener getent-Stub plus leere sudoers.
	# Ohne das würde der Test das echte /etc lesen und je nach
	# Entwicklungsrechner unterschiedlich ausgehen.
	LOCAL_STUBS="$BATS_TEST_TMPDIR/stubs-local"
	mkdir -p "$LOCAL_STUBS"
	cat >"$LOCAL_STUBS/getent" <<'STUB'
#!/usr/bin/env bash
case "$1:$2" in
group:sudo)  printf 'sudo:x:27:%s\n' "${FAKE_SUDO_USERS:-}" ;;
group:admin) exit 2 ;;
passwd:*)    printf '%s:x:1000:1000::%s:/bin/bash\n' "$2" "${FAKE_HOME:-/nonexistent}" ;;
*)           exit 2 ;;
esac
STUB
	chmod +x "$LOCAL_STUBS/getent"
	export PATH="$LOCAL_STUBS:$PATH"

	export BANWALL_SUDOERS_FILE="$BATS_TEST_TMPDIR/sudoers"
	export BANWALL_SUDOERS_DIR="$BATS_TEST_TMPDIR/sudoers.d"
	: >"$BANWALL_SUDOERS_FILE"
	mkdir -p "$BANWALL_SUDOERS_DIR"

	export FAKE_HOME="$BATS_TEST_TMPDIR/home/admin"
	mkdir -p "$FAKE_HOME/.ssh"
}

@test "bricht ab, wenn es gar keinen sudo-Benutzer gibt" {
	export FAKE_SUDO_USERS=""
	BANWALL_SSH_PASSWORD_AUTH="no"
	run banwall_ssh_guard
	[ "$status" -eq 4 ]
	[[ "$output" == *"sudo-Rechten gefunden"* ]]
	[[ "$output" == *"adduser"* ]]        # muss einen Ausweg nennen
}

@test "bricht ab, wenn der sudo-Benutzer keinen Key hat" {
	export FAKE_SUDO_USERS="admin"
	BANWALL_SSH_PASSWORD_AUTH="no"
	run banwall_ssh_guard
	[ "$status" -eq 4 ]
	[[ "$output" == *"ssh-copy-id"* ]]
}

@test "bricht ab, wenn authorized_keys nur Kommentare enthält" {
	export FAKE_SUDO_USERS="admin"
	printf '# mein key kommt später\n\n' >"$FAKE_HOME/.ssh/authorized_keys"
	export STUB_SSH_KEYGEN_RC=1          # ssh-keygen findet keinen Key
	BANWALL_SSH_PASSWORD_AUTH="no"
	run banwall_ssh_guard
	[ "$status" -eq 4 ]
}

@test "läuft durch, wenn ein gültiger Key vorliegt" {
	export FAKE_SUDO_USERS="admin"
	printf 'ssh-ed25519 AAAAC3Nza... admin@arbeitsplatz\n' >"$FAKE_HOME/.ssh/authorized_keys"
	export STUB_SSH_KEYGEN_OUT="256 SHA256:abc admin@arbeitsplatz (ED25519)"
	export STUB_SSH_KEYGEN_RC=0
	BANWALL_SSH_PASSWORD_AUTH="no"
	run banwall_ssh_guard
	[ "$status" -eq 0 ]
}

@test "erkennt einen sudo-Benutzer aus sudoers.d ohne Gruppenmitgliedschaft" {
	export FAKE_SUDO_USERS=""
	printf 'deploy ALL=(ALL) NOPASSWD:ALL\n' >"$BANWALL_SUDOERS_DIR/deploy"
	BANWALL_SSH_PASSWORD_AUTH="no"
	run banwall_ssh_guard
	# Benutzer gefunden, aber ohne Key - andere Meldung als "gar keiner".
	[ "$status" -eq 4 ]
	[[ "$output" == *"deploy"* ]]
}

@test "greift nicht, wenn Passwort-Login angeschaltet bleibt" {
	export FAKE_SUDO_USERS=""
	BANWALL_SSH_PASSWORD_AUTH="yes"
	run banwall_ssh_guard
	[ "$status" -eq 0 ]
}

@test "erzeugte sshd-Konfiguration schaltet alle Passwortwege ab" {
	BANWALL_SSH_PASSWORD_AUTH="no"
	BANWALL_SSH_PERMIT_ROOT="no"
	BANWALL_SSH_PORT="22"
	run banwall_ssh_render
	[ "$status" -eq 0 ]
	[[ "$output" == *"PasswordAuthentication no"* ]]
	[[ "$output" == *"PermitRootLogin no"* ]]
	# Ohne diese Zeile bliebe ein Passwort-Login über PAM möglich.
	[[ "$output" == *"KbdInteractiveAuthentication no"* ]]
	[[ "$output" == *"PermitEmptyPasswords no"* ]]
}

@test "AllowUsers erscheint nur, wenn gesetzt" {
	BANWALL_SSH_ALLOW_USERS=""
	run banwall_ssh_render
	[[ "$output" != *"AllowUsers"* ]]

	BANWALL_SSH_ALLOW_USERS="admin deploy"
	run banwall_ssh_render
	[[ "$output" == *"AllowUsers admin deploy"* ]]
}
