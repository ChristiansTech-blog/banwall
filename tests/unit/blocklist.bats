#!/usr/bin/env bats
# Blocklisten kommen von Dritten. Diese Tests halten fest, dass Müll
# aussortiert wird und dass eigene Adressen es niemals in ein Set
# schaffen - der zweite Weg, sich mit Banwall auszusperren.

load helper
setup() {
	setup_banwall
	load_module nftables
	load_module blocklist
}

@test "erkennt IPv4-Adressen und CIDR-Präfixe" {
	run bash -c 'printf "192.0.2.1\n198.51.100.0/24\n" | _bl_parse 4'
	[ "$status" -eq 0 ]
	[[ "$output" == *"192.0.2.1"* ]]
	[[ "$output" == *"198.51.100.0/24"* ]]
}

@test "verwirft Müll und Hostnamen" {
	result="$(printf 'kein-eintrag\nexample.org\n999.1.1.1\n\n' | _bl_parse 4 || true)"
	[ -z "$result" ]
}

@test "schneidet Kommentare ab" {
	run bash -c 'printf "192.0.2.1 # bekannter Scanner\n; 198.51.100.5\n" | _bl_parse 4'
	[[ "$output" == *"192.0.2.1"* ]]
	[[ "$output" != *"#"* ]]
}

@test "trennt IPv6 von IPv4" {
	v6="$(printf '192.0.2.1\n2001:db8::1\n' | _bl_parse 6)"
	[ "$v6" = "2001:db8::1" ]
}

@test "filtert private und Loopback-Adressen heraus" {
	result="$(printf '10.0.0.1\n192.168.1.1\n127.0.0.1\n172.16.5.5\n203.0.113.9\n' |
		_bl_filter_safe)"
	[[ "$result" == "203.0.113.9" ]]
}

@test "filtert die Gegenstelle der laufenden SSH-Sitzung heraus" {
	export SSH_CLIENT="203.0.113.7 54321 22"
	result="$(printf '203.0.113.7\n198.51.100.1\n' | _bl_filter_safe)"
	[[ "$result" != *"203.0.113.7"* ]]
	[[ "$result" == *"198.51.100.1"* ]]
}

@test "CGNAT und Link-Local werden gefiltert" {
	# Beide stehen tatsächlich in ipv64_blocklist_all.txt. 100.64.0.0/10
	# ist bei manchen Providern der echte Kundenanschluss.
	result="$(printf '100.64.0.0/10\n169.254.0.0/16\n203.0.113.9\n' | _bl_filter_safe)"
	[ "$result" = "203.0.113.9" ]
}

@test "IPv64-Format wird vollständig erkannt" {
	# Auszug im Originalformat: reine /32-Präfixe, LF, keine Kommentare.
	run bash -c 'printf "192.0.2.10/32\n192.0.2.11/32\n2600:3c00::2000:25ff:fecd:617a/64\n" | _bl_parse 4'
	[ "${#lines[@]}" -eq 2 ]
	[[ "$output" == *"192.0.2.10/32"* ]]
}

@test "IPv6 mit gesetzten Host-Bits wird nicht verworfen" {
	# 61 der 62 IPv6-Einträge bei IPv64 sehen so aus. nftables
	# normalisiert sie beim Einfügen selbst - der Parser darf sie also
	# nicht vorher aussortieren.
	run bash -c 'printf "2001:16b8:b1af:d600:b5c8:12ae:b33:9fa4/64\n" | _bl_parse 6'
	[ "$output" = "2001:16b8:b1af:d600:b5c8:12ae:b33:9fa4/64" ]
}

# --- blockweises Laden ---------------------------------------------------
# Eine einzige Transaktion mit allen Elementen scheitert ab etwa 12.000
# Einträgen am Netlink-Puffer. Diese Tests halten fest, dass gestückelt
# wird und in welcher Reihenfolge.

@test "_bl_nft_batch stückelt große Listen" {
	local liste="$BATS_TEST_TMPDIR/gross.txt"
	seq 1 1200 | awk '{printf "203.0.%d.%d/32\n", int($1/256), $1%256}' >"$liste"

	run _bl_nft_batch add blocklist4 "$liste"
	[ "$status" -eq 0 ]
	# 1200 Einträge bei 500 pro Block = 3 Aufrufe
	[ "$(grep -c 'nft add element' "$STUB_LOG")" -eq 3 ]
}

@test "_bl_nft_batch macht bei leerer Datei nichts" {
	: >"$BATS_TEST_TMPDIR/leer.txt"
	run _bl_nft_batch add blocklist4 "$BATS_TEST_TMPDIR/leer.txt"
	[ "$status" -eq 0 ]
	[ ! -s "$STUB_LOG" ]
}

@test "Erstlauf ohne gespeicherten Stand flusht und lädt vollständig" {
	printf '203.0.113.1/32\n203.0.113.2/32\n' >"$BATS_TEST_TMPDIR/neu.txt"
	rm -f "$BANWALL_BL_DIR/current-v4.txt"
	run _bl_load_v4 "$BATS_TEST_TMPDIR/neu.txt"
	[ "$status" -eq 0 ]
	stub_called "nft flush set inet banwall blocklist4"
	stub_called "nft add element inet banwall blocklist4"
}

@test "Folgelauf lädt nur die Differenz und flusht nicht" {
	mkdir -p "$BANWALL_BL_DIR"
	printf '203.0.113.1/32\n203.0.113.2/32\n' >"$BANWALL_BL_DIR/current-v4.txt"
	printf '203.0.113.2/32\n203.0.113.3/32\n' >"$BATS_TEST_TMPDIR/neu.txt"

	run _bl_load_v4 "$BATS_TEST_TMPDIR/neu.txt"
	[ "$status" -eq 0 ]

	# Kein flush: das Set darf nie leer werden, sonst käme während des
	# Ladens jede zuvor gesperrte Adresse durch.
	! grep -q "flush set inet banwall blocklist4" "$STUB_LOG"
	# .3 kommt dazu, .1 fällt weg, .2 bleibt unangetastet.
	grep -q "add element inet banwall blocklist4 { 203.0.113.3/32 }" "$STUB_LOG"
	grep -q "delete element inet banwall blocklist4 { 203.0.113.1/32 }" "$STUB_LOG"
}

@test "erst hinzufügen, dann entfernen" {
	mkdir -p "$BANWALL_BL_DIR"
	printf '203.0.113.1/32\n' >"$BANWALL_BL_DIR/current-v4.txt"
	printf '203.0.113.9/32\n' >"$BATS_TEST_TMPDIR/neu.txt"
	_bl_load_v4 "$BATS_TEST_TMPDIR/neu.txt"

	local add_zeile del_zeile
	add_zeile="$(grep -n 'add element' "$STUB_LOG" | head -1 | cut -d: -f1)"
	del_zeile="$(grep -n 'delete element' "$STUB_LOG" | head -1 | cut -d: -f1)"
	[ "$add_zeile" -lt "$del_zeile" ]
}

@test "IPv6 wird immer vollständig neu geladen" {
	# Differenz ist bei IPv6 nicht verlässlich, weil nftables Präfixe
	# beim Einfügen normalisiert und die gespeicherte Liste dann nicht
	# mehr zum Set-Inhalt passt.
	printf '2001:db8::/64\n' >"$BATS_TEST_TMPDIR/neu6.txt"
	run _bl_load_v6 "$BATS_TEST_TMPDIR/neu6.txt"
	[ "$status" -eq 0 ]
	stub_called "nft flush set inet banwall blocklist6"
}
