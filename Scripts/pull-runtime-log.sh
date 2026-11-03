#!/usr/bin/env bash
# VisionX Project <src@lispm.net>
# Copyright (C) 2026 I. Finder
# SPDX-License-Identifier: MIT

set -euo pipefail

DEVICE_ID="${VISIONX_DEVICE_ID:-}"
BUNDLE_ID="${VISIONX_BUNDLE_ID:-org.uhf.x11}"
DESTINATION="${1:-.tmp/visionx-runtime.log}"

if [[ -z "${DEVICE_ID}" ]]; then
  echo "Set VISIONX_DEVICE_ID to the identifier reported by 'xcrun devicectl list devices'." >&2
  exit 2
fi

mkdir -p "$(dirname "${DESTINATION}")"

xcrun devicectl device copy from \
  --device "${DEVICE_ID}" \
  --domain-type appDataContainer \
  --domain-identifier "${BUNDLE_ID}" \
  --source Library/Caches/X11ProVision/runtime.log \
  --destination "${DESTINATION}"

echo "Runtime log copied to ${DESTINATION}"
