#!/usr/bin/env bats
# 'banwall update' holt ungeprüften Code von außen und ersetzt damit das
# Programm, das anschließend als root Firewall und SSH anfasst. Diese
# Tests halten fest, was dabei nicht passieren darf: ein kaputter Stand
# wird nie eingebaut, und der bisherige ist danach noch da.

load helper

setup() {
	setup_banwall
	load_module selfupdate
	load_module ssh
	load_module adminuser
	load_module wizard
	_wiz_breite

	# Eine vollständige "installierte" Fassung aufbauen ...
	PREFIX="$BATS_TEST_TMPDIR/usr/local"
	mkdir -p "$PREFIX/bin" "$PREFIX/lib/banwall" "$PREFIX/share/banwall/systemd"
	cp "$REPO_ROOT/bin/banwall" "$PREFIX/bin/banwall"
	cp "$REPO_ROOT"/lib/banwall/*.sh "$PREFIX/lib/banwall/"
	cp "$REPO_ROOT"/share/systemd/* "$PREFIX/share/banwall/systemd/"
	cp "$REPO_ROOT/share/banwall.conf.example" "$PREFIX/share/banwall/"

	# ... und Banwall glauben lassen, es liefe von dort.
	export BANWALL_LIB_DIR="$PREFIX/lib/banwall"
	export BANWALL_SHARE_DIR="$PREFIX/share/banwall"
	export BANWALL_CHECKOUT_DIR=""

	# Der "neue Stand", wie er im Tarball läge: GitHub packt alles unter
	# ein Wurzelverzeichnis, deshalb hier genauso.
	QUELLE="$BATS_TEST_TMPDIR/src/banwall-main"
	mkdir -p "$QUELLE"
	cp -r "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/share" \
		"$REPO_ROOT/install.sh" "$QUELLE/"

	export BANWALL_UPDATE_URL="https://example.invalid/banwall.tar.gz"
	# Geprüft wird Schreibrecht, nicht die uid - der Tempordner gehört uns.
	export BANWALL_ASSUME_YES=1
}

# tarball_bauen - aus dem Quellbaum das machen, was curl liefern würde.
tarball_bauen() {
	tar -czf "$BATS_TEST_TMPDIR/banwall.tar.gz" -C "$BATS_TEST_TMPDIR/src" banwall-main
	export STUB_CURL_FILE="$BATS_TEST_TMPDIR/banwall.tar.gz"
}

# version_setzen VERSION - den Quellbaum als neue Fassung ausgeben.
version_setzen() {
	sed -i "s/^BANWALL_VERSION=.*/BANWALL_VERSION=\"$1\"/" "$QUELLE/bin/banwall"
}

@test "meldet einen aktuellen Stand, ohne etwas anzufassen" {
	tarball_bauen
	run banwall_selfupdate_run
	[ "$status" -eq 0 ]
	[[ "$output" == *"aktuellen Stand"* ]]
	# Ein Einbau hätte install.sh gerufen und dabei mktemp-Dateien
	# hinterlassen - hier darf nichts passiert sein.
	[ ! -d "$BANWALL_STATE_DIR/updates" ]
}

@test "baut einen neueren Stand ein" {
	version_setzen "9.9.9"
	tarball_bauen
	run banwall_selfupdate_run
	[ "$status" -eq 0 ]
	[[ "$output" == *"9.9.9"* ]]
	grep -q 'BANWALL_VERSION="9.9.9"' "$PREFIX/bin/banwall"
}

@test "tauscht das laufende Skript per mv aus statt es zu überschreiben" {
	# Beim Update überschreibt die Installation das gerade laufende
	# banwall. Nur wenn die Datei ausgetauscht wird - neuer Inode - liest
	# die laufende bash weiter aus dem alten Stand und stolpert nicht
	# mitten im Skript.
	local vorher nachher
	vorher="$(stat -c '%i' "$PREFIX/bin/banwall")"
	version_setzen "9.9.9"
	tarball_bauen
	run banwall_selfupdate_run
	[ "$status" -eq 0 ]
	nachher="$(stat -c '%i' "$PREFIX/bin/banwall")"
	[ "$vorher" != "$nachher" ]
}

@test "sichert den bisherigen Stand vor dem Einbau" {
	version_setzen "9.9.9"
	tarball_bauen
	run banwall_selfupdate_run
	[ "$status" -eq 0 ]

	local gesichert
	gesichert="$(find "$BANWALL_STATE_DIR/updates" -name banwall -path '*/bin/*' | head -1)"
	[ -n "$gesichert" ]
	grep -q 'BANWALL_VERSION="test"' "$gesichert" ||
		grep -q "BANWALL_VERSION=\"$(sed -n 's/^BANWALL_VERSION="\(.*\)"/\1/p' "$REPO_ROOT/bin/banwall" | head -1)\"" "$gesichert"
}

@test "verweigert einen Stand mit Syntaxfehler" {
	printf '\nif then fi\n' >>"$QUELLE/lib/banwall/nftables.sh"
	version_setzen "9.9.9"
	tarball_bauen
	run banwall_selfupdate_run
	[ "$status" -ne 0 ]
	[[ "$output" == *"Syntaxfehler"* ]]
	! grep -q 'BANWALL_VERSION="9.9.9"' "$PREFIX/bin/banwall"
	! grep -q "if then fi" "$PREFIX/lib/banwall/nftables.sh"
}

@test "verweigert einen unvollständigen Stand" {
	rm -f "$QUELLE/lib/banwall/common.sh"
	tarball_bauen
	run banwall_selfupdate_run
	[ "$status" -ne 0 ]
	[[ "$output" == *"unvollständig"* ]]
	[ -f "$PREFIX/lib/banwall/common.sh" ]
}

@test "verweigert einen Baum, der kein Banwall ist" {
	printf '#!/bin/sh\necho hallo\n' >"$QUELLE/bin/banwall"
	tarball_bauen
	run banwall_selfupdate_run
	[ "$status" -ne 0 ]
	[[ "$output" == *"keine Version"* ]]
}

@test "eine nicht erreichbare Quelle lässt alles unverändert" {
	version_setzen "9.9.9"
	tarball_bauen
	export STUB_CURL_RC=1
	run banwall_selfupdate_run
	[ "$status" -ne 0 ]
	[[ "$output" == *"nicht erreichbar"* ]]
	! grep -q 'BANWALL_VERSION="9.9.9"' "$PREFIX/bin/banwall"
}

@test "im Trockenlauf wird nur gezeigt, was sich ändern würde" {
	version_setzen "9.9.9"
	tarball_bauen
	BANWALL_DRY_RUN=1 run banwall_selfupdate_run
	[ "$status" -eq 0 ]
	[[ "$output" == *"bin/banwall"* ]]
	! grep -q 'BANWALL_VERSION="9.9.9"' "$PREFIX/bin/banwall"
}

@test "ohne Schreibrecht auf die Installation wird abgebrochen" {
	chmod a-w "$PREFIX/lib/banwall"
	run banwall_selfupdate_run
	chmod u+w "$PREFIX/lib/banwall"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Kein Schreibrecht"* ]]
}

@test "aus dem Git-Checkout heraus wird nicht aktualisiert" {
	export BANWALL_CHECKOUT_DIR="$REPO_ROOT"
	run banwall_selfupdate_run
	[ "$status" -ne 0 ]
	[[ "$output" == *"git pull"* ]]
}

@test "ohne Bestätigung wird nichts eingebaut" {
	version_setzen "9.9.9"
	tarball_bauen
	BANWALL_ASSUME_YES=0 run banwall_selfupdate_run
	[ "$status" -eq 0 ]
	[[ "$output" == *"Abgebrochen"* ]]
	! grep -q 'BANWALL_VERSION="9.9.9"' "$PREFIX/bin/banwall"
}

@test "die Konfiguration bleibt beim Update unangetastet" {
	printf 'BANWALL_TCP_PORTS="22 443"\n' >"$BANWALL_CONFIG_FILE"
	version_setzen "9.9.9"
	tarball_bauen
	run banwall_selfupdate_run
	[ "$status" -eq 0 ]
	[ "$(cat "$BANWALL_CONFIG_FILE")" = 'BANWALL_TCP_PORTS="22 443"' ]
}

# --- Update-Prüfung beim Start des Assistenten ---------------------------

# Der Neustart würde per exec den Testlauf übernehmen - hier nur merken,
# dass er gekommen wäre.
neustart_abfangen() {
	_wiz_neustart() { printf 'NEUSTART\n'; }
}

@test "der Assistent meldet einen aktuellen Stand und läuft weiter" {
	neustart_abfangen
	tarball_bauen
	run _wiz_update
	[ "$status" -eq 0 ]
	[[ "$output" == *"ist aktuell"* ]]
	[[ "$output" != *"NEUSTART"* ]]
}

@test "der Assistent bietet eine neuere Fassung an und startet danach neu" {
	neustart_abfangen
	_wiz_jn() { printf -v "$1" '1'; }
	version_setzen "9.9.9"
	tarball_bauen
	run _wiz_update
	[ "$status" -eq 0 ]
	[[ "$output" == *"9.9.9"* ]]
	[[ "$output" == *"NEUSTART"* ]]
	grep -q 'BANWALL_VERSION="9.9.9"' "$PREFIX/bin/banwall"
}

@test "wer im Assistenten ablehnt, richtet mit der alten Fassung ein" {
	neustart_abfangen
	# _wiz_jn liest von /dev/tty, das es im Testlauf nicht gibt - hier
	# steht die Antwort "nein" an seiner Stelle.
	_wiz_jn() { printf -v "$1" '0'; }
	version_setzen "9.9.9"
	tarball_bauen
	run _wiz_update
	[ "$status" -eq 0 ]
	[[ "$output" != *"NEUSTART"* ]]
	! grep -q 'BANWALL_VERSION="9.9.9"' "$PREFIX/bin/banwall"
}

@test "eine nicht erreichbare Quelle hält den Assistenten nicht auf" {
	neustart_abfangen
	export STUB_CURL_RC=1
	run _wiz_update
	[ "$status" -eq 0 ]
	[[ "$output" == *"keine Verbindung"* ]]
}

@test "ein kaputter Stand hält den Assistenten nicht auf" {
	neustart_abfangen
	printf '\nif then fi\n' >>"$QUELLE/lib/banwall/common.sh"
	version_setzen "9.9.9"
	tarball_bauen
	run _wiz_update
	[ "$status" -eq 0 ]
	[[ "$output" != *"NEUSTART"* ]]
	! grep -q "if then fi" "$PREFIX/lib/banwall/common.sh"
}

@test "im Git-Checkout prüft der Assistent gar nicht erst" {
	neustart_abfangen
	export BANWALL_CHECKOUT_DIR="$REPO_ROOT"
	tarball_bauen
	run _wiz_update
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "im Trockenlauf baut der Assistent nichts ein" {
	neustart_abfangen
	version_setzen "9.9.9"
	tarball_bauen
	BANWALL_DRY_RUN=1 run _wiz_update
	[ "$status" -eq 0 ]
	[[ "$output" == *"dry-run"* ]]
	! grep -q 'BANWALL_VERSION="9.9.9"' "$PREFIX/bin/banwall"
}

@test "ein neuer Stand bei gleicher Versionsnummer wird verständlich gemeldet" {
	neustart_abfangen
	_wiz_jn() { printf -v "$1" '0'; }
	# Gleiche Nummer auf beiden Seiten - im Test trägt die Installation
	# die Kennung "test" aus helper.bash.
	version_setzen "$BANWALL_VERSION"
	printf '\n# neuer Kommentar\n' >>"$QUELLE/lib/banwall/nftables.sh"
	tarball_bauen
	run _wiz_update
	[ "$status" -eq 0 ]
	[[ "$output" == *"neuer Stand verfügbar"* ]]
	[[ "$output" != *"neuere Fassung"* ]]
}
