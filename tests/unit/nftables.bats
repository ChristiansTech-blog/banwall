#!/usr/bin/env bats
# Das erzeugte Regelwerk wird gegen 'nft --check' gehalten, sofern nft
# vorhanden ist. Ein Syntaxfehler würde auf dem Zielserver bedeuten,
# dass nftables.service beim Boot scheitert - Server ohne Firewall.

load helper
setup() {
	setup_banwall
	load_module nftables
}

@test "Regelwerk verwirft eingehend per Voreinstellung" {
	run banwall_nftables_render
	[[ "$output" == *"hook input priority filter; policy drop"* ]]
	[[ "$output" == *"hook forward priority filter; policy drop"* ]]
	[[ "$output" == *"hook output priority filter; policy accept"* ]]
}

@test "eine inet-Tabelle deckt IPv4 und IPv6 ab" {
	run banwall_nftables_render
	[[ "$output" == *"table inet banwall"* ]]
	[[ "$output" == *"ip saddr @blocklist4"* ]]
	[[ "$output" == *"ip6 saddr @blocklist6"* ]]
}

@test "konfigurierte Ports landen im Regelwerk" {
	BANWALL_TCP_PORTS="22 80 443"
	BANWALL_UDP_PORTS="51820"
	run banwall_nftables_render
	[[ "$output" == *"tcp dport { 22,80,443 } accept"* ]]
	[[ "$output" == *"udp dport { 51820 } accept"* ]]
}

@test "IPv6-Neighbor-Discovery bleibt erlaubt" {
	# Ohne nd-neighbor-* funktioniert IPv6 im lokalen Netz nicht mehr.
	run banwall_nftables_render
	[[ "$output" == *"nd-neighbor-solicit"* ]]
	[[ "$output" == *"nd-neighbor-advert"* ]]
}

@test "erzeugtes Regelwerk ist für nft gültig" {
	if ! command -v /usr/sbin/nft >/dev/null 2>&1; then
		skip "nft nicht installiert"
	fi
	BANWALL_TCP_PORTS="22 80 443"
	banwall_nftables_render >"$BATS_TEST_TMPDIR/rules.nft"
	run /usr/sbin/nft --check --file "$BATS_TEST_TMPDIR/rules.nft"
	[ "$status" -eq 0 ]
}
