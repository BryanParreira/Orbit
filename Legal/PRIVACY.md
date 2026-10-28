# Privacy Policy

Last updated: October 27, 2026

Orbit runs on your Mac. It has no accounts, no servers of its own and no analytics. This policy says exactly what Orbit does with information, in plain terms.

## What Orbit collects

**Nothing.** Orbit does not collect, transmit or sell personal information. There is no telemetry, crash reporting, advertising or tracking of any kind, and no account to create.

## What stays on your Mac

- **Your machines.** Virtual machines, their disks, snapshots and settings live in the library folder you choose. Orbit never uploads them.
- **Preferences.** Orbit's settings are stored in macOS's standard preferences for the app.
- **Logs.** Orbit writes diagnostic messages to macOS's unified log on your Mac. They stay there under macOS's own retention rules.
- **Diagnostics report.** Only if you choose *Export Diagnostics*, Orbit builds a text report you can read and save. Machine names, file paths, your user name and MAC addresses are left out. Orbit does not send it anywhere; sharing it is up to you.

## Connections Orbit makes

Orbit connects to the internet only to do what you ask:

| When | Where | What is sent |
| --- | --- | --- |
| Checking for updates | GitHub (github.com) | A request for the update feed. Sparkle sends no system profile. |
| Downloading a Linux, BSD or other system | The project's official download server, e.g. Debian, Ubuntu, Fedora, Alpine | A request for the image and its checksum list |
| Downloading Windows | microsoft.com | The page you see inside Orbit is Microsoft's own, and Microsoft's privacy statement applies to it. Orbit keeps nothing from that page afterwards. |
| Downloading Windows drivers | GitHub (virtio-win project) | A request for the driver disc |
| Downloading macOS | Apple's servers | A request for the restore image |

Like any internet request, these reveal your IP address to the server that answers. Orbit adds no identifier, cookie or account information to them. Each server's own privacy policy applies to what it does with its logs.

## What guests can reach

A virtual machine sees only what you give it. Shared folders, clipboard sharing, the microphone and USB devices are all off until you turn them on, per machine. When you turn one on, software running inside that machine can use it. Orbit does not look at that data.

## Permissions

- **Microphone:** used only for machines where you enable microphone input, after macOS asks you.
- **Local network:** used to connect virtual machines to each other and to your Mac.
- **Notifications:** used only to tell you a download or install has finished, if you allow them.
- **Authentication:** if you turn on *Require authentication to start* for a machine, Orbit asks macOS to confirm it is you (Touch ID or your password). Orbit never sees your fingerprint or password.

## Children

Orbit is a general-purpose tool and does not knowingly collect information from anyone, including children.

## Changes

If this policy changes, the new version ships with the app and Orbit asks you to review it. The date above shows when it last changed.

## Contact

Questions about privacy: open an issue at https://github.com/BryanParreira/Orbit/issues. For security problems use the private reporting described in SECURITY.md.
