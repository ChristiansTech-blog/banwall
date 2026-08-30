# Hinweise für Claude Code

## Versionierung

`BANWALL_VERSION` in [bin/banwall](bin/banwall) ist die einzige Stelle, an der
die Version steht — `install.sh` und das Selbstupdate lesen sie von dort.

**Bei jedem Commit die Version prüfen und mitziehen.** Weil `banwall update`
den Standardbranch zieht, ist die Nummer die einzige Auskunft darüber, welchen
Stand ein Server hat. Bleibt sie stehen, melden alle Installationen dasselbe,
egal wie weit sie auseinanderliegen.

Bis zur ersten stabilen Fassung bleibt MAJOR auf 0:

| Änderung | Sprung | Beispiel |
|---|---|---|
| Neue Funktion, neuer Befehl, neues Modul | MINOR (`0.2.0`) | `banwall update` |
| Geändertes Konfigurationsformat, entfernte Option | MINOR | `BANWALL_*` umbenannt |
| Fehlerbehebung, Text, Doku, Tests | PATCH (`0.2.1`) | SSH-Erkennung unter sudo |
| Reines Aufräumen ohne Wirkung nach außen | kein Sprung | Kommentare, Formatierung |

Fasst ein Push mehrere Commits zusammen, zählt die größte Änderung darin.

## Vor jedem Commit

```bash
make syntax
make test          # bats, ohne root
shellcheck --severity=style --external-sources bin/banwall install.sh lib/banwall/*.sh
```

## Sprache

Code, Kommentare, Commit-Nachrichten und Ausgaben sind deutsch. Terminaltexte
knapp halten, Begründungen gehören in die Kommentare und die Doku — nicht in
die Ausgabe.
