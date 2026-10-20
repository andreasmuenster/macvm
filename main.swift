// macvm – minimaler macOS-VM-Launcher, nur Apples Virtualization.framework.
//
// Bewusst NICHT konfiguriert (= keine Angriffsfläche Gast -> Host):
//   Zwischenablage, Audio, USB-Durchreichung, vsock/Socket-Geräte,
//   serielle Konsole, Bridged-Netzwerk, beschreibbare Freigaben.
// Konfiguriert: CPU, RAM, eine Disk, NAT-Netz, Tastatur/Maus, Grafikgerät,
//   optional EIN schreibgeschützter Modellordner per VirtioFS (--models).
// Das Grafikgerät ist Pflicht: darüber bekommt der Gast die paravirtualisierte
// Metal-GPU – auch im Headless-Betrieb.
//
// Firewall: `macvm firewall on` lädt pf-Regeln auf dem HOST (außer Reichweite des
// Gasts): Der Host darf den Gast ansprechen (SSH-Tunnel), der Gast selbst darf
// nichts aufbauen – weder ins Internet noch zu Diensten auf dem Host. Ausnahme: DHCP.

import AppKit
import Foundation
import Virtualization
import vmnet

// MARK: - Hilfen

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func log(_ msg: String) {
    print(msg)
    fflush(stdout)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("Fehler: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

/// Hält Objekte am Leben, solange der Prozess läuft (VM, Installer, Delegates, Signalquellen).
var keepAlive: [Any] = []

let gib: UInt64 = 1024 * 1024 * 1024

/// Startet ein Programm und liefert Exit-Code und Ausgabe (stdout+stderr).
func runCapture(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Startet ein Programm mit dem Terminal des Aufrufers (für sudo-Passwortabfrage).
/// Bewusst posix_spawn statt Process: Process steckt das Kind in eine eigene Prozessgruppe.
/// Für das Terminal ist es dann ein Hintergrundprozess, sudo wird beim Lesen des Passworts
/// per SIGTTIN angehalten und macvm wartet ewig.
@discardableResult
func runInherited(_ path: String, _ arguments: [String]) -> Int32 {
    var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, path, nil, nil, &argv, environ)
    guard rc == 0 else { fail("Konnte \(path) nicht starten: \(String(cString: strerror(rc)))") }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    // WIFEXITED / WEXITSTATUS als Bitoperationen, die Makros gibt es in Swift nicht.
    return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
}

// MARK: - VM-Verzeichnis

struct VMBundle {
    let dir: URL
    var disk: URL { dir.appendingPathComponent("disk.img") }
    var aux: URL { dir.appendingPathComponent("aux.img") }
    var hardwareModel: URL { dir.appendingPathComponent("hardware-model.bin") }
    var machineID: URL { dir.appendingPathComponent("machine-id.bin") }
    var settingsFile: URL { dir.appendingPathComponent("config.json") }
    var pidFile: URL { dir.appendingPathComponent("macvm.pid") }

    init(path: String) { dir = URL(fileURLWithPath: path).standardizedFileURL }
}

struct VMSettings: Codable {
    var cpus: Int
    var memoryGB: UInt64
    var macAddress: String
    /// NAT-Subnetz der VM als CIDR (Standard: 10.77.64.0/24). Weicht bewusst vom macOS-Standard 192.168.64.0/24 ab,
    /// den VPN-Clients (z. B. GlobalProtect) gern über den Tunnel routen.
    var subnet: String?
    /// Bridge-Interface, auf das zuletzt Firewall-Regeln geladen wurden (nur Info).
    var firewallInterface: String?
    /// Host-Ordner, der dem Gast schreibgeschützt als /Volumes/My Shared Files/models erscheint.
    var modelsDir: String?
    /// Admin im Gast: Installationen, Wartung (`macvm ssh --admin`, `macvm copy-id --admin`).
    var adminUser: String?
    /// Standard-User im Gast: LLM-Server, Tunnel, SSH-Shutdown bei `macvm stop`.
    var llmUser: String?
    /// Altes Feld für den Shutdown-User. Wird beim Laden nach `llmUser` übernommen und nicht mehr geschrieben.
    var sshUser: String?
}

// MARK: - PID-Datei

/// Global, damit der atexit-Handler (C-Funktionszeiger, kein Kontext) darauf zugreifen kann.
var pidFileToRemove: String?

func readPID(_ b: VMBundle) -> pid_t? {
    guard let s = try? String(contentsOf: b.pidFile, encoding: .utf8),
        let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    return pid
}

/// Läuft unter dieser PID wirklich ein macvm? (Schutz gegen veraltete PID-Dateien und PID-Wiederverwendung.)
func isRunningMacvm(_ pid: pid_t) -> Bool {
    guard kill(pid, 0) == 0 || errno == EPERM else { return false }
    let comm = runCapture("/bin/ps", ["-p", "\(pid)", "-o", "comm="]).output
    return comm.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("macvm")
}

func loadSettings(_ b: VMBundle) throws -> VMSettings {
    var s = try JSONDecoder().decode(VMSettings.self, from: Data(contentsOf: b.settingsFile))
    if s.llmUser == nil { s.llmUser = s.sshUser }
    s.sshUser = nil
    return s
}

func saveSettings(_ s: VMSettings, _ b: VMBundle) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(s).write(to: b.settingsFile)
}

// MARK: - Konfiguration

func loadPlatform(_ b: VMBundle) throws -> VZMacPlatformConfiguration {
    guard let hw = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: b.hardwareModel)) else {
        throw CLIError("hardware-model.bin unlesbar")
    }
    guard hw.isSupported else { throw CLIError("Hardware-Modell wird auf diesem Host nicht unterstützt") }
    guard let id = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: b.machineID)) else {
        throw CLIError("machine-id.bin unlesbar")
    }
    let p = VZMacPlatformConfiguration()
    p.hardwareModel = hw
    p.machineIdentifier = id
    p.auxiliaryStorage = VZMacAuxiliaryStorage(url: b.aux)
    return p
}

let defaultSubnet = "10.77.64.0/24"
/// Spezialwert für `subnet`: macOS wählt das Subnetz selbst (meist 192.168.64.0/24).
let autoSubnet = "auto"

/// Das vmnet-Netz muss so lange leben wie die VM (Freigabe beendet das Netz).
var vmnetNetwork: vmnet_network_ref?

/// Legt ein eigenes NAT-Netz mit dem gewünschten Subnetz an (macOS 26+, kein root nötig).
func makeVmnetNetwork(cidr: String) throws -> vmnet_network_ref {
    var status: vmnet_return_t = .VMNET_SUCCESS
    guard let cfg = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
        throw CLIError("vmnet-Konfiguration fehlgeschlagen (Status \(status.rawValue)).")
    }
    if cidr != autoSubnet {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]), (8...29).contains(bits) else {
            throw CLIError("Ungültiges Subnetz '\(cidr)'. Erwartet z. B. 10.77.64.0/24 (Präfix 8–29) oder \"auto\".")
        }
        var addr = in_addr()
        guard inet_pton(AF_INET, String(parts[0]), &addr) == 1 else { throw CLIError("Ungültige Subnetz-Adresse in '\(cidr)'.") }
        let hostMask = ~UInt32(0) << UInt32(32 - bits)
        var mask = in_addr(s_addr: hostMask.bigEndian)
        // vmnet erwartet die Host-/Gateway-Adresse (.1) statt der Netzadresse (.0).
        addr.s_addr = ((UInt32(bigEndian: addr.s_addr) & hostMask) | 1).bigEndian
        guard vmnet_network_configuration_set_ipv4_subnet(cfg, &addr, &mask) == .VMNET_SUCCESS else {
            throw CLIError("Subnetz \(cidr) wurde von vmnet abgelehnt.")
        }
    }
    guard let net = vmnet_network_create(cfg, &status) else {
        throw CLIError("vmnet-Netz \(cidr) konnte nicht angelegt werden (Status \(status.rawValue)). Kollidiert es mit einem vorhandenen Netz?")
    }
    vmnetNetwork = net
    return net
}

func makeConfiguration(_ b: VMBundle, _ s: VMSettings, _ platform: VZMacPlatformConfiguration) throws
    -> VZVirtualMachineConfiguration
{
    let c = VZVirtualMachineConfiguration()
    c.platform = platform
    c.bootLoader = VZMacOSBootLoader()
    c.cpuCount = s.cpus
    c.memorySize = s.memoryGB * gib

    let gfx = VZMacGraphicsDeviceConfiguration()
    gfx.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80)]
    c.graphicsDevices = [gfx]

    let disk = try VZDiskImageStorageDeviceAttachment(url: b.disk, readOnly: false)
    c.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

    guard let mac = VZMACAddress(string: s.macAddress) else { throw CLIError("Ungültige MAC-Adresse in config.json") }
    let net = VZVirtioNetworkDeviceConfiguration()
    net.attachment = VZVmnetNetworkDeviceAttachment(network: try makeVmnetNetwork(cidr: s.subnet ?? defaultSubnet))
    net.macAddress = mac
    c.networkDevices = [net]

    c.keyboards = [VZUSBKeyboardConfiguration()]
    c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

    // Optional: genau EIN Host-Ordner, schreibgeschützt, per VirtioFS.
    // macOS-Gäste hängen ihn automatisch unter /Volumes/My Shared Files/models ein.
    if let m = s.modelsDir {
        let url = try validatedModelsDir(m)
        let share = VZMultipleDirectoryShare(directories: ["models": VZSharedDirectory(url: url, readOnly: true)])
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        fs.share = share
        c.directorySharingDevices = [fs]
    }

    try c.validate()
    return c
}

/// Prüft den freizugebenden Ordner: muss existieren, ein Verzeichnis sein und darf
/// kein offensichtlich zu großer Bereich sein (/, /Users, Home-Verzeichnis).
func validatedModelsDir(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
        throw CLIError("Modellordner nicht gefunden: \(url.path)")
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
    let tooBroad = ["/", "/Users", "/Volumes", home]
    if tooBroad.contains(url.path) || url.path.components(separatedBy: "/").count < 3 {
        throw CLIError("\(url.path) ist zu weit gefasst. Gib einen eigenen Ordner nur mit Modellen frei, z. B. ~/vms/models")
    }
    return url
}

// MARK: - Netz-Hilfen

/// macOS schreibt MAC-Oktette in den DHCP-Leases ohne führende Nullen, daher normalisieren.
func normalizeMAC(_ mac: String) -> String {
    mac.lowercased().split(separator: ":").map { String(Int($0, radix: 16) ?? 0, radix: 16) }.joined(separator: ":")
}

/// Liegt die IP im konfigurierten VM-Subnetz? Filtert veraltete Leases aus früheren Netzen heraus.
func isInSubnet(_ ip: String, _ cidr: String) -> Bool {
    let parts = cidr.split(separator: "/")
    guard parts.count == 2, let bits = Int(parts[1]), (1...32).contains(bits),
        let net = parseIPv4(String(parts[0])), let addr = parseIPv4(ip)
    else { return false }
    let mask = ~UInt32(0) << UInt32(32 - bits)
    return addr & mask == net & mask
}

/// Sucht die neueste DHCP-Lease des NAT-Netzes (vmnet) zur MAC der VM, nur im Subnetz der VM.
func leaseIP(for settings: VMSettings) -> String? {
    guard let leases = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else { return nil }
    let wanted = normalizeMAC(settings.macAddress)
    let subnet = settings.subnet ?? defaultSubnet
    var best: (ip: String, lease: UInt64)?
    for block in leases.components(separatedBy: "}") {
        var ip: String?
        var hw: String?
        var lease: UInt64 = 0
        for line in block.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("ip_address=") { ip = String(t.dropFirst("ip_address=".count)) }
            if t.hasPrefix("hw_address=") {
                hw = t.dropFirst("hw_address=".count).split(separator: ",").last.map { normalizeMAC(String($0)) }
            }
            if t.hasPrefix("lease=0x") { lease = UInt64(t.dropFirst("lease=0x".count), radix: 16) ?? 0 }
        }
        if hw == wanted, let ip, subnet == autoSubnet || isInSubnet(ip, subnet), best == nil || lease > best!.lease {
            best = (ip, lease)
        }
    }
    return best?.ip
}

func parseIPv4(_ s: String) -> UInt32? {
    let parts = s.split(separator: ".")
    guard parts.count == 4 else { return nil }
    var v: UInt32 = 0
    for part in parts {
        guard let byte = UInt8(part) else { return nil }
        v = (v << 8) | UInt32(byte)
    }
    return v
}

struct IPv4Net {
    let addr: UInt32
    let mask: UInt32
    func contains(_ ip: UInt32) -> Bool { (ip & mask) == (addr & mask) }
}

struct BridgeInfo {
    let name: String
    let nets: [IPv4Net]
    let members: [String]
}

/// Liest alle bridgeN-Interfaces aus `ifconfig` (Adresse, Netzmaske, Mitglieder).
func listBridges() -> [BridgeInfo] {
    let out = runCapture("/sbin/ifconfig", []).output
    var result: [BridgeInfo] = []
    var name: String?
    var nets: [IPv4Net] = []
    var members: [String] = []

    func flush() {
        if let n = name, n.hasPrefix("bridge") {
            result.append(BridgeInfo(name: n, nets: nets, members: members))
        }
    }

    for line in out.split(separator: "\n") {
        if let first = line.first, !first.isWhitespace {
            flush()
            name = String(line.prefix(while: { $0 != ":" }))
            nets = []
            members = []
            continue
        }
        let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if f.count >= 4, f[0] == "inet", f[2] == "netmask",
            let a = parseIPv4(String(f[1])), let m = UInt32(f[3].dropFirst(2), radix: 16)
        {
            nets.append(IPv4Net(addr: a, mask: m))
        }
        if f.count >= 2, f[0] == "member:" { members.append(String(f[1])) }
    }
    flush()
    return result
}

// MARK: - Befehl: ipsw-url

func cmdIpswURL() -> Never {
    VZMacOSRestoreImage.fetchLatestSupported { result in
        switch result {
        case .success(let image):
            log(image.url.absoluteString)
            exit(0)
        case .failure(let e):
            fail("Konnte IPSW-URL nicht abfragen: \(e)")
        }
    }
    dispatchMain()
}

// MARK: - Befehl: create

func cmdCreate(path: String, ipsw: String, cpus: Int, memoryGB: UInt64, diskGB: UInt64) -> Never {
    let b = VMBundle(path: path)
    let fm = FileManager.default
    if fm.fileExists(atPath: b.dir.path) { fail("\(b.dir.path) existiert bereits") }
    let ipswURL = URL(fileURLWithPath: ipsw).standardizedFileURL
    guard fm.fileExists(atPath: ipswURL.path) else { fail("IPSW nicht gefunden: \(ipswURL.path)") }

    VZMacOSRestoreImage.load(from: ipswURL) { result in
        DispatchQueue.main.async {
            do {
                let image = try result.get()
                guard let req = image.mostFeaturefulSupportedConfiguration, req.hardwareModel.isSupported else {
                    throw CLIError("Dieses IPSW wird auf diesem Mac nicht unterstützt")
                }
                if cpus < req.minimumSupportedCPUCount {
                    throw CLIError("Mindestens \(req.minimumSupportedCPUCount) CPUs nötig")
                }
                if memoryGB * gib < req.minimumSupportedMemorySize {
                    throw CLIError("Mindestens \(req.minimumSupportedMemorySize / gib) GB RAM nötig")
                }

                try fm.createDirectory(at: b.dir, withIntermediateDirectories: true)

                // Sparse-Disk: belegt nur tatsächlich geschriebene Blöcke.
                guard fm.createFile(atPath: b.disk.path, contents: nil) else { throw CLIError("Disk anlegen fehlgeschlagen") }
                let fh = try FileHandle(forWritingTo: b.disk)
                try fh.truncate(atOffset: diskGB * gib)
                try fh.close()

                let platform = VZMacPlatformConfiguration()
                platform.hardwareModel = req.hardwareModel
                platform.auxiliaryStorage = try VZMacAuxiliaryStorage(
                    creatingStorageAt: b.aux, hardwareModel: req.hardwareModel, options: [])
                let machineID = VZMacMachineIdentifier()
                platform.machineIdentifier = machineID
                try req.hardwareModel.dataRepresentation.write(to: b.hardwareModel)
                try machineID.dataRepresentation.write(to: b.machineID)

                let settings = VMSettings(
                    cpus: cpus, memoryGB: memoryGB,
                    macAddress: VZMACAddress.randomLocallyAdministered().string)
                try saveSettings(settings, b)

                let vm = VZVirtualMachine(configuration: try makeConfiguration(b, settings, platform))
                let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipswURL)
                var lastPct = -1
                let obs = installer.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                    let pct = Int(p.fractionCompleted * 100)
                    if pct != lastPct {
                        lastPct = pct
                        log("Installation: \(pct) %")
                    }
                }
                keepAlive += [vm, installer, obs]

                log("Installiere macOS in \(b.dir.path) …")
                installer.install { r in
                    switch r {
                    case .success:
                        log("Fertig. Erster Start mit Fenster: macvm run \(path) --gui")
                        exit(0)
                    case .failure(let e):
                        fail("Installation fehlgeschlagen: \(e)")
                    }
                }
            } catch {
                fail("\(error)")
            }
        }
    }
    dispatchMain()
}

// MARK: - Befehl: run

final class VMDelegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        log("Gast heruntergefahren.")
        exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        fail("VM mit Fehler gestoppt: \(error)")
    }
}

final class WindowDelegate: NSObject, NSWindowDelegate {
    let shutdown: () -> Void
    init(shutdown: @escaping () -> Void) { self.shutdown = shutdown }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shutdown()  // Fenster zu = sauberes Herunterfahren anfordern, VM nicht hart abschießen
        return false
    }
}

func cmdRun(path: String, gui: Bool, models: String?, noModels: Bool) -> Never {
    let b = VMBundle(path: path)
    let vm: VZVirtualMachine
    var settings: VMSettings
    do {
        settings = try loadSettings(b)
        // --models / --no-models werden in config.json gespeichert und gelten für spätere Starts.
        if let models {
            settings.modelsDir = try validatedModelsDir(models).path
            try saveSettings(settings, b)
        } else if noModels {
            settings.modelsDir = nil
            try saveSettings(settings, b)
        }
        vm = VZVirtualMachine(configuration: try makeConfiguration(b, settings, try loadPlatform(b)))
    } catch {
        fail("\(error)")
    }

    // PID-Datei: verhindert Doppelstart und ermöglicht `macvm stop`.
    if let old = readPID(b), isRunningMacvm(old) {
        fail("Diese VM läuft bereits (PID \(old)). Stoppen: macvm stop \(path)")
    }
    do { try "\(getpid())\n".write(to: b.pidFile, atomically: true, encoding: .utf8) } catch {
        fail("PID-Datei nicht schreibbar: \(error)")
    }
    pidFileToRemove = b.pidFile.path
    atexit {
        if let p = pidFileToRemove { unlink(p) }
    }

    let delegate = VMDelegate()
    vm.delegate = delegate
    keepAlive += [vm, delegate]

    // Erstes Ctrl-C / SIGTERM: Gast sauber herunterfahren. Zweites: hart stoppen.
    var stopRequested = false
    let shutdown: () -> Void = {
        if !stopRequested && vm.canRequestStop {
            stopRequested = true
            do {
                try vm.requestStop()
                log("Herunterfahren angefordert (nochmal = hart stoppen) …")
                return
            } catch {
                log("requestStop fehlgeschlagen: \(error)")
            }
        }
        log("Stoppe VM hart …")
        vm.stop { _ in exit(0) }
    }
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler(handler: shutdown)
        src.resume()
        keepAlive.append(src)
    }

    vm.start { r in
        if case .failure(let e) = r { fail("Start fehlgeschlagen: \(e)") }
        log("VM läuft (\(settings.cpus) CPUs, \(settings.memoryGB) GB, MAC \(settings.macAddress)).")
        if let m = settings.modelsDir {
            log("Modelle (read-only): \(m) → Gast: /Volumes/My Shared Files/models")
        }
        log("Firewall prüfen bzw. aktivieren, sobald der Gast gebootet ist: macvm firewall status|on \(path)")
    }

    if gui {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "macvm – \(b.dir.lastPathComponent)"
        let view = VZVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        window.contentView = view
        let wd = WindowDelegate(shutdown: shutdown)
        window.delegate = wd
        keepAlive += [window, wd]
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
    dispatchMain()
}

// MARK: - Befehl: stop

/// Stoppt eine laufende VM in Stufen:
///  1. sauber: per SSH `sudo -n /sbin/shutdown -h now` im Gast (wenn ein SSH-User hinterlegt ist),
///     sonst Power-Taste (SIGTERM an macvm → requestStop)
///  2. nach Timeout: hart (zweites SIGTERM → VZVirtualMachine.stop)
///  3. wenn macvm selbst hängt: SIGKILL
func cmdStop(path: String, user: String?, timeout: Int, force: Bool) -> Never {
    let b = VMBundle(path: path)
    var settings: VMSettings
    do { settings = try loadSettings(b) } catch { fail("\(error)") }

    guard let pid = readPID(b), isRunningMacvm(pid) else {
        try? FileManager.default.removeItem(at: b.pidFile)
        log("VM läuft nicht.")
        exit(0)
    }
    if let user, user != settings.llmUser {
        settings.llmUser = validUserName(user)
        try? saveSettings(settings, b)
    }

    var termsSent = 0
    func sendTerm() {
        kill(pid, SIGTERM)
        termsSent += 1
    }
    func waitForExit(seconds: Int) -> Bool {
        for _ in 0..<(seconds * 2) {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    if !force {
        if let u = settings.llmUser, let ip = leaseIP(for: settings) {
            log("Fahre Gast per SSH herunter (\(u)@\(ip)) …")
            let r = runCapture("/usr/bin/ssh", [
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                "\(u)@\(ip)", "sudo -n /sbin/shutdown -h now",
            ])
            // Bricht der Gast die Verbindung beim Herunterfahren ab, ist das ein Erfolg.
            let ok = r.status == 0 || r.output.contains("closed by remote host")
            if !ok {
                log("SSH-Shutdown fehlgeschlagen: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
                log("Sende stattdessen die Power-Taste …")
                sendTerm()
            }
        } else {
            log("Kein LLM-User hinterlegt (macvm users <dir> --llm <name>) – sende die Power-Taste an den Gast …")
            sendTerm()
        }
        if waitForExit(seconds: timeout) {
            log("VM sauber gestoppt.")
            exit(0)
        }
        log("Gast hat nach \(timeout) s nicht reagiert – stoppe hart.")
    }

    // macvm: erstes Signal = Power-Taste, zweites = harter Stopp.
    while termsSent < 2 {
        sendTerm()
        Thread.sleep(forTimeInterval: 1)
    }
    if waitForExit(seconds: 15) {
        log("VM hart gestoppt.")
        exit(0)
    }
    log("macvm reagiert nicht – beende den Prozess (SIGKILL).")
    kill(pid, SIGKILL)
    _ = waitForExit(seconds: 5)
    try? FileManager.default.removeItem(at: b.pidFile)
    exit(0)
}

// MARK: - Befehl: ip

func cmdIP(path: String) -> Never {
    let settings: VMSettings
    do { settings = try loadSettings(VMBundle(path: path)) } catch { fail("\(error)") }
    guard let ip = leaseIP(for: settings) else {
        fail("Keine IP für MAC \(settings.macAddress) gefunden (läuft die VM und hat sie gebootet?)")
    }
    log(ip)
    exit(0)
}

// MARK: - Befehle: users, ssh, tunnel, copy-id

/// Erlaubte Usernamen: Buchstaben, Ziffern, . _ -, nicht mit - beginnend (sonst hielte ssh ihn für eine Option).
func validUserName(_ name: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    guard !name.isEmpty, !name.hasPrefix("-"), name.allSatisfy({ allowed.contains($0) }) else {
        fail("Ungültiger Username '\(name)' (erlaubt: Buchstaben, Ziffern, . _ -)")
    }
    return name
}

func cmdUsers(path: String, admin: String?, llm: String?) -> Never {
    let b = VMBundle(path: path)
    var settings: VMSettings
    do { settings = try loadSettings(b) } catch { fail("\(error)") }
    if admin != nil || llm != nil {
        if let admin { settings.adminUser = validUserName(admin) }
        if let llm { settings.llmUser = validUserName(llm) }
        do { try saveSettings(settings, b) } catch { fail("\(error)") }
    }
    log("admin  \(settings.adminUser ?? "(nicht gesetzt)")")
    log("llm    \(settings.llmUser ?? "(nicht gesetzt)")")
    exit(0)
}

/// Ziel `user@ip` aus config.json. `admin` wählt den Admin statt des LLM-Users.
func sshTarget(path: String, admin: Bool) -> String {
    let settings: VMSettings
    do { settings = try loadSettings(VMBundle(path: path)) } catch { fail("\(error)") }
    let (user, flagName) = admin ? (settings.adminUser, "--admin") : (settings.llmUser, "--llm")
    guard let user else { fail("Kein User hinterlegt. Einmalig: macvm users \(path) \(flagName) <name>") }
    guard let ip = leaseIP(for: settings) else {
        fail("Keine IP für MAC \(settings.macAddress) gefunden (läuft die VM und hat sie gebootet?)")
    }
    return "\(user)@\(ip)"
}

/// Ersetzt macvm durch das Programm. So gehört das Terminal direkt ssh (Passwortabfrage, Ctrl-C, Exit-Code).
func execTool(_ path: String, _ arguments: [String]) -> Never {
    var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
    execv(path, &argv)
    fail("Konnte \(path) nicht starten: \(String(cString: strerror(errno)))")
}

// MARK: - Befehl: firewall

/// pf-Anchor pro VM. Liegt unter "com.apple/", weil Apples Standard-/etc/pf.conf
/// alle Unter-Anchors davon auswertet (`anchor "com.apple/*"`) – /etc/pf.conf bleibt unverändert.
func anchorName(_ b: VMBundle) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    let name = String(b.dir.lastPathComponent.map { allowed.contains($0) ? $0 : "_" })
    return "com.apple/macvm-" + name
}

/// Regeln für das NAT-Bridge-Interface der VM (IPv4 und IPv6).
///  1. Alles, was der Host zum Gast aufbaut, ist erlaubt; Antworten laufen über den State.
///  2. DHCP vom Gast zum Host, sonst verliert der Gast nach Ablauf der Lease seine IP.
///  3. Alles andere, was beim Host vom Gast ankommt, wird verworfen:
///     Internet (NAT läuft über den Host), Host-Dienste, DNS, mDNS, IPv6.
func firewallRules(interface i: String) -> String {
    """
    pass  out quick on \(i) all keep state
    pass  in  quick on \(i) inet proto udp from any port 68 to any port 67 keep state
    block drop in quick on \(i) all
    """
}

func cmdFirewall(action: String, path: String, force: Bool) -> Never {
    let b = VMBundle(path: path)
    var settings: VMSettings
    do { settings = try loadSettings(b) } catch { fail("\(error)") }
    let anchor = anchorName(b)
    let sudo = "/usr/bin/sudo"
    let pfctl = "/sbin/pfctl"

    // Passwort einmal im Vordergrund abfragen. Spätere sudo-Aufrufe über runCapture laufen in
    // einer eigenen Prozessgruppe und könnten selbst kein Passwort mehr lesen.
    if ["on", "off", "status"].contains(action) {
        log("sudo fragt eventuell nach dem Passwort deines Mac-Users (HOST, nicht der VM) – für pfctl.")
        guard runInherited(sudo, ["-v"]) == 0 else { fail("sudo fehlgeschlagen.") }
    }

    /// pfctl über sudo -n (Passwort ist durch sudo -v schon bestätigt). Die Ausgabe wird ohne die
    /// harmlose macOS-Meldung "No ALTQ support in kernel" weitergegeben.
    func pf(_ a: [String]) -> Int32 {
        let r = runCapture(sudo, ["-n", pfctl] + a)
        r.output.split(separator: "\n")
            .filter { !$0.hasPrefix("No ALTQ") && !$0.contains("ALTQ related") }
            .forEach { log("  " + String($0)) }
        return r.status
    }

    switch action {
    case "on":
        guard let ipString = leaseIP(for: settings), let ip = parseIPv4(ipString) else {
            fail("VM-IP nicht gefunden. Läuft die VM und hat sie gebootet? (macvm ip \(path))")
        }
        let candidates = listBridges().filter { br in br.nets.contains { $0.contains(ip) } }
        guard candidates.count == 1, let bridge = candidates.first else {
            fail(candidates.isEmpty
                ? "Keine Bridge mit dem Netz von \(ipString) gefunden (ifconfig prüfen)."
                : "Mehrere Bridges passen zu \(ipString): \(candidates.map(\.name).joined(separator: ", "))")
        }
        if bridge.members.count > 1 && !force {
            fail("""
                An \(bridge.name) hängen \(bridge.members.count) VM-Interfaces (\(bridge.members.joined(separator: ", "))).
                Die Regeln gelten für die ganze Bridge und würden auch die anderen VMs (z. B. Docker, UTM) abschotten.
                Andere VMs stoppen oder mit --force trotzdem aktivieren.
                """)
        }

        let rules = firewallRules(interface: bridge.name)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("macvm-pf-\(getpid()).conf")
        do { try (rules + "\n").write(to: tmp, atomically: true, encoding: .utf8) } catch { fail("\(error)") }

        log("VM \(ipString) hängt an \(bridge.name). Lade in Anchor \(anchor):\n\n\(rules)\n")
        let loaded = pf(["-a", anchor, "-f", tmp.path])
        try? FileManager.default.removeItem(at: tmp)
        guard loaded == 0 else { fail("Regeln konnten nicht geladen werden (pfctl -f).") }

        // -E: pf einschalten und Referenzzähler erhöhen (schaltet nichts aus, was andere brauchen).
        guard runCapture(sudo, [pfctl, "-E"]).status == 0 else { fail("pf konnte nicht eingeschaltet werden (pfctl -E).") }

        settings.firewallInterface = bridge.name
        try? saveSettings(settings, b)
        log("Firewall aktiv. Wichtig: einen schon laufenden SSH-Tunnel jetzt neu aufbauen.")
        log("Gegenprobe im Gast: curl -m 5 https://example.com  → muss scheitern.")
        exit(0)

    case "off":
        log("Leere Anchor \(anchor) – der Gast hat danach wieder vollen Netzzugang.")
        guard pf(["-a", anchor, "-F", "rules"]) == 0 else { fail("pfctl -F fehlgeschlagen") }
        guard pf(["-a", anchor, "-F", "states"]) == 0 else { fail("pfctl -F fehlgeschlagen") }
        log("Firewall aus. Nach der Wartung: macvm firewall on \(path)")
        exit(0)

    case "status":
        let info = runCapture(sudo, [pfctl, "-s", "info"])
        let pfStatus = info.output.split(separator: "\n").first { $0.hasPrefix("Status:") }.map(String.init) ?? "Status: unbekannt"
        let rules = runCapture(sudo, [pfctl, "-a", anchor, "-s", "rules"]).output
            .split(separator: "\n").filter { !$0.hasPrefix("No ALTQ") && !$0.contains("ALTQ related") }

        log("pf          \(pfStatus)")
        log("Anchor      \(anchor)")
        if let iface = settings.firewallInterface { log("Interface   \(iface) (zuletzt geladen)") }
        if rules.isEmpty {
            log("Regeln      keine → Gast hat VOLLEN Netzzugang")
            exit(2)
        }
        log("Regeln:")
        rules.forEach { log("  " + String($0)) }
        if let ipString = leaseIP(for: settings), let ip = parseIPv4(ipString),
            let current = listBridges().first(where: { br in br.nets.contains { $0.contains(ip) } }),
            current.name != settings.firewallInterface
        {
            log("WARNUNG: Die VM hängt jetzt an \(current.name), die Regeln gelten für ein anderes Interface.")
            log("         macvm firewall on \(path) erneut ausführen.")
            exit(2)
        }
        if !pfStatus.contains("Enabled") {
            log("WARNUNG: pf ist ausgeschaltet – die Regeln wirken nicht. macvm firewall on \(path)")
            exit(2)
        }
        exit(0)

    default:
        fail("Unbekannte Aktion '\(action)' (on|off|status)")
    }
}

// MARK: - Argumente

let usage = """
    macvm – minimaler macOS-VM-Launcher (Apple Virtualization.framework)

      macvm ipsw-url                       URL des neuesten passenden IPSW bei Apple
      macvm create <dir> --ipsw <datei>    VM anlegen und macOS installieren
            [--cpus 12] [--memory 100] [--disk 250]   (RAM/Disk in GB)
      macvm run <dir> [--gui]              VM starten (ohne --gui: headless)
            [--models <ordner>]            Ordner read-only freigeben (wird gespeichert)
            [--no-models]                  Freigabe wieder entfernen
      macvm stop <dir>                     sauber herunterfahren, nach Timeout hart stoppen
            [--user <name>]                wie: macvm users <dir> --llm <name>
            [--timeout 90] [--force]       Wartezeit in s / sofort hart stoppen
      macvm ip <dir>                       IP der laufenden VM
      macvm users <dir>                    Gast-User anzeigen
            [--admin <name>] [--llm <name>]  Gast-User setzen (wird gespeichert)
      macvm ssh <dir> [--admin]            per SSH als LLM-User (bzw. Admin) einloggen
            [ssh-optionen…] [-- befehl…]   z. B. macvm ssh <dir> -- uptime
      macvm tunnel <dir> <port>…           Ports aus dem Gast als LLM-User auf localhost holen
      macvm copy-id <dir> [--admin]        SSH-Schlüssel beim LLM-User (bzw. Admin) hinterlegen
      macvm firewall on <dir> [--force]    Gast abschotten (pf auf dem Host, braucht sudo)
      macvm firewall off <dir>             Abschottung aufheben (Wartung: Updates, Downloads)
      macvm firewall status <dir>          Zustand prüfen (Exit-Code 0 = wirksam)

    CPU/RAM später ändern: config.json im VM-Verzeichnis bearbeiten (VM gestoppt).
    """

var args = Array(CommandLine.arguments.dropFirst())

/// Wert einer Option wie `--user <name>`. Fehlt der Wert, ist er leer oder sieht er selbst wie eine
/// Option aus, bricht macvm ab – typischer Fall: `--user $LLM_USER` mit nicht gesetzter Variable.
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) braucht einen Wert (leere Shell-Variable?)") }
    let v = args[i + 1]
    if v.trimmingCharacters(in: .whitespaces).isEmpty || v.hasPrefix("--") {
        fail("\(name) braucht einen Wert, bekommen: '\(v)' (leere Shell-Variable?)")
    }
    args.removeSubrange(i...(i + 1))
    return v
}

/// Ganzzahlige Option mit Standardwert; ein Wert, der keine positive Zahl ist, bricht ab.
func numberOption<T: FixedWidthInteger>(_ name: String, default def: T) -> T {
    guard let v = option(name) else { return def }
    guard let n = T(v), n > 0 else { fail("\(name) erwartet eine positive Zahl, bekommen: '\(v)'") }
    return n
}

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

guard let command = args.first else { log(usage); exit(1) }
args.removeFirst()

switch command {
case "ipsw-url":
    cmdIpswURL()
case "create":
    let ipsw = option("--ipsw")
    let cpus = numberOption("--cpus", default: 12)
    let mem = numberOption("--memory", default: UInt64(100))
    let disk = numberOption("--disk", default: UInt64(250))
    guard let dir = args.first, let ipsw else { log(usage); exit(1) }
    cmdCreate(path: dir, ipsw: ipsw, cpus: cpus, memoryGB: mem, diskGB: disk)
case "run":
    let gui = flag("--gui")
    let noModels = flag("--no-models")
    let models = option("--models")
    guard let dir = args.first else { log(usage); exit(1) }
    cmdRun(path: dir, gui: gui, models: models, noModels: noModels)
case "stop":
    let force = flag("--force")
    let user = option("--user")
    let timeout = numberOption("--timeout", default: 90)
    guard let dir = args.first else { log(usage); exit(1) }
    cmdStop(path: dir, user: user, timeout: timeout, force: force)
case "ip":
    guard let dir = args.first else { log(usage); exit(1) }
    cmdIP(path: dir)
case "users":
    let admin = option("--admin")
    let llm = option("--llm")
    guard args.count == 1, let dir = args.first else { log(usage); exit(1) }
    cmdUsers(path: dir, admin: admin, llm: llm)
case "ssh":
    // Alles nach "--" ist der Befehl im Gast und wird nicht als macvm-Option gelesen.
    var remote: [String] = []
    if let i = args.firstIndex(of: "--") {
        remote = Array(args[(i + 1)...])
        args.removeSubrange(i...)
    }
    let admin = flag("--admin")
    guard let dir = args.first else { log(usage); exit(1) }
    let sshOptions = Array(args.dropFirst())
    execTool("/usr/bin/ssh", sshOptions + [sshTarget(path: dir, admin: admin)] + remote)
case "tunnel":
    guard args.count >= 2, let dir = args.first else { log(usage); exit(1) }
    let ports = args.dropFirst().map { p -> Int in
        guard let port = Int(p), (1...65535).contains(port) else { fail("Ungültiger Port '\(p)'") }
        return port
    }
    let target = sshTarget(path: dir, admin: false)
    ports.forEach { log("http://localhost:\($0) → Gast localhost:\($0)") }
    log("Tunnel offen, beenden mit Ctrl-C.")
    let forwards = ports.flatMap { ["-L", "\($0):localhost:\($0)"] }
    execTool("/usr/bin/ssh", ["-N", "-o", "ExitOnForwardFailure=yes"] + forwards + [target])
case "copy-id":
    let admin = flag("--admin")
    guard args.count == 1, let dir = args.first else { log(usage); exit(1) }
    execTool("/usr/bin/ssh-copy-id", [sshTarget(path: dir, admin: admin)])
case "firewall":
    let force = flag("--force")
    guard args.count == 2 else { log(usage); exit(1) }
    cmdFirewall(action: args[0], path: args[1], force: force)
default:
    log(usage)
    exit(1)
}
