# wb-docker

`wb-docker` is a Debian integration package for Docker on Wiren Board
controllers.

The package does not ship Docker Engine. It depends on Debian Docker packages
and owns only the Wiren Board integration layer around them: package lifecycle
hooks, persistent layout, default daemon configuration, and recovery behavior.

## Repository Layout

- `debian/` Debian package metadata and maintainer scripts.
- `libexec/` Package helper entrypoints installed under `/usr/lib/wb-docker/`.
- `share/` Static templates installed under `/usr/share/wb-docker/`.
- `configs/` `wb-configs` manifests installed under `/etc/wb-configs.d/`.

## Reconcile Contract

Maintainer scripts delegate package work to
`/usr/lib/wb-docker/wb-docker-reconcile`. The helper exports a small environment
contract and then runs executable hooks from
`/usr/lib/wb-docker/reconcile.d/` in lexical order.

The current hooks:

- keep Docker config under `/mnt/data/etc/docker` and expose it through
  `/etc/docker`;
- keep Docker data under `/mnt/data/docker/lib`;
- keep containerd state under `/mnt/data/var/lib/containerd` and expose it
  through `/var/lib/containerd`;
- install the default daemon config only when no persistent config exists yet;
- switch `iptables` and `ip6tables` to the legacy backend on supported WB
  releases, then restore the previous alternatives on remove or purge;
- enable and start `containerd.service` and `docker.service` when the units are
  present.

`apt remove wb-docker` removes only the rootfs-facing integration owned by this
package. `apt purge wb-docker` is the destructive path and removes persistent
Docker config and data under `/mnt/data`.

## Local Checks

```bash
make check
```

`make check` runs lightweight syntax checks that work outside a Debian build
environment.

## Debian Build

Run the package build inside Debian with `debhelper-compat (= 13)` installed:

```bash
make build
```
