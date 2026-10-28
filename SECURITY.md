# Security

## Reporting a vulnerability

Please report security problems privately through [GitHub Security Advisories](https://github.com/BryanParreira/Orbit/security/advisories/new) rather than in a public issue. Include the Orbit version, your macOS version and the steps to reproduce. You'll get a reply as soon as possible, and a fix will be released before the details are made public.

## Security model

### The app

- **Signed and notarized.** Every release is signed with a Developer ID, uses the hardened runtime, and is notarized and stapled by Apple. Gatekeeper verifies it before it first runs.
- **Minimal entitlements.** Orbit asks for only two: `com.apple.security.virtualization` (to run virtual machines) and `com.apple.security.device.audio-input` (only used when you turn on a machine's microphone, after macOS asks you). No JIT, no disabled library validation, no unsigned code.
- **Nothing installed on your system.** No privileged helper, launch agent, login item, kernel or system extension. Orbit never asks for an administrator password.
- **No partitioning.** Orbit never partitions or formats your Mac's disks. Virtual disks are ordinary files inside each machine's package. The only time a disk image is attached is while converting an Apple ASIF image you import into a QEMU machine: macOS attaches it briefly, without mounting any volume, and detaches it when the copy is done.
- **No telemetry.** No analytics, crash reporting or tracking of any kind.

### Updates

- Delivered with [Sparkle](https://sparkle-project.org) over HTTPS from this repository's GitHub releases.
- Each update is signed with an EdDSA key held only by the maintainer and verified against the public key built into Orbit before it is extracted. The update itself is also Developer ID signed and notarized.
- Development builds never update themselves.

### Downloads

- Guest systems are downloaded only over HTTPS from each project's official server. A download that is redirected to plain HTTP is refused. Large files are fetched in several parallel ranges; the finished file goes through the same checksum verification as any other.
- Every image is verified against the SHA-256 checksum the project publishes. Verification fails closed: an image that doesn't match is deleted, and an image whose checksum can't be fetched isn't used.
- Windows is downloaded from the link Microsoft's own download page hands out, shown inside Orbit in a private browser view that keeps nothing afterwards. Orbit accepts only HTTPS links on microsoft.com, and checks the image against the SHA-256 checksums that page lists.
- The VirtIO drivers for Windows guests come from the [virtio-win](https://github.com/virtio-win/virtio-win-pkg-scripts) project over HTTPS. The project publishes no checksum for its ISO, so Orbit pins one exact release by its SHA-256 and refuses anything else. Only the driver files are taken from it. The answer file and install script on the drivers disc are written by Orbit, run only inside the Windows guest during its setup, and don't set accounts, product keys or disk layout. Windows also checks each driver's signature before installing it.
- macOS restore images come from Apple's catalog and are verified by macOS during installation.

### Protecting your Mac

- **Memory budget.** A machine won't start if the running machines plus this one would leave macOS less than 3 GB of memory, so guests can't push the Mac into heavy swapping.
- **Disk space.** A machine won't start with less than 3 GB free, and a running machine is paused automatically if free space drops below 1 GB, before a guest can fill the disk macOS needs.
- **Clean failures.** Interrupted downloads, imports and copies are removed rather than left half-written. Temporary files used while machines run are deleted when they stop, and leftovers from a crash are cleaned up the next time Orbit opens.

### Locking a machine

- **Require authentication to start.** Turn it on in a machine's settings and Orbit asks macOS to confirm it is you (Touch ID, Apple Watch or your password) before the machine starts, including when Orbit opens it automatically. It fails closed: if the Mac has no password set, the machine doesn't start. Orbit never sees your fingerprint or password.

### Virtual machines

- Guests run in Apple's Virtualization framework (each in its own sandboxed process) or in QEMU, a separate process.
- A guest sees only what you give it: shared folders you choose (optionally read-only), the clipboard only if you turn it on (off by default), the microphone only if you turn it on (off by default).
- Networking defaults to NAT, so guests aren't reachable from your local network.
- QEMU's control sockets live in your user's private temporary folder, accessible only to you. File paths are escaped before being passed to QEMU, so a file name can't inject options.

### Machines from elsewhere

A machine package is just a folder, so one you received from someone else could describe anything. Orbit treats every package as untrusted:

- Disks must be files inside the package. A package that points a disk at another file on your Mac, or uses `../` to escape its folder, has that disk removed.
- A package that contains symbolic links isn't imported, and a machine whose package contains one won't start: a link could hand the guest any file on your Mac.
- Installer media is always attached read-only. Imported machines lose any installer outside their own package, because it could name any file on your Mac.
- Imported machines start without shared folders, port forwards, custom QEMU arguments, bridged networking or *Start when Orbit opens*.
- Settings that reach QEMU's command line (the MAC address, the machine type) must have their expected form, so they can't carry extra options.
- Snapshot data can only restore files inside its own package, and a snapshot containing a link is refused before anything is changed.

### Disk images

- QCOW2 and VMDK images can name other files: a backing file, an external data file, the pieces of a split disk. A crafted image could use that to pass a guest any file you can read. Orbit refuses images that name files outside their own folder, when importing them and (for QCOW2) every time a machine starts.
- Installer discs are passed to QEMU as plain data, never probed for a format.

## Legal

- [Privacy Policy](Legal/PRIVACY.md)
- [Terms of Use](Legal/TERMS.md)
- [Open source notices](NOTICE)

The same documents are inside the app under Settings → About, and Orbit asks you to review them the first time it opens.

## Supported versions

Security fixes are released for the latest version of Orbit. Keep automatic updates on to receive them.
