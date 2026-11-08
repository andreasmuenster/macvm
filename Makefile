# macvm – Build mit Bordmitteln der Xcode Command Line Tools (swiftc, codesign, make).
#
#   make              bauen und ad-hoc signieren
#   make verify       Signatur, Entitlements, Architektur und Mindest-macOS prüfen
#   make install      nach $(PREFIX)/bin kopieren (Standard: ~/.local/bin)
#   make uninstall    wieder entfernen
#   make clean        Build-Ausgabe löschen

PREFIX       ?= $(HOME)/.local
BINDIR       := $(PREFIX)/bin
BIN          := macvm
SRC          := main.swift
ENTITLEMENTS := macvm.entitlements
# Fest auf Apple Silicon und macOS 26: Das vmnet-Netz (vmnet_network_create) gibt es erst ab macOS 26.
# Ohne -target erbt das Binary als Mindestversion die macOS-Version des Build-Hosts.
MINOS        := 26.0
TARGET       := arm64-apple-macos$(MINOS)
SWIFTFLAGS   ?= -O -swift-version 5

.PHONY: all install uninstall clean verify

all: $(BIN)

# Neu gebaut wird nur, wenn sich Quelle, Entitlements oder Build-Einstellungen ändern.
$(BIN): $(SRC) $(ENTITLEMENTS) Makefile
	swiftc -target $(TARGET) $(SWIFTFLAGS) -o $@ $(SRC)
	codesign --force --sign - --options runtime --entitlements $(ENTITLEMENTS) $@
	@$(MAKE) --no-print-directory verify

# Bricht ab, wenn das Binary nicht genau com.apple.security.virtualization trägt.
verify:
	@scripts/verify-signature.sh $(BIN) $(ENTITLEMENTS) $(MINOS)

install: $(BIN)
	install -d $(BINDIR)
	install -m 755 $(BIN) $(BINDIR)/$(BIN)
	@codesign --verify --strict $(BINDIR)/$(BIN)
	@echo "Installiert: $(BINDIR)/$(BIN)"

uninstall:
	rm -f $(BINDIR)/$(BIN)

clean:
	rm -f $(BIN)
	rm -rf $(BIN).dSYM
