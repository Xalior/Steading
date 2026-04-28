# Tart VM home (placeholder)

This directory exists only as a fallback location for `TART_HOME`
when no `.env` is present at the repo root. In normal use, the
project's `.env` (gitignored) points `TART_HOME` at wherever the
developer keeps their VM blobs — typically a large external volume
shared across multiple repos so the OCI base-image cache isn't
duplicated.

## Setup

Create `<repo>/.env` at the repo root with:

```sh
TART_HOME=/path/to/your/tart-home
```

`scripts/vm-*.sh` source this automatically. A plain `tart …`
invocation from a shell where `.env` hasn't been sourced will need
`TART_HOME=…` prefixed explicitly, otherwise tart silently falls
back to `~/.tart/` and drops multi-GB images on the boot volume.

## Layout under `TART_HOME`

Tart creates these subdirectories on first use:

- `vms/` — working VM instances (one directory per named VM)
- `cache/OCIs/` — pulled base images from the cirruslabs registry

Both are huge (each macOS image is tens of GB) and entirely
reproducible from the OCI registry.
