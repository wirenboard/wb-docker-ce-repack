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
#
# Structure: config below, then one function per install step, then a short
# entry point at the bottom that runs the steps in order on `configure`.

PERSISTENT_ROOT=/mnt/data
PERSISTENT_ETC_DOCKER="${PERSISTENT_ROOT}/etc/docker"
PERSISTENT_CONTAINERD="${PERSISTENT_ROOT}/var/lib/containerd"
PERSISTENT_DOCKER_DATA="${PERSISTENT_ROOT}/docker/lib"
# Data-root used by the legacy community installer (wb-docker-manager.sh).
COMMUNITY_LEGACY_DOCKER_DATA="${PERSISTENT_ROOT}/.docker"

ROOTFS_ETC_DOCKER=/etc/docker
ROOTFS_CONTAINERD=/var/lib/containerd
ROOTFS_DOCKER_DATA=/var/lib/docker

DAEMON_JSON_TEMPLATE=/usr/share/wb-docker/daemon.json
DAEMON_JSON_TARGET="${PERSISTENT_ETC_DOCKER}/daemon.json"

log() {
    # dpkg shows postinst stderr in apt output — keep it human-readable.
    printf 'wb-docker: %s\n' "$*" >&2
}

# /mnt/data is the persistent partition on every WB controller. If it is
# missing here we are running on a misconfigured host — fail loudly rather
# than silently scribbling Docker data onto the rootfs.
require_persistent_root() {
    if [ ! -d "$PERSISTENT_ROOT" ]; then
        log "FATAL: ${PERSISTENT_ROOT} does not exist — refusing to seed Docker layout"
        exit 1
    fi
}

# Replace a rootfs path with a symlink into /mnt/data. docker-ce.deb unpacks
# /etc/docker (and sometimes /var/lib/containerd is created by
# containerd.io.deb) — migrate any content to the persistent location,
# skipping conflicts, then symlink.
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

# Migrate /var/lib/containerd onto /mnt/data, then restart containerd if it was
# actually migrated. containerd.io started containerd before this postinst, so
# it has meta.db open on the old rootfs /var/lib/containerd. The migration
# symlinked that onto /mnt/data; restart containerd so it reopens meta.db there
# instead of writing to the now-deleted rootfs inode, which is dropped on reboot
# (losing all image/container metadata). The pre-migration detection has to
# happen before migrate_rootfs_to_persistent turns the path into a symlink.
setup_containerd_symlink() {
    containerd_was_migrated=no
    if [ -L "$ROOTFS_CONTAINERD" ]; then
        [ "$(readlink "$ROOTFS_CONTAINERD")" = "$PERSISTENT_CONTAINERD" ] || containerd_was_migrated=yes
    elif [ -e "$ROOTFS_CONTAINERD" ]; then
        containerd_was_migrated=yes
    fi

    migrate_rootfs_to_persistent "$ROOTFS_CONTAINERD" "$PERSISTENT_CONTAINERD" || true

    if [ "$containerd_was_migrated" = yes ] && \
       [ -L "$ROOTFS_CONTAINERD" ] && \
       [ "$(readlink "$ROOTFS_CONTAINERD")" = "$PERSISTENT_CONTAINERD" ] && \
       [ -d /run/systemd/system ]; then
        systemctl daemon-reload 2>/dev/null || true
        if systemctl is-active --quiet containerd.service 2>/dev/null; then
            log "restarting containerd to reopen meta.db on ${PERSISTENT_CONTAINERD}"
            systemctl restart containerd.service || \
                log "WARN: containerd restart failed — restart it before rebooting"
        fi
    fi
}

# Migrate data laid down by the legacy community installer
# (https://github.com/wirenboard/wb-community/blob/main/scripts/docker-install/wb-docker-manager.sh):
# it kept Docker data-root at /mnt/data/.docker. If that directory still
# exists and our target is empty, move it across. Also patch any daemon.json
# that still points data-root at the legacy location.
#
# Runs AFTER the rootfs symlink migration, on purpose: a community daemon.json
# starts life at /etc/docker/daemon.json and only lands at $DAEMON_JSON_TARGET
# (/mnt/data/etc/docker/daemon.json) once /etc/docker has been migrated into
# /mnt/data. Patching it before that migration was a silent no-op — the target
# did not exist yet — which left dockerd reading a /mnt/data/.docker we had just
# emptied. Keep the data move next to the daemon.json patch so the on-disk path
# and the configured path always agree.
migrate_community_legacy_data() {
    [ -d "$COMMUNITY_LEGACY_DOCKER_DATA" ] && [ ! -L "$COMMUNITY_LEGACY_DOCKER_DATA" ] || return 0

    if [ -f "$DAEMON_JSON_TARGET" ] && \
       grep -q '"data-root".*"/mnt/data/\.docker"' "$DAEMON_JSON_TARGET"; then
        sed -i "s|\"data-root\"[[:space:]]*:[[:space:]]*\"/mnt/data/\.docker\"|\"data-root\": \"${PERSISTENT_DOCKER_DATA}\"|" \
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
}

# Seed daemon.json from the WB template only if the user does not already
# have one. Never overwrite.
seed_daemon_json() {
    [ ! -e "$DAEMON_JSON_TARGET" ] || return 0
    if [ -f "$DAEMON_JSON_TEMPLATE" ]; then
        install -m 0644 "$DAEMON_JSON_TEMPLATE" "$DAEMON_JSON_TARGET"
        log "seeded ${DAEMON_JSON_TARGET} from template"
    else
        log "WARN: daemon.json template missing at ${DAEMON_JSON_TEMPLATE} — skipping seed"
    fi
}

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

# Pin iptables/ip6tables to the legacy backend via update-alternatives on the
# releases that need it.
switch_iptables_to_legacy() {
    release_needs_legacy_iptables || return 0

    if ! command -v update-alternatives >/dev/null 2>&1; then
        log "iptables: update-alternatives not available — skipping legacy pin"
        return 0
    fi

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
        # --set` then fails with no useful message. Register both candidates
        # explicitly before --set so the operation is deterministic regardless
        # of upstream packaging quirks.
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
}

# Warn about data left behind by a previous Docker (docker.io or an older
# docker-ce) in the rootfs /var/lib/docker. WB Docker keeps data-root on
# /mnt/data and, on 29.x, defaults to the containerd image store — neither
# reads the old overlay2 graph store, so those images/containers are invisible
# to the new daemon. We deliberately do NOT touch that data: migrating a graph
# store across Docker versions/backends isn't reliably automatable (upstream
# itself only offers `docker save`/registry push from the old daemon, which is
# already gone by the time this runs). Just tell the user it is there.
warn_old_docker_not_migrated() {
    [ -d "$ROOTFS_DOCKER_DATA" ] && [ ! -L "$ROOTFS_DOCKER_DATA" ] && \
    { [ -d "$ROOTFS_DOCKER_DATA/image" ] || \
      [ -d "$ROOTFS_DOCKER_DATA/overlay2" ] || \
      [ -d "$ROOTFS_DOCKER_DATA/containers" ]; } || return 0

    # Suppress the warning if the active daemon.json pins data-root back at
    # /var/lib/docker — then that data is actually in use, nothing is hidden.
    if [ -f "$DAEMON_JSON_TARGET" ] && \
       grep -q "\"data-root\"[[:space:]]*:[[:space:]]*\"${ROOTFS_DOCKER_DATA}\"" "$DAEMON_JSON_TARGET"; then
        return 0
    fi

    log "WARNING: found data from a previous Docker in ${ROOTFS_DOCKER_DATA}"
    log "  (docker.io or an older docker-ce). WB Docker stores data on /mnt/data and"
    log "  on 29.x uses the containerd image store, so those images and containers"
    log "  are NOT visible in 'docker images' / 'docker ps -a'."
    log "  The data is NOT deleted — it stays in ${ROOTFS_DOCKER_DATA}. Migrating it"
    log "  across Docker versions cannot be automated; see"
    log "  https://wiki.wirenboard.com/wiki/Docker"
}

# Only run our setup on `configure`. dpkg invokes postinst with arguments like
# `configure <prev-version>` on install/upgrade, and `abort-upgrade`,
# `abort-remove`, etc. on rollback paths. We do not want to seed Docker layout
# during a rollback.
if [ "$1" = "configure" ]; then
    require_persistent_root
    mkdir -p "$PERSISTENT_ETC_DOCKER" "$PERSISTENT_CONTAINERD" "$PERSISTENT_DOCKER_DATA"

    migrate_rootfs_to_persistent "$ROOTFS_ETC_DOCKER" "$PERSISTENT_ETC_DOCKER" || true
    setup_containerd_symlink
    migrate_community_legacy_data
    seed_daemon_json
    switch_iptables_to_legacy
    warn_old_docker_not_migrated
fi
