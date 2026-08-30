#!/usr/bin/env bash
#
# ssh.sh - SSH-Hardening mit Aussperr-Schutz.
#
# Das gefährlichste Modul: PasswordAuthentication no auf einem Server,
# auf dem kein Key hinterlegt ist, kostet den Zugang. Deshalb steht vor
# jeder Änderung banwall_ssh_guard(), die nachweisen muss, dass mindestens
# ein Nicht-Root-User mit sudo-Rechten einen brauchbaren Key besitzt.
# Findet sie keinen, bricht das Modul mit Exit-Code 4 ab.
#
# Geschrieben wird nach /etc/ssh/sshd_config.d/, nicht in die
# sshd_config selbst: Debians Datei bleibt bei Updates aktuell, und das
# Zurücknehmen ist ein rm statt eines Textpatches.

[[ -n "${_BANWALL_SSH_LOADED:-}" ]] && return 0
_BANWALL_SSH_LOADED=1

readonly BANWALL_SSHD_DROPIN="/etc/ssh/sshd_config.d/99-banwall.conf"
readonly BANWALL_SSHD_MAIN="/etc/ssh/sshd_config"

# Ueberschreibbar, damit die Tests den Aussperr-Schutz gegen eine
# nachgebaute Rechtelage prüfen können statt gegen das echte /etc.
: "${BANWALL_SUDOERS_FILE:=/etc/sudoers}"
: "${BANWALL_SUDOERS_DIR:=/etc/sudoers.d}"

# _ssh_sudo_users - Nicht-Root-Konten mit sudo-Rechten.
_ssh_sudo_users() {
	{
		getent group sudo 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n'
		getent group admin 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n'
		# Direkte Einträge in sudoers, ohne Gruppenmitgliedschaft.
		grep -rhoE '^[[:space:]]*[a-z_][a-z0-9_-]*[[:space:]]+ALL' \
			"$BANWALL_SUDOERS_FILE" "$BANWALL_SUDOERS_DIR" 2>/dev/null |
			awk '{print $1}'
	} | grep -vE '^(root|%|#|$)' | sort -u
}

# _ssh_user_has_key USER - hat der User mindestens einen gültigen Key?
# Geprüft wird mit ssh-keygen, nicht mit 'test -s': eine Datei voller
# Kommentare oder ein abgeschnittener Key sind wertlos, sehen aber
# für eine Größenprüfung gut aus.
_ssh_user_has_key() {
	local user="$1" home akf count
	home="$(getent passwd "$user" | cut -d: -f6)"
	[[ -n "$home" && -d "$home" ]] || return 1

	akf="$home/.ssh/authorized_keys"
	[[ -r "$akf" ]] || return 1

	count="$(ssh-keygen -l -f "$akf" 2>/dev/null | grep -c . || true)"
	((count > 0))
}

# banwall_ssh_guard - der Aussperr-Schutz. Exit-Code 4 heißt: abgebrochen,
# weil das Ergebnis den Admin ausgesperrt hätte.
banwall_ssh_guard() {
	# Nur relevant, wenn Passwort-Logins tatsächlich abgeschaltet werden.
	[[ "$BANWALL_SSH_PASSWORD_AUTH" == "no" ]] || {
		log_debug "PasswordAuthentication bleibt an - Aussperr-Schutz nicht nötig."
		return 0
	}

	require_cmd ssh-keygen "Das Paket openssh-client wird für die Key-Prüfung gebraucht."

	local users=() user ok=()
	mapfile -t users < <(_ssh_sudo_users)

	if ((${#users[@]} == 0)); then
		log_error "Kein Nicht-Root-Benutzer mit sudo-Rechten gefunden."
		log_error "Banwall würde dich mit 'PermitRootLogin no' aussperren."
		log_error ""
		log_error "So legst du einen an - in einer ZWEITEN, offenen Sitzung:"
		log_error "  adduser admin && usermod -aG sudo admin"
		log_error "  ssh-copy-id admin@<server>          # vom Arbeitsplatz aus"
		return 4
	fi

	for user in "${users[@]}"; do
		if _ssh_user_has_key "$user"; then
			ok+=("$user")
			log_debug "SSH-Key gefunden für: $user"
		else
			log_debug "kein gültiger Key für: $user"
		fi
	done

	if ((${#ok[@]} == 0)); then
		log_error "Sudo-Benutzer gefunden (${users[*]}), aber keiner hat einen gültigen SSH-Key."
		log_error "Mit 'PasswordAuthentication no' käme niemand mehr auf diesen Server."
		log_error ""
		log_error "Key hinterlegen - vom Arbeitsplatz aus, Sitzung hier offen lassen:"
		log_error "  ssh-copy-id ${users[0]}@<server>"
		log_error "Danach in einem NEUEN Terminal testen: ssh ${users[0]}@<server>"
		log_error "Erst wenn das ohne Passwort klappt: 'banwall apply' erneut."
		return 4
	fi

	log_ok "Aussperr-Schutz: Key-Login möglich für ${ok[*]}"

	# Zusätzliche Warnung, wenn der Port wechselt: die laufende Sitzung
	# bleibt bestehen, aber der nächste Login geht woanders hin.
	if [[ "$BANWALL_SSH_PORT" != "22" ]]; then
		log_warn "SSH wechselt auf Port $BANWALL_SSH_PORT. Diese Sitzung bleibt offen,"
		log_warn "der nächste Login braucht: ssh -p $BANWALL_SSH_PORT <user>@<server>"
	fi
	return 0
}

banwall_ssh_render() {
	cat <<CONF
# Erzeugt von Banwall - nicht von Hand ändern.
# Änderungen gehören in /etc/banwall/banwall.conf, danach 'banwall apply'.

Port ${BANWALL_SSH_PORT}
PermitRootLogin ${BANWALL_SSH_PERMIT_ROOT}
PasswordAuthentication ${BANWALL_SSH_PASSWORD_AUTH}

# Ohne diese beiden bleibt ein Passwort-Login über Umwege möglich.
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes

PubkeyAuthentication yes
PermitEmptyPasswords no

# Bremst Bruteforce auf Protokollebene: höchstens 3 Versuche, und ab
# 10 unauthentifizierten Verbindungen werden 30 % davon verworfen.
MaxAuthTries 3
MaxSessions 10
LoginGraceTime 30
MaxStartups 10:30:60

# Tote Sitzungen nach ~5 Minuten aufräumen.
ClientAliveInterval 300
ClientAliveCountMax 2

X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitUserEnvironment no
CONF
	[[ -n "${BANWALL_SSH_ALLOW_USERS// /}" ]] &&
		printf '\nAllowUsers %s\n' "$BANWALL_SSH_ALLOW_USERS"
	return 0
}

# _ssh_unit - wie heißt die SSH-Unit auf diesem System?
# Debian nennt sie ssh.service, andere Distributionen sshd.service.
# 'systemctl cat' beantwortet das auch dann, wenn der Dienst gerade
# nicht läuft - anders als is-active oder is-enabled.
_ssh_unit() {
	local unit
	for unit in ssh.service sshd.service; do
		systemctl cat "$unit" >/dev/null 2>&1 && { printf '%s' "$unit"; return 0; }
	done
	return 1
}

# _ssh_reload - die neue Konfiguration übernehmen lassen.
#
# Debian 13 startet sshd per Socket-Aktivierung: ssh.socket lauscht,
# ssh.service ist zwischen zwei Logins inaktiv. Ein 'systemctl reload ssh'
# scheitert dann mit "Unit is not active" - obwohl nichts kaputt ist, denn
# jede neue Verbindung startet sshd ohnehin mit der frischen Konfiguration.
# Ein harter Abbruch an dieser Stelle wäre also ein Fehlalarm, der einen
# vollständig gehärteten Server als gescheitert meldet.
_ssh_reload() {
	local unit err

	unit="$(_ssh_unit)" || unit=""

	if is_dry_run; then
		banwall_run systemctl reload "${unit:-ssh.service}"
		return 0
	fi

	if [[ -z "$unit" ]]; then
		log_warn "Keine SSH-Unit gefunden (weder ssh.service noch sshd.service)."
		log_warn "Die Konfiguration steht in $BANWALL_SSHD_DROPIN und gilt ab dem nächsten sshd-Start."
		return 0
	fi

	if systemctl is-active --quiet "$unit"; then
		err="$(banwall_run systemctl reload "$unit" 2>&1)" && return 0
		log_error "'systemctl reload $unit' fehlgeschlagen:"
		log_error "${err:-keine Ausgabe von systemctl}"
		return 1
	fi

	# Dienst inaktiv - bei Socket-Aktivierung der Normalfall.
	if systemctl is-active --quiet ssh.socket; then
		log_debug "$unit ist inaktiv, ssh.socket lauscht - neue Sitzungen erben die Konfiguration."
		return 0
	fi

	log_warn "$unit läuft nicht, es gibt nichts neu zu laden."
	log_warn "SSH starten mit: systemctl enable --now ${unit%.service}"
	return 0
}

banwall_ssh_apply() {
	ensure_cmd sshd openssh-server "Ohne sshd gibt es nichts zu härten."

	banwall_ssh_guard || return $?

	# Ohne Include-Zeile bliebe das Drop-in wirkungslos - stiller
	# Fehlschlag, der schlimmer wäre als ein Abbruch.
	if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$BANWALL_SSHD_MAIN"; then
		log_error "$BANWALL_SSHD_MAIN enthält keine Include-Zeile für sshd_config.d/."
		log_error "Ergänze ganz oben: Include /etc/ssh/sshd_config.d/*.conf"
		return 1
	fi

	backup_file "$BANWALL_SSHD_DROPIN"
	banwall_run mkdir -p /etc/ssh/sshd_config.d
	banwall_ssh_render | write_file "$BANWALL_SSHD_DROPIN" 0600

	# 'sshd -t' verlangt das Privilege-Separation-Verzeichnis. Systemd
	# legt es als RuntimeDirectory an - auf einem Server, auf dem sshd noch
	# nie lief, fehlt es, und der Test scheitert dann an der Umgebung statt
	# an der Konfiguration ("Missing privilege separation directory").
	[[ -d /run/sshd ]] || banwall_run install -d -m 0755 /run/sshd

	# Konfiguration testen, bevor sshd sie sieht. Ein 'reload' mit
	# kaputter Config lässt den Dienst beim nächsten Start scheitern.
	if ! is_dry_run; then
		local err
		if ! err="$(sshd -t 2>&1)"; then
			log_error "sshd lehnt die neue Konfiguration ab:"
			log_error "$err"
			log_warn "Nehme das Drop-in zurück, damit SSH erreichbar bleibt."
			rm -f "$BANWALL_SSHD_DROPIN"
			return 1
		fi
	fi

	# Debian 13 startet sshd per Socket-Aktivierung. Ein geänderter Port
	# in der sshd_config wird dann ignoriert - der Socket bestimmt ihn.
	if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
		if [[ "$BANWALL_SSH_PORT" != "22" ]]; then
			backup_file /etc/systemd/system/ssh.socket.d/banwall-port.conf
			banwall_run mkdir -p /etc/systemd/system/ssh.socket.d
			printf '[Socket]\nListenStream=\nListenStream=%s\n' "$BANWALL_SSH_PORT" |
				write_file /etc/systemd/system/ssh.socket.d/banwall-port.conf 0644
			banwall_run systemctl daemon-reload
			banwall_run systemctl restart ssh.socket
		fi
	fi

	# reload, nicht restart: bestehende Sitzungen überleben. Falls die
	# neue Konfiguration doch nicht passt, bleibt das Terminal offen.
	_ssh_reload || return 1

	log_ok "SSH gehärtet (Port $BANWALL_SSH_PORT, Root-Login: $BANWALL_SSH_PERMIT_ROOT, Passwort: $BANWALL_SSH_PASSWORD_AUTH)"
	log_warn "Jetzt in einem NEUEN Terminal testen, bevor du diese Sitzung schließt:"
	log_warn "  ssh -p $BANWALL_SSH_PORT <user>@<server>"
	return 0
}

banwall_ssh_status() {
	if [[ -f "$BANWALL_SSHD_DROPIN" ]]; then
		local port root pw
		port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
		root="$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')"
		pw="$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')"
		printf 'Drop-in aktiv (Port %s, root %s, Passwort %s)\n' \
			"${port:-?}" "${root:-?}" "${pw:-?}"
	else
		printf 'kein Banwall-Drop-in vorhanden\n'
	fi
}

banwall_ssh_rollback() {
	[[ -f "$BANWALL_SSHD_DROPIN" ]] || return 0
	banwall_run rm -f "$BANWALL_SSHD_DROPIN"
	banwall_run rm -f /etc/systemd/system/ssh.socket.d/banwall-port.conf
	banwall_run systemctl daemon-reload
	_ssh_reload || true
	log_ok "SSH-Hardening zurückgenommen."
}
