# macvm – Build mit Bordmitteln der Xcode Command Line Tools (swiftc, codesign, make).
#
#   make              bauen und ad-hoc signieren
#   make verify       Signatur, Entitlements, Architektur und Mindest-macOS prüfen
#   make check        alles, was auch die CI prüft (Build, Signatur, Tests); lässt ./macvm unberührt
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
# Ausgabe von `make check`, getrennt vom Binary, das gerade benutzt wird.
CHECKDIR     := .build/check
# Bis zu dieser Zeile ist main.swift Bibliothek für die Unit-Tests, danach kommt Top-Level-Code.
ENTRY_MARK   := // MARK: - Einstieg

.PHONY: all install uninstall clean verify check

all: $(BIN)

# Neu gebaut wird nur, wenn sich Quelle, Entitlements oder Build-Einstellungen ändern.
$(BIN): $(SRC) $(ENTITLEMENTS) Makefile
	swiftc -target $(TARGET) $(SWIFTFLAGS) -o $@ $(SRC)
	codesign --force --sign - --options runtime --entitlements $(ENTITLEMENTS) $@
	@$(MAKE) --no-print-directory verify

# Bricht ab, wenn das Binary nicht genau com.apple.security.virtualization trägt.
verify:
	@scripts/verify-signature.sh $(BIN) $(ENTITLEMENTS) $(MINOS)

# Gleicher Einstieg für Entwickler und CI (.github/workflows/check.yml). Baut immer frisch.
#   1. Release-Build wie `make`, aber mit Warnungen als Fehler, signieren, Signatur prüfen
#   2. Unit-Tests: main.swift bis $(ENTRY_MARK) plus tests/UnitTests.swift als eigenes Programm
#   3. CLI-Tests gegen das signierte Binary (nur Abbruchpfade, keine VM)
check:
	rm -rf $(CHECKDIR)
	mkdir -p $(CHECKDIR)
	swiftc -target $(TARGET) $(SWIFTFLAGS) -warnings-as-errors -o $(CHECKDIR)/$(BIN) $(SRC)
	codesign --force --sign - --options runtime --entitlements $(ENTITLEMENTS) $(CHECKDIR)/$(BIN)
	scripts/verify-signature.sh $(CHECKDIR)/$(BIN) $(ENTITLEMENTS) $(MINOS)
	@grep -qx '$(ENTRY_MARK)' $(SRC) || { echo "Fehler: Marke '$(ENTRY_MARK)' fehlt in $(SRC)" >&2; exit 1; }
	sed '\|^$(ENTRY_MARK)$$|,$$d' $(SRC) > $(CHECKDIR)/MacVMCore.swift
	swiftc -parse-as-library -target $(TARGET) $(SWIFTFLAGS) -warnings-as-errors \
		-o $(CHECKDIR)/unit-tests $(CHECKDIR)/MacVMCore.swift tests/UnitTests.swift
	$(CHECKDIR)/unit-tests
	tests/cli.sh $(CHECKDIR)/$(BIN)
	@echo "make check: alles grün"

install: $(BIN)
	install -d $(BINDIR)
	install -m 755 $(BIN) $(BINDIR)/$(BIN)
	@codesign --verify --strict $(BINDIR)/$(BIN)
	@echo "Installiert: $(BINDIR)/$(BIN)"

uninstall:
	rm -f $(BINDIR)/$(BIN)

clean:
	rm -f $(BIN)
	rm -rf $(BIN).dSYM $(CHECKDIR)
