#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "${TMP_DIR}"
    # Kill any left-behind fake server from --stop test.
    kill "${FAKE_JLINK_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT

dump_debug() {
    local status=$?

    if ((status != 0)); then
        printf '[ERROR] Test failed with status %s\n' "${status}" >&2
        for file in \
            "${TMP_DIR}/rtt_output.log" \
            "${TMP_DIR}/captured_rtt.log" \
            "${TMP_DIR}/jlink.log" \
            "${TMP_DIR}/gdb.log" \
            "${TMP_DIR}/print_config.log" \
            "${TMP_DIR}/env_ignored.log" \
            "${TMP_DIR}/no_config.log" \
            "${TMP_DIR}/init_output.log" \
            "${TMP_DIR}/existing_init_output.log" \
            "${TMP_DIR}/no_config_output.log" \
            "${TMP_DIR}/no_config_serial_output.log" \
            "${TMP_DIR}/no_probe_output.log" \
            "${TMP_DIR}/capture_ok_output.log" \
            "${TMP_DIR}/stop_output.log"; do
            if [[ -f "${file}" ]]; then
                printf '\n--- %s ---\n' "${file}" >&2
                sed -n '1,160p' "${file}" >&2
            fi
        done
    fi

    cleanup
    exit "${status}"
}
trap dump_debug EXIT

log_info() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

mkdir -p "${TMP_DIR}/bin" "${TMP_DIR}/project/subdir"

# Fake host tools let the test cover orchestration without USB/J-Link hardware.
cat > "${TMP_DIR}/bin/JLinkGDBServer" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

printf '%s\n' "$*" > "${JLINK_RTT_TEST_TMP}/jlink_args"
touch "${JLINK_RTT_TEST_TMP}/server_started"

cleanup_srv() {
    rm -f "${JLINK_RTT_TEST_TMP}/server_started"
    exit 0
}
trap cleanup_srv TERM INT

while true; do
    sleep 1
done
EOF

cat > "${TMP_DIR}/bin/gdb-multiarch" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

printf '%s\n' "$*" > "${JLINK_RTT_TEST_TMP}/gdb_args"
exit 0
EOF

cat > "${TMP_DIR}/bin/nc" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == "-z" ]]; then
    if [[ -f "${JLINK_RTT_TEST_TMP}/server_started" ]]; then
        exit 0
    fi
    exit 1
fi

printf 'boot line\nApplication started\n'
exit 0
EOF

chmod +x "${TMP_DIR}/bin/JLinkGDBServer" "${TMP_DIR}/bin/gdb-multiarch" "${TMP_DIR}/bin/nc"

# Fake JLinkExe for device database resolution (used by --init fuzzy matching).
cat > "${TMP_DIR}/bin/JLinkExe" <<'JLEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "-NoGui" ]]; then
    printf 'SEGGER J-Link Commander V9.99a (Compiled Jan 1 2026 00:00:00)\n'
    if [[ "${*}" == *"/dev/null"* ]]; then
        exit 0
    fi
    # Parse -CommandFile to find the script, then extract ExpDevList target path.
    cmd_file=""
    for arg in "$@"; do
        if [[ "${arg}" == "-CommandFile" ]]; then continue; fi
        if [[ -f "${arg}" ]]; then cmd_file="${arg}"; break; fi
    done
    if [[ -n "${cmd_file}" ]]; then
        csv_path="$(sed -n 's/^ExpDevList[[:space:]]\+//p' "${cmd_file}" | head -1)"
        if [[ -n "${csv_path}" ]]; then
            cat > "${csv_path}" <<CSV
"Manufacturer", "Device", "Core", {Flash areas}, {RAM areas}
"Nordic Semi", "nRF52840_xxAA", "Cortex-M4", { {0x00000000, 0x00100000} }, {0x20000000, 0x00040000}
"Nordic Semi", "nRF52833_xxAA", "Cortex-M4", { {0x00000000, 0x00080000} }, {0x20000000, 0x00020000}
"Nordic Semi", "nRF52832_xxAA", "Cortex-M4", { {0x00000000, 0x00080000} }, {0x20000000, 0x00010000}
"ST", "STM32F407IG", "Cortex-M4", { {0x08000000, 0x00100000} }, {0x20000000, 0x00020000}
"ST", "STM32F407VG", "Cortex-M4", { {0x08000000, 0x00100000} }, {0x20000000, 0x00020000}
"ST", "STM32F407ZE", "Cortex-M4", { {0x08000000, 0x00080000} }, {0x20000000, 0x00020000}
CSV
        fi
    fi
fi
exit 0
JLEOF
chmod +x "${TMP_DIR}/bin/JLinkExe"

cat > "${TMP_DIR}/project/.jlink-rtt.env" <<EOF
DEVICE=NRF52840_XXAA
JLINK_IF=SWD
SPEED=4000
HOST=127.0.0.1
GDB_PORT=32331
RTT_PORT=39021
RTT_READY_TIMEOUT=2
LOG_FILE=${TMP_DIR}/jlink.log
GDB_LOG_FILE=${TMP_DIR}/gdb.log
EOF

OUTPUT_FILE="${TMP_DIR}/rtt_output.log"
OUT_FILE="${TMP_DIR}/captured_rtt.log"

(
    cd "${TMP_DIR}/project/subdir"
    JLINK_RTT_TEST_TMP="${TMP_DIR}" \
    PATH="${TMP_DIR}/bin:${PATH}" \
    "${SCRIPT_DIR}/jlink_rtt.sh" \
        --project-root "${TMP_DIR}/project" \
        --match "Application started" \
        --match-timeout 3 \
        --out "${OUT_FILE}" \
        > "${OUTPUT_FILE}" 2>&1
)

grep -Fq 'Application started' "${OUTPUT_FILE}" || fail "RTT output was not forwarded."
grep -Fq 'Application started' "${OUT_FILE}" || fail "RTT output was not saved."
grep -Fq -- '-device NRF52840_XXAA' "${TMP_DIR}/jlink_args" || fail "JLink device argument is missing."
grep -Fq -- '-RTTTelnetPort 39021' "${TMP_DIR}/jlink_args" || fail "RTT port argument is missing."
grep -Fq -- 'target remote 127.0.0.1:32331' "${TMP_DIR}/gdb_args" || fail "GDB target argument is missing."
grep -Fq -- 'monitor reset' "${TMP_DIR}/gdb_args" || fail "GDB reset command is missing."
grep -Fq -- 'monitor go' "${TMP_DIR}/gdb_args" || fail "GDB resume command is missing."

PRINT_CONFIG="${TMP_DIR}/print_config.log"
(
    cd "${TMP_DIR}/project/subdir"
    JLINK_RTT_TEST_TMP="${TMP_DIR}" \
    PATH="${TMP_DIR}/bin:${PATH}" \
    DEVICE=ENV_DEVICE \
    "${SCRIPT_DIR}/jlink_rtt.sh" \
        --project-root "${TMP_DIR}/project" \
        --print-config \
        --device CLI_DEVICE \
        > "${PRINT_CONFIG}" 2>&1
)

grep -Fq 'CONFIG_FILE='"${TMP_DIR}"'/project/.jlink-rtt.env' "${PRINT_CONFIG}" || fail "Config file was not discovered within project root."
grep -Fq 'DEVICE=CLI_DEVICE' "${PRINT_CONFIG}" || fail "Command line did not override config."

# DEVICE=ENV_DEVICE is intentional: RTT settings must not be overridden by env vars.
ENV_IGNORED="${TMP_DIR}/env_ignored.log"
(
    cd "${TMP_DIR}/project/subdir"
    PATH="${TMP_DIR}/bin:${PATH}" \
    DEVICE=ENV_DEVICE \
    "${SCRIPT_DIR}/jlink_rtt.sh" \
        --project-root "${TMP_DIR}/project" \
        --print-config \
        > "${ENV_IGNORED}" 2>&1
)

grep -Fq 'DEVICE=NRF52840_XXAA' "${ENV_IGNORED}" || fail "Config DEVICE was not used."
if grep -Fq 'DEVICE=ENV_DEVICE' "${ENV_IGNORED}"; then
    fail "Environment DEVICE unexpectedly overrode config."
fi

mkdir -p "${TMP_DIR}/outside/subdir"
cat > "${TMP_DIR}/outside/.jlink-rtt.env" <<EOF
DEVICE=SHOULD_NOT_LOAD
EOF

# Non-git directories only check the current directory unless --project-root is explicit.
NO_CONFIG="${TMP_DIR}/no_config.log"
(
    cd "${TMP_DIR}/outside/subdir"
    PATH="${TMP_DIR}/bin:${PATH}" \
    "${SCRIPT_DIR}/jlink_rtt.sh" --print-config > "${NO_CONFIG}" 2>&1
)

if grep -Fq 'DEVICE=SHOULD_NOT_LOAD' "${NO_CONFIG}"; then
    fail "Non-git search escaped current directory without an explicit project root."
fi

# --- --init mode ---
INIT_DIR="${TMP_DIR}/init_project"
mkdir -p "${INIT_DIR}"
INIT_CONFIG="${INIT_DIR}/.jlink-rtt.env"
INIT_OUT="${TMP_DIR}/init_output.log"

(
    cd "${INIT_DIR}"
    PATH="${TMP_DIR}/bin:${PATH}" \
    "${SCRIPT_DIR}/jlink_rtt.sh" \
        --project-root "${INIT_DIR}" \
        --init \
        --device NRF52840_XXAA \
        > "${INIT_OUT}" 2>&1
)

grep -Fq 'DEVICE=nRF52840_xxAA' "${INIT_CONFIG}" || fail "--init did not write DEVICE."
grep -Fq 'JLINK_IF=SWD' "${INIT_CONFIG}" || fail "--init did not write JLINK_IF."
grep -Fq 'SPEED=4000' "${INIT_CONFIG}" || fail "--init did not write SPEED."
grep -Fq 'Created config:' "${INIT_OUT}" || fail "--init did not print config created message."
grep -Fq 'Config created. Now run the capture command again:' "${INIT_OUT}" || fail "--init did not print next-step hint."

# --- no-config message ---
NO_CFG_DIR="${TMP_DIR}/no_config_project"
mkdir -p "${NO_CFG_DIR}"
NO_CFG_OUT="${TMP_DIR}/no_config_output.log"

(
    cd "${NO_CFG_DIR}"
    PATH="${TMP_DIR}/bin:${PATH}" \
    "${SCRIPT_DIR}/jlink_rtt.sh" \
        --project-root "${NO_CFG_DIR}" \
        > "${NO_CFG_OUT}" 2>&1
)

grep -Fq 'No .jlink-rtt.env found' "${NO_CFG_OUT}" || fail "No-config did not print missing config message."
grep -Fq 'Scan the project for the DEVICE name' "${NO_CFG_OUT}" || fail "No-config did not print scan-project hint."
grep -Fq -- '--init --device' "${NO_CFG_OUT}" || fail "No-config did not print --init command hint."
grep -Fq -- '--if SWD' "${NO_CFG_OUT}" || fail "No-config did not include --if in init command."
grep -Fq -- '--speed 4000' "${NO_CFG_OUT}" || fail "No-config did not include --speed in init command."
grep -Fq -- '--gdb-port' "${NO_CFG_OUT}" || fail "No-config did not include --gdb-port in init command."
grep -Fq -- '--rtt-port' "${NO_CFG_OUT}" || fail "No-config did not include --rtt-port in init command."
grep -Fq 'Review all parameters above before executing' "${NO_CFG_OUT}" || fail "No-config did not print review hint."

# --- no-config with single J-Link probe (auto-detect serial) ---
cat > "${TMP_DIR}/bin/lsusb" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then
    printf 'Bus 001 Device 004: ID 1366:1024 SEGGER J-Link\n'
    printf '  iSerial                 3 000683041131\n'
    exit 0
fi
printf 'Bus 001 Device 004: ID 1366:1024 SEGGER J-Link\n'
exit 0
EOF
chmod +x "${TMP_DIR}/bin/lsusb"

NO_CFG_SERIAL_OUT="${TMP_DIR}/no_config_serial_output.log"
(
    cd "${NO_CFG_DIR}"
    PATH="${TMP_DIR}/bin:${PATH}" \
    "${SCRIPT_DIR}/jlink_rtt.sh" \
        --project-root "${NO_CFG_DIR}" \
        > "${NO_CFG_SERIAL_OUT}" 2>&1
)

grep -Fq -- '--serial 000683041131' "${NO_CFG_SERIAL_OUT}" || fail "No-config did not auto-detect serial in init command."

# --- no_probe warning (lsusb returns nothing) ---
cat > "${TMP_DIR}/bin/lsusb" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TMP_DIR}/bin/lsusb"

NO_PROBE_OUT="${TMP_DIR}/no_probe_output.log"
(
    cd "${TMP_DIR}/project/subdir"
    JLINK_RTT_TEST_TMP="${TMP_DIR}" \
    PATH="${TMP_DIR}/bin:${PATH}" \
    "${SCRIPT_DIR}/jlink_rtt.sh" \
        --project-root "${TMP_DIR}/project" \
        --match "Application started" \
        --match-timeout 3 \
        > "${NO_PROBE_OUT}" 2>&1
)

grep -Fq 'No SEGGER/J-Link USB device detected' "${NO_PROBE_OUT}" || fail "Missing USB not detected warning."
grep -Fq 'Ask the user to check: USB connection' "${NO_PROBE_OUT}" || fail "Missing USB check hint."

# --- --init with existing config should die with hint ---
EXISTING_INIT_OUT="${TMP_DIR}/existing_init_output.log"
(
    cd "${TMP_DIR}/project/subdir"
    PATH="${TMP_DIR}/bin:${PATH}" \
    "${SCRIPT_DIR}/jlink_rtt.sh" \
        --project-root "${TMP_DIR}/project" \
        --init \
        --device NRF52840_XXAA \
        > "${EXISTING_INIT_OUT}" 2>&1 || true
)
if ! grep -Fq 'Config file already exists' "${EXISTING_INIT_OUT}"; then
    fail "--init on existing config did not report conflict."
fi
grep -Fq -- '--print-config' "${EXISTING_INIT_OUT}" || fail "--init on existing config did not hint --print-config."

# --- capture success (lsusb returns J-Link) ---
cat > "${TMP_DIR}/bin/lsusb" <<'EOF'
#!/usr/bin/env bash
printf 'Bus 001 Device 005: ID 1366:0101 SEGGER J-Link\n'
exit 0
EOF
chmod +x "${TMP_DIR}/bin/lsusb"

CAPTURE_OK_OUT="${TMP_DIR}/capture_ok_output.log"
(
    cd "${TMP_DIR}/project/subdir"
    JLINK_RTT_TEST_TMP="${TMP_DIR}" \
    PATH="${TMP_DIR}/bin:${PATH}" \
    "${SCRIPT_DIR}/jlink_rtt.sh" \
        --project-root "${TMP_DIR}/project" \
        --match "Application started" \
        --match-timeout 3 \
        > "${CAPTURE_OK_OUT}" 2>&1
)

grep -Fq 'Application started' "${CAPTURE_OK_OUT}" || fail "RTT output not captured."

# --- --stop kills running session ---
STOP_OUT="${TMP_DIR}/stop_output.log"

# Start fake JLinkGDBServer in background with matching ports.
JLINK_RTT_TEST_TMP="${TMP_DIR}" PATH="${TMP_DIR}/bin:${PATH}" \
"${TMP_DIR}/bin/JLinkGDBServer" -port 32331 -RTTTelnetPort 39021 &
FAKE_JLINK_PID=$!

# Wait for fake server to be ready (up to 3s).
for _ in $(seq 1 30); do
    [[ -f "${TMP_DIR}/server_started" ]] && break
    sleep 0.1
done

# First --stop should kill the server by port match, exit 0.
(
    cd "${TMP_DIR}/project/subdir"
    PATH="${TMP_DIR}/bin:${PATH}" \
    "${SCRIPT_DIR}/jlink_rtt.sh" \
        --project-root "${TMP_DIR}/project" \
        --gdb-port 32331 \
        --rtt-port 39021 \
        --stop \
        > "${STOP_OUT}" 2>&1
) || fail "--stop failed."

grep -Fq 'Stop signal sent' "${STOP_OUT}" || fail "--stop did not report success."

# Verify the fake server was killed (timeout in case process lingers).
wait_sec=5
while kill -0 "${FAKE_JLINK_PID}" 2>/dev/null; do
    sleep 1
    ((wait_sec--))
    if ((wait_sec <= 0)); then
        fail "--stop should have killed JLinkGDBServer (PID ${FAKE_JLINK_PID})."
    fi
done

# --- --stop on idle session (no matching process) should exit 1 ---
# Ensure no lingering fake server on these ports (defensive; --stop should have killed it).
pkill -f "JLinkGDBServer.*-port 32331.*-RTTTelnetPort 39021" 2>/dev/null || true
# Stale PID file must not cause a false positive; --stop ignores PID file.
echo "$$" > "/tmp/jlink_rtt_project.pid"
(
    cd "${TMP_DIR}/project/subdir"
    PATH="${TMP_DIR}/bin:${PATH}" \
    "${SCRIPT_DIR}/jlink_rtt.sh" \
        --project-root "${TMP_DIR}/project" \
        --gdb-port 32331 \
        --rtt-port 39021 \
        --stop \
        > "${STOP_OUT}" 2>&1
) && fail "--stop on idle session should exit 1." || true

grep -Fq 'No running RTT session' "${STOP_OUT}" || fail "--stop should report no session."
# --stop should have cleaned up the stale PID file.
[[ ! -f "/tmp/jlink_rtt_project.pid" ]] || fail "--stop did not clean up stale PID file."

log_info "J-Link RTT script simulation passed."
