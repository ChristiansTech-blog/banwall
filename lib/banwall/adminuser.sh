#!/usr/bin/env bash
#
# adminuser.sh - Admin-Benutzer mit sudo-Rechten und SSH-Key anlegen.
#
# Der einzige Teil des Assistenten, der das System sofort verändert
# statt die Absicht nur aufzuschreiben. Das ist Absicht: Ohne einen
# Benutzer mit sudo-Rechten UND hinterlegtem Key darf 'banwall apply'
# den Passwort-Login nicht abschalten - banwall_ssh_guard bricht sonst
# mit Exit-Code 4 ab. Entstünde der Benutzer erst beim Anwenden, bliebe
# keine Gelegenheit mehr, den Key-Login in einer zweiten Sitzung zu
# testen. Genau dieser Test ist aber das, was vor dem Aussperren
# schützt - deshalb steht der Schritt vorne.
#
# Alle verändernden Kommandos laufen über banwall_run, damit auch hier
# ein Trockenlauf möglich bleibt.

[[ -n "${_BANWALL_ADMINUSER_LOADED:-}" ]] && return 0
_BANWALL_ADMINUSER_LOADED=1

# Die Gruppe, die auf Debian sudo-Rechte trägt. Überschreibbar, weil
# manche Images 'wheel' verwenden - und weil die Tests keine echte
# Gruppe anfassen sollen.
: "${BANWALL_SUDO_GROUP:=sudo}"

# adminuser_name_gueltig NAME
# Debians NAME_REGEX aus adduser.conf: Kleinbuchstabe oder Unterstrich
# am Anfang, danach a-z 0-9 _ - und höchstens 32 Zeichen insgesamt.
# Vorab prüfen statt adduser scheitern zu lassen - dessen Fehlermeldung
# kommt mitten in den Assistenten und erklärt nichts.
adminuser_name_gueltig() {
	[[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

adminuser_exists() {
	getent passwd "$1" >/dev/null 2>&1
}

adminuser_home() {
	getent passwd "$1" 2>/dev/null | cut -d: -f6
}

# adminuser_key_gueltig KEY
# Geprüft wird mit ssh-keygen statt mit einer eigenen Regex: nur
# ssh-keygen weiß, welche Typen und Längen OpenSSH wirklich akzeptiert.
# Ein Key, den der Server später ablehnt, wäre hier schlimmer als eine
# abgelehnte Eingabe.
adminuser_key_gueltig() {
	local key="$1" tmp rc

	[[ -n "${key// /}" ]] || return 1
	# Eine Zeile, kein Optionen-Präfix: was hier hineingeht, wird
	# unverändert an authorized_keys angehängt.
	[[ "$key" != *$'\n'* ]] || return 1
	[[ "$key" =~ ^(ssh|ecdsa|sk-)[A-Za-z0-9@.-]*[[:space:]] ]] || return 1

	tmp="$(mktemp)" || return 1
	printf '%s\n' "$key" >"$tmp"
	ssh-keygen -l -f "$tmp" >/dev/null 2>&1
	rc=$?
	rm -f "$tmp"
	return "$rc"
}

# adminuser_anlegen NAME
# --disabled-password legt das Konto ohne Passwort an; gesetzt wird es
# danach mit passwd. Andernfalls fragt adduser selbst nach Passwort und
# fünf Feldern Adressdaten - mitten im Assistenten.
adminuser_anlegen() {
	local name="$1"
	ensure_cmd adduser adduser "Ohne 'adduser' kann Banwall keinen Benutzer anlegen."
	banwall_run adduser --disabled-password --gecos "" "$name"
}

adminuser_sudo_geben() {
	banwall_run usermod -aG "$BANWALL_SUDO_GROUP" "$1"
}

# adminuser_passwort_setzen NAME
# sudo verlangt das Passwort des Benutzers. Ohne eines kommt man per Key
# zwar auf den Server, aber nicht an root.
adminuser_passwort_setzen() {
	banwall_run passwd "$1"
}

# adminuser_key_hinterlegen NAME HOME KEY
# Der Key wird angehängt, nicht überschrieben: auf einem bestehenden
# Konto kann bereits ein zweiter Rechner eingetragen sein, und den zu
# löschen wäre ein stiller Zugangsverlust.
adminuser_key_hinterlegen() {
	local name="$1" home="$2" key="$3"
	local ssh_dir="$home/.ssh" akf="$home/.ssh/authorized_keys"

	banwall_run mkdir -p "$ssh_dir" || return 1

	if is_dry_run; then
		printf '%s  [dry-run] Key anhängen an %s%s\n' "$_C_DIM" "$akf" "$_C_RST" >&2
	elif [[ -r "$akf" ]] && grep -qxF "$key" "$akf"; then
		log_debug "Key steht bereits in $akf"
	else
		printf '%s\n' "$key" >>"$akf" || return 1
	fi

	# Rechte zuletzt: OpenSSH ignoriert authorized_keys, sobald die
	# Datei oder ihr Verzeichnis für andere schreibbar ist.
	banwall_run chown -R "$name:$name" "$ssh_dir" || return 1
	banwall_run chmod 700 "$ssh_dir" || return 1
	banwall_run chmod 600 "$akf" || return 1
}

# adminuser_einrichten NAME KEY
# Legt an, was fehlt, und lässt bestehen, was schon da ist. Damit ist
# der Aufruf auch für ein vorhandenes Konto ohne Key richtig - der
# häufigere Fall auf einem Server, der schon läuft.
adminuser_einrichten() {
	local name="$1" key="$2" home

	adminuser_name_gueltig "$name" || {
		log_error "'$name' ist kein gültiger Benutzername."
		return 1
	}
	adminuser_key_gueltig "$key" || {
		log_error "Der angegebene SSH-Key ist nicht verwertbar."
		return 1
	}

	if adminuser_exists "$name"; then
		log_info "Benutzer $name existiert bereits - es wird nur ergänzt."
	else
		adminuser_anlegen "$name" || {
			log_error "Benutzer $name konnte nicht angelegt werden."
			return 1
		}
	fi

	adminuser_sudo_geben "$name" || {
		log_error "$name konnte nicht in die Gruppe $BANWALL_SUDO_GROUP aufgenommen werden."
		return 1
	}

	home="$(adminuser_home "$name")"
	if [[ -z "$home" ]]; then
		# Im Trockenlauf existiert das Konto nicht, also auch kein
		# Eintrag in passwd. Der Pfad ist dort nur Anschauungsmaterial.
		is_dry_run || {
			log_error "Kein Home-Verzeichnis für $name gefunden."
			return 1
		}
		home="/home/$name"
	fi

	adminuser_key_hinterlegen "$name" "$home" "$key" || {
		log_error "Der SSH-Key konnte nicht hinterlegt werden."
		return 1
	}
}
