#!/usr/bin/env bash
#
# install.sh - Banwall aus dem Git-Checkout installieren.
#
# Kopiert nur Dateien und ändert nichts am System. Die eigentliche
# Absicherung passiert erst bei 'banwall apply'. Das ist Absicht:
# installieren und scharfschalten sollen zwei bewusste Schritte sein.
#
# Danach übernimmt der Assistent ('banwall setup'). Auch der schreibt
# nur die Konfiguration - mit einer Ausnahme: Fehlt ein Admin-Benutzer
# mit SSH-Key, bietet er an, einen anzulegen.

set -Eeuo pipefail

PREFIX="${PREFIX:-/usr/local}"
CONFDIR="${CONFDIR:-/etc/banwall}"
STATEDIR="${STATEDIR:-/var/lib/banwall}"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'Fehler: %s\n' "$*" >&2; exit 1; }

# datei_einbauen MODUS QUELLE ZIEL
# Baut über eine temporäre Datei im Zielverzeichnis ein und tauscht sie
# per mv ein. Klingt umständlich, ist aber für 'banwall update' nötig:
# dabei überschreibt die Installation das gerade laufende banwall-Skript.
# Direktes Überschreiben zöge der laufenden bash die noch ungelesenen
# Zeilen unter den Füßen weg; ein mv lässt den alten Inode stehen, bis
# der Prozess fertig ist.
datei_einbauen() {
	local modus="$1" quelle="$2" ziel="$3" tmp
	tmp="$(mktemp "${ziel}.neu.XXXXXX")" || die "Kann in $(dirname "$ziel") nicht schreiben."
	cat "$quelle" >"$tmp"
	chmod "$modus" "$tmp"
	mv -f "$tmp" "$ziel"
}

# Standardmäßig führt die Installation direkt in den Assistenten. Für
# automatisierte Provisionierung lässt sich das abschalten.
WIZARD=1
NUR_DATEIEN=0
AKTION="install"
while (($# > 0)); do
	case "$1" in
	--no-wizard) WIZARD=0 ;;
	# Von 'banwall update' benutzt: dort sind Konfiguration und
	# Assistent längst durch, gebraucht werden nur die neuen Dateien.
	--files-only) WIZARD=0; NUR_DATEIEN=1 ;;
	install | uninstall) AKTION="$1" ;;
	-h | --help)
		cat <<'HILFE'
install.sh - Banwall installieren

  ./install.sh [install|uninstall] [--no-wizard|--files-only]

  install        Dateien kopieren und den Einrichtungsassistenten starten
  uninstall      Programmdateien entfernen (Konfiguration bleibt)
  --no-wizard    Assistenten überspringen, nur Vorlage anlegen
  --files-only   Nur Programmdateien einbauen, sonst nichts
                 (das benutzt 'banwall update')

Umgebungsvariablen: PREFIX (Standard /usr/local), CONFDIR, STATEDIR
HILFE
		exit 0
		;;
	*) die "Unbekanntes Argument '$1'. './install.sh --help' zeigt die Hilfe." ;;
	esac
	shift
done

# root ist kein Selbstzweck - gebraucht wird Schreibrecht auf die
# Zielverzeichnisse. Bei den Standardpfaden heißt das root, bei
# PREFIX=$HOME/.local nicht. Geprüft wird der nächste existierende
# Vorfahre: das Verzeichnis selbst legt die Installation ja erst an.
schreibbar() {
	local pfad="$1"
	while [[ ! -e "$pfad" ]]; do pfad="$(dirname "$pfad")"; done
	[[ -w "$pfad" ]]
}

if [[ "$AKTION" == "install" ]]; then
	for _d in "$PREFIX" "$CONFDIR" "$STATEDIR"; do
		schreibbar "$_d" ||
			die "Kein Schreibrecht auf $_d. Bitte mit sudo ausführen: sudo ./install.sh"
	done
else
	schreibbar "$PREFIX" ||
		die "Kein Schreibrecht auf $PREFIX. Bitte mit sudo ausführen: sudo ./install.sh uninstall"
fi

case "$AKTION" in
install)
	install -d -m 0755 "$PREFIX/bin" "$PREFIX/lib/banwall" "$PREFIX/share/banwall/systemd"
	install -d -m 0700 "$CONFDIR" "$STATEDIR"

	datei_einbauen 0755 "$SRC/bin/banwall" "$PREFIX/bin/banwall"
	for f in "$SRC"/lib/banwall/*.sh; do
		datei_einbauen 0644 "$f" "$PREFIX/lib/banwall/$(basename "$f")"
	done
	for f in "$SRC"/share/systemd/*; do
		datei_einbauen 0644 "$f" "$PREFIX/share/banwall/systemd/$(basename "$f")"
	done
	datei_einbauen 0644 "$SRC/share/banwall.conf.example" \
		"$PREFIX/share/banwall/banwall.conf.example"

	printf 'Banwall %s installiert nach %s\n' \
		"$(sed -n 's/^BANWALL_VERSION="\(.*\)"/\1/p' "$SRC/bin/banwall" | head -1)" \
		"$PREFIX/bin/banwall"

	# Beim Update endet der Auftrag hier: Konfiguration liegt schon,
	# und was zu tun bleibt, sagt 'banwall update' selbst.
	((NUR_DATEIEN)) && exit 0

	# Der Assistent legt die Konfiguration an. Eine vorhandene Datei
	# wird nie kommentarlos überschrieben - der Assistent liest sie als
	# Vorgabe ein und sichert sie vor dem Speichern.
	if [[ "$WIZARD" == "0" ]]; then
		if [[ ! -e "$CONFDIR/banwall.conf" ]]; then
			install -m 0600 "$SRC/share/banwall.conf.example" "$CONFDIR/banwall.conf"
			printf 'Konfigurationsvorlage angelegt: %s\n' "$CONFDIR/banwall.conf"
		fi
		cat <<MSG

Assistent übersprungen (--no-wizard). Nächste Schritte:

  1. $CONFDIR/banwall.conf anpassen - vor allem BANWALL_TCP_PORTS
  2. banwall check              Voraussetzungen prüfen
  3. banwall apply --dry-run    ansehen, was passieren würde
  4. banwall apply              anwenden

Oder jederzeit den Assistenten starten: banwall setup

Halte beim ersten 'apply' eine zweite SSH-Sitzung offen.
MSG
		exit 0
	fi

	# Ohne Terminal - etwa in einem Provisionierungslauf - läuft der
	# Assistent nicht. Dann bekommt der Nutzer die Vorlage und den
	# Hinweis, wie er ihn später nachholt.
	if [[ ! -t 1 ]] || [[ ! -r /dev/tty ]]; then
		[[ -e "$CONFDIR/banwall.conf" ]] ||
			install -m 0600 "$SRC/share/banwall.conf.example" "$CONFDIR/banwall.conf"
		cat <<MSG

Kein Terminal erkannt - der Einrichtungsassistent wurde übersprungen.
Vorlage liegt unter $CONFDIR/banwall.conf

In einer interaktiven Sitzung nachholen:  banwall setup
MSG
		exit 0
	fi

	printf '\nDer Einrichtungsassistent startet jetzt.\n'
	printf 'Er stellt nur Fragen - verändert wird noch nichts.\n\n'
	exec "$PREFIX/bin/banwall" setup
	;;
uninstall)
	# Konfiguration und Backups bleiben liegen: wer deinstalliert, will
	# meist nicht auch noch seine Rollback-Punkte verlieren.
	rm -f "$PREFIX/bin/banwall"
	rm -rf "$PREFIX/lib/banwall" "$PREFIX/share/banwall"
	printf 'Programmdateien entfernt.\n'
	printf 'Erhalten geblieben: %s und %s\n' "$CONFDIR" "$STATEDIR"
	printf "Systemänderungen nimmt 'banwall rollback' zurück - VOR dem Deinstallieren.\n"
	;;
esac
