#!/usr/bin/env bash
# VisionX Project <src@lispm.net>
# Copyright (C) 2026 I. Finder
# SPDX-License-Identifier: MIT

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Scripts/smoke-simulator-clients.sh [options]

Build/install/launch UHF X11 in the visionOS simulator, wait for the X11 TCP
listener, then run protocol and real-client smoke tests without manual client
launches.

Options:
  --display HOST:N        DISPLAY target. Default: 127.0.0.1:0
  --duration SECONDS     How long to hold persistent demo clients. Default: 12
  --output-dir DIR       Artifact directory. Default: .tmp/client-smoke/<timestamp>
  --no-build             Do not run Scripts/build-simulator.sh.
  --no-launch            Do not launch the simulator app. Implies --no-build.
  --attach               Alias for --no-launch.
  --keep-clients         Leave spawned clients running after the harness exits.
  --no-wmaker            Do not auto-start WindowMaker even if installed.
  --no-xephem            Do not auto-start XEphem even if installed.
  --no-glx-spin          Do not build/run the bundled GLX spin probes.
  --glx-probe-seconds N  Runtime for each bundled GLX probe. Default: 6
  --start-twm            Also start twm if it is installed.
  --require-real-clients Fail if no external X11 demo clients are available.
  --help                 Show this help.

Useful environment:
  VISIONX_SIMULATOR_ID, VISIONX_CONFIGURATION, VISIONX_BUNDLE_ID,
  VISIONX_CLIENT_SMOKE_DURATION, VISIONX_CLIENT_SMOKE_DISPLAY,
  VISIONX_CLIENT_SMOKE_OUTPUT_DIR, VISIONX_CLIENT_SMOKE_REQUIRE_REAL_CLIENTS
  VISIONX_CLIENT_SMOKE_START_GLX_SPIN, VISIONX_CLIENT_SMOKE_GLX_PROBE_SECONDS
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="${VISIONX_BUNDLE_ID:-org.uhf.x11}"
CONFIGURATION="${VISIONX_CONFIGURATION:-Debug}"
APP_PRODUCT_NAME="${VISIONX_APP_PRODUCT_NAME:-UHF X11}"
DISPLAY_SPEC="${VISIONX_CLIENT_SMOKE_DISPLAY:-127.0.0.1:0}"
DURATION="${VISIONX_CLIENT_SMOKE_DURATION:-12}"
DO_BUILD="${VISIONX_CLIENT_SMOKE_BUILD:-1}"
DO_LAUNCH="${VISIONX_CLIENT_SMOKE_LAUNCH:-1}"
KEEP_CLIENTS="${VISIONX_CLIENT_SMOKE_KEEP_CLIENTS:-0}"
START_WMAKER="${VISIONX_CLIENT_SMOKE_START_WMAKER:-1}"
START_XEPHEM="${VISIONX_CLIENT_SMOKE_START_XEPHEM:-1}"
START_TWM="${VISIONX_CLIENT_SMOKE_START_TWM:-0}"
START_GLX_SPIN="${VISIONX_CLIENT_SMOKE_START_GLX_SPIN:-1}"
GLX_PROBE_SECONDS="${VISIONX_CLIENT_SMOKE_GLX_PROBE_SECONDS:-6}"
REQUIRE_REAL_CLIENTS="${VISIONX_CLIENT_SMOKE_REQUIRE_REAL_CLIENTS:-0}"
PORT_OVERRIDE="${VISIONX_CLIENT_SMOKE_PORT:-}"
WAIT_SECONDS="${VISIONX_CLIENT_SMOKE_WAIT_SECONDS:-60}"
OPEN_SIMULATOR_UI="${VISIONX_SIMULATOR_OPEN_UI:-1}"
OUTPUT_DIR="${VISIONX_CLIENT_SMOKE_OUTPUT_DIR:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --display)
            shift
            DISPLAY_SPEC="${1:?missing DISPLAY value}"
            ;;
        --duration)
            shift
            DURATION="${1:?missing duration value}"
            ;;
        --output-dir)
            shift
            OUTPUT_DIR="${1:?missing output directory value}"
            ;;
        --no-build)
            DO_BUILD=0
            ;;
        --no-launch|--attach)
            DO_BUILD=0
            DO_LAUNCH=0
            ;;
        --keep-clients)
            KEEP_CLIENTS=1
            ;;
        --no-wmaker)
            START_WMAKER=0
            ;;
        --no-xephem)
            START_XEPHEM=0
            ;;
        --no-glx-spin)
            START_GLX_SPIN=0
            ;;
        --glx-probe-seconds)
            shift
            GLX_PROBE_SECONDS="${1:?missing GLX probe seconds value}"
            ;;
        --start-twm)
            START_TWM=1
            ;;
        --require-real-clients)
            REQUIRE_REAL_CLIENTS=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [[ "${DISPLAY_SPEC}" != *:* ]]; then
    echo "DISPLAY must look like HOST:N, got: ${DISPLAY_SPEC}" >&2
    exit 2
fi

DISPLAY_HOST="${DISPLAY_SPEC%:*}"
DISPLAY_NUMBER_TEXT="${DISPLAY_SPEC##*:}"
DISPLAY_NUMBER="${DISPLAY_NUMBER_TEXT%%.*}"
if [[ -z "${DISPLAY_HOST}" ]]; then
    DISPLAY_HOST="127.0.0.1"
    DISPLAY_SPEC="${DISPLAY_HOST}:${DISPLAY_NUMBER_TEXT}"
fi
if [[ ! "${DISPLAY_NUMBER}" =~ ^[0-9]+$ ]]; then
    echo "DISPLAY number must be numeric, got: ${DISPLAY_NUMBER_TEXT}" >&2
    exit 2
fi
if [[ -n "${PORT_OVERRIDE}" ]]; then
    X11_PORT="${PORT_OVERRIDE}"
else
    X11_PORT=$((6000 + DISPLAY_NUMBER))
fi
X11_ENDPOINT_KIND="tcp"
X11_SOCKET_PATH=""
case "${DISPLAY_HOST}" in
    unix|unix/|local)
        X11_ENDPOINT_KIND="unix"
        X11_SOCKET_PATH="/tmp/.X11-unix/X${DISPLAY_NUMBER}"
        ;;
esac

if [[ -z "${OUTPUT_DIR}" ]]; then
    RUN_ID="$(date +%Y%m%d-%H%M%S)"
    OUTPUT_DIR="${ROOT_DIR}/.tmp/client-smoke/${RUN_ID}"
fi
mkdir -p "${OUTPUT_DIR}"
HARNESS_LOG="${OUTPUT_DIR}/harness.log"
SUMMARY_FILE="${OUTPUT_DIR}/summary.txt"

CLIENT_PIDS=()
CLIENT_NAMES=()
GLX_SPIN_BIN=""
REAL_CLIENT_COUNT=0
REQUIRED_FAILURES=0
OPTIONAL_FAILURES=0
SKIPPED_CLIENTS=""
TIMEOUT_BIN=""

log() {
    printf '[client-smoke] %s\n' "$*" | tee -a "${HARNESS_LOG}"
}

summary() {
    printf '%s\n' "$*" >> "${SUMMARY_FILE}"
}

find_simulator_id() {
    if [[ -n "${VISIONX_SIMULATOR_ID:-}" ]]; then
        printf '%s\n' "${VISIONX_SIMULATOR_ID}"
        return
    fi
    xcrun simctl list devices available |
        awk '/Apple Vision Pro/ { gsub(/[()]/, "", $4); id = $4 } END { print id }'
}

find_binary() {
    local name="$1"
    local candidate=""
    if [[ "${name}" == */* ]]; then
        if [[ -x "${name}" ]]; then
            printf '%s\n' "${name}"
        fi
        return
    fi

    for directory in /opt/local/bin /usr/local/bin /opt/X11/bin /usr/X11/bin /usr/bin /bin; do
        candidate="${directory}/${name}"
        if [[ -x "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return
        fi
    done

    candidate="$(command -v "${name}" 2>/dev/null || true)"
    if [[ -n "${candidate}" && -x "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
    fi
}

choose_timeout() {
    local candidate=""
    candidate="$(find_binary gtimeout || true)"
    if [[ -n "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
        return
    fi
    candidate="$(find_binary timeout || true)"
    if [[ -n "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
    fi
}

build_glx_spin_client() {
    local compiler=""
    compiler="$(find_binary cc || true)"
    if [[ -z "${compiler}" ]]; then
        log "Skipping bundled GLX spin probes; cc not installed"
        summary "SKIP glx-spin-build missing=cc"
        return 1
    fi

    GLX_SPIN_BIN="${OUTPUT_DIR}/uhf_glx_spin"
    log "Building bundled GLX spin probe ${GLX_SPIN_BIN}"
    if "${compiler}" -O2 -Wall -Wextra \
        -I/opt/local/include \
        -L/opt/local/lib \
        "${ROOT_DIR}/Tools/glx-clients/uhf_glx_spin.c" \
        -lGL -lX11 -lm \
        -o "${GLX_SPIN_BIN}" >"${OUTPUT_DIR}/uhf_glx_spin-build.log" 2>&1; then
        summary "PASS glx-spin-build ${OUTPUT_DIR}/uhf_glx_spin-build.log"
        return 0
    fi

    log "Bundled GLX spin probe build failed; log=${OUTPUT_DIR}/uhf_glx_spin-build.log"
    summary "FAIL glx-spin-build ${OUTPUT_DIR}/uhf_glx_spin-build.log"
    return 1
}

check_port() {
    if [[ "${X11_ENDPOINT_KIND}" == "unix" ]]; then
        [[ -S "${X11_SOCKET_PATH}" ]]
        return $?
    fi

    if command -v nc >/dev/null 2>&1; then
        nc -z -G 1 "${DISPLAY_HOST}" "${X11_PORT}" >/dev/null 2>&1 ||
            nc -z -w 1 "${DISPLAY_HOST}" "${X11_PORT}" >/dev/null 2>&1
        return $?
    fi
    (echo >"/dev/tcp/${DISPLAY_HOST}/${X11_PORT}") >/dev/null 2>&1
}

wait_for_x11() {
    local deadline=$((SECONDS + WAIT_SECONDS))
    while (( SECONDS < deadline )); do
        if check_port; then
            return 0
        fi
        sleep 1
    done
    return 1
}

run_with_timeout() {
    local seconds="$1"
    local log_file="$2"
    shift 2

    if [[ -n "${TIMEOUT_BIN}" ]]; then
        "${TIMEOUT_BIN}" "${seconds}" "$@" >"${log_file}" 2>&1
        return $?
    fi

    "$@" >"${log_file}" 2>&1 &
    local pid=$!
    local deadline=$((SECONDS + seconds))
    local status=0
    while kill -0 "${pid}" >/dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
            kill "${pid}" >/dev/null 2>&1 || true
            sleep 1
            kill -9 "${pid}" >/dev/null 2>&1 || true
            wait "${pid}" >/dev/null 2>&1 || true
            return 124
        fi
        sleep 0.2
    done
    wait "${pid}" || status=$?
    return ${status}
}

run_logged() {
    local name="$1"
    local seconds="$2"
    local log_file="${OUTPUT_DIR}/${name}.log"
    shift 2

    log "Running ${name}; log=${log_file}"
    local status=0
    run_with_timeout "${seconds}" "${log_file}" "$@" || status=$?
    if [[ "${status}" == "0" ]]; then
        log "${name} passed"
        summary "PASS ${name} ${log_file}"
        return 0
    fi

    log "${name} failed with status ${status}; log=${log_file}"
    summary "FAIL ${name} status=${status} ${log_file}"
    return ${status}
}

run_required() {
    local name="$1"
    shift
    if ! run_logged "${name}" "$@"; then
        REQUIRED_FAILURES=$((REQUIRED_FAILURES + 1))
    fi
}

run_optional_x_probe() {
    local name="$1"
    local seconds="$2"
    local binary_name="$3"
    shift 3
    local binary
    local log_file="${OUTPUT_DIR}/${name}.log"
    binary="$(find_binary "${binary_name}" || true)"
    if [[ -z "${binary}" ]]; then
        log "Skipping ${name}; ${binary_name} not installed"
        summary "SKIP ${name} missing=${binary_name}"
        SKIPPED_CLIENTS="${SKIPPED_CLIENTS} ${name}"
        return 0
    fi

    log "Running ${name}; log=${log_file}"
    local status=0
    run_with_timeout "${seconds}" "${log_file}" env DISPLAY="${DISPLAY_SPEC}" LIBGL_ALWAYS_INDIRECT=1 "${binary}" "$@" || status=$?
    if [[ "${status}" == "0" ]]; then
        log "${name} passed"
        summary "PASS ${name} ${log_file}"
        REAL_CLIENT_COUNT=$((REAL_CLIENT_COUNT + 1))
        return 0
    fi

    if [[ "${status}" == "126" ]] && grep -qi "Bad CPU type" "${log_file}" 2>/dev/null; then
        log "Skipping ${name}; ${binary} is not runnable on this CPU"
        summary "SKIP ${name} incompatible=${binary}"
        SKIPPED_CLIENTS="${SKIPPED_CLIENTS} ${name}"
        return 0
    fi

    log "${name} failed with status ${status}; log=${log_file}"
    summary "FAIL ${name} status=${status} ${log_file}"
    OPTIONAL_FAILURES=$((OPTIONAL_FAILURES + 1))
    return 0
}

run_optional_glx_spin_probe() {
    local name="$1"
    shift

    if [[ -z "${GLX_SPIN_BIN}" || ! -x "${GLX_SPIN_BIN}" ]]; then
        log "Skipping ${name}; bundled GLX spin probe is not built"
        summary "SKIP ${name} missing=uhf_glx_spin"
        SKIPPED_CLIENTS="${SKIPPED_CLIENTS} ${name}"
        return 0
    fi

    local timeout_seconds=$((GLX_PROBE_SECONDS + 8))
    if run_logged "${name}" "${timeout_seconds}" \
        env DISPLAY="${DISPLAY_SPEC}" LIBGL_ALWAYS_INDIRECT=1 \
        "${GLX_SPIN_BIN}" "$@" --seconds "${GLX_PROBE_SECONDS}"; then
        REAL_CLIENT_COUNT=$((REAL_CLIENT_COUNT + 1))
        return 0
    fi
    OPTIONAL_FAILURES=$((OPTIONAL_FAILURES + 1))
    return 0
}

spawn_process() {
    local name="$1"
    local log_file="${OUTPUT_DIR}/${name}.log"
    shift

    log "Spawning ${name}; log=${log_file}"
    "$@" >"${log_file}" 2>&1 &
    local pid=$!
    sleep 0.6
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
        local status=0
        wait "${pid}" || status=$?
        log "${name} exited early with status ${status}; log=${log_file}"
        summary "FAIL ${name} early-exit status=${status} ${log_file}"
        return 1
    fi

    CLIENT_PIDS+=("${pid}")
    CLIENT_NAMES+=("${name}")
    summary "SPAWN ${name} pid=${pid} ${log_file}"
    return 0
}

spawn_required_process() {
    local name="$1"
    shift
    if ! spawn_process "${name}" "$@"; then
        REQUIRED_FAILURES=$((REQUIRED_FAILURES + 1))
    fi
}

spawn_optional_x_client() {
    local name="$1"
    local binary_name="$2"
    shift 2
    local binary
    binary="$(find_binary "${binary_name}" || true)"
    if [[ -z "${binary}" ]]; then
        log "Skipping ${name}; ${binary_name} not installed"
        summary "SKIP ${name} missing=${binary_name}"
        SKIPPED_CLIENTS="${SKIPPED_CLIENTS} ${name}"
        return 0
    fi

    if spawn_process "${name}" env DISPLAY="${DISPLAY_SPEC}" LIBGL_ALWAYS_INDIRECT=1 "${binary}" "$@"; then
        REAL_CLIENT_COUNT=$((REAL_CLIENT_COUNT + 1))
        return 0
    fi
    OPTIONAL_FAILURES=$((OPTIONAL_FAILURES + 1))
    return 0
}

capture_screenshot() {
    local name="$1"
    local destination="${OUTPUT_DIR}/${name}.png"
    if xcrun simctl io "${SIMULATOR_ID}" screenshot "${destination}" >/dev/null 2>&1; then
        log "Captured simulator screenshot ${destination}"
        summary "ARTIFACT screenshot ${destination}"
    else
        log "Simulator screenshot failed"
        summary "WARN screenshot failed"
    fi
}

copy_runtime_log() {
    local container=""
    local source=""
    container="$(xcrun simctl get_app_container "${SIMULATOR_ID}" "${BUNDLE_ID}" data 2>/dev/null || true)"
    if [[ -z "${container}" ]]; then
        log "Could not locate app data container for ${BUNDLE_ID}"
        summary "WARN runtime-log missing-container"
        return
    fi

    source="${container}/Library/Caches/X11ProVision/runtime.log"
    if [[ -f "${source}" ]]; then
        cp "${source}" "${OUTPUT_DIR}/runtime.log"
        log "Copied runtime log ${OUTPUT_DIR}/runtime.log"
        summary "ARTIFACT runtime-log ${OUTPUT_DIR}/runtime.log"
    else
        log "Runtime log not found at ${source}"
        summary "WARN runtime-log missing-file"
    fi
}

cleanup() {
    local status=$?
    set +e +u
    if [[ "${KEEP_CLIENTS}" != "1" ]]; then
        local index=0
        while (( index < ${#CLIENT_PIDS[@]} )); do
            local pid="${CLIENT_PIDS[${index}]}"
            local name="${CLIENT_NAMES[${index}]}"
            if kill -0 "${pid}" >/dev/null 2>&1; then
                log "Stopping ${name} pid=${pid}"
                kill "${pid}" >/dev/null 2>&1 || true
            fi
            index=$((index + 1))
        done
        sleep 1
        for pid in "${CLIENT_PIDS[@]}"; do
            kill -9 "${pid}" >/dev/null 2>&1 || true
            wait "${pid}" >/dev/null 2>&1 || true
        done
    else
        log "Leaving spawned clients running: ${CLIENT_PIDS[*]:-none}"
    fi
    copy_runtime_log
    exit ${status}
}
trap cleanup EXIT INT TERM

: >"${HARNESS_LOG}"
: >"${SUMMARY_FILE}"
TIMEOUT_BIN="$(choose_timeout || true)"
SIMULATOR_ID="$(find_simulator_id)"
if [[ -z "${SIMULATOR_ID}" ]]; then
    echo "No available Apple Vision Pro simulator found. Set VISIONX_SIMULATOR_ID explicitly." >&2
    exit 2
fi

summary "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
summary "root=${ROOT_DIR}"
summary "simulator=${SIMULATOR_ID}"
summary "configuration=${CONFIGURATION}"
summary "display=${DISPLAY_SPEC}"
summary "endpoint=${X11_ENDPOINT_KIND}"
if [[ "${X11_ENDPOINT_KIND}" == "unix" ]]; then
    summary "socket=${X11_SOCKET_PATH}"
else
    summary "port=${X11_PORT}"
fi
summary "duration=${DURATION}"
summary "timeout=${TIMEOUT_BIN:-internal}"

log "Artifacts: ${OUTPUT_DIR}"
log "Simulator: ${SIMULATOR_ID}"
if [[ "${X11_ENDPOINT_KIND}" == "unix" ]]; then
    log "Target DISPLAY=${DISPLAY_SPEC} socket=${X11_SOCKET_PATH}"
else
    log "Target DISPLAY=${DISPLAY_SPEC} port=${X11_PORT}"
fi

if [[ "${DO_BUILD}" == "1" ]]; then
    log "Building, installing, and launching simulator app"
    VISIONX_CONFIGURATION="${CONFIGURATION}" \
        VISIONX_SIMULATOR_LAUNCH=1 \
        VISIONX_SIMULATOR_OPEN_UI="${OPEN_SIMULATOR_UI}" \
        "${ROOT_DIR}/Scripts/build-simulator.sh" >"${OUTPUT_DIR}/build-simulator.log" 2>&1
    summary "PASS build-simulator ${OUTPUT_DIR}/build-simulator.log"
elif [[ "${DO_LAUNCH}" == "1" ]]; then
    log "Launching existing simulator app"
    xcrun simctl boot "${SIMULATOR_ID}" >/dev/null 2>&1 || true
    if [[ "${OPEN_SIMULATOR_UI}" == "1" ]]; then
        open -a Simulator --args -CurrentDeviceUDID "${SIMULATOR_ID}"
    fi
    xcrun simctl bootstatus "${SIMULATOR_ID}" -b
    xcrun simctl launch --terminate-running-process \
        "${SIMULATOR_ID}" \
        "${BUNDLE_ID}" \
        --visionx-autostart \
        --visionx-xhost-plus \
        --visionx-bind-address=127.0.0.1 \
        --visionx-accept-notice \
        --visionx-experimental-glx >"${OUTPUT_DIR}/simulator-launch.log" 2>&1
    summary "PASS simulator-launch ${OUTPUT_DIR}/simulator-launch.log"
else
    log "Attach mode: using the currently running app/server"
    summary "INFO attach-mode"
fi

log "Waiting up to ${WAIT_SECONDS}s for X11 listener"
if wait_for_x11; then
    log "X11 listener is reachable"
    if [[ "${X11_ENDPOINT_KIND}" == "unix" ]]; then
        summary "PASS wait-x11 ${X11_SOCKET_PATH}"
    else
        summary "PASS wait-x11 ${DISPLAY_HOST}:${X11_PORT}"
    fi
else
    if [[ "${X11_ENDPOINT_KIND}" == "unix" ]]; then
        log "X11 listener did not open at ${X11_SOCKET_PATH}"
        summary "FAIL wait-x11 ${X11_SOCKET_PATH}"
    else
        log "X11 listener did not open on ${DISPLAY_HOST}:${X11_PORT}"
        summary "FAIL wait-x11 ${DISPLAY_HOST}:${X11_PORT}"
    fi
    exit 1
fi

if [[ "${X11_ENDPOINT_KIND}" == "tcp" ]]; then
    run_required "direct-glx-visible" 20 \
        python3 "${ROOT_DIR}/Scripts/smoke-glx-direct.py" --render-triangle --visible-window "${DISPLAY_SPEC}"

    spawn_required_process "overlap-smoke" \
        python3 "${ROOT_DIR}/Scripts/x11-overlap-smoke.py" \
            --host "${DISPLAY_HOST}" \
            --port "${X11_PORT}" \
            --duration "${DURATION}"
else
    log "Skipping raw TCP probes for Unix-socket DISPLAY=${DISPLAY_SPEC}"
    summary "SKIP direct-glx-visible endpoint=${X11_ENDPOINT_KIND}"
    summary "SKIP overlap-smoke endpoint=${X11_ENDPOINT_KIND}"
fi

run_optional_x_probe "xdpyinfo" 12 xdpyinfo -queryExtensions
run_optional_x_probe "glxinfo-basic" 15 glxinfo -B

if [[ "${START_GLX_SPIN}" == "1" ]]; then
    if build_glx_spin_client; then
        run_optional_glx_spin_probe "uhf-glx-time" --time --size 320x240 --rate 360
        run_optional_glx_spin_probe "uhf-glx-swap-step" --swap-step --size 320x240 --step 3
        run_optional_glx_spin_probe "uhf-glx-list" --list --size 300x220 --rate 240
        run_optional_glx_spin_probe "uhf-glx-primitives" --primitives --size 340x240 --rate 180
        run_optional_glx_spin_probe "uhf-glx-resize" --resize --size 280x220 --rate 180
        run_optional_glx_spin_probe "uhf-glx-finish" --time --finish --size 280x220 --rate 180
    else
        OPTIONAL_FAILURES=$((OPTIONAL_FAILURES + 1))
    fi
fi

if [[ "${START_WMAKER}" == "1" ]]; then
    spawn_optional_x_client "wmaker" wmaker
    sleep 1
fi
if [[ "${START_TWM}" == "1" ]]; then
    spawn_optional_x_client "twm" twm
    sleep 1
fi

spawn_optional_x_client "xterm-cursor-churn" xterm \
    -geometry 100x24+20+20 \
    -T "UHF X11 cursor churn" \
    -e /bin/sh -lc 'i=0; while [ "$i" -lt 350 ]; do printf "cursor-block-%04d ABCDEFGHIJ" "$i"; printf "\b\b\b\b\b\b\b\b\b\b          \b\b\b\b\b\b\b\b\b\b"; i=$((i + 1)); sleep 0.02; done; sleep 4'
spawn_optional_x_client "xeyes" xeyes -geometry 220x160+290+40
spawn_optional_x_client "xclock" xclock -geometry 220x160+540+40 -update 1
spawn_optional_x_client "xlogo" xlogo -geometry 220x160+790+40
if [[ "${START_XEPHEM}" == "1" ]]; then
    spawn_optional_x_client "xephem" xephem
fi
spawn_optional_x_client "glxgears" glxgears -info

sleep 2
run_optional_x_probe "xwininfo-root-tree" 12 xwininfo -root -tree
run_optional_x_probe "xprop-root" 12 xprop -root

capture_screenshot "simulator-before"
log "Holding clients for ${DURATION}s"
sleep "${DURATION}"
capture_screenshot "simulator-after"

if [[ "${REQUIRE_REAL_CLIENTS}" == "1" && "${REAL_CLIENT_COUNT}" == "0" ]]; then
    log "No external X11 clients were available, and --require-real-clients was set"
    summary "FAIL real-clients none-available"
    REQUIRED_FAILURES=$((REQUIRED_FAILURES + 1))
fi

summary "real_client_count=${REAL_CLIENT_COUNT}"
summary "optional_failures=${OPTIONAL_FAILURES}"
summary "required_failures=${REQUIRED_FAILURES}"
summary "skipped=${SKIPPED_CLIENTS}"

if [[ "${REQUIRED_FAILURES}" != "0" ]]; then
    log "Required smoke checks failed: ${REQUIRED_FAILURES}"
    exit 1
fi

if [[ "${OPTIONAL_FAILURES}" != "0" ]]; then
    log "Completed with optional client failures: ${OPTIONAL_FAILURES}"
else
    log "Completed client smoke successfully"
fi
log "Summary: ${SUMMARY_FILE}"
