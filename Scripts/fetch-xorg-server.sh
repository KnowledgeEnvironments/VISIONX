#!/usr/bin/env bash
# VisionX Project <src@lispm.net>
# Copyright (C) 2026 I. Finder
# SPDX-License-Identifier: MIT

set -euo pipefail

VERSION="${1:-21.1.25}"
XTRANS_VERSION="${XTRANS_VERSION:-1.6.0}"
PIXMAN_VERSION="${PIXMAN_VERSION:-0.46.0}"
LIBXAU_VERSION="${LIBXAU_VERSION:-1.0.12}"
LIBFONTENC_VERSION="${LIBFONTENC_VERSION:-1.1.8}"
LIBXKBFILE_VERSION="${LIBXKBFILE_VERSION:-1.1.3}"
LIBXFONT2_VERSION="${LIBXFONT2_VERSION:-2.0.9}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THIRD_PARTY_DIR="${ROOT_DIR}/ThirdParty"
ARCHIVE="xorg-server-${VERSION}.tar.xz"
URL="https://www.x.org/releases/individual/xserver/${ARCHIVE}"
XTRANS_ARCHIVE="xtrans-${XTRANS_VERSION}.tar.xz"
XTRANS_URL="https://www.x.org/releases/individual/lib/${XTRANS_ARCHIVE}"

fetch_archive() {
    local directory="$1"
    local archive="$2"
    local url="$3"
    local sha256="$4"
    local marker="$5"

    if [[ -f "${directory}/${marker}" ]]; then
        echo "ThirdParty/${directory} is ready"
        return
    fi

    if [[ ! -f "${archive}" ]]; then
        curl --retry 3 --connect-timeout 10 --max-time 120 -fL "${url}" -o "${archive}.download"
        mv "${archive}.download" "${archive}"
    fi

    printf '%s  %s\n' "${sha256}" "${archive}" | shasum -a 256 -c -

    local staging_dir
    staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/visionx-fetch.XXXXXX")"
    tar -xf "${archive}" -C "${staging_dir}"
    mkdir -p "${directory}"
    rsync -a --ignore-existing "${staging_dir}/${directory}/" "${directory}/"
    rm -rf "${staging_dir}"
    echo "Fetched and verified ${url}"
}

mkdir -p "${THIRD_PARTY_DIR}"
cd "${THIRD_PARTY_DIR}"

fetch_archive "xorg-server-${VERSION}" "${ARCHIVE}" "${URL}" \
    "6ad4e3c7b59a309b32c92e5c15ce1267110f9e13f1ac78da62361a628da1a0eb" "dix/dispatch.c"
fetch_archive "xtrans-${XTRANS_VERSION}" "${XTRANS_ARCHIVE}" "${XTRANS_URL}" \
    "faafea166bf2451a173d9d593352940ec6404145c5d1da5c213423ce4d359e92" "Xtrans.c"
fetch_archive "pixman-${PIXMAN_VERSION}" "pixman-${PIXMAN_VERSION}.tar.xz" "https://www.cairographics.org/releases/pixman-${PIXMAN_VERSION}.tar.xz" \
    "d2eab57e1ce79de991f8ceb3fcd726a6978b970382c8ac8c8f112b61ceaa9167" "pixman/pixman.c"
fetch_archive "libXau-${LIBXAU_VERSION}" "libXau-${LIBXAU_VERSION}.tar.xz" "https://www.x.org/releases/individual/lib/libXau-${LIBXAU_VERSION}.tar.xz" \
    "74d0e4dfa3d39ad8939e99bda37f5967aba528211076828464d2777d477fc0fb" "AuRead.c"
fetch_archive "libfontenc-${LIBFONTENC_VERSION}" "libfontenc-${LIBFONTENC_VERSION}.tar.xz" "https://www.x.org/releases/individual/lib/libfontenc-${LIBFONTENC_VERSION}.tar.xz" \
    "7b02c3d405236e0d86806b1de9d6868fe60c313628b38350b032914aa4fd14c6" "src/fontenc.c"
fetch_archive "libxkbfile-${LIBXKBFILE_VERSION}" "libxkbfile-${LIBXKBFILE_VERSION}.tar.xz" "https://www.x.org/releases/individual/lib/libxkbfile-${LIBXKBFILE_VERSION}.tar.xz" \
    "a9b63eea997abb9ee6a8b4fbb515831c841f471af845a09de443b28003874bec" "src/xkbtext.c"
fetch_archive "libXfont2-${LIBXFONT2_VERSION}" "libXfont2-${LIBXFONT2_VERSION}.tar.xz" "https://www.x.org/releases/individual/lib/libXfont2-${LIBXFONT2_VERSION}.tar.xz" \
    "f042a370666815e7b941e9b7019024755bd1c6c2954afbfa515af378251799e2" "src/fontfile/fontfile.c"
