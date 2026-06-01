#!/bin/sh
# Wiren Board Docker integration: install-time setup, injected into docker-ce's
# DEBIAN/postinst by repack/repack-docker-ce.sh. Runs ONCE on `apt install
# docker-ce` before debhelper's auto-generated `deb-systemd-invoke start
# docker.service` block, so the daemon starts already pointing at /mnt/data.
#
# This snippet is not a standalone executable: the repack script reads its body
# (minus the shebang) and inlines it after `set -e` inside docker-ce's postinst,
# wrapped in BEGIN/END markers.
#
# No postrm/prerm counterpart, by design. Everything this snippet creates is
# meant to outlive package removal: Docker data, configs and daemon.json all
# live under /mnt/data and must survive `apt purge docker-ce`, reinstall and
# firmware upgrade. The /etc/docker and /var/lib/containerd symlinks left
# behind point into /mnt/data and are harmless once the package is gone — a
# reinstall re-validates and re-creates them. Wiping that state is an explicit,
# user-driven action (see the "Удалить" section in README), not something a
# package maintainer script should do automatically.

# Only run our setup on `configure`. dpkg invokes postinst with arguments like
# `configure <prev-version>` on install/upgrade, and `abort-upgrade`,
# `abort-remove`, etc. on rollback paths. We do not want to seed Docker layout
# during a rollback.
if [ "$1" = "configure" ]; then

    PERSISTENT_ROOT=/mnt/data
    PERSISTENT_ETC_DOCKER="${PERSISTENT_ROOT}/etc/docker"
    PERSISTENT_CONTAINERD="${PERSISTENT_ROOT}/var/lib/containerd"
    PERSISTENT_DOCKER_DATA="${PERSISTENT_ROOT}/docker/lib"

    ROOTFS_ETC_DOCKER=/etc/docker
    ROOTFS_CONTAINERD=/var/lib/containerd

    DAEMON_JSON_TEMPLATE=/usr/share/wb-docker/daemon.json
    DAEMON_JSON_TARGET="${PERSISTENT_ETC_DOCKER}/daemon.json"

    log() {
        # dpkg shows postinst stderr in apt output — keep it human-readable.
        printf 'wb-docker: %s\n' "$*" >&2
    }

    # /mnt/data is the persistent partition on every WB controller. If it is
    # missing here we are running on a misconfigured host — fail loudly rather
    # than silently scribbling Docker data onto the rootfs.
    if [ ! -d "$PERSISTENT_ROOT" ]; then
        log "FATAL: ${PERSISTENT_ROOT} does not exist — refusing to seed Docker layout"
        exit 1
    fi

    mkdir -p "$PERSISTENT_ETC_DOCKER" "$PERSISTENT_CONTAINERD" "$PERSISTENT_DOCKER_DATA"

    # Migrate data laid down by the legacy community installer
    # (https://github.com/wirenboard/wb-community/blob/main/scripts/docker-install/wb-docker-manager.sh):
    # it kept Docker data-root at /mnt/data/.docker. If that directory still
    # exists and our target is empty, move it across. Also patch any pre-existing
    # daemon.json that still points data-root at the legacy location.
    COMMUNITY_LEGACY_DOCKER_DATA="${PERSISTENT_ROOT}/.docker"
    if [ -d "$COMMUNITY_LEGACY_DOCKER_DATA" ] && [ ! -L "$COMMUNITY_LEGACY_DOCKER_DATA" ]; then
        if [ -f "$DAEMON_JSON_TARGET" ] && \
           grep -q '"data-root".*"/mnt/data/\.docker"' "$DAEMON_JSON_TARGET"; then
            sed -i 's|"data-root"[[:space:]]*:[[:space:]]*"/mnt/data/\.docker"|"data-root": "/mnt/data/docker/lib"|' \
                "$DAEMON_JSON_TARGET"
            log "patched daemon.json data-root: ${COMMUNITY_LEGACY_DOCKER_DATA} -> ${PERSISTENT_DOCKER_DATA}"
        fi

        # shellcheck disable=SC2012
        if [ -z "$(ls -A "$PERSISTENT_DOCKER_DATA" 2>/dev/null || true)" ]; then
            log "migrating ${COMMUNITY_LEGACY_DOCKER_DATA} -> ${PERSISTENT_DOCKER_DATA}"
            for entry in "$COMMUNITY_LEGACY_DOCKER_DATA"/.* "$COMMUNITY_LEGACY_DOCKER_DATA"/*; do
                case "$entry" in
                    "$COMMUNITY_LEGACY_DOCKER_DATA"/.|"$COMMUNITY_LEGACY_DOCKER_DATA"/..) continue ;;
                    "$COMMUNITY_LEGACY_DOCKER_DATA"/.*\*|"$COMMUNITY_LEGACY_DOCKER_DATA"/\*) continue ;;
                esac
                base=$(basename "$entry")
                if [ -e "$PERSISTENT_DOCKER_DATA/$base" ]; then
                    log "  skip ${base}: already present in ${PERSISTENT_DOCKER_DATA}"
                    continue
                fi
                mv -- "$entry" "$PERSISTENT_DOCKER_DATA/"
            done
            rmdir "$COMMUNITY_LEGACY_DOCKER_DATA" 2>/dev/null || \
                log "  ${COMMUNITY_LEGACY_DOCKER_DATA} not empty after migration — left in place"
        else
            log "${PERSISTENT_DOCKER_DATA} already has content — leaving ${COMMUNITY_LEGACY_DOCKER_DATA} untouched"
        fi
    fi

    # Replace rootfs /etc/docker and /var/lib/containerd with symlinks into
    # /mnt/data. docker-ce.deb unpacks /etc/docker (and sometimes
    # /var/lib/containerd is created by containerd.io.deb) — migrate any content
    # to the persistent location, skipping conflicts, then symlink.
    migrate_rootfs_to_persistent() {
        rootfs_path="$1"
        persistent_path="$2"

        if [ -L "$rootfs_path" ]; then
            current_target=$(readlink "$rootfs_path")
            if [ "$current_target" = "$persistent_path" ]; then
                return 0
            fi
            log "replacing stale symlink ${rootfs_path} (was -> ${current_target})"
            rm -f "$rootfs_path"
        elif [ -d "$rootfs_path" ]; then
            log "migrating contents of ${rootfs_path} into ${persistent_path}"
            mkdir -p "$persistent_path"
            for entry in "$rootfs_path"/.* "$rootfs_path"/*; do
                case "$entry" in
                    "$rootfs_path"/.|"$rootfs_path"/..) continue ;;
                    "$rootfs_path"/.*\*|"$rootfs_path"/\*) continue ;;
                esac
                base=$(basename "$entry")
                if [ -e "$persistent_path/$base" ]; then
                    log "  skip ${base}: already present in ${persistent_path}"
                    continue
                fi
                mv -- "$entry" "$persistent_path/"
            done
            rmdir "$rootfs_path" 2>/dev/null || {
                log "WARN: ${rootfs_path} not empty after migration — leaving in place; symlink not created"
                return 1
            }
        elif [ -e "$rootfs_path" ]; then
            log "WARN: ${rootfs_path} exists and is neither symlink nor directory — leaving alone"
            return 1
        fi

        ln -s "$persistent_path" "$rootfs_path"
        log "linked ${rootfs_path} -> ${persistent_path}"
    }

    migrate_rootfs_to_persistent "$ROOTFS_ETC_DOCKER" "$PERSISTENT_ETC_DOCKER" || true
    migrate_rootfs_to_persistent "$ROOTFS_CONTAINERD" "$PERSISTENT_CONTAINERD" || true

    # Seed daemon.json from the WB template only if the user does not already
    # have one. Never overwrite.
    if [ ! -e "$DAEMON_JSON_TARGET" ]; then
        if [ -f "$DAEMON_JSON_TEMPLATE" ]; then
            install -m 0644 "$DAEMON_JSON_TEMPLATE" "$DAEMON_JSON_TARGET"
            log "seeded ${DAEMON_JSON_TARGET} from template"
        else
            log "WARN: daemon.json template missing at ${DAEMON_JSON_TEMPLATE} — skipping seed"
        fi
    fi

    # Wiki rule: every Wiren Board release wb-2304 and newer (plus the rolling
    # unstable.latest channel) needs the iptables-legacy backend for Docker NAT
    # to work. See https://wiki.wirenboard.com/wiki/Docker. Releases that
    # already default to legacy or use a different chain backend are skipped.
    release_needs_legacy_iptables() {
        wb_release=/etc/wb-release
        [ -f "$wb_release" ] || return 1

        release_name=$(
            # shellcheck source=/dev/null
            . "$wb_release" >/dev/null 2>&1 || exit 1
            printf '%s' "${RELEASE_NAME-}"
        ) || return 1

        case "$release_name" in
            unstable.latest)
                return 0 ;;
            wb-[0-9][0-9][0-9][0-9])
                num=${release_name#wb-}
                [ "$num" -ge 2304 ] ;;
            *)
                return 1 ;;
        esac
    }

    if release_needs_legacy_iptables; then
        if command -v update-alternatives >/dev/null 2>&1; then
            for name in iptables ip6tables; do
                legacy_bin="/usr/sbin/${name}-legacy"
                nft_bin="/usr/sbin/${name}-nft"
                link_path="/usr/sbin/${name}"

                if [ ! -x "$legacy_bin" ]; then
                    log "iptables: ${legacy_bin} missing — skipping ${name}"
                    continue
                fi

                # On some WB releases (wb-2602/wb7 confirmed) the iptables package
                # leaves the alternatives group unregistered. `update-alternatives
                # --set` then fails with no useful message. Register both
                # candidates explicitly before --set so the operation is
                # deterministic regardless of upstream packaging quirks.
                if ! update-alternatives --query "$name" >/dev/null 2>&1; then
                    if [ -x "$nft_bin" ]; then
                        update-alternatives --install "$link_path" "$name" "$nft_bin" 10 2>/dev/null || true
                    fi
                    update-alternatives --install "$link_path" "$name" "$legacy_bin" 20 2>/dev/null || \
                        log "iptables: WARN failed to register ${name} alternative"
                fi

                if update-alternatives --set "$name" "$legacy_bin" 2>/dev/null; then
                    log "iptables: pinned ${name} -> ${legacy_bin}"
                else
                    log "iptables: WARN --set ${name} -> ${legacy_bin} failed"
                fi
            done
        else
            log "iptables: update-alternatives not available — skipping legacy pin"
        fi
    fi

fi
