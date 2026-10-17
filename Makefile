# macvm – Build mit Bordmitteln der Xcode Command Line Tools (swiftc, codesign, make).
#
#   make              bauen und ad-hoc signieren
#   make install      nach $(PREFIX)/bin kopieren (Standard: ~/.local/bin)
#   make uninstall    wieder entfernen
#   make clean        Build-Ausgabe löschen

PREFIX       ?= $(HOME)/.local
BINDIR       := $(PREFIX)/bin
BIN          := macvm
SRC          := main.swift
ENTITLEMENTS := macvm.entitlements
SWIFTFLAGS   ?= -O -swift-version 5

.PHONY: all install uninstall clean verify

all: $(BIN)

# Neu gebaut wird nur, wenn sich Quelle oder Entitlements ändern.
$(BIN): $(SRC) $(ENTITLEMENTS)
	swiftc $(SWIFTFLAGS) -o $@ $(SRC)
	codesign --force --sign - --options runtime --entitlements $(ENTITLEMENTS) $@
	@$(MAKE) --no-print-directory verify

# Zeigt die eingebetteten Entitlements – erwartet: genau com.apple.security.virtualization.
verify:
	@codesign --verify --strict $(BIN)
	@codesign -d --entitlements - $(BIN) 2>/dev/null
	@echo "OK: $(CURDIR)/$(BIN)"

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
