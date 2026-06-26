---
name: jlink-rtt
description: Read SEGGER J-Link RTT logs with RTT project config, reset/attach modes, pattern matching, and troubleshooting.
---

# J-Link RTT

## Quick Path

**Run the script first — The script does all and tells you exactly what to do next**

Use `scripts/jlink_rtt.sh`; do not rewrite JLinkGDBServer/JLinkExe/nc orchestration.

- **AI Tip**: When observing `RTT_LOG`, prefer using your own read/grep/search tools to inspect, filter or browse the log. Do not simply `cat` the entire file to avoid token overflow.

Always run from the target project root. Three modes:

```bash
JLINK_RTT_SCRIPT="<loaded-skill-base>/scripts/jlink_rtt.sh"
RTT_LOG="/tmp/$(basename "$PWD")_rtt.log"
```

**Timed capture** — auto-stop after N(+3) seconds, suitable for quick log collection:

```bash
timeout 12 "${JLINK_RTT_SCRIPT}" --out "${RTT_LOG}"   # adjust 12s as needed
echo "exit=$?"
echo "log=${RTT_LOG}"
```

**Pattern-triggered capture** — exit when a specific pattern appears in RTT output:

```bash
"${JLINK_RTT_SCRIPT}" --out "${RTT_LOG}" --match "Application started" --match-timeout 30
echo "exit=$?"
echo "log=${RTT_LOG}"
```

**Continuous stream** — no timeout, runs until stopped. Stop by running `--stop` from another shell:

**Start (AI-Friendly & Non-blocking):**
```bash
# Start in background via double-fork to prevent hanging, write logs to startup.log
( "\${JLINK_RTT_SCRIPT}" --out "\${RTT_LOG}" > "/tmp/jlink_rtt_startup.log" 2>&1 & )

# Wait 1s and print startup log to verify if it started successfully (e.g. catch uninitialized config errors)
sleep 1
cat "/tmp/jlink_rtt_startup.log"

# Read RTT_LOG periodically to observe output
echo "\${RTT_LOG}"  # or use read file tools, repeat as needed
```

**Stop:**
```bash
"${JLINK_RTT_SCRIPT}" --stop
echo "log=${RTT_LOG}"
```

The script handles all pre-flight checks internally. Its output is self-contained: every `[ERROR]` line is followed by `[INFO]` lines describing what to do next — follow them directly, no lookup or translation needed.

- **Do not read project files, check for `.jlink-rtt.env`, or run `lsusb` before running the script.** Just run it and respond to the output.
- Use the loaded skill base path directly; do not list the scripts directory to verify it or guess another install path.
- When the script exits 0 with `[INFO]` instructions (e.g. no config found), follow the instructions: scan the project for the requested value, ask the user if not found, then run the command it prints.
- When the script exits non-zero, read the `[ERROR]` + `[INFO]` lines and relay them to the user as the next action.
- For all options: `${JLINK_RTT_SCRIPT} --help`

## Device Name Resolution

`--init --device` accepts fuzzy names (e.g. `nrf52840`, `stm32f407`). The script queries the J-Link device database via `JLinkExe ExpDevList` (no hardware needed) and auto-resolves:

- **Unique match** → uses the exact device name (e.g. `nrf52840` → `nRF52840_xxAA`)
- **Multiple matches** → prints all candidates as `[INFO]` hints, exits non-zero
- **No match** → prints `[ERROR]` + `[INFO]` with search suggestions
- **JLinkExe unavailable** → keeps the original name as-is (silent fallback)

Use `--search-device <pattern>` to browse the database interactively.