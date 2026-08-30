#!/usr/bin/env bats
# Der Assistent ist interaktiv und lässt sich deshalb nur teilweise mit
# bats prüfen. Getestet wird, was ohne Terminal geht - vor allem die
# Stelle, an der er Schaden anrichten könnte: die geschriebene
# Konfigurationsdatei.

load helper

setup() {
	setup_banwall
	load_module ssh
	load_module wizard
	BANWALL_DRY_RUN=0
}

# Vorgaben setzen, wie sie nach einem Durchlauf im Speicher stünden.
wiz_werte() {
	WIZ_TCP_PORTS="22 80 443"
	WIZ_UDP_PORTS=""
	WIZ_ALLOW_NETS=""
	WIZ_ALLOW_PING=1
	WIZ_SSH_RATE_LIMIT=1
	WIZ_SSH_PORT="22"
	WIZ_SSH_PERMIT_ROOT="no"
	WIZ_SSH_PASSWORD_AUTH="no"
	WIZ_SSH_ALLOW_USERS=""
	WIZ_ENABLE_FAIL2BAN=1
	WIZ_F2B_BANTIME="1h"
	WIZ_F2B_FINDTIME="10m"
	WIZ_F2B_MAXRETRY="5"
	WIZ_F2B_WEBSERVER=0
	WIZ_ENABLE_UPDATES=1
	WIZ_UPDATES_AUTOREBOOT=0
	WIZ_UPDATES_REBOOT_TIME="04:00"
	WIZ_ENABLE_BLOCKLIST=1
	WIZ_BLOCKLIST_URLS="https://ipv64.net/blocklists/ipv64_blocklist_blocklistde_all.txt"
	WIZ_BLOCKLIST_INTERVAL="daily"
}

@test "Portprüfung akzeptiert gültige Listen" {
	run _wiz_ports_gueltig "22 80 443 65535"
	[ "$status" -eq 0 ]
	run _wiz_ports_gueltig ""
	[ "$status" -eq 0 ]
}

@test "Portprüfung lehnt Unsinn ab" {
	run _wiz_ports_gueltig "22 99999"
	[ "$status" -ne 0 ]
	run _wiz_ports_gueltig "22 http"
	[ "$status" -ne 0 ]
	run _wiz_ports_gueltig "0"
	[ "$status" -ne 0 ]
}

@test "geschriebene Konfiguration ist für Banwall gültig" {
	# Der wichtigste Test des Assistenten: was er schreibt, muss die
	# reguläre Prüfung bestehen. Sonst hätte der Nutzer am Ende eine
	# Datei, die 'banwall apply' beim nächsten Start ablehnt.
	wiz_werte
	_wiz_schreiben
	[ -f "$BANWALL_CONFIG_FILE" ]
	run config_load
	[ "$status" -eq 0 ]
}

@test "geschriebene Konfiguration ist nur für root lesbar" {
	wiz_werte
	_wiz_schreiben
	[ "$(stat -c '%a' "$BANWALL_CONFIG_FILE")" = "600" ]
}

@test "geschriebene Konfiguration übersteht die Vorprüfung" {
	# Alle Werte müssen als einfache BANWALL_-Zuweisungen herauskommen.
	# Ein Wert mit Anführungszeichen oder Semikolon darin würde die
	# Datei beim nächsten Laden unbrauchbar machen.
	wiz_werte
	WIZ_SSH_ALLOW_USERS="admin deploy"
	WIZ_ALLOW_NETS="203.0.113.0/24 2001:db8::/32"
	_wiz_schreiben
	# Direkt aufrufen, nicht über 'run': dessen Subshell würde die
	# geladenen Werte nicht in den Test zurückgeben.
	config_load
	[ "$BANWALL_SSH_ALLOW_USERS" = "admin deploy" ]
	[ "$BANWALL_ALLOW_NETS" = "203.0.113.0/24 2001:db8::/32" ]
}

@test "alle Werte kommen unverändert in der Datei an" {
	wiz_werte
	WIZ_SSH_PORT="2222"
	WIZ_TCP_PORTS="2222 80"
	WIZ_F2B_MAXRETRY="3"
	WIZ_BLOCKLIST_INTERVAL="hourly"
	_wiz_schreiben
	config_load
	[ "$BANWALL_SSH_PORT" = "2222" ]
	[ "$BANWALL_TCP_PORTS" = "2222 80" ]
	[ "$BANWALL_F2B_MAXRETRY" = "3" ]
	[ "$BANWALL_BLOCKLIST_INTERVAL" = "hourly" ]
}

@test "bestehende Konfiguration wird vor dem Überschreiben gesichert" {
	printf '# von Hand angepasst\nBANWALL_TCP_PORTS="1234"\n' >"$BANWALL_CONFIG_FILE"
	wiz_werte
	_wiz_schreiben
	# Es muss genau eine .bak-Datei mit dem alten Inhalt geben.
	local sicherung
	sicherung="$(find "$BANWALL_CONFIG_DIR" -name '*.bak' | head -1)"
	[ -n "$sicherung" ]
	grep -q 'von Hand angepasst' "$sicherung"
}

@test "abgeschaltete Module werden als 0 geschrieben" {
	wiz_werte
	WIZ_ENABLE_FAIL2BAN=0
	WIZ_ENABLE_BLOCKLIST=0
	WIZ_BLOCKLIST_URLS=""
	_wiz_schreiben
	config_load
	run config_module_enabled fail2ban
	[ "$status" -ne 0 ]
	run config_module_enabled blocklist
	[ "$status" -ne 0 ]
}

@test "ohne Terminal läuft der Assistent nicht, bricht aber nicht ab" {
	# In einer Provisionierung gibt es kein Terminal. Das ist kein
	# Fehler - der Assistent muss das sagen und sauber zurückkehren,
	# damit install.sh nicht mit Exit-Code != 0 endet.
	require_root() { return 0; }
	run banwall_wizard_run </dev/null
	[ "$status" -eq 0 ]
	[[ "$output" == *"Kein Terminal"* ]]
	[[ "$output" == *"banwall setup"* ]]
}

@test "Portliste aus ss wird korrekt geparst" {
	# ss-Stub mit realistischer Ausgabe, inklusive IPv6-Zeile.
	mkdir -p "$BATS_TEST_TMPDIR/stubs"
	cat >"$BATS_TEST_TMPDIR/stubs/ss" <<'STUB'
#!/usr/bin/env bash
cat <<'AUSGABE'
LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))
LISTEN 0 511 [::]:443 [::]:* users:(("nginx",pid=2,fd=6))
LISTEN 0 244 127.0.0.1:5432 0.0.0.0:* users:(("postgres",pid=3,fd=5))
AUSGABE
STUB
	chmod +x "$BATS_TEST_TMPDIR/stubs/ss"
	PATH="$BATS_TEST_TMPDIR/stubs:$PATH"

	run _wiz_lauschende_ports t
	[ "$status" -eq 0 ]
	[[ "$output" == *"22 sshd"* ]]
	[[ "$output" == *"443 nginx"* ]]
	[[ "$output" == *"5432 postgres"* ]]
}
