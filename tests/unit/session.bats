#!/usr/bin/env bats
# Ob Banwall die eigene SSH-Sitzung erkennt, entscheidet über die Warnung
# vor dem Aussperren und darüber, welche Adresse nie gesperrt wird. Der
# Stolperstein ist sudo: es reicht SSH_CONNECTION nicht durch, und ohne
# sudo läuft Banwall nie. Diese Tests halten die Ersatzwege fest.

load helper
setup() {
	setup_banwall
	unset SSH_CONNECTION SSH_CLIENT SSH_TTY XDG_SESSION_ID

	# Ohne Vorgabe findet kein Weg etwas - so ist jeder Testfall auf
	# genau den Weg beschränkt, den er selbst einschaltet. Die
	# Prozesskette wird überschrieben, weil die Testumgebung selbst
	# unter einem sshd hängen kann.
	_banwall_sshd_ancestor() { return 1; }
}

@test "nimmt SSH_CONNECTION, wenn die Umgebung sie hat" {
	export SSH_CONNECTION="203.0.113.7 54321 192.0.2.1 22"
	[ "$(banwall_ssh_peer)" = "203.0.113.7" ]
	banwall_is_ssh_session
}

@test "nimmt SSH_CLIENT als zweite Umgebungsquelle" {
	export SSH_CLIENT="203.0.113.8 54321 22"
	[ "$(banwall_ssh_peer)" = "203.0.113.8" ]
}

@test "findet die Gegenstelle über loginctl, wenn sudo die Umgebung geleert hat" {
	export XDG_SESSION_ID="7"
	export STUB_LOGINCTL_OUT="203.0.113.9"
	[ "$(banwall_ssh_peer)" = "203.0.113.9" ]
	stub_called "loginctl show-session 7 --property=RemoteHost"
}

@test "erkennt die SSH-Sitzung über loginctl auch ohne Adresse" {
	export XDG_SESSION_ID="7"
	export STUB_LOGINCTL_OUT="yes"
	banwall_is_ssh_session
}

@test "findet die Gegenstelle über die sshd-Prozesskette" {
	_banwall_sshd_ancestor() { printf '4711\n'; }
	export STUB_SS_OUT='ESTAB 0 0 192.0.2.1:22 203.0.113.10:54321 users:(("sshd-session",pid=4711,fd=5))'
	[ "$(banwall_ssh_peer)" = "203.0.113.10" ]
}

@test "schneidet den Port einer IPv6-Gegenstelle sauber ab" {
	_banwall_sshd_ancestor() { printf '4711\n'; }
	export STUB_SS_OUT='ESTAB 0 0 [2001:db8::1]:22 [2001:db8::2]:54321 users:(("sshd",pid=4711,fd=5))'
	[ "$(banwall_ssh_peer)" = "2001:db8::2" ]
}

@test "ignoriert Verbindungen fremder Prozesse" {
	_banwall_sshd_ancestor() { printf '4711\n'; }
	export STUB_SS_OUT='ESTAB 0 0 192.0.2.1:22 203.0.113.11:54321 users:(("sshd",pid=9999,fd=5))'
	run banwall_ssh_peer
	[ "$status" -ne 0 ]
	[ -z "$output" ]
}

@test "lokale Konsole bleibt lokale Konsole" {
	run banwall_ssh_peer
	[ "$status" -ne 0 ]
	[ -z "$output" ]
	run banwall_is_ssh_session
	[ "$status" -ne 0 ]
}

@test "die Gegenstelle landet nie in einer Blocklist" {
	load_module nftables
	load_module blocklist
	export XDG_SESSION_ID="7"
	export STUB_LOGINCTL_OUT="203.0.113.9"

	local ergebnis
	ergebnis="$(printf '203.0.113.9\n198.51.100.1\n' | _bl_filter_safe)"
	[[ "$ergebnis" != *"203.0.113.9"* ]]
	[[ "$ergebnis" == *"198.51.100.1"* ]]
}
