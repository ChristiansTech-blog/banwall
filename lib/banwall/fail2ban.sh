#!/usr/bin/env bash
#
# fail2ban.sh - Jail für sshd, optional für Webserver.
#
# Konfiguriert wird über /etc/fail2ban/jail.d/, nicht über jail.conf.
# Debians jail.conf wird bei Paketupdates ersetzt; alles in jail.d/
# überlebt das und lässt sich mit einem rm wieder loswerden.

[[ -n "${_BANWALL_FAIL2BAN_LOADED:-}" ]] && return 0
_BANWALL_FAIL2BAN_LOADED=1

readonly BANWALL_F2B_JAIL="/etc/fail2ban/jail.d/banwall.local"

banwall_fail2ban_render() {
	cat <<CONF
# Erzeugt von Banwall - nicht von Hand ändern.

[DEFAULT]
bantime  = ${BANWALL_F2B_BANTIME}
findtime = ${BANWALL_F2B_FINDTIME}
maxretry = ${BANWALL_F2B_MAXRETRY}

# nftables statt iptables: Debian 13 bringt kein iptables mehr mit, und
# die Standardaktion würde sonst still fehlschlagen.
banaction      = nftables[type=multiport]
banaction_allports = nftables[type=allports]

# Eigene Netze nie sperren - sonst sperrt ein vertipptes Passwort aus
# dem Büro das ganze Büro aus.
ignoreip = 127.0.0.1/8 ::1${BANWALL_ALLOW_NETS:+ ${BANWALL_ALLOW_NETS}}

# Debian 13 loggt SSH nach journald, nicht mehr nach /var/log/auth.log.
backend = systemd

[sshd]
enabled  = true
port     = ${BANWALL_SSH_PORT}
mode     = aggressive
CONF

	((BANWALL_F2B_WEBSERVER)) && cat <<'CONF'

[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled = true

[apache-auth]
enabled = true

[apache-badbots]
enabled = true
CONF
	return 0
}

banwall_fail2ban_apply() {
	# python3-systemd wird für 'backend = systemd' gebraucht. Fehlt es,
	# startet fail2ban zwar, findet aber nie einen Loginversuch.
	pkg_install fail2ban python3-systemd

	backup_file "$BANWALL_F2B_JAIL"
	banwall_run mkdir -p /etc/fail2ban/jail.d
	banwall_fail2ban_render | write_file "$BANWALL_F2B_JAIL" 0644

	if ! is_dry_run; then
		# Konfiguration prüfen, bevor der Dienst sie lädt.
		if ! fail2ban-client --test >/dev/null 2>&1; then
			log_error "fail2ban lehnt die Konfiguration ab:"
			log_error "$(fail2ban-client --test 2>&1 | tail -5)"
			rm -f "$BANWALL_F2B_JAIL"
			return 1
		fi
	fi

	service_enable fail2ban
	banwall_run systemctl reload fail2ban 2>/dev/null || true

	log_ok "fail2ban aktiv (sshd, ${BANWALL_F2B_MAXRETRY} Versuche in ${BANWALL_F2B_FINDTIME}, Sperre ${BANWALL_F2B_BANTIME})"
}

banwall_fail2ban_status() {
	if ! command -v fail2ban-client >/dev/null 2>&1; then
		printf 'fail2ban nicht installiert\n'
		return 0
	fi
	if service_active fail2ban; then
		local jails banned
		jails="$(fail2ban-client status 2>/dev/null |
			awk -F: '/Jail list/{gsub(/^[ \t]+/,"",$2); print $2}')"
		banned="$(fail2ban-client status sshd 2>/dev/null |
			awk '/Currently banned/{print $NF}')"
		printf 'läuft, Jails:%s, aktuell gesperrt (sshd): %s\n' \
			"${jails:- keine}" "${banned:-0}"
	else
		printf 'installiert, läuft aber nicht\n'
	fi
}

banwall_fail2ban_rollback() {
	[[ -f "$BANWALL_F2B_JAIL" ]] || return 0
	banwall_run rm -f "$BANWALL_F2B_JAIL"
	banwall_run systemctl reload fail2ban 2>/dev/null || true
	log_ok "fail2ban-Jail von Banwall entfernt."
}
