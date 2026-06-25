# J-Link RTT Skill

SEGGER J-Link RTT log reader skill for AI coding agents. Read and validate RTT logs with project config, reset/attach modes, pattern matching, and troubleshooting.

## Quick Start

```bash
# Timed capture (auto-stop after N seconds)
JLINK_RTT_SCRIPT="./scripts/jlink_rtt.sh"
RTT_LOG="/tmp/$(basename "$PWD")_rtt.log"
timeout 12 "${JLINK_RTT_SCRIPT}" --out "${RTT_LOG}"

# Continuous stream
"${JLINK_RTT_SCRIPT}" --out "${RTT_LOG}" &
# ... observe or interact with the device ...
"${JLINK_RTT_SCRIPT}" --stop
```

## Commands

| Command | Description |
|---------|-------------|
| `jlink_rtt.sh` | Reset, resume, stream RTT |
| `jlink_rtt.sh --no-reset` | Attach without reset |
| `jlink_rtt.sh --no-resume` | Do not issue GDB reset/go |
| `jlink_rtt.sh --init --device NRF52840_XXAA` | Create `.jlink-rtt.env` |
| `jlink_rtt.sh --match "Application started" --match-timeout 30` | Exit after pattern found |
| `jlink_rtt.sh --stop` | Stop running RTT session |
| `jlink_rtt.sh --print-config` | Print resolved config |
| `jlink_rtt_no_hardware_test.sh` | Run self-test (no hardware required) |

## Options

| Option | Description |
|--------|-------------|
| `--config FILE` | Load explicit `.jlink-rtt.env` file |
| `--project-root DIR` | Limit config search to this project root |
| `--init` | Create `.jlink-rtt.env` with current settings |
| `--device DEVICE` | J-Link target device (e.g. NRF52840_XXAA) |
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
