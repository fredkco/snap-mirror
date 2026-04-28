# snap-mirror

Build an HTTP-served offline mirror for Snap packages.

`snap-fetch.sh` reads snap requests from a list, downloads `.snap` and `.assert` files, discovers dependencies from snap metadata (`base` and `default-provider`), and generates a repository (`manifest.tsv`, `manifest.json`, `index.html`, `snap-offline.sh`) that clients can use for offline install/update.

Search keywords: `snap-offline`, `snap offline`, `offline snap repository`.

## Compatibility

Tested on Ubuntu 22.04, 24.04, and 26.04 (beta).

## Requirements

- Linux with Bash and `snapd`
- `snap` (with permission to run `snap download`)
- `unsquashfs` (from `squashfs-tools`)
- `awk`, `sed`, `find`, `sort`, `tail`, `tee`, `date`, `basename`, `paste`, `cut`, `realpath`
- Enough disk space for snap artifacts

## Quick Start

```bash
git clone https://github.com/fredkco/snap-mirror.git
cd snap-mirror
chmod +x snap-fetch.sh
./snap-fetch.sh snap.list ./snap-offline
```

## Input List Format (`snap.list`)

```text
firefox
thunderbird=stable
snap-store=latest/stable
firefox=7901
# comments are ignored
```

- `name` means default channel
- `name=<number>` means specific revision
- `name=<channel>` means channel selector

## Generated Output

By default, output is written to `./snap-offline`:

- `*.snap`
- `*.assert`
- `manifest.tsv`
- `manifest.json`
- `index.html`
- `repo-metadata.env`
- `snap-offline.sh`

The fetch process is incremental and keeps state in `snap-offline/.state/`.
On repeated runs, unpinned entries (`name` or `name=<channel>`) are checked for newer revisions and downloaded when updates are available.
Pinned revision entries (`name=<number>`) are kept during old-revision cleanup and do not count toward the normal rotation window.

## Host The Repository

From the project directory:

```bash
python3 -m http.server 8080
```

This makes the repo available at:

- `http://<server>:8080/snap-offline`

## Install/Update From The Mirror

On the target machine:

```bash
wget http://<server>:8080/snap-offline/snap-offline.sh
chmod +x snap-offline.sh
export SNAP_REPO_URL="http://<server>:8080/snap-offline"
./snap-offline.sh --list
./snap-offline.sh --install firefox
./snap-offline.sh --update
./snap-offline.sh --force-stop-running --update
```

## Useful Environment Variables

- `SNAP_REPO_URL`: mirror base URL used by `snap-offline.sh`
- `SNAP_CACHE_DIR`: local directory for client-side downloaded files

## Important Behavior

- Client install/update uses `sudo snap ack` and `sudo snap install`.
- Assertions are required for signed offline install.
- `--force-stop-running` helps when updates fail due to running snap apps.

## Publishing Notes

- Keep generated artifacts out of git unless you intentionally want to publish binaries.
- Review Snap licensing and redistribution terms before publishing packages.
