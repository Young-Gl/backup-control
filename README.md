<p align="center">
  <img src="docs/icon-1024.png" width="128" alt="Backup Control icon">
</p>

<h1 align="center">Backup Control</h1>

<p align="center">
  A small native macOS app that puts a friendly face on
  <a href="https://restic.net">restic</a> + <a href="https://rclone.org">rclone</a> —
  encrypted, incremental backups to OneDrive.
</p>

<p align="center">
  <b>English</b> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-14%2B-blue">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-orange">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-green">
</p>

---

## Features

- **One-click backup** to OneDrive — encrypted on your Mac before upload
- **Incremental & deduplicated** — only new or changed chunks are uploaded
- **Pick what to back up** — Documents, Desktop, Pictures, Music, Downloads, dotfiles, or the whole home folder
- **Live estimates** — size, file count, measured upload speed and ETA before every run
- **Data budgets** — monthly upload cap, bandwidth limit, AC-power only
- **Scheduling** — daily at a time you choose, via `launchd`, low-priority I/O
- **Restore-friendly** — content-addressed snapshots; deleted files stay recoverable
- **First-run wizard** — detects the tools, lists remotes, initializes the repository
- **English / 简体中文** UI, light and dark mode

## Requirements

| | |
|---|---|
| macOS | 14 Sonoma or newer |
| Engines | [`restic`](https://restic.net) and [`rclone`](https://rclone.org) |
| Remote | an existing rclone remote (examples use `onedrive`) |
| Build | Xcode Command Line Tools |

## Setup

```bash
brew install restic rclone
rclone config                     # create the remote, e.g. "onedrive"

git clone https://github.com/Young-Gl/backup-control.git
cd backup-control
./build.sh
open "build/Backup Control.app"
```

### First run

The wizard checks for `restic` / `rclone`, lists your rclone remotes, then asks for:

| Field | Meaning |
|---|---|
| Remote | name of the rclone remote |
| Folder | path inside it, e.g. `MacBackup/restic` |
| Password | encrypts every snapshot — generate one or type your own |

Press **Initialize repository**. The app runs `restic init`, stores the password at
`~/Library/Application Support/macbackup/restic.pass` (mode `600`), and opens the main window.

> The wizard never modifies your rclone configuration.

### Configuration

`~/Library/Application Support/macbackup/config.json`

```json
{
  "remote": "onedrive",
  "repoPath": "MacBackup/restic",
  "initialized": true,
  "autoEnabled": false,
  "hour": 3,
  "minute": 0,
  "monthlyCapGB": 25,
  "bwlimitMB": 2,
  "language": "en",
  "useProxy": false,
  "scope": ["documents", "desktop", "pictures", "dotfiles"]
}
```

## Restoring

Restore to a scratch folder first — never straight over your live files:

```bash
export RESTIC_PASSWORD_FILE="$HOME/Library/Application Support/macbackup/restic.pass"
export RESTIC_REPOSITORY="rclone:onedrive:MacBackup/restic"

restic snapshots
restic restore latest --target ~/Desktop/Restore
restic restore <snapshot-id> --target /tmp/one --include "/Users/you/Documents/report.docx"
```

> Keep the repository password safe. Without it the data cannot be recovered —
> restic has no password reset.

## Backup Control vs. Time Machine

| | Backup Control | Time Machine |
|---|---|---|
| Scope | selected user data | whole system |
| Destination | any rclone remote | local disk / supported NAS |
| Encryption at rest | always, client-side | depends on target |
| Full-system recovery | no | yes |

They solve different problems. Use both if you can.

## How it works

```
SwiftUI app ──► scripts/backup.sh ──► restic ──► rclone ──► OneDrive
                     │                  │
                     └── launchd        └── AES-256 + Poly1305, chunked dedup
```

The app only orchestrates: it writes a `launchd` job, runs the shell script, and
reads back state. All backup and encryption work is done by restic.

## Legal & disclaimers

- Not affiliated with Microsoft, OneDrive, Apple, restic or rclone. Names are
  used descriptively; no third-party logos are included.
- The app implements no cryptography — it invokes restic (AES-256 + Poly1305).
- **Backup software: test your restores.** Provided under the MIT license,
  without warranty of any kind.
- Your credentials stay local: the rclone config in `~/.config/rclone/` and the
  restic password file are never sent anywhere except to your configured remote.
- Icon and artwork in this repository are original vector work.

## License

MIT — see [LICENSE](LICENSE).

<p align="center">
  <sub>SwiftUI · macOS 14+ · no accounts, no telemetry</sub>
</p>
