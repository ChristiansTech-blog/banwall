#!/usr/bin/env bats
# Das Modul legt Benutzer an und schreibt authorized_keys - beides
# Stellen, an denen ein Fehler den Zugang kostet. Getestet wird deshalb
# gegen nachgebaute Kommandos: adduser, usermod und chown treffen nie
# das echte System.

load helper

setup() {
	setup_banwall
	load_module adminuser

	LOCAL_STUBS="$BATS_TEST_TMPDIR/stubs-local"
	mkdir -p "$LOCAL_STUBS"

	# getent kennt genau die Benutzer aus FAKE_USERS und legt ihr Home
	# in den Testordner.
	cat >"$LOCAL_STUBS/getent" <<'STUB'
#!/usr/bin/env bash
# Bekannte Benutzer: die vorab gesetzten und die, die der adduser-Stub
# im Lauf des Tests nachgetragen hat.
case "$1" in
passwd)
	for u in ${FAKE_USERS:-} $(cat "${FAKE_USERS_FILE:-/dev/null}" 2>/dev/null); do
		[[ "$u" == "$2" ]] || continue
		printf '%s:x:1000:1000::%s/%s:/bin/bash\n' "$2" "${FAKE_HOME_ROOT:-/home}" "$2"
		exit 0
	done
	exit 2
	;;
*) exit 2 ;;
esac
STUB

	# adduser trägt den Benutzer nach - so verhält sich getent danach
	# wie auf einem echten System.
	cat >"$LOCAL_STUBS/adduser" <<'STUB'
#!/usr/bin/env bash
printf 'adduser %s\n' "$*" >>"${STUB_LOG:-/dev/null}"
[[ -n "${STUB_ADDUSER_RC:-}" ]] && exit "$STUB_ADDUSER_RC"
name="${*: -1}"
printf '%s\n' "$name" >>"$FAKE_USERS_FILE"
mkdir -p "${FAKE_HOME_ROOT}/$name"
exit 0
STUB

	for cmd in usermod chown passwd; do
		cat >"$LOCAL_STUBS/$cmd" <<STUB
#!/usr/bin/env bash
printf '$cmd %s\n' "\$*" >>"\${STUB_LOG:-/dev/null}"
_rc="STUB_${cmd^^}_RC"
exit "\${!_rc:-0}"
STUB
	done

	# Der Projekt-Stub für ssh-keygen winkt jede Eingabe durch. Für die
	# Key-Prüfung ist genau das wertlos - hier muss das echte Programm
	# urteilen, so wie später der sshd.
	ECHTES_SSH_KEYGEN="$(PATH=/usr/bin:/bin command -v ssh-keygen || true)"
	if [[ -n "$ECHTES_SSH_KEYGEN" ]]; then
		printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$ECHTES_SSH_KEYGEN" \
			>"$LOCAL_STUBS/ssh-keygen"
	fi

	chmod +x "$LOCAL_STUBS"/*
	export PATH="$LOCAL_STUBS:$PATH"

	export FAKE_HOME_ROOT="$BATS_TEST_TMPDIR/home"
	export FAKE_USERS_FILE="$BATS_TEST_TMPDIR/users"
	: >"$FAKE_USERS_FILE"
	export FAKE_USERS=""
	mkdir -p "$FAKE_HOME_ROOT"

	# Echter Key, damit die Prüfung das echte ssh-keygen beschäftigt.
	KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJdQ8VJ+8Q3lI/tj8YZ0nQBt0m9nGZ0lZ4o7Fk3vXqZq test@arbeitsplatz"
}

# Ohne echtes ssh-keygen ist über die Key-Prüfung nichts auszusagen.
braucht_ssh_keygen() {
	[[ -n "$ECHTES_SSH_KEYGEN" ]] || skip "ssh-keygen nicht gefunden"
}

@test "gültige Benutzernamen werden akzeptiert" {
	run adminuser_name_gueltig "admin"
	[ "$status" -eq 0 ]
	run adminuser_name_gueltig "_deploy-2"
	[ "$status" -eq 0 ]
}

@test "unbrauchbare Benutzernamen werden abgelehnt" {
	# Großbuchstaben, führende Ziffer, Punkt, Leerzeichen und Leerstring
	# lehnt adduser selbst ab - besser, es fällt vorher auf.
	for name in "Admin" "1admin" "ad.min" "ad min" "" "root;rm -rf /"; do
		run adminuser_name_gueltig "$name"
		[ "$status" -ne 0 ]
	done
}

@test "zu langer Benutzername wird abgelehnt" {
	run adminuser_name_gueltig "$(printf 'a%.0s' {1..33})"
	[ "$status" -ne 0 ]
	run adminuser_name_gueltig "$(printf 'a%.0s' {1..32})"
	[ "$status" -eq 0 ]
}

@test "echter öffentlicher Schlüssel wird akzeptiert" {
	braucht_ssh_keygen
	run adminuser_key_gueltig "$KEY"
	[ "$status" -eq 0 ]
}

@test "Unsinn wird nicht als Schlüssel akzeptiert" {
	braucht_ssh_keygen
	run adminuser_key_gueltig ""
	[ "$status" -ne 0 ]
	run adminuser_key_gueltig "   "
	[ "$status" -ne 0 ]
	run adminuser_key_gueltig "das ist kein key"
	[ "$status" -ne 0 ]
	# Ein privater Schlüssel ist mehrzeilig - und gehört hier nie hin.
	run adminuser_key_gueltig "-----BEGIN OPENSSH PRIVATE KEY-----"
	[ "$status" -ne 0 ]
}

@test "Schlüssel mit Zeilenumbruch wird abgelehnt" {
	# Sonst könnte eine zweite Zeile mit fremdem Key in authorized_keys
	# landen, ohne dass sie jemand sieht.
	run adminuser_key_gueltig "$KEY"$'\n'"$KEY"
	[ "$status" -ne 0 ]
}

@test "neuer Benutzer wird angelegt, bekommt sudo und den Key" {
	run adminuser_einrichten "admin" "$KEY"
	[ "$status" -eq 0 ]
	stub_called "adduser --disabled-password --gecos  admin"
	stub_called "usermod -aG sudo admin"

	local akf="$FAKE_HOME_ROOT/admin/.ssh/authorized_keys"
	[ -f "$akf" ]
	grep -qF "$KEY" "$akf"
	[ "$(stat -c '%a' "$akf")" = "600" ]
	[ "$(stat -c '%a' "$FAKE_HOME_ROOT/admin/.ssh")" = "700" ]
	stub_called "chown -R admin:admin"
}

@test "vorhandener Benutzer wird nicht neu angelegt" {
	export FAKE_USERS="admin"
	mkdir -p "$FAKE_HOME_ROOT/admin"
	run adminuser_einrichten "admin" "$KEY"
	[ "$status" -eq 0 ]
	run stub_called "adduser"
	[ "$status" -ne 0 ]
	stub_called "usermod -aG sudo admin"
	grep -qF "$KEY" "$FAKE_HOME_ROOT/admin/.ssh/authorized_keys"
}

@test "bestehende Schlüssel bleiben erhalten" {
	# Der zweite Rechner des Admins darf nicht verschwinden, nur weil
	# ein weiterer Key dazukommt.
	export FAKE_USERS="admin"
	mkdir -p "$FAKE_HOME_ROOT/admin/.ssh"
	printf 'ssh-rsa AAAAB3NzaC1yc2E fremder-rechner\n' \
		>"$FAKE_HOME_ROOT/admin/.ssh/authorized_keys"

	run adminuser_einrichten "admin" "$KEY"
	[ "$status" -eq 0 ]
	grep -qF "fremder-rechner" "$FAKE_HOME_ROOT/admin/.ssh/authorized_keys"
	grep -qF "$KEY" "$FAKE_HOME_ROOT/admin/.ssh/authorized_keys"
}

@test "derselbe Schlüssel wird nicht doppelt eingetragen" {
	export FAKE_USERS="admin"
	mkdir -p "$FAKE_HOME_ROOT/admin/.ssh"
	printf '%s\n' "$KEY" >"$FAKE_HOME_ROOT/admin/.ssh/authorized_keys"

	run adminuser_einrichten "admin" "$KEY"
	[ "$status" -eq 0 ]
	[ "$(grep -cF "$KEY" "$FAKE_HOME_ROOT/admin/.ssh/authorized_keys")" = "1" ]
}

@test "ungültiger Name oder Schlüssel bricht ab, bevor etwas passiert" {
	run adminuser_einrichten "Admin" "$KEY"
	[ "$status" -ne 0 ]
	run adminuser_einrichten "admin" "kein key"
	[ "$status" -ne 0 ]
	# Kein einziger verändernder Aufruf darf gelaufen sein.
	for cmd in adduser usermod chown passwd; do
		run stub_called "$cmd "
		[ "$status" -ne 0 ]
	done
}

@test "gescheitertes adduser meldet einen Fehler statt weiterzumachen" {
	export STUB_ADDUSER_RC=1
	run adminuser_einrichten "admin" "$KEY"
	[ "$status" -ne 0 ]
	[[ "$output" == *"konnte nicht angelegt werden"* ]]
	run stub_called "usermod"
	[ "$status" -ne 0 ]
}

@test "im Trockenlauf wird nichts angelegt und nichts geschrieben" {
	BANWALL_DRY_RUN=1
	run adminuser_einrichten "admin" "$KEY"
	[ "$status" -eq 0 ]
	[[ "$output" == *"[dry-run]"* ]]
	[[ "$output" == *"adduser"* ]]
	[ ! -e "$FAKE_HOME_ROOT/admin/.ssh/authorized_keys" ]
	for cmd in adduser usermod chown passwd; do
		run stub_called "$cmd "
		[ "$status" -ne 0 ]
	done
}
