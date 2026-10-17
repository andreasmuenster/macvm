# macvm

Minimaler macOS-VM-Launcher, nur mit Apples `Virtualization.framework`, ohne fremde Abhängigkeiten.
Es sind etwa 500 Zeilen Swift, die du vor dem Bauen komplett lesen kannst.

**Status:** Der Code ist ungetestet. Er ist gegen die öffentliche API geschrieben, wurde aber noch nie auf einem Mac kompiliert. Rechne beim ersten Build mit kleinen Korrekturen.

## Was die VM bekommt und was nicht

| Bekommt | Bekommt bewusst nicht |
|---|---|
| CPU, RAM, eine Disk | beschreibbare Freigaben |
| NAT-Netz (`bridge100`, 192.168.64.x) | Zwischenablage |
| Tastatur, Maus | Audio |
| Grafikgerät (= paravirtualisierte Metal-GPU) | USB-Durchreichung |
| optional: **ein** Modellordner, read-only | vsock / serielle Konsole |
| | Bridged-Netz |

Das Grafikgerät ist auch im Headless-Betrieb konfiguriert, weil der Gast nur darüber die GPU bekommt.

## Bauen

```bash
xcode-select --install        # falls noch nicht vorhanden
./build.sh
```

`build.sh` signiert das Binary ad-hoc mit genau einer Berechtigung: `com.apple.security.virtualization`. Ein Apple-Developer-Account ist nicht nötig.

## Benutzen

```bash
# 1. IPSW direkt von Apple laden
./macvm ipsw-url
curl -L -o ~/vms/macos.ipsw "<URL von oben>"

# 2. VM anlegen und macOS installieren (dauert)
./macvm create ~/vms/omlx-vm --ipsw ~/vms/macos.ipsw --cpus 12 --memory 100 --disk 250

# 3. Erster Start mit Fenster: Setup-Assistent, User anlegen,
#    Systemeinstellungen → Allgemein → Teilen → Entfernte Anmeldung an
./macvm run ~/vms/omlx-vm --gui

# 4. Danach headless
./macvm run ~/vms/omlx-vm &
./macvm ip ~/vms/omlx-vm

# 5. Gast abschotten (sobald er gebootet hat)
./macvm firewall on ~/vms/omlx-vm
```

Beim Herunterfahren gilt:
- **Ctrl-C** oder Fenster schließen fordert ein sauberes Herunterfahren an.
- Ein **zweites Ctrl-C** stoppt die VM hart.

CPU und RAM änderst du in `config.json` im VM-Verzeichnis, während die VM gestoppt ist.

## Modellordner freigeben (read-only)

Damit die rund 100 GB Modelle nicht doppelt auf der SSD liegen, kann macvm genau einen Host-Ordner per VirtioFS schreibgeschützt in den Gast einhängen.

```bash
mkdir -p ~/vms/models
# Modelle hierher verschieben, z. B. aus ~/.omlx/models:
mv ~/.omlx/models/<modellname> ~/vms/models/

./macvm run ~/vms/omlx-vm --models ~/vms/models     # wird in config.json gespeichert
./macvm run ~/vms/omlx-vm                           # nutzt die gespeicherte Freigabe
./macvm run ~/vms/omlx-vm --no-models               # Freigabe entfernen
```

Im Gast erscheint der Ordner automatisch unter `/Volumes/My Shared Files/models`. oMLX startest du dort entsprechend:

```bash
omlx serve --model-dir "/Volumes/My Shared Files/models" ...
```

Im LaunchAgent gehört der Pfad als eigenes `<string>` hinter `--model-dir`, ohne Anführungszeichen.

**Zur Sicherheit:**
- **Schreibschutz:** Der Gast kann im Ordner nichts ändern, löschen oder anlegen. Ein kompromittiertes oMLX kann deine Modelle also nicht manipulieren.
- **Nur Modelle freigeben:** Der Ordner sollte ausschließlich Modelle enthalten, also keine Settings, Caches oder Schlüssel. macvm verweigert `/`, `/Users`, `/Volumes` und dein Home-Verzeichnis.
- **Keine absoluten Symlinks:** Leg im Ordner echte Dateien ab. Absolute Symlinks zeigen im Gast ins Leere, relative innerhalb des Ordners funktionieren.
- **Zusätzliche Angriffsfläche:** Der Gast spricht jetzt mit Apples VirtioFS-Server auf dem Host. Das ist mehr als eine nackte Disk, bei read-only aber vertretbar.
- **Ladezeit:** Ein Modell über VirtioFS zu laden dauert länger als von der Gast-Disk. Das betrifft nur das einmalige Laden, die Inferenz danach ist unverändert. Miss es im Benchmark mit.

## Firewall

Die Regeln laufen in **pf auf dem Host**, also außerhalb der Reichweite des Gasts. Selbst wer im Gast Root-Rechte hat, kann sie nicht abschalten.

| Richtung | Erlaubt? |
|---|---|
| Host → Gast (SSH, Tunnel zu oMLX) | ja |
| Antworten des Gasts auf Host-Verbindungen | ja |
| Gast → Host: DHCP | ja, sonst verliert der Gast seine IP |
| Gast → Internet | **nein** |
| Gast → Dienste auf dem Host (inkl. DNS, mDNS, Docker-Ports) | **nein** |
| IPv6 vom Gast | **nein** |

Geladene Regeln, für das Bridge-Interface der VM:

```
pass  out quick on bridge100 all keep state
pass  in  quick on bridge100 inet proto udp from any port 68 to any port 67 keep state
block drop in quick on bridge100 all
```

### Befehle

```bash
./macvm firewall on ~/vms/omlx-vm       # Regeln laden, pf einschalten (sudo)
./macvm firewall status ~/vms/omlx-vm   # Exit-Code 0 = wirksam, 2 = NICHT wirksam
./macvm firewall off ~/vms/omlx-vm      # Wartung: Updates, Modell-Downloads
```

Die Regeln landen im eigenen pf-Anchor `com.apple/macvm-<VM-Name>`. Apples Standard-`/etc/pf.conf` wertet alle Anchors unter `com.apple/` aus, deshalb bleibt die Datei unverändert. Falls du `/etc/pf.conf` selbst angepasst hast, muss die Zeile `anchor "com.apple/*"` darin enthalten sein.

### Wichtig zu wissen

- **Nach dem Laden der Regeln den SSH-Tunnel neu aufbauen.** Verbindungen, die schon vorher bestanden, haben keinen pf-State und werden abgeschnitten.
- **Die Regeln überleben keinen Host-Neustart.** Nach jedem Reboot und nach jedem VM-Start `firewall status` prüfen und bei Bedarf `firewall on` ausführen. `status` warnt auch, wenn die VM inzwischen an einer anderen Bridge hängt, zum Beispiel `bridge101` statt `bridge100`.
- **Die Regeln gelten für die ganze Bridge.** Hängen dort noch andere VMs (Docker, UTM, Lima mit vmnet), werden sie mit abgeschottet. `firewall on` bricht in diesem Fall ab, außer du gibst `--force` mit.
- **Selbst prüfen.** Ich habe das Zusammenspiel von vmnet und pf nicht auf deinem konkreten macOS getestet. Mach nach dem ersten `firewall on` diese Gegenprobe:

```bash
# im Gast – alle drei müssen scheitern:
curl -m 5 https://example.com
curl -m 5 http://192.168.64.1
ping -c 2 1.1.1.1

# auf dem Host – muss funktionieren:
ssh <user>@$(./macvm ip ~/vms/omlx-vm) true
```

Klappt eine der Gegenproben im Gast, wirken die Regeln nicht. Dann nichts produktiv laufen lassen und mir die Ausgabe von `./macvm firewall status` schicken.

## Golden Image

```bash
cp -cR ~/vms/omlx-vm ~/vms/omlx-vm-golden   # APFS-Clone, kostet kaum Platz
```

Original und Klon dürfen nicht gleichzeitig laufen, weil sie dieselbe Machine-ID und dieselbe MAC-Adresse haben.

## Dateien im VM-Verzeichnis

| Datei | Inhalt |
|---|---|
| `disk.img` | Sparse-Disk des Gasts |
| `aux.img` | Hilfsspeicher (NVRAM) |
| `hardware-model.bin`, `machine-id.bin` | Identität der VM |
| `config.json` | CPUs, RAM, MAC-Adresse, Modellordner, zuletzt genutztes Firewall-Interface |
