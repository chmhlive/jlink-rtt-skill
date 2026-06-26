# J-Link RTT Skill

SEGGER J-Link RTT log reader skill for AI coding agents. Read and validate RTT logs with project config, reset/attach modes, pattern matching, and troubleshooting.

## Quick Start

```bash
# Timed capture (auto-stop after N seconds)
JLINK_RTT_SCRIPT="./scripts/jlink_rtt.sh"
RTT_LOG="/tmp/$(basename "$PWD")_rtt.log"
timeout 12 "${JLINK_RTT_SCRIPT}" --out "${RTT_LOG}"

# Pattern-triggered capture (exit when pattern found)
"${JLINK_RTT_SCRIPT}" --out "${RTT_LOG}" --match "Application started" --match-timeout 30

# Continuous stream (AI-Friendly & Non-blocking)
( "${JLINK_RTT_SCRIPT}" --out "${RTT_LOG}" > "/tmp/jlink_rtt_startup.log" 2>&1 & )
sleep 1
cat "/tmp/jlink_rtt_startup.log"  # Verify if it started successfully
# ... observe or interact with the device (AI: use read/grep/search tools to check RTT_LOG) ...
"${JLINK_RTT_SCRIPT}" --stop
```

## Script Hints

The script outputs `[ERROR]` + `[INFO]` hints for different scenarios. Follow them directly.

**No config and no device:**
```
[INFO] No .jlink-rtt.env found and no --device given.
[INFO] Scan the project for the DEVICE name (e.g. NRF52840_XXAA).
[INFO] Use --search-device to confirm the exact name:
[INFO]   ./scripts/jlink_rtt.sh --search-device <pattern>
[INFO] Then run:
[INFO]   ./scripts/jlink_rtt.sh --init --device <DEVICE> --if SWD --speed 4000 ...
```

**No device matches:**
```
[ERROR] No J-Link device matches 'nrf52840'.
[INFO] Try a broader pattern, e.g. 'nrf52' instead of 'nrf52840'.
[INFO] Or confirm the exact name: ./scripts/jlink_rtt.sh --search-device <pattern>
```

**Multiple matches:**
```
[ERROR] Multiple J-Link devices match 'stm32f407' (6 found).
[INFO] Pick the correct device from the list below and re-run with --device <EXACT_NAME>:
[INFO]   ST | STM32F407IG
[INFO]   ST | STM32F407VG
[INFO]   ...
```

**Pattern-triggered timeout:**
```
[ERROR] Timed out waiting for RTT pattern after 30s: Application started
[INFO] Check the RTT output above for what was captured.
[INFO] Or extend the timeout: --match-timeout 60
[INFO] Or re-run without --match and without timeout to stream continuously, stop with SIGINT.
```

## Options

| Option | Description |
|--------|-------------|
| `--config FILE` | Load explicit `.jlink-rtt.env` file |
| `--project-root DIR` | Limit config search to this project root |
| `--init` | Create `.jlink-rtt.env` with current settings |
| `--device DEVICE` | J-Link target device; accepts fuzzy names (e.g. `nrf52840`) |
| `--search-device PATTERN` | Search J-Link device database for PATTERN |
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
| `--stop` | Kill JLinkGDBServer for current project |
| `--jlink-gdb-server CMD` | Override auto-detected JLinkGDBServer |
| `--gdb CMD` | Override auto-detected GDB |
| `--nc CMD` | Override auto-detected nc |

## Requirements

### Runtime Environment

- **OS**: Linux (tested on Ubuntu 20.04+), macOS (untested but should work with compatible tools)
- **Shell**: Bash 4.0+
- **Hardware**: SEGGER J-Link debug probe connected via USB (required for real capture; self-test runs without hardware)

### Dependencies

| Tool | Required | Auto-detected candidates |
|------|----------|--------------------------|
| `JLinkGDBServer` | Yes | `JLinkGDBServer`, `JLinkGDBServerCLExe` |
| `gdb` | Yes (for reset/resume) | `gdb-multiarch`, `arm-none-eabi-gdb`, `gdb` |
| `nc` (netcat) | Yes | `nc`, `ncat` |
| `lsusb` | Optional (for USB detection) | system default |

Install SEGGER J-Link Software from [SEGGER Downloads](https://www.segger.com/downloads/jlink/).

For ARM embedded targets, install the ARM toolchain:

```bash
# Ubuntu/Debian
sudo apt install gdb-multiarch netcat-openbsd

# macOS
brew install arm-none-eabi-gdb netcat
```

### Project Config

Create a `.jlink-rtt.env` in your project root:

```bash
./scripts/jlink_rtt.sh --init --device NRF52840_XXAA
```

This generates a config file with default ports and settings. The script auto-discovers `.jlink-rtt.env` by searching upward from the current directory (within the git worktree or `--project-root`).

## License

MIT
