#!/usr/bin/env bash
#
# Repack Docker upstream .deb packages with a Wiren Board version suffix and
# Wiren Board integration overlay.
#
# Iteration 2 scope:
#   1. Download official docker-ce, docker-ce-cli, containerd.io,
#      docker-compose-plugin from download.docker.com.
#   2. Bump Version in DEBIAN/control to add the WB suffix (every package).
#   3. For docker-ce only:
#        a. inject the WB overlay tree from repack/overlay/ into the .deb's
#           data archive (currently: a daemon.json template), regenerate
#           DEBIAN/md5sums for new files;
#        b. inject the WB setup snippet (repack/postinst-snippet.sh) into the
#           existing docker-ce DEBIAN/postinst, so `apt install docker-ce`
#           seeds /mnt/data layout, symlinks, daemon.json and iptables-legacy
#           BEFORE debhelper's auto-generated start of docker.service;
#        c. append `docker-compose-plugin` to Depends — so a single
#           `apt install docker-ce` against our local apt-repo brings in the
#           compose plugin alongside the daemon.
#   4. Repack everything with dpkg-deb --root-owner-group.
#
# The overlay (see repack/overlay/) ships:
#   /usr/share/wb-docker/daemon.json   — daemon.json template, seeded into
#                                        /mnt/data/etc/docker/ on install.
#
# Requires: wget, dpkg-deb, md5sum, tar (all present on macOS via Homebrew or
# coreutils, and stock on Debian).
# Run from repo root: bash repack/repack-docker-ce.sh

set -euo pipefail

# --- Inputs (override via env) ----------------------------------------------
DOCKER_CE_VERSION="${DOCKER_CE_VERSION:-29.5.2}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.2.4}"
COMPOSE_VERSION="${COMPOSE_VERSION:-5.1.4}"
SUITE="${SUITE:-bullseye}"        # bullseye | trixie  (bookworm intentionally skipped — WB jumps bullseye → trixie)

# Derive Debian major version from SUITE unless explicitly overridden.
if [[ -z "${DEBIAN_NUM:-}" ]]; then
    case "${SUITE}" in
        bullseye) DEBIAN_NUM=11 ;;
        trixie)   DEBIAN_NUM=13 ;;
        *) echo "[fail] Unknown SUITE: ${SUITE}"; exit 1 ;;
    esac
fi
ARCH="${ARCH:-armhf}"             # armhf | arm64
WB_SUFFIX="${WB_SUFFIX:-+wb100}"  # WB downstream marker. Leading "+" keeps
                                  # the suffix inside debian-revision
                                  # (1~debian.11~bullseye+wb100), leaving the
                                  # upstream-version field untouched — the
                                  # canonical downstream convention. The
                                  # "1xx" numbering is a counter for WB-side
                                  # iterations on top of the same upstream
                                  # Docker version: +wb100 first ship,
                                  # +wb101 next overlay change, etc. Reset
                                  # to +wb100 when the upstream version is
                                  # bumped. Reserved ranges +wb2xx and
                                  # +wb9xx left for future experimental and
                                  # hotfix streams.

# --- Layout ------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${HERE}/src"
OUT_DIR="${HERE}/out"
ART_DIR="${HERE}/artifacts"
OVERLAY_DIR="${HERE}/overlay"
POSTINST_SNIPPET="${HERE}/postinst-snippet.sh"
mkdir -p "${SRC_DIR}" "${OUT_DIR}" "${ART_DIR}"

DOCKER_CE_UPSTREAM="${DOCKER_CE_VERSION}-1~debian.${DEBIAN_NUM}~${SUITE}"
CONTAINERD_UPSTREAM="${CONTAINERD_VERSION}-1~debian.${DEBIAN_NUM}~${SUITE}"
COMPOSE_UPSTREAM="${COMPOSE_VERSION}-1~debian.${DEBIAN_NUM}~${SUITE}"
BASE_URL="https://download.docker.com/linux/debian/dists/${SUITE}/pool/stable/${ARCH}"

# --- 1. Download upstream .deb files ----------------------------------------
fetch_one() {
    local name="$1" upstream="$2"
    local fname="${name}_${upstream}_${ARCH}.deb"
    if [[ ! -f "${SRC_DIR}/${fname}" ]]; then
        echo "[fetch] ${fname}"
        wget -q -O "${SRC_DIR}/${fname}" "${BASE_URL}/${fname}"
    else
        echo "[skip ] ${fname} (cached)"
    fi
}

fetch_one docker-ce              "${DOCKER_CE_UPSTREAM}"
fetch_one docker-ce-cli          "${DOCKER_CE_UPSTREAM}"
fetch_one containerd.io          "${CONTAINERD_UPSTREAM}"
fetch_one docker-compose-plugin  "${COMPOSE_UPSTREAM}"

# --- 2. Helpers --------------------------------------------------------------

# Patch DEBIAN/control: Version: <upstream> -> Version: <upstream><WB_SUFFIX>.
# Handles the epoched form (5:...) used by docker-ce / docker-ce-cli.
patch_version() {
    local control="$1" upstream="$2"
    local old_line new_line

    if grep -q "^Version: 5:${upstream}$" "${control}"; then
        old_line="Version: 5:${upstream}"
        new_line="Version: 5:${upstream}${WB_SUFFIX}"
    else
        old_line="Version: ${upstream}"
        new_line="Version: ${upstream}${WB_SUFFIX}"
    fi

    sed -i.bak "s|^${old_line}$|${new_line}|" "${control}"
    rm -f "${control}.bak"
    grep -q "^${new_line}$" "${control}"
}

# Inject the WB overlay tree into the unpacked docker-ce stage:
#   - tar | tar to preserve file modes
#   - append md5sums for newly added files
#   - re-sort DEBIAN/md5sums (dpkg does not require sort, but it keeps the
#     file diffable against upstream).
inject_overlay() {
    local stage="$1" overlay="$2"

    (cd "${overlay}" && tar cf - .) | (cd "${stage}" && tar xpf -)

    local md5sums="${stage}/DEBIAN/md5sums"
    (
        cd "${overlay}"
        find . -type f -print \
            | sed 's|^\./||' \
            | sort \
            | while read -r path; do
                  ( cd "${stage}" && md5sum "${path}" )
              done
    ) >> "${md5sums}"

    sort -k2 -o "${md5sums}" "${md5sums}"
}

# Inject the WB setup snippet into the docker-ce DEBIAN/postinst. The snippet
# (repack/postinst-snippet.sh) sets up /mnt/data layout, symlinks, daemon.json
# and iptables-legacy on install. We must run it BEFORE debhelper's
# auto-generated `deb-systemd-invoke start docker.service` block at the tail of
# postinst, so the daemon starts already pointing at /mnt/data.
#
# Strategy: read the upstream postinst, find the first `set -e` line, and
# inline the snippet body (everything after its own shebang) right after it,
# wrapped in clear BEGIN/END markers. The snippet itself is guarded by
# `if [ "$1" = "configure" ]; then ... fi`, so it is a no-op on rollback paths.
# Asserts a `set -e` line exists — if a future upstream postinst drops it, the
# function fails loudly instead of silently appending nowhere.
inject_postinst() {
    local stage="$1" snippet="$2"
    local postinst="${stage}/DEBIAN/postinst"

    if [[ ! -f "${snippet}" ]]; then
        echo "[fail] postinst snippet missing at ${snippet}"
        return 1
    fi

    # Strip the snippet's own shebang line into a temp file — the upstream
    # postinst already has one. Keep everything else verbatim.
    local snippet_body
    snippet_body=$(mktemp)
    sed -e '1{/^#!/d;}' "${snippet}" > "${snippet_body}"

    if [[ ! -f "${postinst}" ]]; then
        # Upstream docker-ce ships a postinst, but be defensive in case a
        # future version stops doing so — synthesize a minimal one.
        {
            echo '#!/bin/sh'
            echo 'set -e'
            echo
            echo '# --- BEGIN wb-docker setup ---'
            cat "${snippet_body}"
            echo '# --- END wb-docker setup ---'
            echo
            echo 'exit 0'
        } > "${postinst}"
        chmod 0755 "${postinst}"
        rm -f "${snippet_body}"
        return 0
    fi

    if ! grep -q '^set -e' "${postinst}"; then
        echo "[fail] no 'set -e' line in ${postinst}; refusing to inject blindly"
        rm -f "${snippet_body}"
        return 1
    fi

    # Inject the snippet right after the FIRST line matching `^set -e`. We
    # build the new file by streaming lines through a small awk that, on hit,
    # prints the line, then cats the snippet via getline. The snippet path is
    # passed in an awk variable so multi-line snippet content stays in a file.
    local tmp
    tmp=$(mktemp)
    awk -v body_file="${snippet_body}" '
        BEGIN { injected = 0 }
        {
            print
            if (!injected && $0 ~ /^set -e[[:space:]]*$/) {
                print ""
                print "# --- BEGIN wb-docker setup ---"
                while ((getline line < body_file) > 0) print line
                close(body_file)
                print "# --- END wb-docker setup ---"
                injected = 1
            }
        }
        END {
            if (!injected) exit 1
        }
    ' "${postinst}" > "${tmp}" || {
        echo "[fail] failed to locate '^set -e' insertion point in ${postinst}"
        rm -f "${tmp}" "${snippet_body}"
        return 1
    }
    mv "${tmp}" "${postinst}"
    chmod 0755 "${postinst}"
    rm -f "${snippet_body}"
}

# Append a new dependency to the Depends: line in DEBIAN/control. Asserts the
# field is single-line (upstream docker-ce keeps it that way; if a future
# upstream rewraps it onto multiple lines, this assertion catches the change
# instead of silently corrupting the file).
append_depends() {
    local control="$1" new_dep="$2"
    local depends_lines
    depends_lines=$(grep -c '^Depends:' "${control}" || true)
    if [[ "${depends_lines}" -ne 1 ]]; then
        echo "[fail] expected exactly one 'Depends:' line in ${control}, found ${depends_lines}"
        return 1
    fi
    sed -i.bak "s|^\(Depends:.*\)\$|\1, ${new_dep}|" "${control}"
    rm -f "${control}.bak"
    grep -q "^Depends:.*${new_dep}" "${control}"
}

# --- 3. Repack ---------------------------------------------------------------

repack_one() {
    local name="$1" upstream="$2"
    local src="${SRC_DIR}/${name}_${upstream}_${ARCH}.deb"
    local stage="${OUT_DIR}/${name}"

    rm -rf "${stage}"
    dpkg-deb -R "${src}" "${stage}"

    patch_version "${stage}/DEBIAN/control" "${upstream}" \
        || { echo "[fail] Version patch failed for ${name}"; exit 1; }

    # docker-ce is the only package that carries the WB overlay, the WB
    # postinst snippet and the extra Depends on docker-compose-plugin —
    # everything else is a clean version-suffix repack.
    if [[ "${name}" == "docker-ce" ]]; then
        inject_overlay "${stage}" "${OVERLAY_DIR}"
        inject_postinst "${stage}" "${POSTINST_SNIPPET}" \
            || { echo "[fail] postinst injection failed"; exit 1; }
        append_depends "${stage}/DEBIAN/control" \
            "docker-compose-plugin (>= ${COMPOSE_VERSION})" \
            || { echo "[fail] Depends patch failed"; exit 1; }
    fi

    # --root-owner-group: build env runs as the user; without this flag the
    # tarball would carry uid=501 and dpkg --install would refuse it.
    dpkg-deb --root-owner-group -b "${stage}" "${ART_DIR}/" >/dev/null

    echo "[ok  ] ${name}${WB_SUFFIX}"
}

repack_one docker-ce              "${DOCKER_CE_UPSTREAM}"
repack_one docker-ce-cli          "${DOCKER_CE_UPSTREAM}"
repack_one containerd.io          "${CONTAINERD_UPSTREAM}"
repack_one docker-compose-plugin  "${COMPOSE_UPSTREAM}"

echo
echo "Artefacts:"
ls -lh "${ART_DIR}"
