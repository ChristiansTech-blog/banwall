# Banwall

**Ein Befehl zwischen einer frischen Debian-Installation und einem Server, der kein offenes Scheunentor ist.**

Banwall richtet die Grundsicherung eines frisch installierten Debian-13-Servers
ein: Firewall, SSH-Härtung, fail2ban, automatische Sicherheitsupdates und
IP-Blocklisten. Gedacht für die ersten dreißig Minuten nach dem Erhalt eines
neuen vServers — die Zeitspanne, in der die ersten Bruteforce-Versuche schon
laufen, aber noch nichts abgesichert ist.

Banwall ersetzt keine durchdachte Sicherheitsarchitektur. Es sorgt dafür, dass
ein neuer Server nicht als offene Tür im Netz steht.

> [!WARNING]
> Banwall schaltet Passwort-Logins und den Root-Zugang per SSH ab. Ein Fehler
> dabei kostet den Zugriff auf den Server. Es gibt einen eingebauten
> Aussperr-Schutz, aber die goldene Regel gilt trotzdem:
> **beim ersten Lauf eine zweite SSH-Sitzung offen halten.**

## Installation

```bash
git clone https://github.com/ChristiansTech-blog/banwall.git
cd banwall
sudo ./install.sh
```

Danach startet ein Assistent, der durch die Einrichtung führt. Er erkennt
laufende Dienste, den SSH-Port und vorhandene SSH-Schlüssel, erklärt zu jedem
Schritt das Risiko und zeigt am Ende eine Zusammenfassung zum Korrigieren.

**Der Assistent verändert nichts** — er schreibt nur `/etc/banwall/banwall.conf`.
Umgesetzt wird erst danach:

```bash
sudo banwall apply --dry-run    # ansehen, was passieren würde
sudo banwall apply              # anwenden
```

Dann — **bevor** du die aktuelle Sitzung schließt — in einem neuen Terminal
anmelden. Klappt das nicht, nimmt `sudo banwall rollback` in der noch offenen
Sitzung alles zurück.

## Befehle

```bash
banwall setup              geführte Einrichtung (auch später jederzeit)
banwall apply              Einstellungen umsetzen
banwall apply --dry-run    zeigen, was passieren würde
banwall apply -m ssh       nur ein Modul anwenden
banwall status             Ist-Zustand aller Module
banwall rollback           alle Änderungen zurücknehmen
banwall blocklist-update   Blocklisten sofort aktualisieren
```

## Was Banwall einrichtet

| Modul | Was passiert |
|---|---|
| `nftables` | Eigene Tabelle `inet banwall`: eingehend verboten, ausgehend erlaubt, IPv4 und IPv6 in einem Regelsatz. Offene Ports kommen aus der Konfiguration. |
| `fail2ban` | Jail für `sshd`, optional für nginx und Apache. Nutzt `nftables` als Backend. |
| `ssh` | `PermitRootLogin no`, `PasswordAuthentication no`, `MaxAuthTries`, kein Forwarding. |
| `updates` | `unattended-upgrades` für ausschließlich Security-Updates. |
| `blocklist` | systemd-Timer, der IP-Blocklisten holt, prüft und in ein nftables-Set lädt. |

Jedes Modul lässt sich in der Konfiguration einzeln abschalten.

## Aussperr-Schutz

Bevor das SSH-Modul etwas schreibt, weist es nach, dass mindestens ein
Nicht-Root-Benutzer mit sudo-Rechten einen funktionierenden SSH-Schlüssel hat.
Geprüft wird mit `ssh-keygen` — eine `authorized_keys` voller Kommentare sieht
für eine Größenprüfung gut aus, ist aber wertlos.

Findet Banwall keinen solchen Zugang, bricht es mit **Exit-Code 4** ab und
schreibt keine einzige Datei.

Dazu kommt:

- die erzeugte `sshd_config` wird mit `sshd -t` geprüft, **bevor** sshd sie
  sieht; scheitert der Test, wird sie sofort wieder entfernt
- `reload` statt `restart` — bestehende Sitzungen überleben
- ein SSH-Port, der nicht in den offenen Ports steht, lässt schon
  `banwall check` fehlschlagen
- jede geänderte Datei wird vorher nach `/var/lib/banwall/backups/` gesichert

## Konfiguration

Alles steht in `/etc/banwall/banwall.conf` — das Skript wird nie bearbeitet.
`banwall setup` schreibt die Datei, von Hand geht aber auch:

```bash
BANWALL_TCP_PORTS="22 80 443"        # der SSH-Port MUSS hier stehen
BANWALL_ALLOW_NETS="203.0.113.0/24"  # Büro/VPN: voller Zugang, nie gebannt
BANWALL_SSH_PORT="22"
```

`share/banwall.conf.example` enthält jede Option mit Erklärung.

Die Datei muss root gehören und darf für andere nicht schreibbar sein. Erlaubt
sind nur einfache Zuweisungen an `BANWALL_*` — sie wird als root eingelesen,
deshalb lehnt Banwall alles ab, was nach Kommandoausführung aussieht.

## Blocklisten

Voreingestellt ist eine Liste von **[IPv64.net](https://ipv64.net/v64_blocklists)**:

```
https://ipv64.net/blocklists/ipv64_blocklist_blocklistde_all.txt
```

Rund 26.000 Adressen, die durch SSH-, Mail- oder Web-Angriffe auffällig
geworden sind. IPv64 bietet noch zwei weitere Listen an — alle drei sind in
`banwall.conf.example` beschrieben.

Banwall filtert aus jeder Liste automatisch die eigenen Adressen, die
Gegenstelle der laufenden SSH-Sitzung sowie private, Link-Local- und
CGNAT-Adressen heraus. Das ist kein theoretischer Schutz: Die große
IPv64-Liste enthält tatsächlich `100.64.0.0/10` — bei manchen Providern der
echte Kundenanschluss.

> [!NOTE]
> IPv64 ist ein kostenloser Dienst ohne Verfügbarkeitsgarantie und kann laut
> [AGB](https://ipv64.net/agb) jederzeit abgeschaltet werden. Deshalb bittet
> IPv64 auch darum, „die API-Schnittstelle und Webseite" nicht zu überlasten
> — die Voreinstellung ruft die Liste einmal täglich ab, mit zufälliger
> Verzögerung. Bitte nicht ohne Grund auf stündlich stellen.
>
> Ist eine Quelle nicht erreichbar, behält Banwall den zuletzt geladenen Stand.

## Danke

Banwall klebt vorhandene Werkzeuge zusammen. Die eigentliche Arbeit steckt
woanders:

- **[IPv64.net](https://ipv64.net)** — bereitet die Blocklisten auf und stellt
  sie kostenlos bereit. Ohne diese Aufbereitung müsste jedes Projekt die
  Rohlisten selbst zusammensuchen und säubern.
- **[blocklist.de](https://www.blocklist.de)** — die Originalquelle der
  voreingestellten Liste, gespeist aus den Meldungen vieler Serverbetreiber.
- **[Spamhaus](https://www.spamhaus.org)** — DROP-Liste, in der zweiten
  IPv64-Liste enthalten.
- **[nftables](https://netfilter.org)**, **[fail2ban](https://www.fail2ban.org)**
  und **unattended-upgrades** — sie tun die eigentliche Arbeit auf dem Server.

Wer die Blocklisten anders als über Banwall nutzt: Bitte die Bedingungen der
jeweiligen Anbieter beachten, insbesondere maßvolle Abrufhäufigkeit.

## Mitmachen

Fehlerberichte und Pull Requests sind willkommen. Für alles, was größer als ein
paar Zeilen ist, vorher ein Issue aufmachen — das erspart Arbeit an etwas, das
nicht ins Projekt passt.

Vor einem Pull Request:

```bash
make lint     # shellcheck
make syntax   # bash -n
make test     # Unit-Tests (bats, ohne root)
```

Drei Regeln, an denen der Rest hängt:

1. **Alles Verändernde läuft durch `run()`** bzw. `write_file` — daran hängt
   `--dry-run`. Wer daran vorbei arbeitet, macht den Trockenlauf zur Lüge.
2. **Vor der ersten Änderung an einer Datei steht `backup_file`** — sonst kann
   `banwall rollback` sie nicht wiederherstellen.
3. **Zweimal ausführen muss dasselbe Ergebnis liefern.**

Kommentare erklären das Warum; was der Code tut, steht im Code.

**Sicherheitslücken** bitte nicht als öffentliches Issue, sondern über
[GitHub Security Advisories][advisory]. Besonders relevant: alles, was einen
Server aussperrt oder eine Härtung wirkungslos macht.

[advisory]: https://github.com/ChristiansTech-blog/banwall/security/advisories/new

## Voraussetzungen

Debian 13 (Trixie) mit systemd, root-Rechte, und ein Nicht-Root-Benutzer mit
sudo-Rechten und hinterlegtem SSH-Schlüssel.

## Lizenz

[MIT](LICENSE) — nutzen, ändern, weitergeben und in eigene Projekte einbauen
ist ausdrücklich erwünscht, auch kommerziell. Die einzige Bedingung: Der
Copyright-Hinweis und der Lizenztext müssen erhalten bleiben, damit
nachvollziehbar bleibt, woher der Code stammt.

Banwall kommt ohne Garantie. Es fasst Firewall und SSH-Zugang an — was es tut,
ist dokumentiert und im Trockenlauf einsehbar, aber die Verantwortung für den
Server bleibt bei dir.
