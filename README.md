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
make                          # bauen und signieren
make install                  # optional: nach ~/.local/bin (anderes Ziel: make install PREFIX=/opt/macvm)
make clean
```

`make` signiert das Binary ad-hoc mit genau einer Berechtigung, `com.apple.security.virtualization`, und zeigt sie zur Kontrolle an. Ein Apple-Developer-Account ist nicht nötig. Neu gebaut wird nur, wenn sich `main.swift` oder die Entitlements geändert haben.

## Ersteinrichtung

### Variablen

Die Befehle in diesem README benutzen drei Shell-Variablen. Shell-Variablen gelten nur in dem Terminal, in dem du sie gesetzt hast. Damit sie in jedem neuen Tab und Fenster da sind, trägst du sie einmalig auf dem Host in `~/.zshrc` ein. Die Namen ersetzt du durch deine eigenen:

```zsh
cat >> ~/.zshrc <<'EOF'

# macvm
VM=~/vms/omlx-vm
ADMIN_USER=admin     # Admin im Gast: Installationen, Wartung
LLM_USER=llm         # normaler User im Gast: LLM-Server, Tunnel, Shutdown
EOF
source ~/.zshrc
echo "VM=$VM ADMIN_USER=$ADMIN_USER LLM_USER=$LLM_USER"   # Kontrolle
```

Ist eine Variable leer, lässt zsh sie stillschweigend weg:
- macvm bricht dann ab, etwa mit `Fehler: --user braucht einen Wert (leere Shell-Variable?)`.
- `ssh $LLM_USER@…` meldet sich dagegen ohne Warnung mit deinem **Host**-Usernamen an.

In beiden Fällen hilft die Kontrollzeile oben.

Schreib Usernamen nie mit spitzen Klammern in den Befehl. In zsh ist `<…>` ein Zahlenbereich-Muster, deshalb bricht `ssh <user>@…` mit `zsh: number expected` ab.

### 1. VM anlegen

```zsh
./macvm ipsw-url
curl -L -o ~/vms/macos.ipsw "https://…"     # URL aus der Zeile darüber

./macvm create $VM --ipsw ~/vms/macos.ipsw --cpus 12 --memory 100 --disk 250   # dauert
```

### 2. Setup im Fenster

```zsh
./macvm run $VM --gui
```

Im Gast:

1. **Setup-Assistent** durchlaufen. Der dort angelegte User ist der **Admin** (`$ADMIN_USER`). macvm legt selbst keinen User an.
2. **Zweiten User anlegen:** Systemeinstellungen → Benutzer:innen & Gruppen → Benutzer:in hinzufügen, Typ **Standard**, nicht Admin. Das ist `$LLM_USER`. Unter diesem User laufen die LLM-Server. Wird ein Server kompromittiert, hat der Angreifer damit keine Admin-Rechte im Gast.
3. **SSH einschalten:** Systemeinstellungen → Allgemein → Teilen → **Entfernte Anmeldung** an.
4. **SSH-Zugriff für beide User erlauben:** Neben „Entfernte Anmeldung“ auf **ⓘ** klicken und bei „Zugriff erlauben für“ beide User eintragen. Standardmäßig dürfen nur Administratoren per SSH rein. Ein anderer User kann das Passwort richtig eingeben und bekommt danach trotzdem nur `Connection closed`.
5. Die Frage nach **Festplattenvollzugriff für entfernte Benutzer:innen** kannst du ablehnen. SSH braucht ihn nicht.
6. IP prüfen: Im Gast-Terminal liefert `ipconfig getifaddr en0` eine Adresse 192.168.64.x.
7. **Command Line Tools installieren (Pflicht, nur im Fenster möglich):** Im Gast-Terminal als Admin `xcode-select --install` ausführen und den Dialog bestätigen. Kontrolle: `git --version`. Headless per SSH geht das nicht, siehe [Wartungsfenster](#wartungsfenster-gilt-für-beide). Die Firewall ist zu diesem Zeitpunkt noch aus, der Download funktioniert also.

Das Fenster bleibt vorerst offen.

### 3. Host: Zugriff aufs lokale Netzwerk erlauben

Seit macOS 15 brauchen Apps auf dem **Host** eine Erlaubnis, um Adressen im lokalen Netz zu erreichen, also auch die VM. Fehlt sie, schlägt `ssh` und `ping` mit `No route to host` fehl, obwohl die VM einwandfrei läuft.

Systemeinstellungen → Datenschutz & Sicherheit → **Lokales Netzwerk** öffnen, dein Terminal einschalten (Terminal, iTerm, Ghostty usw.) und das Terminal neu starten.

```zsh
ping -c 2 $(./macvm ip $VM)       # muss antworten
```

### 4. SSH-Schlüssel hinterlegen

`macvm stop` meldet sich mit `BatchMode=yes` an, also ohne Passwortabfrage. Dafür braucht der Shutdown-User einen Schlüssel. Für den Admin ist er optional, aber bequemer.

```zsh
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519     # nur falls noch kein Schlüssel existiert

ssh-copy-id $LLM_USER@$(./macvm ip $VM)      # fragt einmal nach Passwort, bestätigt den Host-Key
ssh-copy-id $ADMIN_USER@$(./macvm ip $VM)    # optional

ssh $LLM_USER@$(./macvm ip $VM) true         # muss ohne Passwortabfrage durchlaufen
```

`ssh-copy-id` speichert den Host-Key gleich mit. Das ist nötig, weil `stop` bei unbekannten Host-Keys abbricht.

### 5. Shutdown-Recht für den LLM-User

Damit `macvm stop` den Gast sauber herunterfahren kann, braucht `$LLM_USER` passwortloses sudo, aber **nur für shutdown**. Sonst darf dieser User nichts mit sudo. Die Regel schreibt der Admin:

```zsh
ssh $ADMIN_USER@$(./macvm ip $VM)

# im Gast, als Admin; den Namen des LLM-Users einsetzen:
LLM_USER=llm
echo "$LLM_USER ALL=(root) NOPASSWD: /sbin/shutdown" | sudo tee /etc/sudoers.d/macvm-shutdown
sudo chmod 440 /etc/sudoers.d/macvm-shutdown
sudo visudo -cf /etc/sudoers.d/macvm-shutdown    # muss "parsed OK" melden
exit
```

Gegenprobe vom Host aus, die den Gast **nicht** herunterfährt:

```zsh
ssh $LLM_USER@$(./macvm ip $VM) 'sudo -n -l /sbin/shutdown'   # gibt /sbin/shutdown aus
```

### 6. Auf headless umstellen und abschotten

```zsh
./macvm stop $VM --user $LLM_USER    # User wird in config.json gespeichert
./macvm run $VM &
sleep 60                             # Boot abwarten, bis eine IP da ist
./macvm ip $VM
./macvm firewall on $VM
./macvm firewall status $VM          # Exit-Code 0 = wirksam
ssh $LLM_USER@$(./macvm ip $VM)
```

Sind die LLM-Server installiert, geht es mit der [Härtung](#härtung) weiter.

### Fehlersuche

| Meldung | Ursache | Lösung |
|---|---|---|
| `zsh: number expected` | Platzhalter mit `<…>` in den Befehl kopiert | Namen ohne spitze Klammern einsetzen oder die Variablen oben benutzen |
| `Fehler: --user braucht einen Wert (leere Shell-Variable?)` | Variable in diesem Terminal nicht gesetzt | [Variablen](#variablen) in `~/.zshrc` eintragen, `source ~/.zshrc` |
| `Kein SSH-User hinterlegt` bei `stop` | `stop` wurde noch nie mit `--user` aufgerufen, `config.json` hat kein `sshUser` | einmal `./macvm stop $VM --user $LLM_USER` |
| `No route to host` | Das Host-Terminal darf nicht ins lokale Netz, oder die VM hat noch keine IP | Schritt 3; `./macvm ip $VM` prüfen, nach dem Start bis zu einer Minute warten |
| Passwort wird akzeptiert, dann `Connection closed` | User steht nicht in der Zugriffsliste von „Entfernte Anmeldung“ | Schritt 2, Punkt 4 |
| `Connection refused` | Entfernte Anmeldung im Gast aus | Schritt 2, Punkt 3 |
| `stop` sendet die Power-Taste statt per SSH herunterzufahren | Kein Schlüssel, unbekannter Host-Key oder fehlende sudo-Regel | Schritt 4 und 5, Gegenprobe ausführen |
| Bestehende SSH-Verbindung bricht ab | `firewall on` wurde geladen, alte Verbindungen haben keinen pf-State | Neu verbinden |

Zur Ursachensuche:

```zsh
ssh -v $LLM_USER@$(./macvm ip $VM) 2>&1 | tail -30                        # Host
log show --last 5m --predicate 'process == "sshd" OR process == "sshd-session"' | tail -30   # Gast
```

## Stoppen

```zsh
./macvm stop $VM --user $LLM_USER   # erstes Mal: User angeben, wird gespeichert
./macvm stop $VM                    # danach reicht das
./macvm stop $VM --force            # sofort hart stoppen
```

`stop` arbeitet in drei Stufen:
1. **Sauber:** Per SSH führt macvm im Gast `sudo -n /sbin/shutdown -h now` aus. Ist kein User hinterlegt oder schlägt SSH fehl, schickt es stattdessen die Power-Taste.
2. **Hart:** Ist der Gast nach `--timeout` Sekunden (Standard 90) noch nicht unten, stoppt macvm die VM hart. Das ist wie Stecker ziehen.
3. **Notfall:** Reagiert macvm selbst nicht mehr, wird der Prozess beendet.

Für Stufe 1 braucht es Schlüssel und sudo-Regel aus der Ersteinrichtung (Schritte 4 und 5).

Das Stoppen von Hand geht so:
- **Ctrl-C** im Vordergrund oder Fenster schließen fordert ein sauberes Herunterfahren an. Ein **zweites Ctrl-C** stoppt die VM hart.
- macvm legt beim Start `macvm.pid` im VM-Verzeichnis an und verhindert damit, dass dieselbe VM doppelt gestartet wird.

## CPU, RAM, Disk

Ohne Angaben legt `create` die VM mit **12 CPUs, 100 GB RAM und 250 GB Disk** an. CPU und RAM landen in `config.json` im VM-Verzeichnis. `run` liest sie bei jedem Start von dort, es gelten also die Werte vom `create`, bis du die Datei änderst. Einen Schalter, um sie nur für einen Start zu überschreiben, gibt es nicht.

So änderst du die Werte, während die VM gestoppt ist:

```bash
cat $VM/config.json   # aktuelle Werte anzeigen
# "cpus" und "memoryGB" anpassen, z. B. { "cpus": 8, "memoryGB": 64, ... }
```

Beim nächsten `run` gelten die neuen Werte. Die tatsächlich genutzten stehen im Log: `VM läuft (12 CPUs, 100 GB, MAC …)`.

Die Disk-Größe wird nur beim `create` festgelegt und steht nicht in `config.json`. Eine Einstellung zum späteren Vergrößern gibt es nicht.

## Modellordner freigeben (read-only)

Damit die rund 100 GB Modelle nicht doppelt auf der SSD liegen, kann macvm genau einen Host-Ordner per VirtioFS schreibgeschützt in den Gast einhängen.

```bash
mkdir -p ~/vms/models
# Modelle hierher verschieben, z. B. aus ~/.omlx/models:
mv ~/.omlx/models/MODELLNAME ~/vms/models/

./macvm run $VM --models ~/vms/models     # wird in config.json gespeichert
./macvm run $VM                           # nutzt die gespeicherte Freigabe
./macvm run $VM --no-models               # Freigabe entfernen
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
./macvm firewall on $VM       # Regeln laden, pf einschalten (sudo)
./macvm firewall status $VM   # Exit-Code 0 = wirksam, 2 = NICHT wirksam
./macvm firewall off $VM      # Wartung: Updates, Modell-Downloads
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
ssh $LLM_USER@$(./macvm ip $VM) true
```

Klappt eine der Gegenproben im Gast, wirken die Regeln nicht. Dann nichts produktiv laufen lassen und mir die Ausgabe von `./macvm firewall status` schicken.

## Härtung

Diese Schritte erst nach der kompletten Ersteinrichtung und der Installation der LLM-Server ausführen. Danach kommst du per SSH nur noch als LLM-User mit Schlüssel in den Gast.

### Getrennte User

| User | Rechte | Wofür |
|---|---|---|
| `$ADMIN_USER` | Admin | Installationen, Updates, Systemeinstellungen |
| `$LLM_USER` | Standard, per sudo **nur** `/sbin/shutdown` | LLM-Server, SSH-Tunnel, `macvm stop` |

Übernimmt ein Angreifer einen LLM-Server, hat er damit nur die Rechte des LLM-Users. Er kann weder Software installieren noch Einstellungen ändern oder die Firewall berühren. Die läuft ohnehin auf dem Host.

### Admin aus dem SSH-Zugriff nehmen

Im Gast unter Systemeinstellungen → Allgemein → Teilen → Entfernte Anmeldung → **ⓘ** bei „Zugriff erlauben für“ nur noch `$LLM_USER` eintragen.

Prüfen vom Host aus:

```zsh
ssh $ADMIN_USER@$(./macvm ip $VM) true    # muss mit "Connection closed" scheitern
ssh $LLM_USER@$(./macvm ip $VM) true      # muss funktionieren
```

**Wartung danach:** Am besten über das Fenster mit `./macvm run $VM --gui`. Dort meldest du dich als Admin an, gibst ihn bei Bedarf kurz wieder für SSH frei und nimmst ihn danach wieder raus.

`su - $ADMIN_USER` in einer SSH-Sitzung des LLM-Users geht zwar auch, ist aber nicht empfehlenswert: Dabei tippst du das Admin-Passwort in genau die Sitzung, die du absichern willst.

### Nur Schlüssel, keine Passwörter

Steht der Schlüssel aus Schritt 4 der Ersteinrichtung, braucht SSH keine Passwörter mehr. Im Gast als Admin (im Fenster):

```zsh
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' | sudo tee /etc/ssh/sshd_config.d/100-macvm.conf
sudo sshd -t                                          # keine Ausgabe = Konfiguration gültig
sudo launchctl kickstart -k system/com.openssh.sshd   # sshd neu starten
```

Prüfen vom Host aus:

```zsh
ssh -o PubkeyAuthentication=no $LLM_USER@$(./macvm ip $VM) true   # muss mit "Permission denied" scheitern
ssh $LLM_USER@$(./macvm ip $VM) true                              # muss funktionieren
```

Lass das Fenster offen, bis beide Proben passen. Sperrst du dich aus, kommst du darüber wieder rein.

### Übersicht

- Firewall auf dem Host an: kein Internet und keine Host-Dienste für den Gast (siehe [Firewall](#firewall)). Nach jedem Host-Neustart und VM-Start `firewall status` prüfen.
- LLM-Server binden nur an `localhost`, Zugriff gibt es nur über den SSH-Tunnel. Kein `--host 0.0.0.0` setzen.
- Modellordner nur read-only freigeben und nur mit Modellen darin.
- SSH nur für den LLM-User, nur mit Schlüssel.
- Admin nur für Wartung, am besten über das Fenster.
- Zwischenablage, Audio, USB, beschreibbare Freigaben und Bridged-Netz bekommt die VM gar nicht erst.

## LLM-Server im Gast installieren

Server wie oMLX oder Strata laufen **im Gast**, nicht auf dem Host. Für die Installation braucht der Gast kurz Internet. Danach wird er wieder abgeschottet und nur über einen SSH-Tunnel vom Host aus erreicht.

### Wartungsfenster (gilt für beide)

**Die Command Line Tools (git, clang, make) MÜSSEN einmalig über das Fenster installiert werden.** Ohne sie ist `git` im Gast nur ein Platzhalter und meldet `xcode-select: error: No developer tools were found`. Headless per SSH funktioniert die Installation nicht: `xcode-select --install` öffnet im Gast einen Dialog, den niemand bestätigen kann, und auch der Weg über `softwareupdate` hat in der VM nicht funktioniert.

```zsh
# Host: läuft die VM headless, erst stoppen (dieselbe VM kann nicht doppelt laufen)
./macvm stop $VM
./macvm run $VM --gui --models ~/vms/models &
./macvm firewall off $VM            # die Installation lädt von Apple

# Im Fenster: als Admin anmelden, Terminal öffnen
xcode-select --install              # Dialog bestätigen, Download abwarten
git --version                       # Kontrolle
```

Danach kann die VM im Fenster weiterlaufen, oder du stoppst sie und startest headless neu. Alles Weitere geht per SSH:

```zsh
# Host
./macvm run $VM --models ~/vms/models &     # nur, falls neu gestartet
./macvm firewall off $VM
ssh $ADMIN_USER@$(./macvm ip $VM)
```

Ist die Installation fertig, gilt für beide Server:

```bash
# Host
./macvm firewall on $VM
./macvm firewall status $VM
```

Danach den Tunnel neu aufbauen (siehe unten). Updates gehen nur bei abgeschalteter Firewall: `brew upgrade omlx` als Admin, Strata mit `./update.sh` als LLM-User.

**GPU in der VM ungetestet:** Beide Server nutzen eigene Metal-Kernels. Ob die paravirtualisierte GPU im Gast alle nötigen Features hat, ist nicht geprüft. Schlägt das Laden mit Metal-Fehlern fehl, liegt es an der VM und nicht an der Installation.

**RAM:** Metal lässt ein Programm etwa 3/4 des Gast-RAMs fest belegen. Bei `--memory 100` sind das rund 75 GB. Lass nie beide Server gleichzeitig ein großes Modell laden.

### oMLX

Quelle: <https://github.com/jundot/omlx>. Voraussetzung: macOS 15+, Python 3.11–3.13 (Homebrew kümmert sich darum).

```bash
# Gast, als Admin (Homebrew braucht Admin-Rechte)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew tap jundot/omlx https://github.com/jundot/omlx
brew install jundot/omlx/omlx
```

`--with-custom-kernel` baut schnellere native Kernels für Qwen3.5, GLM-5.2 und MiniMax M3, braucht dafür aber das **volle Xcode** im Gast. Die DMG aus den GitHub-Releases geht auch, braucht aber das Fenster (`./macvm run … --gui`).

Installiert wird als Admin, gestartet als LLM-User. Homebrew trägt sich nur in das `PATH` des Admins ein. Damit der LLM-User `omlx` findet, einmalig als LLM-User ausführen:

```zsh
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
```

Modelle liest oMLX direkt aus der read-only-Freigabe:

```bash
# Gast, als LLM-User (ssh $LLM_USER@…) – Test im Vordergrund
omlx serve --model-dir "/Volumes/My Shared Files/models"
curl localhost:8000/v1/models    # zweites SSH-Fenster

# Host – Tunnel
ssh -N -L 8000:localhost:8000 $LLM_USER@$(./macvm ip $VM)
# → http://localhost:8000/v1 (OpenAI-API), http://localhost:8000/admin/chat (Web-UI)
```

Kein `--host 0.0.0.0` setzen. Der Tunnel reicht, und oMLX bleibt nur im Gast erreichbar.

### Strata

Quelle: <https://github.com/Niko1221/Strata> (Mac-Doku: `docs/MAC.md`). Strata führt das Modell Qwen3.8-Flash-Next aus. Der Mac-Support ist laut Projekt **experimentell**. Das Engine-Binary wird im Gast aus dem Quellcode gebaut, dafür reichen die Command Line Tools. Python 3.10+ ist nötig. Fehlt es, lädt `setup.sh` ein eigenes Python in `.python`, ohne sudo und ohne Homebrew.

**Wichtiger Unterschied zu oMLX:** `setup.sh` lädt das Modell nicht nur herunter, sondern **schreibt** daraus ein eigenes Pack und eine Draft-Schicht. In die read-only-Freigabe kann der Gast das nicht schreiben. Deshalb liegen die Strata-Modelle auf der Gast-Disk.

Platzbedarf auf der Gast-Disk: 66–84 GB Download, dazu ca. 7 GB Pack und Draft-Schicht. Die n-gram-Tabelle kommt mit rund 29 GB pro Pack noch obendrauf, wird aber von der SSD gelesen und belegt keinen RAM. Bei `--disk 250` passt das, für ein zweites Pack wird es aber eng.

```bash
# Gast, als LLM-User, noch im Wartungsfenster (Firewall aus)
git clone https://github.com/Niko1221/Strata && cd Strata
./setup.sh --check                                    # prüft nur Chip, RAM, macOS, Tools, Disk
./setup.sh --model IQ3_S --models-dir ~/strata-models --no-start --no-browser
```

**Modellgröße:** IQ3_S braucht rund 63 GB und passt in die ~75 GB, die Metal bei 100 GB Gast-RAM belegen darf. UD-Q4_K_XL braucht 91 GB und passt nicht. Strata würde die Experts dann von der SSD streamen, was deutlich langsamer ist. Mit `--memory 128` oder mehr (falls der Host das hergibt) wird UD-Q4_K_XL möglich.

Starten und Zugriff:

```bash
# Gast, als LLM-User – Port 8080, bindet standardmäßig nur an 127.0.0.1
cd ~/Strata && ./setup.sh --no-browser    # erkennt die fertige Installation und startet sofort

# Host – Tunnel
ssh -N -L 8080:localhost:8080 $LLM_USER@$(./macvm ip $VM)
# → http://localhost:8080/v1 (OpenAI-API), /v1/messages (Anthropic-API), http://localhost:8080/ (Chat)
```

`setup.sh` legt zusätzlich ein `run-<modell>.sh` an, z. B. `run-iq3_s.sh`, mit dem du direkt startest. Auch hier gilt: kein `--host 0.0.0.0` setzen. Strata bearbeitet **eine Anfrage nach der anderen**, weitere Clients warten in der Schlange.

**Ungetestete Alternative, um die Gast-Disk zu sparen:** Strata einmal auf dem **Host** mit `--models-dir ~/vms/models/strata --no-start` vorbereiten und im Gast mit `--models-dir "/Volumes/My Shared Files/models/strata"` starten. Ob Strata beim Start aus einem schreibgeschützten Ordner noch etwas schreiben will, ist nicht geprüft. Außerdem würde Strata im Streaming-Modus über VirtioFS lesen, und das ist langsam.

## Golden Image

```bash
cp -cR $VM $VM-golden       # APFS-Clone, kostet kaum Platz
```

Original und Klon dürfen nicht gleichzeitig laufen, weil sie dieselbe Machine-ID und dieselbe MAC-Adresse haben.

## Dateien im VM-Verzeichnis

| Datei | Inhalt |
|---|---|
| `disk.img` | Sparse-Disk des Gasts |
| `aux.img` | Hilfsspeicher (NVRAM) |
| `hardware-model.bin`, `machine-id.bin` | Identität der VM |
| `config.json` | CPUs, RAM, MAC-Adresse, Modellordner, zuletzt genutztes Firewall-Interface |
