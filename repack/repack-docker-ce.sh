#!/usr/bin/env bash
#
# Build the WB Docker package set:
#   - docker-ce is repacked with a Wiren Board downstream Version suffix
#     (`+wb1xx`); future iterations of this script will also inject the WB
#     overlay and postinst snippet into this package.
#   - docker-ce-cli, containerd.io, docker-compose-plugin are mirrored as-is
#     from download.docker.com into our artifacts/ directory. They keep their
#     upstream filenames, upstream Version, and byte-identical contents — they
#     ship next to docker-ce in the WB apt repo only so that apt can resolve
#     docker-ce's strict `Depends:` from a single source.
#
# Why not bump Version on all four: it would buy nothing (we don't modify
# their contents) while making WB responsible for re-running the repack on
# every upstream bump of those three packages.
#
# Goal: let WB control the Docker version delivered to controllers
# independently of Debian's stale `docker.io` snapshot, and independently of
# Docker Inc.'s upstream release cadence. The WB suffix on docker-ce sorts
# above both Debian's docker.io and Docker Inc.'s upstream, so apt prefers
# our docker-ce; the dependency chain then pins the matching upstream
# versions of cli/containerd/compose.
#
# Requires: wget, dpkg-deb (on macOS: `brew install wget dpkg`).
# Run from repo root: bash repack/repack-docker-ce.sh

set -euo pipefail

# --- Inputs (override via env) ----------------------------------------------
DOCKER_CE_VERSION="${DOCKER_CE_VERSION:-29.5.2}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.2.4}"
COMPOSE_VERSION="${COMPOSE_VERSION:-5.1.4}"
SUITE="${SUITE:-bullseye}"        # bullseye | trixie  (bookworm intentionally skipped — WB jumps bullseye → trixie)

# DEBIAN_NUM is derived from SUITE — no override on purpose. A mismatch
# (e.g. SUITE=trixie + DEBIAN_NUM=11) would produce a non-existent upstream
# filename and surface only as a 404 several MB later.
case "${SUITE}" in
    bullseye) DEBIAN_NUM=11 ;;
    trixie)   DEBIAN_NUM=13 ;;
    *) echo "[fail] Unknown SUITE: ${SUITE}" >&2; exit 1 ;;
esac
ARCH="${ARCH:-armhf}"             # armhf | arm64
WB_SUFFIX="${WB_SUFFIX:-+wb100}"  # WB downstream marker for docker-ce only.
                                  # Leading "+" keeps the suffix inside
                                  # debian-revision
                                  # (1~debian.11~bullseye+wb100), leaving the
                                  # upstream-version field untouched — the
                                  # canonical downstream convention. The
                                  # "1xx" numbering is a counter for WB-side
                                  # iterations on top of the same upstream
                                  # docker-ce: +wb100 first ship, +wb101
                                  # next overlay change, etc. Reset to
                                  # +wb100 when the upstream version is
                                  # bumped. Reserved ranges +wb2xx and
                                  # +wb9xx left for future experimental and
                                  # hotfix streams.

# --- Layout ------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${HERE}/src"
OUT_DIR="${HERE}/out"
ART_DIR="${HERE}/artifacts"

DOCKER_CE_UPSTREAM="${DOCKER_CE_VERSION}-1~debian.${DEBIAN_NUM}~${SUITE}"
CONTAINERD_UPSTREAM="${CONTAINERD_VERSION}-1~debian.${DEBIAN_NUM}~${SUITE}"
COMPOSE_UPSTREAM="${COMPOSE_VERSION}-1~debian.${DEBIAN_NUM}~${SUITE}"
BASE_URL="https://download.docker.com/linux/debian/dists/${SUITE}/pool/stable/${ARCH}"

# --- Helpers ----------------------------------------------------------------

# Fetch one upstream .deb. `-nv` keeps the line count low but still prints
# the URL and any HTTP error to stderr — so a wrong DOCKER_CE_VERSION shows
# up as a clear "404 Not Found" instead of an opaque empty file. wget exits
# non-zero on errors and `set -e` propagates that.
fetch_one() {
    local name="$1" upstream="$2"
    local fname="${name}_${upstream}_${ARCH}.deb"
    local url="${BASE_URL}/${fname}"

    if [[ -f "${SRC_DIR}/${fname}" ]]; then
        echo "[cached  ] ${fname}"
        return 0
    fi

    echo "[download] ${url}"
    if ! wget -nv -O "${SRC_DIR}/${fname}" "${url}"; then
        rm -f "${SRC_DIR}/${fname}"
        echo "[fail    ] could not download ${url}" >&2
        exit 1
    fi
}

# Patch DEBIAN/control: Version: <upstream> -> Version: <upstream><WB_SUFFIX>.
# docker-ce ships with epoch `5:` in its Version field; the fallback branch
# without the epoch is a forward-compat guard — if upstream ever drops the
# epoch the final `grep -q` assertion below will catch a silent change of
# format either way.
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

    echo "[version ] ${new_line#Version: }"
    sed -i.bak "s|^${old_line}$|${new_line}|" "${control}"
    rm -f "${control}.bak"
    grep -q "^${new_line}$" "${control}"
}

# docker-ce: unpack, patch Version, repack with the WB suffix.
repack_docker_ce() {
    local upstream="$1"
    local src="${SRC_DIR}/docker-ce_${upstream}_${ARCH}.deb"
    local stage="${OUT_DIR}/docker-ce"

    echo "[repack  ] docker-ce"
    rm -rf "${stage}"
    dpkg-deb -R "${src}" "${stage}"

    patch_version "${stage}/DEBIAN/control" "${upstream}" \
        || { echo "[fail    ] Version patch failed for docker-ce" >&2; exit 1; }

    # --root-owner-group: build env runs as the user; without this flag the
    # tarball would carry uid=501 and dpkg --install would refuse it.
    # Output is a directory: dpkg-deb auto-derives the canonical filename
    # `${Package}_${Version}_${Architecture}.deb` from DEBIAN/control, so the
    # WB suffix is preserved in the artifact name.
    dpkg-deb --root-owner-group -b "${stage}" "${ART_DIR}/" >/dev/null

    echo "[ok      ] docker-ce${WB_SUFFIX}"
}

# Mirror an upstream .deb as-is: same filename, same Version, identical bytes.
# Lives in our apt repo only to satisfy docker-ce's strict Depends from a
# single source.
mirror_one() {
    local name="$1" upstream="$2"
    local fname="${name}_${upstream}_${ARCH}.deb"

    cp -f "${SRC_DIR}/${fname}" "${ART_DIR}/${fname}"
    echo "[mirror  ] ${fname}"
}

# --- Entry point ------------------------------------------------------------

main() {
    mkdir -p "${SRC_DIR}" "${OUT_DIR}" "${ART_DIR}"

    fetch_one docker-ce              "${DOCKER_CE_UPSTREAM}"
    # docker-ce-cli is released by Docker Inc. in lockstep with docker-ce
    # itself and shares the same upstream version string — that's why
    # DOCKER_CE_UPSTREAM is reused for it.
    fetch_one docker-ce-cli          "${DOCKER_CE_UPSTREAM}"
    fetch_one containerd.io          "${CONTAINERD_UPSTREAM}"
    fetch_one docker-compose-plugin  "${COMPOSE_UPSTREAM}"

    repack_docker_ce "${DOCKER_CE_UPSTREAM}"
    mirror_one docker-ce-cli         "${DOCKER_CE_UPSTREAM}"
    mirror_one containerd.io         "${CONTAINERD_UPSTREAM}"
    mirror_one docker-compose-plugin "${COMPOSE_UPSTREAM}"

    echo
    echo "Artefacts:"
    ls -lh "${ART_DIR}"
}

main "$@"
