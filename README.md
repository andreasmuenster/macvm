# macvm

A minimal, dependency-free launcher for macOS virtual machines on Apple silicon, built directly on Apple's `Virtualization.framework`.

macvm is designed for one job: running local LLM servers (such as [oMLX](https://github.com/jundot/omlx) or [Strata](https://github.com/Niko1221/Strata)) inside an **isolated macOS guest** that has GPU access but no way to reach the internet, the host's services, or your LAN. The whole tool is a single Swift file (~800 lines) that you can read in full before building it.

> **Status:** Early stage. macvm builds, creates, runs, and stops VMs. Two things have **not** been verified across macOS versions: whether the paravirtualized GPU exposes every Metal feature that LLM servers need, and how vmnet and pf interact. Always run the [firewall verification](#verifying-the-firewall) on your own machine.

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Building](#building)
- [Conventions used in this document](#conventions-used-in-this-document)
- [Initial setup](#initial-setup)
- [Daily operation](#daily-operation)
- [Configuration](#configuration)
- [Access through a VPN](#access-through-a-vpn)
- [Sharing a model folder (read-only)](#sharing-a-model-folder-read-only)
- [Network isolation (firewall)](#network-isolation-firewall)
- [Hardening](#hardening)
- [Installing LLM servers in the guest](#installing-llm-servers-in-the-guest)
- [Golden image](#golden-image)
- [Deleting a VM](#deleting-a-vm)
- [Troubleshooting](#troubleshooting)
- [Command reference](#command-reference)
- [VM directory layout](#vm-directory-layout)
- [License](#license)

## Features

| The guest gets | The guest deliberately does not get |
|---|---|
| CPU, RAM, one disk | Writable shared folders |
| NAT network (own vmnet network, default 10.77.64.x) | Clipboard sharing |
| Keyboard, mouse | Audio |
| Graphics device (paravirtualized Metal GPU) | USB passthrough |
| Optional: **one** read-only model folder | vsock / serial console |
| | Bridged networking |

The graphics device stays attached in headless mode too, because it is the guest's only path to the GPU.

Additional capabilities:

- **Host-side firewall** based on pf. The guest cannot change it, not even as root.
- **Graceful shutdown** over SSH, with escalation to a hard stop.
- **PID locking** prevents the same VM from being started twice.
- **Golden images** as near-free APFS clones.

## Requirements

- A Mac with Apple silicon. macOS guests are only supported on Apple silicon.
- Xcode Command Line Tools on the host (`swiftc`, `codesign`, `make`).
- An admin account on the host. The firewall uses `sudo pfctl`.
- Enough free resources for the guest. The defaults are 12 CPUs, 100 GB RAM and a 250 GB sparse disk.

No Apple Developer account is required.

## Building

```zsh
xcode-select --install  # if the Command Line Tools are not installed yet
make                    # build and ad-hoc sign
make install            # optional: copy to ~/.local/bin (or: make install PREFIX=/opt/macvm)
make uninstall
make clean
```

`make` ad-hoc signs the binary with exactly one entitlement, `com.apple.security.virtualization`, and prints the embedded entitlements so you can check them. It rebuilds only when `main.swift` or the entitlements file has changed.

> If you used `make install`, make sure you run the freshly built binary. `which macvm` shows which copy your shell picks up. The examples below use `./macvm` from the project directory.

## Conventions used in this document

### VM directory and guest users

Every command takes the VM directory as its argument. The examples use `~/vms/omlx-vm`.

The guest has two users (see [step 2](#2-first-boot-with-a-window)), and macvm stores their names in the VM's `config.json`:

| Role | Example name | Used by |
|---|---|---|
| **Admin user** | `admin` | `macvm ssh --admin`, `macvm copy-id --admin`: installations, maintenance |
| **LLM user** | `llm` | `macvm ssh`, `macvm tunnel`, `macvm copy-id`, `macvm stop`: LLM servers, tunnels, shutdown |

macvm reads the usernames and the guest's current IP itself, so you never have to type `user@ip`:

```zsh
./macvm users ~/vms/omlx-vm --admin admin --llm llm  # set once
./macvm users ~/vms/omlx-vm                          # show
```

### Placeholders

`<…>` in this document marks a placeholder. Never type the angle brackets: in zsh, `<…>` is a numeric range glob, and the command fails with `zsh: number expected`.

### Which password?

| Prompt | Password |
|---|---|
| `Password:` from `macvm firewall …` | Your **host** (Mac) login password. This is `sudo` on the host. |
| `macvm ssh` / `macvm copy-id` | The password of the **guest** user you are connecting as |
| `sudo` inside the guest | The password of the guest's admin user |

### Program output

macvm prints its messages in German. They are quoted verbatim below, with a translation where it helps.

## Initial setup

### 1. Create the VM

```zsh
mkdir -p ~/vms
./macvm ipsw-url  # prints the latest compatible IPSW URL from Apple
curl -L -o ~/vms/macos.ipsw "https://…"  # URL from the previous command

./macvm create ~/vms/omlx-vm --ipsw ~/vms/macos.ipsw --cpus 12 --memory 100 --disk 250  # takes a while
```

### 2. First boot with a window

```zsh
./macvm run ~/vms/omlx-vm --gui
```

In the guest:

1. **Complete Setup Assistant.** The account created here is the **admin user**. macvm does not create any user.
2. **Create a second user.** Go to System Settings → Users & Groups → Add User and choose type **Standard**, not Administrator. This is the **LLM user**. The LLM servers run as this user, so a compromised server does not get admin rights in the guest.
3. **Enable SSH.** Go to System Settings → General → Sharing and turn on **Remote Login**.
4. **Allow both users to use SSH.** Click **ⓘ** next to Remote Login and add both users under "Allow access for". By default only administrators may log in. Any other user gets `Connection closed` right after entering the correct password.
5. You can decline **Full Disk Access for remote users**. SSH does not need it.
6. **Check the IP.** In the guest's Terminal, `ipconfig getifaddr en0` should print an address from the VM subnet (default 10.77.64.x).
7. **Install the Command Line Tools. This step is required and only works in the window.** Run `xcode-select --install` as the admin in the guest's Terminal, confirm the dialog, then check with `git --version`. Over headless SSH this does not work, see [Command Line Tools](#command-line-tools-gui-required). The firewall is still off at this point, so the download works.

Then, on the host, tell macvm the two usernames:

```zsh
./macvm users ~/vms/omlx-vm --admin admin --llm llm  # use the names you created
```

Keep the window open for now.

### 3. Allow local network access on the host

Since macOS 15, apps on the **host** need permission to reach addresses on the local network, and that includes the VM. Without it, `ssh` fails with `No route to host` even though the VM is running fine.

Open System Settings → Privacy & Security → **Local Network**, enable your terminal app (Terminal, iTerm, Ghostty, …), then restart the terminal.

```zsh
nc -z -w 5 $(./macvm ip ~/vms/omlx-vm) 22 && echo reachable  # checks the SSH port
```

> **Do not use `ping` to test reachability.** The guest never answers ICMP echo requests, so `ping` only reports `Request timeout` even when SSH works. Use `nc` against port 22 or `ssh` directly.

### 4. Install an SSH key

`macvm stop` connects with `BatchMode=yes`, which means it never prompts for a password. The shutdown user therefore needs key-based login. A key for the admin is optional, but convenient.

```zsh
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519  # only if you have no key yet

./macvm copy-id ~/vms/omlx-vm                      # LLM user; asks for the guest password once, records the host key
./macvm copy-id ~/vms/omlx-vm --admin              # optional

./macvm ssh ~/vms/omlx-vm -- true                  # must succeed without a password prompt
```

`copy-id` also records the guest's host key. This matters because `stop` refuses unknown host keys.

### 5. Grant shutdown rights to the LLM user

For a clean shutdown, the LLM user needs passwordless `sudo` for `/sbin/shutdown` and **nothing else**. The admin installs the rule:

```zsh
./macvm ssh ~/vms/omlx-vm --admin

# in the guest, as admin; replace "llm" with your LLM user's name:
echo "llm ALL=(root) NOPASSWD: /sbin/shutdown" | sudo tee /etc/sudoers.d/macvm-shutdown
sudo chmod 440 /etc/sudoers.d/macvm-shutdown
sudo visudo -cf /etc/sudoers.d/macvm-shutdown  # must report "parsed OK"
exit
```

Check it from the host. This does **not** shut the guest down:

```zsh
./macvm ssh ~/vms/omlx-vm -- sudo -n -l /sbin/shutdown  # prints /sbin/shutdown
```

### 6. Switch to headless and isolate the guest

```zsh
./macvm stop ~/vms/omlx-vm
./macvm run ~/vms/omlx-vm &
sleep 60                               # wait for boot and a DHCP lease
./macvm ip ~/vms/omlx-vm
./macvm firewall on ~/vms/omlx-vm      # asks for your HOST password
./macvm firewall status ~/vms/omlx-vm  # exit code 0 = active
./macvm ssh ~/vms/omlx-vm
```

Next, [install the LLM servers](#installing-llm-servers-in-the-guest) and then apply the [hardening](#hardening) steps.

## Daily operation

```zsh
./macvm run ~/vms/omlx-vm &            # start headless
./macvm run ~/vms/omlx-vm --gui        # start with a window
./macvm ip ~/vms/omlx-vm               # print the guest's IP
./macvm ssh ~/vms/omlx-vm              # log in as the LLM user (--admin for the admin)
./macvm tunnel ~/vms/omlx-vm 8000      # forward guest port 8000 to localhost:8000
./macvm firewall status ~/vms/omlx-vm  # check after every host reboot and VM start
./macvm stop ~/vms/omlx-vm             # graceful shutdown
```

### Stopping

```zsh
./macvm stop ~/vms/omlx-vm                # graceful, as the LLM user from config.json
./macvm stop ~/vms/omlx-vm --force        # immediate hard stop
./macvm stop ~/vms/omlx-vm --timeout 180  # wait longer before escalating (default: 90 s)
```

`stop` escalates in three stages:

1. **Graceful:** macvm runs `sudo -n /sbin/shutdown -h now` in the guest over SSH. If no LLM user is set or SSH fails, it sends the power button instead.
2. **Hard:** If the guest is still running after `--timeout` seconds, macvm stops the VM hard. This is the equivalent of pulling the plug.
3. **Last resort:** If macvm itself no longer responds, its process is terminated.

Stage 1 requires the SSH key and the sudo rule from [steps 4 and 5](#4-install-an-ssh-key).

Manual stopping:

- **Ctrl-C** in the foreground, or closing the window, requests a graceful shutdown. A **second Ctrl-C** stops the VM hard.
- On start, macvm writes `macvm.pid` into the VM directory to prevent the same VM from running twice.

## Configuration

`create` defaults to **12 CPUs, 100 GB RAM and a 250 GB disk**. CPU and RAM are stored in `config.json` in the VM directory and read on **every** `run`, so the values from `create` apply until you edit the file. There is no flag to override them for a single run.

To change them, stop the VM and edit `config.json`:

```zsh
cat ~/vms/omlx-vm/config.json
# adjust "cpus" and "memoryGB", e.g. { "cpus": 8, "memoryGB": 64, ... }
```

The effective values are logged on start: `VM läuft (12 CPUs, 100 GB, MAC …)` ("VM running").

The disk size is set once by `create` and is not stored in `config.json`. There is no setting to grow the disk later.

The VM's NAT subnet is `10.77.64.0/24` by default. To change it, set `"subnet": "a.b.c.0/24"` in `config.json` and restart the VM (it gets a new IP). `"subnet": "auto"` lets macOS pick its own range (usually `192.168.64.0/24`). If you change the subnet, also update the `Host` entry in `~/.ssh/config` from [Access through a VPN](#access-through-a-vpn).

## Access through a VPN

VPN clients such as GlobalProtect route local subnets, including the VM's, through the tunnel. The guest is then unreachable, and `ssh` hangs without an error. `route -n get <vm-ip>` shows `utun…` instead of `bridge100`. Changing the subnet does not help, because the client does the same for any local range. Binding connections to the VM's interface bypasses the tunnel route.

**SSH (`macvm ssh`, `tunnel`, `copy-id`):** add this to `~/.ssh/config` once, adjusted to your subnet:

```
Host 10.77.64.*
    BindInterface bridge100
```

**HTTP(S) and other ports:** browsers and most tools cannot bind to an interface. Use `macvm tunnel`, which runs over SSH and uses the setting above:

```zsh
./macvm tunnel ~/vms/omlx-vm 8000   # then open http://localhost:8000
```

For a single request, `curl --interface bridge100 http://<vm-ip>:8000` and `nc -b bridge100 -z <vm-ip> 22` also work.

If another tool such as Docker or UTM uses vmnet, the VM's bridge may be named `bridge101`. Check with `ifconfig | grep -B1 "inet <subnet-prefix>"` and adjust the name.

## Sharing a model folder (read-only)

To avoid keeping roughly 100 GB of models on the SSD twice, macvm can mount exactly one host folder into the guest via VirtioFS, read-only.

```zsh
mkdir -p ~/vms/models
mv ~/.omlx/models/MODEL_NAME ~/vms/models/       # move models here, e.g. from ~/.omlx/models

./macvm run ~/vms/omlx-vm --models ~/vms/models  # saved to config.json
./macvm run ~/vms/omlx-vm                        # uses the saved share
./macvm run ~/vms/omlx-vm --no-models            # removes the share
```

In the guest, the folder appears at `/Volumes/My Shared Files/models`:

```zsh
omlx serve --model-dir "/Volumes/My Shared Files/models" ...
```

In a LaunchAgent plist, put the path in its own `<string>` element after `--model-dir`, without quotes.

Security notes:

- **Read-only:** The guest cannot modify, delete or create anything in the folder. A compromised server cannot tamper with your models.
- **Models only:** Keep only models in the folder, no settings, caches or keys. macvm refuses `/`, `/Users`, `/Volumes` and your home directory.
- **No absolute symlinks:** Absolute symlinks point nowhere inside the guest. Relative links within the folder work.
- **Extra attack surface:** The guest now talks to Apple's VirtioFS server on the host. That is more than a bare disk, but acceptable when read-only.
- **Load time:** Loading a model over VirtioFS is slower than from the guest disk. Only the initial load is affected, inference speed is not. Include it in your benchmarks.

## Network isolation (firewall)

### Purpose

The guest runs code you have not audited: LLM servers, Python packages, custom Metal kernels and downloaded models. The firewall limits the damage if any of it is malicious or compromised:

- **No exfiltration.** Prompts, outputs and files cannot leave for the internet.
- **No second stage.** Malware cannot download further payloads or receive commands.
- **No lateral movement.** The guest cannot reach host services (DNS, Docker ports, local servers) or other devices on your LAN.

You can still reach the guest from the host, via SSH and port-forwarding tunnels.

### How it works

macvm creates its own vmnet NAT network (macOS 26+, no root) with the subnet `10.77.64.0/24` and attaches the VM to it. macOS creates a virtual interface on the host, usually `bridge100`. The subnet differs from the macOS default `192.168.64.0/24` on purpose: VPN clients such as GlobalProtect often route that range through the tunnel, which breaks SSH to the VM. To use another range, set `"subnet": "a.b.c.0/24"` in the VM's `config.json` and restart the VM; the VM gets a new IP.

```
  Internet / LAN
        │
   ┌────┴────────────────── Host ──────────────────────┐
   │  en0 (Wi-Fi / Ethernet)                            │
   │    ▲  NAT                                          │
   │    │                                               │
   │  bridge100  10.77.64.1     ◄── pf rules applied    │
   │    ▲        (DHCP, DNS proxy)                      │
   └────┼───────────────────────────────────────────────┘
        │
   Guest 10.77.64.x
```

**Every** packet from the guest enters the host through `bridge100`, including internet traffic, because NAT happens afterwards. Filtering on `bridge100` therefore covers all of the guest's traffic.

The loaded rules:

```
pass  out quick on bridge100 all keep state
pass  in  quick on bridge100 inet proto udp from any port 68 to any port 67 keep state
block drop in quick on bridge100 all
```

pf sees directions from the host's point of view: `in` means guest → host and `out` means host → guest.

1. **Host → guest is allowed and stateful.** When you open a connection to the guest, pf records it, and the guest's replies match that state.
2. **DHCP is allowed.** Without it the guest would lose its IP address when the lease expires.
3. **Everything else from the guest is dropped silently.** Programs in the guest run into timeouts instead of getting an immediate error.

In short, this is an **outbound** firewall for the VM. The guest can only answer and renew its lease. Every connection has to start on the host.

| Direction | Allowed |
|---|---|
| Host → guest (SSH, tunnels) | yes, all ports |
| Guest replies to host connections | yes |
| Guest → host: DHCP | yes |
| Guest → internet | **no** |
| Guest → host services (DNS, mDNS, Docker ports, …) | **no** |
| Guest → LAN | **no** |
| IPv6 from the guest | **no** |

Inbound connections from your LAN or the internet cannot reach the guest regardless. That is a property of NAT, not of the firewall.

The rules run in **pf on the host**, out of the guest's reach. Even root in the guest cannot see or disable them.

### Commands

```zsh
./macvm firewall on ~/vms/omlx-vm      # load rules, enable pf
./macvm firewall status ~/vms/omlx-vm  # exit code 0 = active, 2 = NOT active
./macvm firewall off ~/vms/omlx-vm     # maintenance: updates, downloads
```

> **Password: your HOST password, not the guest's.** All three commands run `sudo` on your Mac, because pf is the host's firewall. Enter your Mac login password, not the password of a guest user. Your Mac user must be an administrator. `sudo` caches the password for a few minutes.

`No ALTQ support in kernel` / `ALTQ related functions disabled` is harmless. `pfctl` prints it on macOS on almost every call because ALTQ (traffic shaping) is not compiled into the kernel. Current macvm versions filter it out.

The rules live in a dedicated anchor, `com.apple/macvm-<vm-name>`. Apple's default `/etc/pf.conf` evaluates every anchor under `com.apple/`, so macvm never modifies that file. If you have customized `/etc/pf.conf`, make sure it still contains `anchor "com.apple/*"`.

### Caveats

- **Reconnect after `firewall on`.** Connections opened before the rules were loaded have no pf state and get cut off.
- **Rules do not survive a host reboot.** Run `firewall status` after every reboot and every VM start, and `firewall on` if needed. `status` also warns if the VM has moved to a different bridge, e.g. `bridge101` instead of `bridge100`.
- **Rules apply to the whole bridge.** Other VMs on the same bridge (Docker, UTM, Lima with vmnet) are isolated too. `firewall on` aborts in that case unless you pass `--force`.

### Verifying the firewall

Run this after the first `firewall on`:

```zsh
# in the guest — all three must fail:
curl -m 5 https://example.com
curl -m 5 http://10.77.64.1
nc -z -w 5 1.1.1.1 443  # TCP, not ping: ICMP is not a reliable test here

# on the host — must succeed:
./macvm ssh ~/vms/omlx-vm -- true
```

If any of the guest checks succeeds, the rules are not in effect. Do not run anything productive in the guest until you have resolved it. Start with the output of `./macvm firewall status ~/vms/omlx-vm`.

## Hardening

Apply these steps once the initial setup is complete and the LLM servers are installed. Afterwards, the only way into the guest over SSH is as the LLM user, with a key.

### Separate users

| User | Privileges | Purpose |
|---|---|---|
| Admin user | Administrator | Installations, updates, system settings |
| LLM user | Standard; `sudo` for `/sbin/shutdown` **only** | LLM servers, SSH tunnels, `macvm stop` |

An attacker who takes over an LLM server only gets the LLM user's privileges. They cannot install software or change system settings, and they cannot touch the firewall, which runs on the host anyway.

### Remove the admin from SSH access

In the guest, go to System Settings → General → Sharing → Remote Login → **ⓘ** and leave only the LLM user under "Allow access for".

Check from the host:

```zsh
./macvm ssh ~/vms/omlx-vm --admin -- true  # must fail with "Connection closed"
./macvm ssh ~/vms/omlx-vm -- true          # must succeed
```

**Maintenance afterwards:** Preferably use the window, `./macvm run ~/vms/omlx-vm --gui`. Log in as admin there, temporarily re-enable SSH access if needed, and remove it again afterwards.

Running `su - <admin>` inside an LLM-user SSH session works, but is discouraged: it means typing the admin password into exactly the session you are trying to contain.

### Key-only authentication

Once the key from [step 4](#4-install-an-ssh-key) is in place, SSH no longer needs passwords. In the guest, as admin (in the window):

```zsh
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' | sudo tee /etc/ssh/sshd_config.d/100-macvm.conf
sudo sshd -t                                         # no output = valid configuration
sudo launchctl kickstart -k system/com.openssh.sshd  # restart sshd
```

Check from the host:

```zsh
./macvm ssh ~/vms/omlx-vm -o PubkeyAuthentication=no -- true  # must fail with "Permission denied"
./macvm ssh ~/vms/omlx-vm -- true                             # must succeed
```

Keep the window open until both checks pass, so you can recover if you lock yourself out.

### Checklist

- [ ] Host firewall on: no internet and no host services for the guest. Check `firewall status` after every host reboot and VM start.
- [ ] LLM servers bind to `localhost` only and are reached through SSH tunnels. Never set `--host 0.0.0.0`.
- [ ] The model folder is shared read-only and contains models only.
- [ ] SSH is limited to the LLM user and uses keys only.
- [ ] The admin account is used for maintenance only, preferably via the window.
- [ ] No clipboard, audio, USB, writable shares or bridged networking. macvm never attaches them.

## Installing LLM servers in the guest

LLM servers such as oMLX or Strata run **in the guest**, not on the host. Installation needs temporary internet access. Afterwards the guest is isolated again and reached only through SSH tunnels.

### Maintenance window

```zsh
# host
./macvm run ~/vms/omlx-vm --models ~/vms/models &
./macvm firewall off ~/vms/omlx-vm
./macvm ssh ~/vms/omlx-vm --admin
```

When you are done:

```zsh
# host
./macvm firewall on ~/vms/omlx-vm  # HOST password
./macvm firewall status ~/vms/omlx-vm
```

Then re-establish your tunnels. Updates also require the firewall to be off: run `brew upgrade omlx` as admin, and Strata's `./update.sh` as the LLM user.

### Command Line Tools (GUI required)

**The Command Line Tools (git, clang, make) must be installed once through the window.** Without them, `git` in the guest is only a stub that fails with `xcode-select: error: No developer tools were found`. Headless installation does not work: `xcode-select --install` opens a dialog in the guest that nobody can confirm over SSH, and installing through `softwareupdate` did not work in the VM either.

If you already did this in [step 2](#2-first-boot-with-a-window), skip this section.

```zsh
# host: stop the VM first if it is running headless (the same VM cannot run twice)
./macvm stop ~/vms/omlx-vm
./macvm run ~/vms/omlx-vm --gui --models ~/vms/models &
./macvm firewall off ~/vms/omlx-vm  # the installer downloads from Apple

# in the window: log in as admin, open Terminal
xcode-select --install              # confirm the dialog, wait for the download
git --version                       # check
```

### Homebrew and CMake (optional, recommended)

Homebrew is the standard package manager on macOS, and oMLX is installed through it anyway. Many projects build native code with CMake, for example kernels, llama.cpp-style engines and Python packages with C++ extensions. With the Command Line Tools alone, such builds fail with `cmake: command not found`.

Both can be installed headless over SSH, as admin, with the firewall off:

```zsh
# guest, as admin
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
brew install cmake
cmake --version  # check
```

Homebrew only adds itself to the admin's `PATH`. So that the LLM user can find Homebrew programs such as `cmake` or `omlx`, run this once **as the LLM user**:

```zsh
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
```

Only the admin can install or upgrade packages.

### GPU and memory notes

- **GPU support is untested.** Both servers use custom Metal kernels. Whether the paravirtualized GPU exposes every required feature has not been verified. If loading fails with Metal errors, the cause is the VM, not the installation.
- **Memory:** Metal lets a single process wire roughly ¾ of the guest's RAM, so about 75 GB with `--memory 100`. Never let both servers load a large model at the same time.

### oMLX

Source: <https://github.com/jundot/omlx>. Requires macOS 15+ and Python 3.11–3.13. Homebrew takes care of Python.

```zsh
# guest, as admin
brew tap jundot/omlx https://github.com/jundot/omlx
brew install jundot/omlx/omlx
```

`--with-custom-kernel` builds faster native kernels for Qwen3.5, GLM-5.2 and MiniMax M3, but requires the **full Xcode** in the guest. The DMG from the GitHub releases also works, but needs the window (`--gui`).

oMLX is installed as admin and run as the LLM user. It reads models directly from the read-only share:

```zsh
# guest, as LLM user — foreground test
omlx serve --model-dir "/Volumes/My Shared Files/models"
curl localhost:8000/v1/models  # from a second SSH session

# host — tunnel
./macvm tunnel ~/vms/omlx-vm 8000
# → http://localhost:8000/v1 (OpenAI API), http://localhost:8000/admin/chat (web UI)
```

Do not set `--host 0.0.0.0`. The tunnel is enough, and oMLX stays reachable only inside the guest.

### Strata

Source: <https://github.com/Niko1221/Strata>. Strata runs the Qwen3.8-Flash-Next model, and its macOS support is **experimental** according to the project, see `docs/MAC.md`. The engine binary is built from source in the guest; the Command Line Tools are sufficient. It requires Python 3.10+. If none is available, `setup.sh` downloads a private Python into `.python`, without sudo or Homebrew.

**Key difference from oMLX:** `setup.sh` does not just download the model. It **writes** its own pack and a draft layer, and the guest cannot write those to the read-only share. Strata models therefore live on the guest disk.

Disk usage in the guest: a 66–84 GB download plus about 7 GB for pack and draft layer. On top of that comes an n-gram table of about 29 GB per pack. It is read from the SSD and does not occupy RAM. A 250 GB disk fits one pack. A second one gets tight.

```zsh
# guest, as LLM user, during a maintenance window (firewall off)
git clone https://github.com/Niko1221/Strata && cd Strata
./setup.sh --check  # checks chip, RAM, macOS, tools, disk only
./setup.sh --model IQ3_S --models-dir ~/strata-models --no-start --no-browser
```

**Model size:** IQ3_S needs about 63 GB and fits within the ~75 GB Metal can use with 100 GB guest RAM. UD-Q4_K_XL needs 91 GB and does not fit; Strata would then stream experts from the SSD, which is much slower. With `--memory 128` or more (if the host has it), UD-Q4_K_XL becomes feasible.

Running and access:

```zsh
# guest, as LLM user — port 8080, binds to 127.0.0.1 by default
cd ~/Strata && ./setup.sh --no-browser  # detects the existing installation and starts immediately

# host — tunnel
./macvm tunnel ~/vms/omlx-vm 8080
# → http://localhost:8080/v1 (OpenAI API), /v1/messages (Anthropic API), http://localhost:8080/ (chat)
```

`setup.sh` also creates a `run-<model>.sh` script, e.g. `run-iq3_s.sh`, for starting directly. Do not set `--host 0.0.0.0` here either. Strata processes **one request at a time**, and additional clients are queued.

**Untested alternative to save guest disk space:** Prepare Strata once on the **host** with `--models-dir ~/vms/models/strata --no-start`, then start it in the guest with `--models-dir "/Volumes/My Shared Files/models/strata"`. It has not been verified whether Strata tries to write to a read-only folder at startup. Strata would also read through VirtioFS in streaming mode, which is slow.

## Golden image

```zsh
cp -cR ~/vms/omlx-vm ~/vms/omlx-vm-golden  # APFS clone, takes almost no space
```

The original and the clone must not run at the same time, because they share the same machine ID and MAC address.

## Deleting a VM

macvm has no `delete` command. A VM is just its directory:

```zsh
./macvm stop ~/vms/omlx-vm          # if running
./macvm firewall off ~/vms/omlx-vm  # only if you used "firewall on"
rm -rf ~/vms/omlx-vm
```

Order matters: `firewall off` needs the VM directory to derive the anchor name. Rules left behind are cleared on the next host reboot anyway.

Optional cleanup:

- `ssh-keygen -R <old-ip>` removes the stale host key, so a new VM with the same IP does not trigger a warning.
- Delete `~/vms/macos.ipsw` if you do not plan to create another VM. The file is several GB.

Do **not** delete `~/vms/models` (only mounted, not part of the VM) or golden-image clones (independent directories).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `zsh: number expected` | A `<…>` placeholder was pasted into the command | Use real names without angle brackets |
| `Kein User hinterlegt` on `ssh` / `tunnel` / `copy-id` ("no user set") | The guest users are not in `config.json` yet | `./macvm users ~/vms/omlx-vm --admin <admin> --llm <llm>` |
| `Kein LLM-User hinterlegt` on `stop`, power button sent instead | Same | Same |
| `Fehler: … braucht einen Wert` ("… needs a value") | An option was given without a value, e.g. from an empty shell variable | Pass the value explicitly |
| `Password:` from `firewall …` rejects a correct password | It asks for the **host** password, not the guest's | Enter your Mac login password, see [Which password?](#which-password) |
| `No ALTQ support in kernel` | Harmless `pfctl` notice on macOS | Ignore |
| `No route to host` | The host terminal lacks local network permission, or the guest has no IP yet | [Step 3](#3-allow-local-network-access-on-the-host); check `./macvm ip ~/vms/omlx-vm` and allow up to a minute after start |
| `ssh` or HTTP hangs while a VPN is connected | The VPN routes the VM subnet through the tunnel | [Access through a VPN](#access-through-a-vpn) |
| `ping` times out | The guest does not answer ICMP | Expected. Test with `nc -z <ip> 22` or `ssh` |
| Password accepted, then `Connection closed` | User is not in the Remote Login access list | [Step 2](#2-first-boot-with-a-window), item 4 |
| `Connection refused` | Remote Login is off in the guest | [Step 2](#2-first-boot-with-a-window), item 3 |
| `stop` sends the power button instead of shutting down over SSH | No key, unknown host key, or missing sudo rule | Steps [4](#4-install-an-ssh-key) and [5](#5-grant-shutdown-rights-to-the-llm-user), run the checks |
| `xcode-select: error: No developer tools were found` in the guest | Command Line Tools are missing | [Install via the window](#command-line-tools-gui-required) |
| `cmake: command not found` | CMake is not installed | [Homebrew and CMake](#homebrew-and-cmake-optional-recommended) |
| Existing SSH session drops | `firewall on` was loaded and old connections have no pf state | Reconnect |

Diagnostics:

```zsh
./macvm ssh ~/vms/omlx-vm -v -- true 2>&1 | tail -30  # host
log show --last 5m --predicate 'process == "sshd" OR process == "sshd-session"' | tail -30  # guest
```

## Command reference

```
macvm ipsw-url                       URL of the latest compatible IPSW from Apple
macvm create <dir> --ipsw <file>     create a VM and install macOS
      [--cpus 12] [--memory 100] [--disk 250]   (RAM/disk in GB)
macvm run <dir> [--gui]              start the VM (headless without --gui)
      [--models <folder>]            share a folder read-only (saved)
      [--no-models]                  remove the share
macvm stop <dir>                     graceful shutdown, hard stop after timeout
      [--user <name>]                same as: macvm users <dir> --llm <name>
      [--timeout 90] [--force]       wait time in seconds / immediate hard stop
macvm ip <dir>                       IP of the running VM
macvm users <dir>                    show the guest users
      [--admin <name>] [--llm <name>]  set the guest users (saved)
macvm ssh <dir> [--admin]            log in as the LLM user (or the admin)
      [ssh-options…] [-- command…]   e.g. macvm ssh <dir> -- uptime
macvm tunnel <dir> <port>…           forward guest ports to localhost, as the LLM user
macvm copy-id <dir> [--admin]        install your SSH key for the LLM user (or the admin)
macvm firewall on <dir> [--force]    isolate the guest (pf on the host, needs sudo)
macvm firewall off <dir>             lift isolation (maintenance)
macvm firewall status <dir>          check state (exit code 0 = active)
```

Options that take a value abort with an error if the value is missing or empty, and numeric options require a positive number.

## VM directory layout

| File | Contents |
|---|---|
| `disk.img` | Guest disk (sparse) |
| `aux.img` | Auxiliary storage (NVRAM) |
| `hardware-model.bin`, `machine-id.bin` | VM identity |
| `config.json` | CPUs, RAM, MAC address, model folder, admin and LLM user, last firewall interface |
| `macvm.pid` | PID of the running macvm process (while running) |

## License

macvm is released under the [MIT License](LICENSE).
