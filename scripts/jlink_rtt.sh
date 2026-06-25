#!/usr/bin/env bash

set -Eeuo pipefail

# User configuration intentionally comes only from .jlink-rtt.env and CLI flags.
# Host tool commands are auto-detected from PATH instead of stored as RTT config.
JLINK_GDB_SERVER=""
GDB=""
NC=""
HOST="127.0.0.1"
DEVICE=""
JLINK_IF="SWD"
SPEED="4000"
JLINK_SERIAL=""
GDB_PORT="2331"
RTT_PORT="19021"
READY_TIMEOUT="10"
LOG_FILE="/tmp/jlink_gdb_server.log"
GDB_LOG_FILE="/tmp/jlink_gdb_resume.log"
RTT_OUT_FILE=""
RTT_MATCH_PATTERN=""
RTT_MATCH_TIMEOUT="30"
RESET_TARGET="1"
RESUME_TARGET="1"
PROJECT_ROOT=""
CONFIG_FILE=""
PRINT_CONFIG=0
INIT_MODE=0
RTT_STOP=0

gdb_srv_pid=""
config_loaded=""

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --config FILE          Load explicit .jlink-rtt.env file
  --project-root DIR     Limit default config search to this project root
  --print-config         Print resolved config and exit
  --init                 Create .jlink-rtt.env with current settings and exit
  --jlink-gdb-server CMD Override auto-detected JLinkGDBServer command
  --gdb CMD              Override auto-detected GDB command
  --nc CMD               Override auto-detected nc command
  --device DEVICE        J-Link target device, required unless configured
  --if INTERFACE         J-Link interface, default: ${JLINK_IF}
  --speed KHZ            J-Link speed in kHz, default: ${SPEED}
  --serial SERIAL        J-Link serial number, optional
  --host HOST            Local host for GDB/RTT ports, default: ${HOST}
  --gdb-port PORT        GDB server port, default: ${GDB_PORT}
  --rtt-port PORT        RTT telnet port, default: ${RTT_PORT}
  --timeout SECONDS      Port ready timeout, default: ${READY_TIMEOUT}
  --log FILE             JLinkGDBServer log file, default: ${LOG_FILE}
  --gdb-log FILE         GDB resume log file, default: ${GDB_LOG_FILE}
  --out FILE             Save RTT output to file while streaming stdout
  --match PATTERN        Exit 0 after this fixed text appears in RTT output
  --match-timeout SEC    Timeout for --match, default: ${RTT_MATCH_TIMEOUT}
  --no-reset             Do not reset the target before reading RTT
  --no-resume            Do not connect GDB to resume the target
  --stop                 Stop a running RTT session (kills JLinkGDBServer, triggers clean shutdown)
  -h, --help             Show this help

Config search:
  Without --config, .jlink-rtt.env is searched from the current directory
  upward, but never beyond --project-root or the current git worktree root.
  Non-git directories only check the current dir.

Precedence:
  command line > .jlink-rtt.env > script built-in defaults
EOF
}

log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
log_hint() { printf '[INFO] %s\n' "$*" >&2; }
die() {
    log_error "$1"
    shift
    local hint
    for hint in "$@"; do
        log_hint "${hint}"
    done
    exit 1
}

# Detect J-Link serial number(s) from lsusb.
# Sets DETECTED_SERIAL to the serial if exactly one probe found.
# Sets DETECTED_SERIAL to empty if zero or multiple probes found.
detect_serial() {
    DETECTED_SERIAL=""
    local serials
    serials="$(lsusb -v -d 1366: 2>/dev/null | grep -i 'iSerial' | awk '{print $3}' | sort -u)" || true

    local count
    count="$(printf '%s\n' "${serials}" | grep -c . || true)"

    if ((count == 1)); then
        DETECTED_SERIAL="${serials}"
    fi
}

do_init() {
    local file="$1"

    if [[ -z "${DEVICE}" ]]; then
        die "DEVICE is required for --init." \
            "Scan the project for the DEVICE name (SEGGER device string, e.g. NRF52840_XXAA)." \
            "If not found, ask the user for the DEVICE name, then run:" \
            "  ${0} --init --device <DEVICE>"
    fi

    if [[ -f "${file}" ]]; then
        die "Config file already exists: ${file}" \
            "To inspect it, run:" \
            "  ${0} --print-config" \
            "To re-create, remove the file first: rm ${file}"
    fi

    mkdir -p "$(dirname "${file}")"

    cat > "${file}" <<EOF
# J-Link RTT project configuration
DEVICE=${DEVICE}
JLINK_IF=${JLINK_IF}
SPEED=${SPEED}
HOST=${HOST}
GDB_PORT=${GDB_PORT}
RTT_PORT=${RTT_PORT}
RTT_READY_TIMEOUT=${READY_TIMEOUT}
LOG_FILE=${LOG_FILE}
GDB_LOG_FILE=${GDB_LOG_FILE}
EOF

    if [[ -n "${JLINK_SERIAL}" ]]; then
        printf 'JLINK_SERIAL=%s\n' "${JLINK_SERIAL}" >> "${file}"
    fi

    config_loaded="${file}"

    log_info "Created config: ${file}"
    log_hint "Config created. Now run the capture command again:"
    log_hint "  ${0} --out /tmp/rtt.log"
    print_config
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

require_value() {
    local option="$1"
    local value="${2:-}"

    if [[ -z "${value}" ]]; then
        die "Missing value for ${option}." \
            "Re-run the command with a value for ${option}."
    fi
}

abs_dir() {
    local dir="$1"
    (cd "${dir}" >/dev/null 2>&1 && pwd -P) || return 1
}

find_git_root() {
    git rev-parse --show-toplevel 2>/dev/null || true
}

resolve_project_root() {
    if [[ -n "${PROJECT_ROOT}" ]]; then
        abs_dir "${PROJECT_ROOT}" || die "Invalid project root: ${PROJECT_ROOT}." \
            "Pass a valid directory with --project-root <DIR>."
        return 0
    fi

    local git_root
    git_root="$(find_git_root)"
    if [[ -n "${git_root}" ]]; then
        abs_dir "${git_root}" || die "Invalid git root: ${git_root}." \
            "Run from a valid git worktree, or pass --project-root <DIR>."
        return 0
    fi

    pwd -P
}

path_is_at_or_below() {
    local path="$1"
    local root="$2"

    [[ "${path}" == "${root}" || "${path}" == "${root}/"* ]]
}

# Default config lookup must not climb above the resolved project root.
find_default_config() {
    local root="$1"
    local dir
    dir="$(pwd -P)"

    path_is_at_or_below "${dir}" "${root}" || die "Current directory is outside project root: ${root}." \
        "Run from within the project, or pass --project-root <DIR>."

    while true; do
        if [[ -f "${dir}/.jlink-rtt.env" ]]; then
            printf '%s\n' "${dir}/.jlink-rtt.env"
            return 0
        fi

        if [[ "${dir}" == "${root}" ]]; then
            return 1
        fi

        dir="$(dirname "${dir}")"
    done
}

# Keep .jlink-rtt.env focused on target/RTT settings; tool paths are CLI-only.
set_config_key() {
    local key="$1"
    local value="$2"

    case "${key}" in
    HOST) HOST="${value}" ;;
    DEVICE) DEVICE="${value}" ;;
    JLINK_IF) JLINK_IF="${value}" ;;
    SPEED) SPEED="${value}" ;;
    JLINK_SERIAL) JLINK_SERIAL="${value}" ;;
    GDB_PORT) GDB_PORT="${value}" ;;
    RTT_PORT) RTT_PORT="${value}" ;;
    RTT_READY_TIMEOUT) READY_TIMEOUT="${value}" ;;
    LOG_FILE) LOG_FILE="${value}" ;;
    GDB_LOG_FILE) GDB_LOG_FILE="${value}" ;;
    RTT_OUT_FILE) RTT_OUT_FILE="${value}" ;;
    RTT_MATCH_PATTERN) RTT_MATCH_PATTERN="${value}" ;;
    RTT_MATCH_TIMEOUT) RTT_MATCH_TIMEOUT="${value}" ;;
    RESET_TARGET) RESET_TARGET="${value}" ;;
    RESUME_TARGET) RESUME_TARGET="${value}" ;;
    *) log_warn "Ignoring unknown config key: ${key}" ;;
    esac
}

load_config_file() {
    local file="$1"
    local line key value

    [[ -f "${file}" ]] || die "Config file not found: ${file}." \
        "Check the --config path, or run without --config to auto-discover .jlink-rtt.env."

    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue

        if [[ ! "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            die "Invalid config line in ${file}: ${line}" \
                "Fix or remove the line, then re-run. Valid format: KEY=VALUE"
        fi

        key="${line%%=*}"
        value="${line#*=}"
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        set_config_key "${key}" "${value}"
    done < "${file}"

    config_loaded="${file}"
}

parse_pre_config_args() {
    while (($# > 0)); do
        case "$1" in
        --config)
            require_value "$1" "${2:-}"
            CONFIG_FILE="$2"
            shift 2
            ;;
        --project-root)
            require_value "$1" "${2:-}"
            PROJECT_ROOT="$2"
            shift 2
            ;;
        *)
            shift
            ;;
        esac
    done
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
        --config | --project-root)
            require_value "$1" "${2:-}"
            shift 2
            ;;
        --jlink-gdb-server)
            require_value "$1" "${2:-}"
            JLINK_GDB_SERVER="$2"
            shift 2
            ;;
        --gdb)
            require_value "$1" "${2:-}"
            GDB="$2"
            shift 2
            ;;
        --nc)
            require_value "$1" "${2:-}"
            NC="$2"
            shift 2
            ;;
        --print-config)
            PRINT_CONFIG=1
            shift
            ;;
        --init)
            INIT_MODE=1
            shift
            ;;
        --device)
            require_value "$1" "${2:-}"
            DEVICE="$2"
            shift 2
            ;;
        --if)
            require_value "$1" "${2:-}"
            JLINK_IF="$2"
            shift 2
            ;;
        --speed)
            require_value "$1" "${2:-}"
            SPEED="$2"
            shift 2
            ;;
        --serial)
            require_value "$1" "${2:-}"
            JLINK_SERIAL="$2"
            shift 2
            ;;
        --host)
            require_value "$1" "${2:-}"
            HOST="$2"
            shift 2
            ;;
        --gdb-port)
            require_value "$1" "${2:-}"
            GDB_PORT="$2"
            shift 2
            ;;
        --rtt-port)
            require_value "$1" "${2:-}"
            RTT_PORT="$2"
            shift 2
            ;;
        --timeout)
            require_value "$1" "${2:-}"
            READY_TIMEOUT="$2"
            shift 2
            ;;
        --log)
            require_value "$1" "${2:-}"
            LOG_FILE="$2"
            shift 2
            ;;
        --gdb-log)
            require_value "$1" "${2:-}"
            GDB_LOG_FILE="$2"
            shift 2
            ;;
        --out)
            require_value "$1" "${2:-}"
            RTT_OUT_FILE="$2"
            shift 2
            ;;
        --match)
            require_value "$1" "${2:-}"
            RTT_MATCH_PATTERN="$2"
            shift 2
            ;;
        --match-timeout)
            require_value "$1" "${2:-}"
            RTT_MATCH_TIMEOUT="$2"
            shift 2
            ;;
        --no-reset)
            RESET_TARGET=0
            shift
            ;;
        --no-resume)
            RESUME_TARGET=0
            shift
            ;;
        --stop)
            RTT_STOP=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage >&2
            exit 2
            ;;
        esac
    done
}

validate_config() {
    [[ -n "${DEVICE}" ]] || die "DEVICE is required." \
        "Scan the project for the DEVICE name (SEGGER device string, e.g. NRF52840_XXAA)." \
        "If not found, ask the user for the DEVICE name, then run:" \
        "  ${0} --init --device <DEVICE>"
    is_uint "${SPEED}" || die "Invalid speed: ${SPEED}." \
        "Set a numeric speed in kHz, e.g. --speed 4000."
    is_uint "${GDB_PORT}" || die "Invalid GDB port: ${GDB_PORT}." \
        "Set a numeric port, e.g. --gdb-port 2331."
    is_uint "${RTT_PORT}" || die "Invalid RTT port: ${RTT_PORT}." \
        "Set a numeric port, e.g. --rtt-port 19021."
    is_uint "${READY_TIMEOUT}" || die "Invalid timeout: ${READY_TIMEOUT}." \
        "Set a numeric timeout in seconds, e.g. --timeout 10."
    is_uint "${RTT_MATCH_TIMEOUT}" || die "Invalid match timeout: ${RTT_MATCH_TIMEOUT}." \
        "Set a numeric timeout in seconds, e.g. --match-timeout 30."
    [[ "${RESET_TARGET}" =~ ^[01]$ ]] || die "RESET_TARGET must be 0 or 1." \
        "Edit .jlink-rtt.env and set RESET_TARGET=0 or RESET_TARGET=1."
    [[ "${RESUME_TARGET}" =~ ^[01]$ ]] || die "RESUME_TARGET must be 0 or 1." \
        "Edit .jlink-rtt.env and set RESUME_TARGET=0 or RESUME_TARGET=1."

    if [[ "${GDB_PORT}" == "${RTT_PORT}" ]]; then
        die "GDB port and RTT port must be different." \
            "Use different ports, e.g. --gdb-port 2331 --rtt-port 19021."
    fi
}

require_command() {
    local cmd="$1"

    if ! command -v "${cmd}" >/dev/null 2>&1; then
        die "Missing required command: ${cmd}." \
            "Install it and add to PATH, or pass an explicit path via CLI option."
    fi
}

find_first_command() {
    local var_name="$1"
    shift
    local current_value candidate

    current_value="${!var_name}"
    if [[ -n "${current_value}" ]]; then
        require_command "${current_value}"
        return 0
    fi

    for candidate in "$@"; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            printf -v "${var_name}" '%s' "${candidate}"
            return 0
        fi
    done

    die "Missing required command. Tried: $*." \
        "Install SEGGER J-Link tools, GDB, and nc; add them to PATH." \
        "Or override individually: --jlink-gdb-server <path> --gdb <path> --nc <path>"
}

# Tool discovery is delayed until real hardware access is needed, so
# --print-config remains usable on machines without J-Link/GDB/nc installed.
detect_tools() {
    find_first_command JLINK_GDB_SERVER JLinkGDBServer JLinkGDBServerCLExe
    find_first_command GDB gdb-multiarch arm-none-eabi-gdb gdb
    find_first_command NC nc ncat
}

prepare_logs() {
    mkdir -p "$(dirname "${LOG_FILE}")" "$(dirname "${GDB_LOG_FILE}")"
    : > "${LOG_FILE}"
    : > "${GDB_LOG_FILE}"

    if [[ -n "${RTT_OUT_FILE}" ]]; then
        mkdir -p "$(dirname "${RTT_OUT_FILE}")"
        : > "${RTT_OUT_FILE}"
    fi
}

port_is_open() {
    local port="$1"

    "${NC}" -z -w 1 "${HOST}" "${port}" >/dev/null 2>&1
}

ensure_port_free() {
    local port="$1"
    local name="$2"

    if port_is_open "${port}"; then
        die "${name} port ${HOST}:${port} is already in use." \
            "Find and stop the stale process: lsof -i :${port} || ss -tlnp | grep :${port}" \
            "Or use a different port: --${name,,}-port <PORT>"
    fi
}

check_server_alive() {
    [[ -n "${gdb_srv_pid}" ]] || return 1
    kill -0 "${gdb_srv_pid}" 2>/dev/null
}

print_server_log() {
    if [[ -s "${LOG_FILE}" ]]; then
        log_error "JLinkGDBServer log:"
        sed -n '1,160p' "${LOG_FILE}" >&2
    fi
}

wait_for_port() {
    local port="$1"
    local name="$2"
    local deadline=$((SECONDS + READY_TIMEOUT))

    while ((SECONDS < deadline)); do
        if ! check_server_alive; then
            print_server_log
            die "JLinkGDBServer stopped before ${name} port became ready." \
                "Check the JLinkGDBServer log above for the error." \
                "Common causes: wrong DEVICE name, target not powered, SWD wiring issue."
        fi

        if port_is_open "${port}"; then
            return 0
        fi

        sleep 0.2
    done

    print_server_log
    die "Timed out waiting for ${name} port ${HOST}:${port}." \
        "Check the JLinkGDBServer log above." \
        "Or increase the timeout: --timeout 20"
}

cleanup() {
    local status=$?

    trap - EXIT INT TERM HUP

    if check_server_alive; then
        log_info "Stopping JLinkGDBServer (pid ${gdb_srv_pid})."
        kill "${gdb_srv_pid}" 2>/dev/null || true
        wait "${gdb_srv_pid}" 2>/dev/null || true
    fi

    # Clean up PID file and any orphan nc from the session.
    rm -f "/tmp/jlink_rtt_$(basename "${PROJECT_ROOT}").pid"
    pkill -f "nc ${HOST} ${RTT_PORT}$" 2>/dev/null || true

    exit "${status}"
}

start_gdb_server() {
    local -a args=(
        -device "${DEVICE}"
        -if "${JLINK_IF}"
        -speed "${SPEED}"
        -port "${GDB_PORT}"
        -RTTTelnetPort "${RTT_PORT}"
    )

    if [[ -n "${JLINK_SERIAL}" ]]; then
        args+=(-select "USB=${JLINK_SERIAL}")
    fi

    log_info "Starting JLinkGDBServer for ${DEVICE} on GDB ${HOST}:${GDB_PORT}, RTT ${HOST}:${RTT_PORT}."
    "${JLINK_GDB_SERVER}" "${args[@]}" > "${LOG_FILE}" 2>&1 &
    gdb_srv_pid=$!
}

resume_target() {
    if ((RESUME_TARGET == 0)); then
        log_info "Skipping target resume."
        return 0
    fi

    local -a gdb_args=(
        -batch
        -ex "set confirm off"
        -ex "target remote ${HOST}:${GDB_PORT}"
    )

    if ((RESET_TARGET != 0)); then
        log_info "Resetting and resuming target through GDB."
        gdb_args+=(-ex "monitor reset")
    else
        log_info "Resuming target through GDB."
    fi

    gdb_args+=(
        -ex "monitor go"
        -ex "detach"
        -ex "quit"
    )

    if ! "${GDB}" "${gdb_args[@]}" > "${GDB_LOG_FILE}" 2>&1; then
        if [[ -s "${GDB_LOG_FILE}" ]]; then
            log_error "GDB resume log:"
            sed -n '1,160p' "${GDB_LOG_FILE}" >&2
        fi
        die "Failed to resume target through GDB." \
            "Check the GDB resume log above." \
            "Or skip resume: --no-resume"
    fi
}

handle_rtt_line() {
    local line="$1"

    printf '%s\n' "${line}"
    if [[ -n "${RTT_OUT_FILE}" ]]; then
        printf '%s\n' "${line}" >> "${RTT_OUT_FILE}"
    fi

    if [[ -n "${RTT_MATCH_PATTERN}" && "${line}" == *"${RTT_MATCH_PATTERN}"* ]]; then
        return 10
    fi

    return 0
}

connect_rtt_stream() {
    log_info "Connecting to RTT telnet port ${HOST}:${RTT_PORT}."
    log_hint "Streaming until interrupted. To stop, send SIGINT (Ctrl+C or kill -INT <pid>)."
    "${NC}" "${HOST}" "${RTT_PORT}"
}

connect_rtt_until_match() {
    local tmp_dir fifo nc_pid line matched=0
    local deadline=$((SECONDS + RTT_MATCH_TIMEOUT))

    tmp_dir="$(mktemp -d /tmp/jlink_rtt.XXXXXX)"
    fifo="${tmp_dir}/rtt.fifo"
    mkfifo "${fifo}"

    log_info "Connecting to RTT telnet port ${HOST}:${RTT_PORT}; waiting for match: ${RTT_MATCH_PATTERN}"
    "${NC}" "${HOST}" "${RTT_PORT}" > "${fifo}" &
    nc_pid=$!
    # Keep the FIFO open on one fd; reopening it for each read can drop buffered lines.
    exec 3< "${fifo}"

    while ((SECONDS < deadline)); do
        if IFS= read -r -t 1 line <&3; then
            set +e
            handle_rtt_line "${line}"
            line_status=$?
            set -e
            if ((line_status == 10)); then
                matched=1
                break
            fi
        elif ! kill -0 "${nc_pid}" 2>/dev/null; then
            break
        fi
    done

    kill "${nc_pid}" 2>/dev/null || true
    wait "${nc_pid}" 2>/dev/null || true
    exec 3<&-
    rm -rf "${tmp_dir}"

    if ((matched != 0)); then
        log_info "Matched RTT pattern: ${RTT_MATCH_PATTERN}"
        return 0
    fi

    die "Timed out waiting for RTT pattern after ${RTT_MATCH_TIMEOUT}s: ${RTT_MATCH_PATTERN}" \
        "Check the RTT output above for what was captured." \
        "Or extend the timeout: --match-timeout 60" \
        "Or re-run without --match and without timeout to stream continuously, stop with SIGINT."
}

connect_rtt() {
    local nc_status=0

    if [[ -n "${RTT_MATCH_PATTERN}" ]]; then
        connect_rtt_until_match
        return 0
    fi

    if [[ -n "${RTT_OUT_FILE}" ]]; then
        set +e
        connect_rtt_stream | tee -a "${RTT_OUT_FILE}"
        nc_status=${PIPESTATUS[0]}
        set -e
    else
        set +e
        connect_rtt_stream
        nc_status=$?
        set -e
    fi

    if ((nc_status != 0)); then
        log_warn "RTT connection closed with status ${nc_status}."
    fi

    return "${nc_status}"
}

print_config() {
    cat <<EOF
CONFIG_FILE=${config_loaded:-}
PROJECT_ROOT=${PROJECT_ROOT:-}
EOF
    [[ -n "${JLINK_GDB_SERVER}" ]] && printf 'JLINK_GDB_SERVER=%s\n' "${JLINK_GDB_SERVER}"
    [[ -n "${GDB}" ]] && printf 'GDB=%s\n' "${GDB}"
    [[ -n "${NC}" ]] && printf 'NC=%s\n' "${NC}"
    cat <<EOF
HOST=${HOST}
DEVICE=${DEVICE}
JLINK_IF=${JLINK_IF}
SPEED=${SPEED}
JLINK_SERIAL=${JLINK_SERIAL}
GDB_PORT=${GDB_PORT}
RTT_PORT=${RTT_PORT}
RTT_READY_TIMEOUT=${READY_TIMEOUT}
LOG_FILE=${LOG_FILE}
GDB_LOG_FILE=${GDB_LOG_FILE}
RTT_OUT_FILE=${RTT_OUT_FILE}
RTT_MATCH_PATTERN=${RTT_MATCH_PATTERN}
RTT_MATCH_TIMEOUT=${RTT_MATCH_TIMEOUT}
RESET_TARGET=${RESET_TARGET}
RESUME_TARGET=${RESUME_TARGET}
EOF
}

main() {
    parse_pre_config_args "$@"
    PROJECT_ROOT="$(resolve_project_root)"

    if [[ -n "${CONFIG_FILE}" ]]; then
        load_config_file "${CONFIG_FILE}"
    else
        if CONFIG_FILE="$(find_default_config "${PROJECT_ROOT}")"; then
            load_config_file "${CONFIG_FILE}"
        fi
    fi

    parse_args "$@"

    # --init mode: write config and exit.
    if ((INIT_MODE != 0)); then
        if [[ -z "${CONFIG_FILE}" ]]; then
            CONFIG_FILE="${PROJECT_ROOT}/.jlink-rtt.env"
        fi
        do_init "${CONFIG_FILE}"
        exit 0
    fi

    # Print config before tool detection to make dry config checks independent of host setup.
    if ((PRINT_CONFIG != 0)); then
        print_config
        exit 0
    fi

    # --stop: kill JLinkGDBServer for this project's ports, causing nc to exit cleanly.
    if ((RTT_STOP != 0)); then
        local pid_file="/tmp/jlink_rtt_$(basename "${PROJECT_ROOT}").pid"
        rm -f "${pid_file}"
        if pkill -f "JLinkGDBServerCLExe.*-port ${GDB_PORT}.*-RTTTelnetPort ${RTT_PORT}" 2>/dev/null || \
           pkill -f "JLinkGDBServer.*-port ${GDB_PORT}.*-RTTTelnetPort ${RTT_PORT}" 2>/dev/null; then
            log_info "Stop signal sent to RTT session (port ${RTT_PORT})."
            exit 0
        fi
        log_warn "No running RTT session found for this project."
        exit 1
    fi

    # No config and no --device: output actionable instructions for AI.
    if [[ -z "${DEVICE}" ]]; then
        log_info "No .jlink-rtt.env found and no --device given."
        log_hint "Scan the project for the DEVICE name (SEGGER device string, e.g. NRF52840_XXAA)."
        log_hint "If not found, ask the user for the DEVICE name, then run:"

        # Auto-detect J-Link serial and build a complete --init command with all params visible.
        detect_serial
        local init_cmd="${0} --init --device <DEVICE>"
        init_cmd+=" --if ${JLINK_IF}"
        init_cmd+=" --speed ${SPEED}"
        init_cmd+=" --host ${HOST}"
        init_cmd+=" --gdb-port ${GDB_PORT}"
        init_cmd+=" --rtt-port ${RTT_PORT}"
        init_cmd+=" --timeout ${READY_TIMEOUT}"
        init_cmd+=" --log ${LOG_FILE}"
        init_cmd+=" --gdb-log ${GDB_LOG_FILE}"

        if [[ -n "${DETECTED_SERIAL}" ]]; then
            init_cmd+=" --serial ${DETECTED_SERIAL}"
            log_hint "  ${init_cmd}"
        else
            # Check if multiple probes found.
            local probe_count
            probe_count="$(lsusb -v -d 1366: 2>/dev/null | grep -i 'iSerial' | awk '{print $3}' | sort -u | grep -c . || true)" || true
            if ((probe_count > 1)); then
                log_hint "Multiple J-Link probes detected. Ask the user which serial to use, then run:"
                log_hint "  ${init_cmd} --serial <SERIAL>"
                log_hint "Available serials:"
                lsusb -v -d 1366: 2>/dev/null | grep -i 'iSerial' | awk '{print $3}' | sort -u | while read -r s; do
                    log_hint "  ${s}"
                done
            else
                log_hint "  ${init_cmd}"
            fi
        fi

        log_hint "Review all parameters above before executing. If the project uses a different interface (e.g. JTAG), adjust --if."
        exit 0
    fi

    detect_tools
    validate_config
    prepare_logs

    # USB check before hardware access.
    if ! lsusb 2>/dev/null | grep -qiE "SEGGER|J-Link|1366"; then
        log_warn "No SEGGER/J-Link USB device detected."
        log_hint "Ask the user to check: USB connection, permissions, or USB passthrough."
        log_hint "If using a remote J-Link, this warning can be ignored."
    fi

    ensure_port_free "${GDB_PORT}" "GDB"
    ensure_port_free "${RTT_PORT}" "RTT"

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    # Write PID file after traps are armed so a die() in pre-flight checks can't leave a stale file.
    echo $$ > "/tmp/jlink_rtt_$(basename "${PROJECT_ROOT}").pid"

    start_gdb_server
    wait_for_port "${GDB_PORT}" "GDB"
    resume_target
    wait_for_port "${RTT_PORT}" "RTT"
    connect_rtt
}

main "$@"
