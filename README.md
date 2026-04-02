<div align="center">

<br>

# mac2n

### Peer-to-peer VPN for macOS — zero kexts, pure utun

Build and run [n2n](https://github.com/ntop/n2n) v3.0.0 on macOS using the native **utun** kernel interface.
No third-party TUN/TAP drivers. No kernel extensions. Just works.

<br>

<img src="docs/mac2n-main-screen.png" alt="mac2n — interactive terminal menu showing instance management, service control, and supernode options" width="680">

<br>
<br>

[![macOS 12+](https://img.shields.io/badge/macOS-12%2B-000000?style=flat-square&logo=apple&logoColor=white)](#prerequisites)
[![Apple Silicon & Intel](https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-supported-000000?style=flat-square&logo=apple&logoColor=white)](#macos-specific-details)
[![n2n v3.0.0](https://img.shields.io/badge/n2n-v3.0.0-2ea44f?style=flat-square)](https://github.com/ntop/n2n/commit/6a64e72dc6cdfac818ffb210515b17cfa70f4bb3)
[![License: GPLv3](https://img.shields.io/badge/License-GPLv3-blue?style=flat-square)](LICENSE)

</div>

<br>

## Get Started in Seconds

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/mchsk/mac2n/main/install.sh)"
```

The installer handles **everything** — Xcode CLI tools, Homebrew, build toolchain, n2n compilation, binary signing, and firewall setup. Requires `sudo`.

Once installed:

```bash
mac2n
```

<br>

## Why mac2n

<table>
<tr>
<td width="50%" valign="top">

**Multi-instance manager**
Run multiple VPN tunnels simultaneously — each with its own community, supernode, IP, encryption, and LaunchDaemon.

**Interactive wizard with presets**
Guided setup for Home VPN, Remote Access, Site-to-Site, Gaming, IoT Mesh, or fully custom configurations.

**Validation built in**
IP conflicts, port collisions, key strength, address formats — caught before they become problems.

</td>
<td width="50%" valign="top">

**Native utun interface**
No kext or DEXT installation. Works on Apple Silicon and Intel. Interfaces appear as `utunN`.

**LaunchDaemon integration**
Services persist across reboots. Start, stop, restart, and tail logs per instance or all at once.

**Backup supernode failover**
Each instance supports a secondary supernode. Automatic rotation by load, RTT, or MAC.

</td>
</tr>
</table>

<br>

## Prerequisites

- macOS 12+ (Monterey or later)
- An admin account with `sudo` privileges

> Xcode Command Line Tools and Homebrew are installed automatically if missing.

<br>

## Usage

### Interactive Mode

```bash
mac2n              # opens the interactive menu
```

### CLI Commands

#### Instance Management

```bash
mac2n create [name]       # Create a new edge instance (guided wizard)
mac2n list                # List all instances with status
mac2n show <name>         # Detailed view of a single instance
mac2n edit <name>         # Edit an existing instance
mac2n delete <name>       # Delete an instance (stops if running)
```

#### Service Control

```bash
mac2n start <name>        # Start a single instance
mac2n start --all         # Start all instances
mac2n stop <name>         # Stop a single instance
mac2n stop --all          # Stop all instances
mac2n restart <name>      # Restart a single instance
mac2n restart --all       # Restart all instances
mac2n logs <name>         # Tail log output for an instance
```

#### Supernode

```bash
mac2n supernode create    # Configure a supernode
mac2n supernode status    # Show supernode status
mac2n supernode start     # Start supernode
mac2n supernode stop      # Stop supernode
mac2n supernode restart   # Restart supernode
mac2n supernode delete    # Remove supernode
```

#### Other

```bash
mac2n status              # Full overview (all instances + supernode + network)
mac2n self-update         # Pull latest source and rebuild
mac2n migrate             # Migrate old single-instance setup
mac2n uninstall           # Remove all n2n services and config
mac2n help                # Show help
```

### Examples

```bash
# Create two edge instances for different networks
mac2n create home
mac2n create office

# Start everything
mac2n start --all

# Check what's running
mac2n status

# Edit the office instance
mac2n edit office
```

<br>

## Use Case Presets

When creating an instance, the wizard offers presets with smart defaults:

| Preset | Cipher | Routing | MTU | Typical Use |
|--------|--------|---------|-----|-------------|
| **Home VPN** | AES-256 | no | 1290 | Personal devices on a private network |
| **Remote Access** | ChaCha20 | yes | 1290 | Reach home/office from anywhere |
| **Site-to-Site** | AES-256 | yes | 1290 | Bridge two separate LANs |
| **Gaming / LAN** | None | no | 1400 | Low-latency direct P2P |
| **IoT Mesh** | Speck-CTR | yes | 1000 | Lightweight encrypted mesh |
| **Custom** | — | — | — | Full manual configuration |

<br>

## Instance Storage

Each instance is stored independently:

| File | Location |
|------|----------|
| Config | `~/.config/n2n/instances/<name>/edge.conf` |
| Plist | `/Library/LaunchDaemons/org.ntop.n2n-edge.<name>.plist` |
| Log | `/var/log/n2n-edge-<name>.log` |

<br>

## Backup Supernode

Each edge instance supports a **backup supernode** for failover. When the primary supernode becomes unreachable, n2n automatically rotates to the backup. Configure via:

```bash
mac2n edit <name>   # choose "Network settings" → add/change backup supernode
```

The supernode selection strategy (by load, RTT, or MAC) can be set under "Advanced settings".

<br>

## Validation

The wizard validates all inputs:

- Instance names, community names, encryption keys (with strength feedback)
- VPN IPs (private range, conflict detection with interfaces and other instances)
- Supernode addresses (`host:port` format)
- Ports (range check, in-use detection, cross-instance conflict prevention)
- MTU, MAC address format, CIDR subnet

<br>

## Security Note

Encryption keys are passed as command-line arguments to the `edge` binary. This is how n2n works — keys may be visible to other local users via `ps`. The LaunchDaemon plist files containing keys are created with mode `600` (owner-only read), but the running process arguments are not hidden from the process table. This is an inherent limitation of n2n's architecture.

<br>

## macOS-Specific Details

This build uses the native **utun** interface:

- No kext/DEXT installation needed
- Works on Apple Silicon and Intel
- Interface appears as `utunN` (e.g., `utun7`)
- Synthetic Ethernet headers with ARP cache for peer MAC resolution
- Automatic subnet route management via the `route` command

<br>

## Manual Install

<details>
<summary>Clone and build manually instead of the one-liner</summary>

<br>

`sudo` is required for installation, binary signing, and firewall setup:

```bash
git clone --recursive https://github.com/mchsk/mac2n.git ~/.mac2n
cd ~/.mac2n
./build.sh all
sudo ln -sf ~/.mac2n/wizard.sh /usr/local/bin/mac2n
```

If you already cloned without `--recursive`:

```bash
git submodule update --init
```

</details>

<br>

## Build Script

```bash
./build.sh deps        # Install Homebrew dependencies
./build.sh source      # Fetch n2n source (submodule or clone)
./build.sh build       # Configure + make (autotools)
./build.sh install     # Install to /usr/local + bundle OpenSSL dylib
./build.sh harden      # Ad-hoc sign binaries + add firewall exceptions
./build.sh verify      # Smoke-test that edge and supernode execute
./build.sh clean       # Clean build artifacts (keeps source)
./build.sh all         # All of the above (default)
```

CMake alternative: `./build.sh build-cmake` instead of `./build.sh build`.

Custom prefix: `PREFIX=/opt/n2n ./build.sh all`.

<br>

## Service Management

```bash
# Use mac2n (recommended)
mac2n start home
mac2n stop home
mac2n logs home

# Or use launchctl directly
sudo launchctl bootstrap system /Library/LaunchDaemons/org.ntop.n2n-edge.home.plist
sudo launchctl kickstart system/org.ntop.n2n-edge.home
```

<br>

<details>
<summary><strong>Manual edge & supernode usage</strong></summary>

<br>

### Edge Node (client)

```bash
sudo edge -c mynetwork -k mysecretkey -a static:10.0.0.1/24 -l supernode.example.com:7777
```

### Supernode (relay server)

```bash
sudo supernode -p 7777 -f
```

### Key Options

| Flag | Description |
|------|-------------|
| `-c` | Community name (like a VLAN) |
| `-k` | Encryption key (shared secret) |
| `-a` | VPN IP address (`static:IP/CIDR`) |
| `-l` | Supernode address (`host:port`), repeatable for failover |
| `-p` | Supernode listen port |
| `-A3` | AES-256-CBC encryption |
| `-A4` | ChaCha20 encryption |
| `-A5` | Speck-CTR encryption (lightweight) |
| `-r` | Enable packet forwarding |
| `-E` | Accept multicast MAC addresses |
| `-M` | Set MTU (default 1290) |
| `-z1` | Enable LZO compression |
| `-n` | Route networks through VPN |
| `-f` | Run in foreground |

</details>

<br>

## Update

```bash
mac2n self-update
```

Or manually:

```bash
cd ~/.mac2n && git pull && ./build.sh all
```

## Uninstall

```bash
# Full uninstall — removes VPN services, configs, binaries, and the mac2n command
~/.mac2n/install.sh --uninstall
```

To remove only VPN services and configs while keeping the tool installed:

```bash
mac2n uninstall
```

<br>

## Appendix: Hardening macOS as an Always-On Server

<details>
<summary><strong>Prevent sleep, WiFi drops, and unreachable hosts on headless Macs</strong></summary>

<br>

> **Who needs this?** Anyone running mac2n on a Mac that should stay reachable 24/7 — headless Mac minis, home VPN gateways, remote-access nodes, site-to-site bridges. macOS aggressively power-manages hardware when it thinks nobody is using it, which will make your VPN node go dark. Apply these settings **once** and forget about it.

All commands below use `sudo` and persist across reboots.

---

### 1. Disable all sleep modes

The `-a` flag applies to **all** power sources (charger, battery, and UPS). macOS has multiple independent sleep mechanisms — you need to disable **all** of them:

| Setting | Value | Effect |
|---------|-------|--------|
| `sleep` | `0` | System sleep — never |
| `disksleep` | `0` | Disk spindown — never |
| `displaysleep` | `0` | Display sleep — never (also prevents associated network drops) |
| `standby` | `0` | Deep sleep (RAM → disk after long idle) — never |
| `autopoweroff` | `0` | Auto power-off after prolonged standby — never |

```bash
sudo pmset -a sleep 0
sudo pmset -a disksleep 0
sudo pmset -a displaysleep 0
sudo pmset -a standby 0
sudo pmset -a autopoweroff 0
```

> **Why `displaysleep 0`?** macOS treats display sleep as a signal to aggressively power-manage other subsystems, including WiFi and USB. Disabling it prevents a cascade of side effects on headless machines.

---

### 2. Auto-restart after power failure

This is the **most critical server setting**. Without it, a brief power outage means your Mac stays off until someone physically presses the power button:

```bash
sudo pmset -a autorestart 1
```

You can also enable this in **System Settings → Energy Saver → Start up automatically after a power failure** (checkbox at the bottom). The `pmset` command above does the same thing.

> **FileVault warning:** If FileVault (disk encryption) is enabled, auto-restart will stop at the FileVault unlock screen — the Mac boots, but macOS does not fully load until someone enters the password. For a truly unattended server, either **disable FileVault** (`sudo fdesetup disable`) or use an [institutional recovery key](https://support.apple.com/en-us/102233) with `fdesetup authrestart`. Understand the security trade-off before disabling FileVault.

---

### 3. Keep network alive

| Setting | Value | Effect |
|---------|-------|--------|
| `tcpkeepalive` | `1` | Maintain TCP connections during display sleep |
| `womp` | `1` | Wake-on-LAN (Magic Packet) — requires compatible NIC |
| `networkoversleep` | `0` | Keep full network during sleep (do **not** use `1` which only keeps partial) |
| `powernap` | `1` | Allow background tasks during sleep (safety net) |

```bash
sudo pmset -a tcpkeepalive 1
sudo pmset -a womp 1
sudo pmset -a networkoversleep 0
sudo pmset -a powernap 1
```

> **What is `womp`?** Wake-on-Magic-Packet lets another device on the LAN wake the Mac by sending a special Ethernet frame. It requires a wired Ethernet connection (does not work over WiFi). Useful as a safety valve if the Mac somehow sleeps despite the above settings.

---

### 4. Disable WiFi power management (skip if using Ethernet)

WiFi power management is the **#1 cause** of headless Macs dropping off the network. If you must use WiFi:

```bash
sudo /usr/libexec/airportd prefs DisconnectOnLogout=NO
```

> **macOS 15+ note:** On macOS Sequoia and later, this command produces no output even on success, and `airportd prefs` no longer prints its configuration. The setting may still take effect silently. If WiFi drops persist, rely on the System Settings method below instead.

Then in **System Settings**:

1. Go to **Wi-Fi** → click your connected network name
2. Click **Details…**
3. Turn **off** "Low data mode"
4. Turn **off** "Limit IP address tracking" (this can interfere with VPN connectivity)

---

### 5. Persistent anti-sleep with caffeinate (recommended)

`caffeinate` is a **built-in macOS command** (at `/usr/bin/caffeinate`) — there is nothing to install. The step below creates a LaunchDaemon that runs `caffeinate` permanently in the background as a safety net against sleep:

Create the plist:

```bash
sudo tee /Library/LaunchDaemons/com.local.caffeinate.plist > /dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.caffeinate</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/caffeinate</string>
        <string>-s</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF
```

Then load it:

```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/com.local.caffeinate.plist
```

**What this does:**
- `-s` prevents **system sleep** for as long as the process runs
- `RunAtLoad` starts it automatically at boot
- `KeepAlive` restarts it if the process is killed

**Verify it's running:**

```bash
sudo launchctl list | grep caffeinate
```

Expected output: a line showing PID, status `0`, and `com.local.caffeinate`.

**To remove it later:**

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.local.caffeinate.plist
sudo rm /Library/LaunchDaemons/com.local.caffeinate.plist
```

---

### 6. Enable SSH for remote management

A headless server is useless if you cannot reach it to troubleshoot. Enable SSH:

```bash
sudo systemsetup -setremotelogin on
```

Or in **System Settings → General → Sharing → Remote Login** (toggle on).

Verify:

```bash
ssh localhost
```

Should prompt for your password — press Ctrl-C to cancel.

> **Tip:** Add your SSH public key to `~/.ssh/authorized_keys` for passwordless access. If you only use SSH (no physical keyboard), consider also enabling **Screen Sharing** in System Settings for emergency GUI access.

---

### 7. Disable automatic software updates (optional but recommended)

macOS automatic updates can reboot your machine without warning. For a server, you want to apply updates **manually** on your own schedule:

```bash
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
```

Or in **System Settings → General → Software Update → Automatic Updates** — turn off all toggles.

> **Important:** You are now responsible for checking and applying security updates yourself. Run `softwareupdate -l` periodically and pick a maintenance window.

---

### 8. Silence all sounds (optional)

A headless server has no reason to beep. Disable the startup chime, alert sounds, and UI sound effects:

```bash
sudo nvram StartupMute=%01
osascript -e "set volume output volume 0"
osascript -e "set volume alert volume 0"
defaults write NSGlobalDomain com.apple.sound.beep.volume -float 0.0
defaults write NSGlobalDomain com.apple.sound.uiaudio.enabled -int 0
defaults write -g com.apple.sound.beep.feedback -int 0
```

| Command | Effect |
|---------|--------|
| `nvram StartupMute=%01` | Disables the boot chime (persists in NVRAM) |
| `set volume output volume 0` | Mutes system audio output |
| `set volume alert volume 0` | Mutes alert/beep sounds |
| `com.apple.sound.beep.volume` | Sets alert volume to zero |
| `com.apple.sound.uiaudio.enabled` | Disables UI sound effects |
| `com.apple.sound.beep.feedback` | Disables volume-change feedback sound |

To undo and restore sounds:

```bash
sudo nvram StartupMute=%00
osascript -e "set volume output volume 50"
osascript -e "set volume alert volume 75"
defaults write NSGlobalDomain com.apple.sound.beep.volume -float 0.7
defaults write NSGlobalDomain com.apple.sound.uiaudio.enabled -int 1
defaults write -g com.apple.sound.beep.feedback -int 1
```

---

### 9. Static IP or DHCP reservation

A server's IP address should not change. Either:

- **Set a static IP** in System Settings → Network → your interface → Details → TCP/IP → Configure IPv4 → Manually
- **Create a DHCP reservation** in your router's admin panel, mapping the Mac's MAC address to a fixed IP

This prevents your VPN node from becoming unreachable after a DHCP lease renewal assigns a different address.

---

### 10. Ethernet vs WiFi

If you have the option, **use Ethernet**. It eliminates WiFi power management issues entirely and is inherently more reliable for an always-on server.

| | Ethernet | WiFi |
|---|---|---|
| Power management issues | None | Frequent on headless Macs |
| Latency & jitter | Low, stable | Variable |
| Wake-on-LAN | Yes | No |
| Headless reliability | Excellent | Good (with steps 4–5 above) |

> **Mac mini without Ethernet port?** Use a USB-C or Thunderbolt Ethernet adapter. Apple and third-party adapters both work. Make sure Ethernet is listed **above** WiFi in **System Settings → Network** (drag to reorder) so it takes priority.

---

### Verify everything

After applying all settings, run:

```bash
pmset -g
```

Confirm these values in the output:

| Setting | Expected |
|---------|----------|
| `sleep` | `0` |
| `disksleep` | `0` |
| `displaysleep` | `0` |
| `standby` | `0` |
| `autopoweroff` | `0` |
| `autorestart` | `1` |
| `tcpkeepalive` | `1` |
| `womp` | `1` |
| `powernap` | `1` |

Then verify services:

Caffeinate daemon running:

```bash
sudo launchctl list | grep caffeinate
```

SSH accessible:

```bash
ssh localhost echo ok
```

n2n running:

```bash
mac2n status
```

---

### Troubleshooting

**Mac still sleeps despite all settings:**
1. Check if an Energy Saver profile is overriding your settings: `sudo pmset -g assertions`
2. Look for sleep events: `pmset -g log | grep -i sleep | tail -20`
3. Ensure the caffeinate daemon is running: `sudo launchctl list | grep caffeinate`
4. On some older Macs, a connected (or HDMI-dummy) display prevents aggressive sleep — search for "HDMI dummy plug" if nothing else works

**WiFi drops after a few hours:**
1. Re-run `sudo /usr/libexec/airportd prefs DisconnectOnLogout=NO` and verify the System Settings toggles (step 4 above)
2. Check WiFi interface power: `ifconfig en0 | grep status` (should show `active`)
3. Review WiFi logs: `log show --predicate 'subsystem == "com.apple.wifi"' --last 1h | grep -i disconnect`
4. If drops persist, switch to Ethernet — it is the definitive fix

**Mac does not restart after power failure:**
1. Verify: `pmset -g | grep autorestart` (should be `1`)
2. Check if FileVault is blocking boot: `fdesetup status`
3. Some surge protectors delay power restoration — ensure the Mac's outlet gets power quickly

---

### Revert all changes

To undo every setting from this guide and return to macOS defaults:

Restore default power management:

```bash
sudo pmset -a sleep 1
sudo pmset -a disksleep 10
sudo pmset -a displaysleep 10
sudo pmset -a standby 1
sudo pmset -a autopoweroff 1
sudo pmset -a autorestart 0
sudo pmset -a tcpkeepalive 1
sudo pmset -a womp 1
sudo pmset -a networkoversleep 0
sudo pmset -a powernap 0
```

Remove caffeinate daemon:

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.local.caffeinate.plist 2>/dev/null
sudo rm -f /Library/LaunchDaemons/com.local.caffeinate.plist
```

Restore WiFi default:

```bash
sudo /usr/libexec/airportd prefs DisconnectOnLogout=YES
```

Disable SSH (if you enabled it):

```bash
sudo systemsetup -setremotelogin off
```

Re-enable automatic updates (if you disabled them):

```bash
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool true
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool true
```

Restore sounds (if you silenced them):

```bash
sudo nvram StartupMute=%00
osascript -e "set volume output volume 50"
osascript -e "set volume alert volume 75"
defaults write NSGlobalDomain com.apple.sound.beep.volume -float 0.7
defaults write NSGlobalDomain com.apple.sound.uiaudio.enabled -int 1
defaults write -g com.apple.sound.beep.feedback -int 1
```

</details>

<br>

## License

n2n is licensed under [GPLv3](https://github.com/ntop/n2n/blob/dev/LICENSE). The build and manager scripts in this repository follow the same license.

<div align="center">
<sub>Pinned to n2n commit <a href="https://github.com/ntop/n2n/commit/6a64e72dc6cdfac818ffb210515b17cfa70f4bb3"><code>6a64e72</code></a> (included as a git submodule)</sub>
</div>
