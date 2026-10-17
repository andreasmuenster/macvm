#!/bin/bash
# Baut macvm und signiert es ad-hoc mit der Virtualization-Berechtigung.
# Voraussetzung: Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

swiftc -O -swift-version 5 -o macvm main.swift
codesign --force --sign - --options runtime --entitlements macvm.entitlements macvm
codesign -d --entitlements - macvm
echo "OK: $(pwd)/macvm"
