#!/usr/bin/env bash
#
# run.sh - Integrationstest in einem Wegwerf-Container.
#
# Prüft das, was Unit-Tests nicht können: dass apt, nft, sshd und
# systemd die erzeugten Dateien tatsächlich akzeptieren, und dass ein
# zweiter Lauf nichts kaputt macht. Der Container wird danach zerstört -
# kein echter Server kommt zu Schaden.
#
#   bash tests/integration/run.sh

set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="banwall-test"
NAME="banwall-test-$$"

if command -v podman >/dev/null 2>&1; then
	ENGINE=podman
	RUNFLAGS=(--systemd=always --cap-add=NET_ADMIN --cap-add=NET_RAW)
elif command -v docker >/dev/null 2>&1; then
	ENGINE=docker
	# Docker braucht den cgroup-Mount, damit systemd startet.
	RUNFLAGS=(--privileged --tmpfs /run --tmpfs /run/lock
		-v /sys/fs/cgroup:/sys/fs/cgroup:ro)
else
	printf 'Fehler: weder podman noch docker gefunden.\n' >&2
	exit 3
fi

cleanup() { "$ENGINE" rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

step() { printf '\n\033[34m==>\033[0m %s\n' "$*"; }
inside() { "$ENGINE" exec "$NAME" bash -c "$1"; }

step "Image bauen"
"$ENGINE" build -t "$IMAGE" -f tests/integration/Containerfile "$REPO"

step "Container starten"
"$ENGINE" run -d --name "$NAME" "${RUNFLAGS[@]}" "$IMAGE"
for _ in {1..30}; do
	inside 'systemctl is-system-running --wait' >/dev/null 2>&1 && break
	sleep 1
done

step "Unit-Tests im Container"
inside 'cd /opt/banwall && bats tests/unit'

step "shellcheck"
inside 'cd /opt/banwall && shellcheck --severity=style bin/banwall install.sh lib/banwall/*.sh'

step "Installation"
inside 'cd /opt/banwall && ./install.sh install'
inside 'command -v banwall && banwall version'

step "Konfiguration für den Test setzen"
inside 'cat > /etc/banwall/banwall.conf <<CONF
BANWALL_ENABLE_NFTABLES=1
BANWALL_ENABLE_FAIL2BAN=0
BANWALL_ENABLE_SSH=1
BANWALL_ENABLE_UPDATES=1
BANWALL_ENABLE_BLOCKLIST=0
BANWALL_TCP_PORTS="22 80"
BANWALL_SSH_PORT="22"
CONF
chmod 600 /etc/banwall/banwall.conf'

step "banwall check"
inside 'banwall check'

step "Trockenlauf darf nichts verändern"
inside 'nft list ruleset > /tmp/vorher.txt; banwall apply --dry-run --yes >/dev/null
nft list ruleset > /tmp/nachher.txt
diff -q /tmp/vorher.txt /tmp/nachher.txt || { echo "FEHLER: dry-run hat das Regelwerk verändert"; exit 1; }
test ! -e /etc/ssh/sshd_config.d/99-banwall.conf || { echo "FEHLER: dry-run hat eine Datei angelegt"; exit 1; }
echo "Trockenlauf sauber."'

step "Erster Lauf"
inside 'banwall apply --yes'

step "Ergebnis prüfen"
inside 'nft list table inet banwall >/dev/null && echo "nftables-Tabelle vorhanden"
sshd -T | grep -q "^passwordauthentication no" && echo "Passwort-Login abgeschaltet"
sshd -T | grep -q "^permitrootlogin no" && echo "Root-Login abgeschaltet"
test -f /etc/apt/apt.conf.d/51banwall-unattended-upgrades && echo "Update-Konfiguration vorhanden"'

step "Zweiter Lauf muss idempotent sein"
inside 'nft list table inet banwall > /tmp/lauf1.txt
sha256sum /etc/ssh/sshd_config.d/99-banwall.conf > /tmp/ssh1.txt
banwall apply --yes
nft list table inet banwall > /tmp/lauf2.txt
diff -u /tmp/lauf1.txt /tmp/lauf2.txt || { echo "FEHLER: Regelwerk hat sich beim zweiten Lauf geändert"; exit 1; }
sha256sum -c /tmp/ssh1.txt || { echo "FEHLER: sshd-Konfiguration hat sich geändert"; exit 1; }
echo "Idempotent."'

step "Aussperr-Schutz muss auslösen"
inside 'rm -f /home/admin/.ssh/authorized_keys
rm -f /etc/ssh/sshd_config.d/99-banwall.conf
set +e
banwall apply --yes -m ssh
rc=$?
set -e
test "$rc" -eq 4 || { echo "FEHLER: erwartet war Exit-Code 4, war aber $rc"; exit 1; }
test ! -e /etc/ssh/sshd_config.d/99-banwall.conf || { echo "FEHLER: trotz Abbruch geschrieben"; exit 1; }
echo "Aussperr-Schutz greift (Exit-Code 4)."'

step "Blocklist gegen die echte IPv64-Liste"
inside 'set -e
sed -i "s/^BANWALL_ENABLE_BLOCKLIST=.*/BANWALL_ENABLE_BLOCKLIST=1/" /etc/banwall/banwall.conf
echo "BANWALL_BLOCKLIST_URLS=\"https://ipv64.net/blocklists/ipv64_blocklist_blocklistde_all.txt\"" >> /etc/banwall/banwall.conf
banwall apply --yes -m nftables
if banwall blocklist-update; then
  n=$(nft list set inet banwall blocklist4 | tr -d "\n\t " | sed -n "s/.*elements={\([^}]*\)}.*/\1/p" | tr "," "\n" | grep -c .)
  echo "geladene IPv4-Einträge: $n"
  test "$n" -gt 10000 || { echo "FEHLER: zu wenige Einträge geladen"; exit 1; }
  echo "Zweiter Lauf (nur Differenz):"
  time banwall blocklist-update
else
  echo "HINWEIS: IPv64 nicht erreichbar - Blocklist-Test übersprungen."
fi'

step "status"
inside 'banwall status'

step "rollback"
inside 'banwall rollback --yes
test ! -e /etc/ssh/sshd_config.d/99-banwall.conf && echo "SSH-Drop-in entfernt"
nft list table inet banwall >/dev/null 2>&1 && { echo "FEHLER: Tabelle noch da"; exit 1; }
echo "Tabelle entfernt."'

printf '\n\033[32m✓\033[0m Alle Integrationstests bestanden.\n'
