#!/bin/bash
# Prüft ein gebautes macvm-Binary, bevor es benutzt oder installiert wird:
#   - gültige Ad-hoc-Signatur (codesign --verify --strict) mit Hardened Runtime
#   - eingebettete Entitlements = <entitlements-datei> = genau com.apple.security.virtualization
#   - nur arm64, Mindest-macOS wie beim Build gesetzt (-target)
#
#   scripts/verify-signature.sh <binary> <entitlements-datei> <mindest-macos>
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Aufruf: $0 <binary> <entitlements-datei> <mindest-macos>" >&2
    exit 2
fi
bin=$1
entitlements=$2
want_minos=$3

die() {
    echo "Fehler: $bin: $*" >&2
    exit 1
}

codesign --verify --strict "$bin" || die "Signatur ungültig"

flags=$(codesign -d --verbose=2 "$bin" 2>&1 | sed -n 's/.*flags=0x[0-9a-f]*(\([^)]*\)).*/\1/p')
[[ ",$flags," == *",adhoc,"* ]] || die "nicht ad-hoc signiert (flags: ${flags:-keine})"
[[ ",$flags," == *",runtime,"* ]] || die "ohne Hardened Runtime signiert (flags: ${flags:-keine})"

embedded=$(codesign -d --entitlements - --xml "$bin" 2>/dev/null | plutil -convert json -o - -) ||
    die "Entitlements nicht lesbar"
expected=$(plutil -convert json -o - "$entitlements")
[[ $embedded == "$expected" ]] || die "eingebettete Entitlements $embedded weichen von $entitlements ab ($expected)"
# Bewusst fest verdrahtet: Jede weitere Berechtigung vergrößert die Angriffsfläche und braucht ein Review.
[[ $embedded == '{"com.apple.security.virtualization":true}' ]] ||
    die "erwartet genau com.apple.security.virtualization, gefunden: $embedded"

archs=$(lipo -archs "$bin")
[[ $archs == arm64 ]] || die "erwartet nur arm64, gefunden: $archs"

minos=$(vtool -show-build "$bin" | awk '$1 == "minos" { print $2; exit }')
[[ $minos == "$want_minos" ]] || die "Mindest-macOS $minos statt $want_minos"

echo "OK: $bin (ad-hoc, Hardened Runtime, $embedded, $archs, macOS ≥ $minos)"
