#!/usr/bin/env bash
# VisionX Project <src@lispm.net>
# Copyright (C) 2026 I. Finder
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_PYTHON="${ROOT_DIR}/.build/meson-venv/bin/python"

if [[ -x "${VENV_PYTHON}" ]] && "${VENV_PYTHON}" -c 'import mesonbuild' >/dev/null 2>&1; then
    exec "${VENV_PYTHON}" -m mesonbuild.mesonmain "$@"
fi

if command -v meson >/dev/null 2>&1; then
    exec meson "$@"
fi

echo "Missing Meson. Install it or create .build/meson-venv first." >&2
exit 127
