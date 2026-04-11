# Tart VM home

All Tart VM images and working VMs live in this directory so they
stay on `/Volumes/McFiver` instead of the boot volume. The directory
itself is not committed — see the repo-root `.gitignore`.

## Usage

Every `tart` invocation for this repo MUST have `TART_HOME` pointing
here. There are two equivalent ways:

```sh
# Inline — robust, no state leakage between commands
TART_HOME=/Volumes/McFiver/u/GIT/Steading/tart tart list
TART_HOME=/Volumes/McFiver/u/GIT/Steading/tart tart clone \
    ghcr.io/cirruslabs/macos-tahoe-xcode:26.4 steading-fresh

# Or export once per shell session
export TART_HOME=/Volumes/McFiver/u/GIT/Steading/tart
tart list
```

A plain `tart …` (with no `TART_HOME` set) will silently fall back
to `~/.tart/` and drop multi-GB images on the boot volume — don't do
that.

## What lives under here

Tart creates these subdirectories on first use:

- `vms/` — working VM instances (one directory per named VM)
- `cache/OCIs/` — pulled base images from the cirruslabs registry

Both are huge (each macOS image is tens of GB) and entirely
reproducible from the OCI registry, so none of this content is
tracked by git.
