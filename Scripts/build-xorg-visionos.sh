#!/usr/bin/env bash
# VisionX Project <src@lispm.net>
# Copyright (C) 2026 I. Finder
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_NAME="${VISIONX_XORG_SDK:-xros}"
MESON="${ROOT_DIR}/Scripts/meson.sh"

find_runnable_ninja() {
    local candidate
    for candidate in "${VISIONX_NINJA:-}" /opt/local/bin/ninja /opt/homebrew/bin/ninja /usr/local/bin/ninja ninja ninja-build; do
        [[ -n "${candidate}" ]] || continue
        if command -v "${candidate}" >/dev/null 2>&1 && "${candidate}" --version >/dev/null 2>&1; then
            command -v "${candidate}"
            return 0
        fi
    done
    return 1
}

if ! NINJA_BIN="$(find_runnable_ninja)"; then
    echo "Missing runnable ninja. Install Ninja or set VISIONX_NINJA to a working binary." >&2
    exit 127
fi
export NINJA="${NINJA_BIN}"

"${ROOT_DIR}/Scripts/fetch-xorg-server.sh"
"${ROOT_DIR}/Scripts/build-xorg-deps-visionos.sh"
"${ROOT_DIR}/Scripts/configure-xorg-visionos.sh"

"${MESON}" compile -C "${ROOT_DIR}/.build/xorg-server-${SDK_NAME}" Xvisionx visionx_xorg_backend

echo "Built ${ROOT_DIR}/.build/xorg-server-${SDK_NAME}/hw/visionx/Xvisionx."
echo "Built ${ROOT_DIR}/.build/xorg-server-${SDK_NAME}/hw/visionx/libvisionx_xorg_backend.a."
