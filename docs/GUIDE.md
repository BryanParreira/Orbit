# Orbit User Guide

Everything you need to run virtual machines with Orbit, from your first install to shared folders and troubleshooting.

**Contents**

1. [Getting started](#getting-started)
2. [Choosing a system](#choosing-a-system)
3. [Creating a machine](#creating-a-machine)
4. [Installing the guest system](#installing-the-guest-system)
5. [Using a machine](#using-a-machine)
6. [Sharing files and the clipboard](#sharing-files-and-the-clipboard)
7. [Suspend, snapshots and disposable sessions](#suspend-snapshots-and-disposable-sessions)
8. [Settings explained](#settings-explained)
9. [Windows 11 on ARM](#windows-11-on-arm)
10. [Bringing machines from other apps](#bringing-machines-from-other-apps)
11. [Updates](#updates)
12. [Privacy and what Orbit stores](#privacy-and-what-orbit-stores)
13. [Uninstalling Orbit](#uninstalling-orbit)
14. [Troubleshooting](#troubleshooting)
15. [Keyboard shortcuts](#keyboard-shortcuts)

---

## Getting started

**You need** a Mac with Apple Silicon (M1 or later) running macOS 26 or later.

1. Download **Orbit.dmg** from the [latest release](https://github.com/BryanParreira/Orbit/releases/latest).
2. Open it and drag **Orbit** into **Applications**.
3. Open Orbit and pick a system on the welcome screen.

Orbit is signed and notarized by Apple, so it opens without security warnings. It never asks for your password.

---

## Choosing a system

Systems in the **Native** group run on Apple's own hypervisor at close to full speed. Systems in the **Compatibility** group run on QEMU, which Orbit can install for you (Settings → Engines).

| System | Engine | Good for |
|---|---|---|
| **macOS** | Native | Testing apps on a clean macOS, a separate work environment |
| **Ubuntu** | Native | A familiar Linux desktop |
| **Ubuntu Server** | Native | Servers, Docker, development without a desktop |
| **Fedora** | Native | The newest GNOME and Linux technologies |
| **Debian** | Native | A stable, minimal base |
| **Kali Linux** | Native | Security testing and learning |
| **Rocky Linux**, **AlmaLinux** | Native | Red Hat Enterprise Linux compatible servers |
| **openSUSE Tumbleweed** | Native | A rolling release that's always current |
| **NixOS** | Native | Reproducible, declarative systems |
| **Alpine** | Native | Tiny, fast containers and appliances |
| **Other Linux** | Native | Any ARM64 Linux image you have |
| **Windows 11** | QEMU | Windows apps on ARM ([details](#windows-11-on-arm)) |
| **FreeBSD** | QEMU | BSD development and servers |
| **Emulated PC** | QEMU | Intel/AMD (x86-64) systems. Works, but much slower |

> **Tip:** Linux and macOS guests should use the native engine whenever possible. It's many times faster than emulation.

---

## Creating a machine

1. Click **+** (or press **⌘N**) and choose a system.
2. Review the settings Orbit picked for your Mac and click **Create**.

That's it. The machine appears in your library right away, and its page shows the download and install progress.

**Downloads are verified.** Orbit downloads images only from each project's official server, always the newest release. It checks every download against the checksum the project publishes. A download that doesn't match is deleted, never used.

**Using your own files.** In the Create step, choose **Use a file on this Mac** to pick an installer you already have. You can also drop a file anywhere in the Orbit window:

| File | Result |
|---|---|
| Installer (`.iso`) | New machine with the installer attached |
| macOS restore image (`.ipsw`) | New macOS machine |
| Disk image (RAW, IMG, uncompressed DMG, ASIF, QCOW2, VMDK, VDI, VHD, VHDX) | New machine that boots that disk. It's converted if needed, and your original file is never changed |
| Orbit or UTM machine | Imported as a copy |

Orbit recognizes files by what they contain, not by their names. If something can't be used, it tells you why.

### Choosing where a machine is kept

Machines go in Orbit's library unless you choose otherwise. In the Create step, **Location → Choose…** puts the new machine in any folder, on this Mac or another drive. That's useful when your Mac is short on space. Everything the machine uses is kept there, including the installer it downloads, and nothing else goes anywhere else.

To change it later, shut the machine down and choose **Move…** from its menu (the **⋯** button, or right-click it). On the same drive a move is instant. To another drive, Orbit copies the machine, checks there's room first, and removes the original only once the copy is complete. **Move to Library** brings it back. The machine's page shows where it's kept under **Location**. Click it to see the machine in Finder.

If a machine's drive is disconnected, Orbit says so and lists the machine again when you reconnect it. **Settings → Storage → Kept elsewhere** lists every machine outside the library. **Forget** stops listing one whose drive is gone for good, and never deletes anything.

Tips:

- An **APFS** drive keeps snapshots and duplicates instant. On other formats they make full copies.
- Machines on a USB drive run slower than on your Mac's internal SSD. A Thunderbolt or USB4 SSD comes close.
- The whole library can also move: **Settings → General → Library → Change…**.

---

## Installing the guest system

Each system installs with its own installer, the same one you'd see on a PC. While the installer is attached, click **Setup Steps** (in the machine's window or on its page) for the choices to make. When an installer asks which disk to use, the only disks it can see are the machine's own virtual disk and the read-only installer: your Mac's drives are never visible to a guest, so "erase disk" only ever erases that virtual disk.

When the machine starts for the first time it boots from the installer. Follow the system's own installer as you would on a real computer. The disk the installer sees is the virtual disk Orbit created. It's a file inside the machine's package, never a disk of your Mac.

**After installation:** shut the machine down, then click **Eject** on the *Installer attached* banner. The next start boots the installed system.

**Kali Linux:** the installer asks you to choose a desktop and to create a user. Use the account you created to log in.

**Ubuntu Server, Rocky, AlmaLinux, Debian:** these install a system without a desktop by default. Log in at the text prompt with the user you created.

---

## Using a machine

- **All Machines:** Orbit opens on a gallery of every machine with a live preview. Hover a card for start, pause, suspend and shut-down buttons; double-click it to start and open the machine; click it for its details page.
- **Start:** click **Start** (or double-click the machine in the sidebar). A suspended machine shows **Resume** and comes back exactly where you left it.
- **The machine window:** click inside to type into the guest. Use the toolbar to pause, restart, shut down, take a snapshot or share a folder.
- **Full screen:** use the green button or **⌃⌘F**.
- **System shortcuts:** with the ⌘ button in the toolbar turned on, shortcuts like ⌘Tab and ⌘Space go to the guest instead of macOS.
- **Text size (Linux):** if text looks too small or too large, use the **Aa** button in the machine window's toolbar, or the machine's settings (**⌘I**) → Display → **Text size**. It changes immediately. *Large* matches macOS and is the default. *Sharp* gives the full Retina resolution.
- **Menu bar:** the planet icon in the menu bar shows every machine and lets you start, pause or stop them without opening the library. A moon appears on the ring while machines are running.

Closing a machine's window doesn't stop it. It keeps running in the background, and you can reopen it from the library or the menu bar.

---

## Sharing files and the clipboard

### Shared folders

Add a folder in the machine's settings → Sharing, or with the folder button in the machine's toolbar while it runs. You can add or remove folders while the machine is running.

**macOS guests:** shared folders appear in Finder under **My Shared Files**.

**Linux guests (native):** mount them once:

```sh
sudo mkdir -p /mnt/share
sudo mount -t virtiofs share /mnt/share
```

Each shared folder appears inside `/mnt/share` under its own name. To mount automatically at startup, add this line to `/etc/fstab`:

```
share  /mnt/share  virtiofs  defaults,nofail  0  0
```

**Linux guests (QEMU):**

```sh
sudo mount -t 9p -o trans=virtio,version=9p2000.L share /mnt/share
```

Tick **Read only** next to a folder if the guest should only see it, not change it.

### Clipboard

Copy and paste between macOS and Linux guests by turning on **Share clipboard** (in the Create step, or Settings → Sharing). Then install the agent in the guest:

```sh
sudo apt install spice-vdagent    # Ubuntu, Debian, Kali
sudo dnf install spice-vdagent    # Fedora, Rocky, AlmaLinux
```

Clipboard sharing is **off by default**. When it's on, the guest can read anything you copy on your Mac, including passwords, so turn it on only for systems you trust.

### USB devices

To use a USB drive's files in a machine, share the drive's folder (see above). It works for every system.

Handing a whole USB device to a machine (a serial adapter, a security key, a microcontroller board, a USB Bluetooth adapter) is coming to Linux and macOS guests on macOS 27. It needs a permission Apple grants separately, and this version of Orbit doesn't have it yet. When it does, a **USB** button appears in the machine's toolbar. Windows machines (QEMU) can't take USB devices.

### Bluetooth

Bluetooth devices connected to your Mac already work in every machine: keyboards, mice and trackpads type and point in the guest, and headphones and speakers play its sound.

A guest can't use your Mac's built-in Bluetooth radio directly; no virtual machine app on Apple Silicon can. For Bluetooth inside the guest itself (pairing devices from Linux, for example), a USB Bluetooth adapter given to the machine will work once USB devices are available.

### Reaching services inside a machine

Machines on **Shared (NAT)** networking can reach the internet, your Mac and each other. To reach a server running inside a machine from your Mac or other devices on your network, add a **port forward** in the machine's settings → Network: traffic to that port on your Mac goes to the port inside the guest. For example, forward 2222 to 22 and connect with `ssh -p 2222 user@your-mac`. Forwards work for every system and start with the machine. The first time, macOS may ask whether Orbit can accept incoming connections; allow it for devices on your network to connect.

**Bridged** networking, where the machine appears on your network as a device of its own, needs an entitlement Apple grants separately and isn't available in this build.

### Running Intel Linux apps with Rosetta

Native Linux machines can run x86-64 Linux programs through Rosetta. Turn on **Rosetta for Linux** in the machine's settings, then in the guest:

```sh
sudo mkdir -p /media/rosetta
sudo mount -t virtiofs rosetta /media/rosetta
sudo /usr/sbin/update-binfmts --install rosetta /media/rosetta/rosetta \
  --magic "\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00" \
  --mask "\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff" \
  --credentials yes --preserve no --fix-binary yes
```

---

## Suspend, snapshots and disposable sessions

**Suspend** saves the machine's memory to disk and stops it. Starting it again resumes in under a second, with every window and app exactly where you left them. When you quit Orbit with machines running, they're suspended automatically (Settings → Advanced → *Suspend when Orbit quits*).

**Snapshots** save the machine's state so you can return to it later. Taking one is instant and uses no extra space until the machine changes afterwards. A snapshot taken while the machine runs (marked with a memory chip) restores to that exact running moment. Find them on the machine's page under **Snapshots**. Hover a snapshot and click **Restore** to return to it.

**Disposable sessions** (**⋯** menu → Start Options → Disposable Session) run the machine on a throwaway copy. Nothing it does is kept, which makes them ideal for opening untrusted files or testing risky changes. Restarting during a disposable session keeps it disposable.

**Duplicate** (in the ⋯ menu) makes an independent copy instantly, with its own network identity, so both can run at the same time.

---

## Settings explained

Open a machine's settings with **⌘I** or the sliders button. Changes save automatically and take effect the next time the machine starts. Shared folders and text size apply right away.

| Setting | What it does |
|---|---|
| **Performance** | *Light*, *Balanced* (recommended) or *Maximum*. Sets processor cores and memory together. *Maximum* still leaves enough for macOS |
| **CPU cores / Memory** | Fine-tune by hand. *Reset* returns to the recommended value |
| **Text size** | How large Linux guests look on a Retina screen: Sharp, Medium or Large |
| **Resize with window** | The guest's screen follows the window as you resize it |
| **Storage** | Resize a disk (disks can only grow), add an existing disk, attach or eject an installer |
| **Disk performance** | *Safe* writes everything to disk immediately, *Balanced* (recommended) is much faster and still survives a guest crash, *Fast* is quickest but a Mac crash may lose the guest's latest writes |
| **Network** | *Shared (NAT)*: the guest uses your Mac's connection (recommended). *Host Only*: the guest can reach your Mac but not the internet. *Disconnected*: no network |
| **Sharing** | Shared folders, clipboard, Rosetta, sound and microphone |
| **Suspend when Orbit quits** | Resume instantly next time instead of a fresh boot |

The microphone is off by default. When you turn it on, macOS asks you once whether Orbit may use it.

---

## Windows 11 on ARM

Windows runs through QEMU with hardware acceleration.

Windows 11 on ARM runs on every Apple Silicon Mac (M1 and later). A Mac with 8 GB of memory can run it with 4 GB.

1. Install QEMU when Orbit asks (or in Settings → Engines). Orbit installs it with Homebrew.
2. Choose **New → Windows 11** and click **Download Windows 11 from Microsoft…**. Microsoft's own download page opens inside Orbit. Choose a language, click **Confirm**, then click the download button. Orbit takes over from there. (Already have the ISO? Choose it under **Or use an ISO on this Mac**.)
3. Give the machine at least 4 GB of memory and 64 GB of disk. The disk only uses space as Windows writes.
4. Click **Create**. Orbit downloads Windows (about 5 GB) with progress on the machine's page, checks it against the checksums Microsoft publishes, adds the drivers Windows needs (downloaded once, about 900 MB, verified), and starts the machine.

Orbit takes care of the rest:

- **Booting the installer.** Orbit answers *Press any key to boot from CD or DVD* for you on the first start. It never does on later starts, so setup's own restarts can't begin it again.
- **Drivers.** A small *Orbit Windows Drivers* disc is attached next to the installer. Setup installs the network, memory and other drivers from it before it asks for a network, so it goes online like on a PC. Every setup page (language, edition, disk, account) still shows as usual.
- **Requirements.** Setup is told not to require a TPM chip or Secure Boot, so nothing else needs installing. If you install `swtpm` yourself (`brew install swtpm`) before creating the machine, it gets an emulated TPM 2.0 chip, which Windows features like BitLocker use.

When Windows is set up, eject the installer from the machine's page. That removes the drivers disc too; the drivers are already installed.

If the network still doesn't appear (for example, you added the installer after creating the machine), setup offers **I don't have internet** so you can finish offline. Then attach the [VirtIO drivers](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso) as the installer, and in **Device Manager** update the driver of each device with a warning sign from the CD drive.

Notes:

- **Keep Windows on a fast disk.** On your Mac's internal SSD or a fast external SSD, setup takes about 20 minutes. On a slow USB drive it can take hours.
- **Screen size.** Windows runs at 800 × 600 in a window you can resize; the picture is scaled to fit. A sharper, adjustable resolution needs a display device the standard QEMU doesn't offer yet.
- After setup, Windows starts straight from its disk even if the installer is still attached.
- QEMU machines open in their own window and can't be suspended to disk. Shut them down normally.

---

## Bringing machines from other apps

- **UTM:** drop a `.utm` file onto Orbit, or use **File → Import (⌘O)**. Orbit makes a copy, so the UTM machine keeps working.
- **VMware, VirtualBox, Hyper-V:** drop the disk image (`.vmdk`, `.vdi`, `.vhd`, `.vhdx`). Orbit converts it and creates a machine that boots it. Converting these formats needs QEMU.
- **Raw disks and Apple disk images:** drop `.img`, `.raw`, uncompressed `.dmg` or `.asif` files directly.

For your safety, imported machines start without shared folders or custom QEMU arguments, and can never point at files outside their own package. Add shared folders again yourself if you want them.

---

## Updates

Orbit checks for updates once a day and tells you when a new version is ready. You can also choose **Orbit → Check for Updates…**. Every update is verified with a cryptographic signature before it's installed. Your machines are never touched; running ones are suspended before the update and resume after it. Turn automatic checks on or off in Settings → Updates.

---

## Privacy and what Orbit stores

Orbit has no account, no analytics and no tracking. It connects to the internet only to:

- download systems you ask for, from their official servers
- check Apple's catalog when you create a macOS machine
- check for Orbit updates on GitHub

Everything Orbit keeps on your Mac (also shown in **Settings → Storage**, with sizes):

| What | Where |
|---|---|
| Your machines and downloaded installers | `~/Library/Application Support/Orbit/Virtual Machines` (or the location you chose) |
| Machines you chose to keep elsewhere | Only the folders you picked for them. Each holds everything its machine uses |
| Settings | `~/Library/Preferences/com.orbitvm.Orbit.plist` |
| Update cache | `~/Library/Caches/com.orbitvm.Orbit` |
| Temporary files while machines run | Your private temporary folder, removed when they stop |

Orbit **never** partitions or formats your Mac's disks. It installs no background services, login items, kernel or system extensions, and it never asks for an administrator password. Each virtual disk is an ordinary file inside its machine's package. When a guest's installer "partitions a disk", it partitions that file, not your Mac.

See [SECURITY.md](../SECURITY.md) for the full security model.

---

## Uninstalling Orbit

1. Quit Orbit.
2. Drag **Orbit** from Applications to the Trash.
3. To remove your machines too, delete the library folder (Settings → Storage → Show in Finder shows where it is), and any machines listed under **Settings → Storage → Kept elsewhere**. The easiest way is to delete them in Orbit first.
4. Optionally remove the settings and update cache:

   ```sh
   rm ~/Library/Preferences/com.orbitvm.Orbit.plist
   rm -r ~/Library/Caches/com.orbitvm.Orbit
   ```

If you installed QEMU through Orbit, remove it with `brew uninstall qemu` (and `swtpm`, if you installed it).

---

## Troubleshooting

**Text in a Linux machine is tiny.** Settings → Display → **Text size** → *Large*. It applies immediately.

**A machine won't start because of memory.** Orbit keeps at least 3 GB for macOS. Shut down another machine, or choose a smaller *Performance* preset in the machine's settings.

**A machine paused itself and says the disk is almost full.** Orbit pauses machines when less than 1 GB is free, so the guest can't fill the disk macOS needs. Free up space (Settings → Storage → Remove Unused shows downloaded installers you can delete), then resume.

**"macOS allows at most two macOS virtual machines to run at the same time."** That's a limit macOS sets. Shut one down, then start the other.

**The machine boots back into the installer.** Shut it down and click **Eject** on the *Installer attached* banner.

**"QEMU couldn't start this machine."** The message includes QEMU's own reason. Common causes: QEMU isn't installed (Settings → Engines), or the same disk is already open in another QEMU window.

**"didn't match its published checksum".** The download was damaged on the way. Create the machine again to download a fresh copy.

**"Library Unavailable".** Your library is on a drive that isn't connected. Connect it and Orbit reloads automatically, or choose another location in Settings → General.

**"… is on a drive that isn't connected."** A machine you keep outside the library is on a drive that isn't plugged in. Connect it and the machine comes back. If the drive is gone for good, choose **Forget** in Settings → Storage.

**"This machine has a TPM chip, which needs swtpm."** The machine was created with an emulated TPM. Run `brew install swtpm` in Terminal. If Windows isn't installed on it yet, you can turn the TPM off in its settings instead.

**"Couldn't resume the saved session, so the machine started fresh."** The machine's hardware settings changed since it was suspended, or macOS was updated. The guest started normally; unsaved work from the suspended session is gone.

**Linux installer: partitioning fails, or it offers a 4 GB "Apple Virtual Disk".** That disk is the installer itself; Orbit before 0.1.5 attached it as a USB drive. Choose **Virtual disk 1 (vda)** instead, or update Orbit.

**No network in Windows.** Machines created with their installer get the drivers during setup. Otherwise add them yourself ([see above](#windows-11-on-arm)).

**Windows setup starts over after a restart.** Press no key at *Press any key to boot from CD or DVD* during setup's restarts. Once Windows is installed, eject the installer.

**Keyboard shortcuts go to macOS instead of the guest.** Turn on the ⌘ button in the machine window's toolbar.

Still stuck? [Report a problem](https://github.com/BryanParreira/Orbit/issues/new) and include what you were doing and the exact message.

---

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘N | New virtual machine |
| ⌘O | Import a machine or file |
| ⌘R | Start or resume the selected machine |
| ⌥⌘P | Pause |
| ⌥⌘S | Suspend |
| ⌥⌘Q | Shut down |
| ⇧⌥⌘Q | Force stop |
| ⇧⌘S | Take a snapshot |
| ⌘I | Show or hide settings |
| ⌘, | Orbit settings |
