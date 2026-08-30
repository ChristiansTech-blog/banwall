#!/usr/bin/env bash
#
# updates.sh - unattended-upgrades für Sicherheitsaktualisierungen.
#
# Bewusst nur Security-Updates. Alle Updates automatisch einzuspielen
# wäre auf einem Produktivserver ein Verfügbarkeitsrisiko; ungepatchte
# Sicherheitslücken sind das größere Risiko.

[[ -n "${_BANWALL_UPDATES_LOADED:-}" ]] && return 0
_BANWALL_UPDATES_LOADED=1

readonly BANWALL_UU_FILE="/etc/apt/apt.conf.d/51banwall-unattended-upgrades"

banwall_updates_render() {
	cat <<CONF
// Erzeugt von Banwall - nicht von Hand ändern.

APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";

Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=\${distro_codename},label=Debian-Security";
        "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";
};

// Kaputte Pakete beim nächsten Lauf reparieren statt hängen zu bleiben.
Unattended-Upgrade::AutoFixInterruptedDpkg "true";

// Nicht während des Herunterfahrens installieren - das verlängert
// Reboots unvorhersehbar.
Unattended-Upgrade::InstallOnShutdown "false";

Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

Unattended-Upgrade::Automatic-Reboot "$( ((BANWALL_UPDATES_AUTOREBOOT)) && echo true || echo false)";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "${BANWALL_UPDATES_REBOOT_TIME}";
CONF
}

banwall_updates_apply() {
	pkg_install unattended-upgrades apt-listchanges

	backup_file "$BANWALL_UU_FILE"
	banwall_updates_render | write_file "$BANWALL_UU_FILE" 0644

	# Syntaxprüfung: apt-config bricht bei einer fehlerhaften Datei ab,
	# und dann funktioniert jedes weitere apt-Kommando nicht mehr.
	if ! is_dry_run && ! apt-config dump >/dev/null 2>&1; then
		log_error "apt lehnt $BANWALL_UU_FILE ab. Nehme die Datei zurück."
		rm -f "$BANWALL_UU_FILE"
		return 1
	fi

	service_enable unattended-upgrades
	run systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

	log_ok "Automatische Sicherheitsupdates aktiv$( ((BANWALL_UPDATES_AUTOREBOOT)) && printf ' (Neustart um %s erlaubt)' "$BANWALL_UPDATES_REBOOT_TIME")"
}

banwall_updates_status() {
	if [[ ! -f "$BANWALL_UU_FILE" ]]; then
		printf 'nicht von Banwall konfiguriert\n'
		return 0
	fi
	local last
	last="$(awk '/^[0-9-]+ [0-9:]+,[0-9]+ INFO/{t=$1" "$2} END{print t}' \
		/var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null)"
	printf 'konfiguriert, letzter Lauf: %s\n' "${last:-unbekannt}"
}

banwall_updates_rollback() {
	[[ -f "$BANWALL_UU_FILE" ]] || return 0
	run rm -f "$BANWALL_UU_FILE"
	log_ok "Konfiguration für automatische Updates entfernt."
}
