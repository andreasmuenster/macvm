// Unit-Tests für die reinen Funktionen aus main.swift: IP- und Subnetz-Logik, MAC-Normalisierung,
// pf-Regeln, Pfade im VM-Verzeichnis, config.json, Modellordner-Prüfung und die Optionsparser.
// Kein Test startet oder ändert eine VM, ruft sudo oder pfctl auf oder geht ins Netz.
//
// `make check` übersetzt main.swift bis zur Marke „MARK: - Einstieg“ zusammen mit dieser Datei
// (swiftc -parse-as-library). Abbruchpfade, die über fail() den Prozess beenden, prüft tests/cli.sh.

import Foundation

var checks = 0
var failures = 0

func report(_ ok: Bool, _ what: String, _ line: UInt) {
    checks += 1
    if !ok {
        failures += 1
        FileHandle.standardError.write("FEHLER tests/UnitTests.swift:\(line): \(what)\n".data(using: .utf8)!)
    }
}

func expect(_ condition: Bool, _ what: String, line: UInt = #line) {
    report(condition, what, line)
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ what: String, line: UInt = #line) {
    report(actual == expected, "\(what): \(actual) statt \(expected)", line)
}

func expectThrows(_ what: String, line: UInt = #line, _ body: () throws -> Void) {
    do {
        try body()
        report(false, "\(what): kein Fehler geworfen", line)
    } catch {
        report(true, what, line)
    }
}

/// Leeres Arbeitsverzeichnis unter $TMPDIR, wird nach dem Test gelöscht.
func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macvm-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

func testParseIPv4() {
    expectEqual(parseIPv4("10.77.64.1"), 0x0A4D_4001, "parseIPv4 10.77.64.1")
    expectEqual(parseIPv4("0.0.0.0"), 0, "parseIPv4 0.0.0.0")
    expectEqual(parseIPv4("255.255.255.255"), UInt32.max, "parseIPv4 255.255.255.255")
    for bad in ["", "10.77.64", "10.77.64.1.5", "256.1.1.1", "a.b.c.d", "10.77.64.-1", "fe80::1"] {
        expectEqual(parseIPv4(bad), nil, "parseIPv4 '\(bad)'")
    }
}

func testIsInSubnet() {
    expect(isInSubnet("10.77.64.2", "10.77.64.0/24"), "10.77.64.2 in 10.77.64.0/24")
    expect(isInSubnet("10.77.64.254", defaultSubnet), "10.77.64.254 im Standard-Subnetz")
    expect(!isInSubnet("10.77.65.2", "10.77.64.0/24"), "10.77.65.2 nicht in 10.77.64.0/24")
    expect(!isInSubnet("192.168.64.2", defaultSubnet), "alte Lease aus 192.168.64.0/24 fällt heraus")
    expect(isInSubnet("10.77.65.2", "10.77.64.0/23"), "10.77.65.2 in 10.77.64.0/23")
    expect(isInSubnet("10.1.2.3", "10.1.2.3/32"), "/32 trifft genau die Adresse")
    expect(!isInSubnet("10.1.2.4", "10.1.2.3/32"), "/32 trifft keine andere Adresse")
    for bad in ["10.77.64.0", "10.77.64.0/0", "10.77.64.0/33", "10.77.64.0/x", "auto", "10.77.64/24"] {
        expect(!isInSubnet("10.77.64.2", bad), "ungültiges Subnetz '\(bad)' trifft nie")
    }
    expect(!isInSubnet("kaputt", "10.77.64.0/24"), "ungültige IP trifft nie")
}

func testIPv4Net() {
    let net = IPv4Net(addr: parseIPv4("10.77.64.1")!, mask: 0xFFFF_FF00)
    expect(net.contains(parseIPv4("10.77.64.200")!), "IPv4Net enthält 10.77.64.200")
    expect(!net.contains(parseIPv4("10.77.63.200")!), "IPv4Net enthält 10.77.63.200 nicht")
}

func testNormalizeMAC() {
    // dhcpd_leases schreibt die Oktette ohne führende Nullen.
    expectEqual(normalizeMAC("0A:1B:02:03:04:F0"), "a:1b:2:3:4:f0", "normalizeMAC mit führenden Nullen")
    expectEqual(normalizeMAC("a:1b:2:3:4:f0"), "a:1b:2:3:4:f0", "normalizeMAC ist idempotent")
    expectEqual(normalizeMAC("00:00:00:00:00:00"), "0:0:0:0:0:0", "normalizeMAC nur Nullen")
}

func testAnchorName() {
    expectEqual(anchorName(VMBundle(path: "/tmp/vms/omlx-vm")), "com.apple/macvm-omlx-vm", "Anchor-Name")
    // Alles außer Buchstaben, Ziffern, - und _ wird ersetzt: kein Ausbruch aus dem pf-Anchor.
    expectEqual(anchorName(VMBundle(path: "/tmp/vms/a b.c\"ä;x")), "com.apple/macvm-a_b_c___x", "Anchor-Name bereinigt")
}

func testFirewallRules() {
    expectEqual(
        firewallRules(interface: "bridge100"),
        """
        pass  out quick on bridge100 all keep state
        pass  in  quick on bridge100 inet proto udp from any port 68 to any port 67 keep state
        block drop in quick on bridge100 all
        """,
        "pf-Regeln für bridge100")
}

func testVMBundle() {
    let b = VMBundle(path: "/tmp/vms/../vms/omlx-vm/")
    expectEqual(b.dir.path, "/tmp/vms/omlx-vm", "VM-Verzeichnis normalisiert")
    expectEqual(b.disk.path, "/tmp/vms/omlx-vm/disk.img", "Disk-Pfad")
    expectEqual(b.aux.path, "/tmp/vms/omlx-vm/aux.img", "Aux-Pfad")
    expectEqual(b.hardwareModel.path, "/tmp/vms/omlx-vm/hardware-model.bin", "Hardware-Modell-Pfad")
    expectEqual(b.machineID.path, "/tmp/vms/omlx-vm/machine-id.bin", "Machine-ID-Pfad")
    expectEqual(b.settingsFile.path, "/tmp/vms/omlx-vm/config.json", "config.json-Pfad")
    expectEqual(b.pidFile.path, "/tmp/vms/omlx-vm/macvm.pid", "PID-Datei-Pfad")
    expect(VMBundle(path: "omlx-vm").dir.path.hasPrefix("/"), "relativer Pfad wird absolut")
}

func testSettingsRoundTrip() {
    withTempDir { dir in
        let b = VMBundle(path: dir.path)
        // Altes Format: der Shutdown-User stand in sshUser.
        let old = #"{"cpus": 4, "memoryGB": 8, "macAddress": "02:00:00:00:00:01", "sshUser": "olduser"}"#
        try! old.write(to: b.settingsFile, atomically: true, encoding: .utf8)
        guard var s = try? loadSettings(b) else {
            report(false, "loadSettings liest das alte Format", #line)
            return
        }
        expectEqual(s.llmUser, "olduser", "sshUser wird nach llmUser übernommen")
        expectEqual(s.sshUser, nil, "sshUser wird nicht weitergeführt")
        expectEqual(s.subnet, nil, "ohne subnet gilt der Standard")

        s.adminUser = "admin"
        s.subnet = "10.77.70.0/24"
        try! saveSettings(s, b)
        let json = try! String(contentsOf: b.settingsFile, encoding: .utf8)
        expect(!json.contains("sshUser"), "sshUser wird nicht mehr geschrieben")
        let again = try? loadSettings(b)
        expectEqual(again?.adminUser, "admin", "adminUser übersteht Speichern und Laden")
        expectEqual(again?.llmUser, "olduser", "llmUser übersteht Speichern und Laden")
        expectEqual(again?.subnet, "10.77.70.0/24", "subnet übersteht Speichern und Laden")
        expectEqual(again?.macAddress, "02:00:00:00:00:01", "MAC übersteht Speichern und Laden")
    }
    expectThrows("loadSettings ohne config.json") { _ = try loadSettings(VMBundle(path: "/nonexistent/macvm-vm")) }
}

func testValidatedModelsDir() {
    withTempDir { dir in
        let models = dir.appendingPathComponent("models")
        try! FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let ok = try? validatedModelsDir(models.path)
        expectEqual(ok?.path, models.resolvingSymlinksInPath().path, "eigener Modellordner wird angenommen")

        let file = dir.appendingPathComponent("datei")
        try! Data().write(to: file)
        expectThrows("Datei statt Ordner") { _ = try validatedModelsDir(file.path) }
        expectThrows("fehlender Ordner") { _ = try validatedModelsDir(dir.appendingPathComponent("fehlt").path) }
    }
    for broad in ["/", "/Users", "/Volumes", "~", NSHomeDirectory(), "/usr"] {
        expectThrows("zu weit gefasst: \(broad)") { _ = try validatedModelsDir(broad) }
    }
}

func testOptionParsing() {
    args = ["vm", "--user", "bob", "--force", "--timeout", "30"]
    expect(flag("--force"), "flag --force gefunden")
    expectEqual(args, ["vm", "--user", "bob", "--timeout", "30"], "flag entfernt nur sich selbst")
    expect(!flag("--gui"), "fehlendes Flag")
    expectEqual(option("--user"), "bob", "option --user")
    expectEqual(args, ["vm", "--timeout", "30"], "option entfernt Name und Wert")
    expectEqual(option("--admin"), nil, "fehlende Option")
    expectEqual(numberOption("--timeout", default: 90), 30, "numberOption mit Wert")
    expectEqual(numberOption("--cpus", default: 12), 12, "numberOption mit Standardwert")
    expectEqual(numberOption("--memory", default: UInt64(100)), 100, "numberOption UInt64-Standardwert")
    expectEqual(args, ["vm"], "nur das VM-Verzeichnis bleibt übrig")

    // Ein Wert, der mit einem einfachen Bindestrich beginnt, ist ein Wert, keine Option.
    args = ["--user", "-x"]
    expectEqual(option("--user"), "-x", "Wert mit einfachem Bindestrich")

    for name in ["bob", "llm.user", "a_b-c", "Admin2"] {
        expectEqual(validUserName(name), name, "gültiger Username '\(name)'")
    }
}

@main
enum UnitTests {
    static func main() {
        testParseIPv4()
        testIsInSubnet()
        testIPv4Net()
        testNormalizeMAC()
        testAnchorName()
        testFirewallRules()
        testVMBundle()
        testSettingsRoundTrip()
        testValidatedModelsDir()
        testOptionParsing()

        print("Unit-Tests: \(checks) Prüfungen, \(failures) Fehler")
        // Ein Lauf ohne Prüfungen zählt als Fehler.
        exit(failures == 0 && checks > 0 ? 0 : 1)
    }
}
