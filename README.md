# wb-docker

`wb-docker` is a Debian integration package for Docker on Wiren Board
controllers.

This initial repository revision contains only the package skeleton: Debian
metadata, maintainer-script entrypoints, a no-op reconcile helper, and default
configuration templates. The actual Docker integration logic is intentionally
kept out of this branch so the packaging shape can be reviewed separately.

## Repository Layout

- `debian/` Debian package metadata and maintainer scripts.
- `libexec/` Package helper entrypoints installed under `/usr/lib/wb-docker/`.
- `share/` Static templates installed under `/usr/share/wb-docker/`.
- `configs/` `wb-configs` manifests installed under `/etc/wb-configs.d/`.

## Local Build

```bash
make build
```
