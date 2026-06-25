---
name: jlink-rtt
description: Read and validate SEGGER J-Link RTT logs with RTT project config, reset/attach modes, pattern matching, and troubleshooting.
---

# J-Link RTT

## Quick Path

**Run the script first — do not explore the project, read config files, or check for `.jlink-rtt.env` before running.** The script does all of that internally and tells you exactly what to do next.

Use `scripts/jlink_rtt.sh`; do not rewrite JLinkGDBServer/GDB/nc orchestration.

Always run from the target project root. Two modes:

**Timed capture** — auto-stop after N seconds, suitable for quick log collection:

```bash
JLINK_RTT_SCRIPT="<loaded-skill-base>/scripts/jlink_rtt.sh"
RTT_LOG="/tmp/$(basename "$PWD")_rtt.log"
timeout 12 "${JLINK_RTT_SCRIPT}" --out "${RTT_LOG}"   # adjust 12s as needed
echo "exit=$?"
echo "log=${RTT_LOG}"
```

**Continuous stream** — no timeout, runs until stopped. Use when you need to observe a full boot sequence or wait for an event that may take longer than the timeout. Stop by running `--stop` from another shell:

```bash
"${JLINK_RTT_SCRIPT}" --out "${RTT_LOG}" &    # start streaming
# ... observe or interact with the device ...
"${JLINK_RTT_SCRIPT}" --stop                   # kill JLinkGDBServer → nc exits cleanly
echo "log=${RTT_LOG}"
```

The script handles all pre-flight checks internally. Its output is self-contained: every `[ERROR]` line is followed by `[INFO]` lines describing what to do next — follow them directly, no lookup or translation needed.

- **Do not read project files, check for `.jlink-rtt.env`, or run `lsusb` before running the script.** Just run it and respond to the output.
- Use the loaded skill base path directly; do not list the scripts directory to verify it or guess another install path.
- When the script exits 0 with `[INFO]` instructions (e.g. no config found), follow the instructions: scan the project for the requested value, ask the user if not found, then run the command it prints.
- When the script exits non-zero, read the `[ERROR]` + `[INFO]` lines and relay them to the user as the next action.

## Commands

```bash
"${JLINK_RTT_SCRIPT}"                                # reset, resume, stream RTT
"${JLINK_RTT_SCRIPT}" --no-reset                     # attach without reset
"${JLINK_RTT_SCRIPT}" --no-resume                    # do not issue GDB reset/go
"${JLINK_RTT_SCRIPT}" --init --device NRF52840_XXAA  # create .jlink-rtt.env
"${JLINK_RTT_SCRIPT}" --init --device nrf52840       # fuzzy name → auto-resolved via J-Link DB
"${JLINK_RTT_SCRIPT}" --search-device nrf52          # search J-Link device database
"${JLINK_RTT_SCRIPT}" --match "Application started" --match-timeout 30  # exit after pattern found
"${JLINK_RTT_SCRIPT}" --stop                        # stop running RTT session
"${JLINK_RTT_SCRIPT}" --print-config                # print resolved config
"$(dirname "${JLINK_RTT_SCRIPT}")/jlink_rtt_no_hardware_test.sh"        # run self-test
```

## Options

| Option | Description |
|--------|-------------|
| `--config FILE` | Load explicit `.jlink-rtt.env` file |
| `--project-root DIR` | Limit config search to this project root |
| `--init` | Create `.jlink-rtt.env` with current settings and exit |
| `--device DEVICE` | J-Link target device; accepts fuzzy names (e.g. `nrf52840`) — auto-resolved via J-Link database |
| `--search-device PATTERN` | Search J-Link device database for PATTERN (case-insensitive) |
| `--if INTERFACE` | J-Link interface, default: SWD |
| `--speed KHZ` | J-Link speed in kHz, default: 4000 |
| `--serial SERIAL` | J-Link serial number |
| `--host HOST` | Local host for GDB/RTT ports, default: 127.0.0.1 |
| `--gdb-port PORT` | GDB server port, default: 2331 |
| `--rtt-port PORT` | RTT telnet port, default: 19021 |
| `--timeout SECONDS` | Port ready timeout, default: 10 |
| `--log FILE` | JLinkGDBServer log file |
| `--gdb-log FILE` | GDB resume log file |
| `--out FILE` | Save RTT output to file while streaming |
| `--match PATTERN` | Exit 0 after this fixed text appears in RTT output |
| `--match-timeout SEC` | Timeout for `--match`, default: 30 |
| `--no-reset` | Do not reset the target before reading RTT |
| `--no-resume` | Do not connect GDB to resume the target |
| `--stop` | Kill JLinkGDBServer for current project; used from another shell to stop continuous stream |
| `--jlink-gdb-server CMD` | Override auto-detected JLinkGDBServer command |
| `--gdb CMD` | Override auto-detected GDB command |
| `--nc CMD` | Override auto-detected nc command |

## Device Name Resolution

`--init --device` accepts fuzzy names (e.g. `nrf52840`, `stm32f407`). The script queries the J-Link device database via `JLinkExe ExpDevList` (no hardware needed) and auto-resolves:

- **Unique match** → uses the exact device name (e.g. `nrf52840` → `nRF52840_xxAA`)
- **Multiple matches** → prints all candidates as `[INFO]` hints, exits non-zero
- **No match** → prints `[ERROR]` + `[INFO]` with search suggestions
- **JLinkExe unavailable** → keeps the original name as-is (silent fallback)

Use `--search-device <pattern>` to browse the database interactively.
