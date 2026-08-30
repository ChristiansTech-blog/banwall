#!/usr/bin/env bats
# ensure_cmd war der Grund für einen echten Ausfall: fehlte curl, brach
# 'banwall apply -m blocklist' ab, obwohl das Paket direkt danach hätte
# installiert werden sollen. Der Fallback stand hinter einem ||, das nie
# ausgewertet wurde, weil require_cmd das Programm beendet.

load helper
setup() {
	setup_banwall
	BANWALL_DRY_RUN=0
}

@test "ensure_cmd installiert nichts, wenn das Kommando da ist" {
	run ensure_cmd sed sed
	[ "$status" -eq 0 ]
	! stub_called "apt-get install"
}

@test "ensure_cmd installiert das Paket, wenn das Kommando fehlt" {
	# dpkg-query meldet 'nicht installiert', apt-get legt den Stub an.
	export STUB_DPKG_QUERY_RC=1
	run ensure_cmd banwall-testkommando banwall-testpaket
	stub_called "apt-get install"
}

@test "ensure_cmd bricht mit 3 ab, wenn das Kommando danach immer noch fehlt" {
	export STUB_DPKG_QUERY_RC=1
	run ensure_cmd banwall-testkommando banwall-testpaket
	[ "$status" -eq 3 ]
	[[ "$output" == *"banwall-testkommando"* ]]
}

@test "ensure_cmd lässt den Trockenlauf weiterlaufen" {
	# Im Trockenlauf wird nichts installiert - hier abzubrechen hiesse,
	# den Trockenlauf dort scheitern zu lassen, wo der echte Lauf liefe.
	export STUB_DPKG_QUERY_RC=1
	BANWALL_DRY_RUN=1
	run ensure_cmd banwall-testkommando banwall-testpaket
	[ "$status" -eq 0 ]
	! stub_called "apt-get install"
}
