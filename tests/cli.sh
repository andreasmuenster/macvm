#!/bin/bash
# CLI-Tests für das gebaute Binary: Aufrufsyntax und Abbruchpfade der Optionsparser (fail → Exit 1).
# Jeder Fall bricht ab, bevor eine VM angefasst wird: Die Verzeichnisse existieren nicht oder enthalten
# nur eine config.json in einem temporären Ordner. Nie aufgerufen werden run, create mit gültigen
# Argumenten, stop, firewall mit Ziel, ssh, tunnel mit gültigen Ports, copy-id und ipsw-url.
#
#   tests/cli.sh <binary>
set -uo pipefail

if [[ $# -ne 1 || ! -x $1 ]]; then
    echo "Aufruf: $0 <binary>" >&2
    exit 2
fi
bin=$1
tmp=$(mktemp -d "${TMPDIR:-/tmp}/macvm-cli.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
missing=$tmp/fehlt # existiert nie

checks=0
failures=0

# expect <exit-code> <muster> -- <argumente…>
# Prüft Exit-Code und dass stdout+stderr das Muster (feste Zeichenkette) enthalten.
expect() {
    local want_rc=$1 pattern=$2
    shift 3
    local out rc
    out=$("$bin" "$@" 2>&1)
    rc=$?
    checks=$((checks + 1))
    if [[ $rc -ne $want_rc || $out != *"$pattern"* ]]; then
        failures=$((failures + 1))
        echo "FEHLER: macvm $* → Exit $rc (erwartet $want_rc), Ausgabe ohne '$pattern':" >&2
        printf '%s\n' "$out" | sed 's/^/    /' >&2
    fi
}

usage='macvm – minimaler macOS-VM-Launcher'

# Aufruf ohne oder mit unbekanntem Befehl
expect 1 "$usage" --
expect 1 "$usage" -- gibts-nicht
expect 1 "$usage" -- run
expect 1 "$usage" -- create "$missing"
expect 1 "$usage" -- users "$missing" zuviel
expect 1 "$usage" -- tunnel "$missing"
expect 1 "$usage" -- firewall on
expect 1 "$usage" -- copy-id

# Optionen ohne Wert (typisch: leere Shell-Variable)
expect 1 '--ipsw braucht einen Wert' -- create "$missing" --ipsw
expect 1 "--ipsw braucht einen Wert, bekommen: '--cpus'" -- create "$missing" --ipsw --cpus 4
expect 1 "--user braucht einen Wert, bekommen: ''" -- stop "$missing" --user ''
expect 1 "--models braucht einen Wert" -- run "$missing" --models

# Zahlen und Ports
expect 1 "--cpus erwartet eine positive Zahl, bekommen: '0'" -- create "$missing" --ipsw x.ipsw --cpus 0
expect 1 "--memory erwartet eine positive Zahl, bekommen: '-5'" -- create "$missing" --ipsw x.ipsw --memory -5
expect 1 "--disk erwartet eine positive Zahl, bekommen: 'viel'" -- create "$missing" --ipsw x.ipsw --disk viel
expect 1 "--timeout erwartet eine positive Zahl, bekommen: '1.5'" -- stop "$missing" --timeout 1.5
expect 1 "Ungültiger Port '0'" -- tunnel "$missing" 0
expect 1 "Ungültiger Port '65536'" -- tunnel "$missing" 8000 65536
expect 1 "Ungültiger Port 'http'" -- tunnel "$missing" http

# Fehlendes VM-Verzeichnis: Abbruch beim Lesen von config.json
expect 1 'Fehler:' -- ip "$missing"
expect 1 'Fehler:' -- users "$missing"

# users auf einer Attrappe (nur config.json, keine VM): Anzeige, Migration sshUser → llmUser, Speichern
vm=$tmp/vm
mkdir "$vm"
printf '%s\n' '{"cpus": 4, "memoryGB": 8, "macAddress": "02:00:00:00:00:01", "sshUser": "olduser"}' >"$vm/config.json"
expect 0 'admin  (nicht gesetzt)' -- users "$vm"
expect 0 'llm    olduser' -- users "$vm"
expect 1 "Ungültiger Username '-x'" -- users "$vm" --admin -x
expect 1 "Ungültiger Username 'a b'" -- users "$vm" --llm 'a b'
expect 0 'admin  root-nein' -- users "$vm" --admin root-nein
checks=$((checks + 1))
if ! grep -q '"adminUser" : "root-nein"' "$vm/config.json" || grep -q sshUser "$vm/config.json"; then
    failures=$((failures + 1))
    echo "FEHLER: users --admin hat config.json nicht wie erwartet geschrieben:" >&2
    sed 's/^/    /' "$vm/config.json" >&2
fi
expect 0 'llm    olduser' -- users "$vm"

echo "CLI-Tests: $checks Prüfungen, $failures Fehler"
# Ein Lauf ohne Prüfungen zählt als Fehler.
[[ $failures -eq 0 && $checks -gt 0 ]]
