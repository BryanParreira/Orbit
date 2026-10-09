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

- Guest systems are downloaded only over HTTPS from each project's official server.
- Every image is verified against the SHA-256 checksum the project publishes. Verification fails closed: an image that doesn't match is deleted, and an image whose checksum can't be fetched isn't used.
- macOS restore images come from Apple's catalog and are verified by macOS during installation.

### Virtual machines

- Guests run in Apple's Virtualization framework (each in its own sandboxed process) or in QEMU, a separate process.
- A guest sees only what you give it: shared folders you choose (optionally read-only), the clipboard only if you turn it on (off by default), the microphone only if you turn it on (off by default).
- Networking defaults to NAT, so guests aren't reachable from your local network.
- QEMU's control sockets live in your user's private temporary folder, accessible only to you. File paths are escaped before being passed to QEMU, so a file name can't inject options.

### Machines from elsewhere

A machine package is just a folder, so one you received from someone else could describe anything. Orbit treats every package as untrusted:

- Disks must be files inside the package. A package that points a disk at another file on your Mac, or uses `../` to escape its folder, has that disk removed.
- Installer media from outside the package is always attached read-only.
- Imported machines start without shared folders, custom QEMU arguments or bridged networking.
- Snapshot data can only restore files inside its own package.

## Supported versions

Security fixes are released for the latest version of Orbit. Keep automatic updates on to receive them.
