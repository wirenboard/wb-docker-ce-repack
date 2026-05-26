#!/usr/bin/env bash
#
# Repack upstream Docker .deb packages with a Wiren Board downstream version
# suffix.
#
# Scope:
#   1. Download official docker-ce, docker-ce-cli, containerd.io,
#      docker-compose-plugin from download.docker.com.
#   2. Bump Version in DEBIAN/control to append the WB suffix (every package).
#   3. Repack with dpkg-deb --root-owner-group.
#
# Goal: let WB control the Docker version delivered to controllers
# independently of Debian's stale `docker.io` snapshot, and independently of
# Docker Inc.'s upstream release cadence. The packages keep canonical
# upstream names and contents — only the Version field gains the WB
# `+wb1xx` marker so apt prefers our build over both Debian and upstream.
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

# --- 3. Repack ---------------------------------------------------------------

repack_one() {
    local name="$1" upstream="$2"
    local src="${SRC_DIR}/${name}_${upstream}_${ARCH}.deb"
    local stage="${OUT_DIR}/${name}"

    rm -rf "${stage}"
    dpkg-deb -R "${src}" "${stage}"

    patch_version "${stage}/DEBIAN/control" "${upstream}" \
        || { echo "[fail] Version patch failed for ${name}"; exit 1; }

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
