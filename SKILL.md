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

**Continuous stream** — no timeout, runs until stopped. Stop by running `--stop` from another shell:

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
- Device names accept fuzzy input (e.g. `nrf52840` → `nRF52840_xxAA`); the script resolves via J-Link database.
- For all options: `${JLINK_RTT_SCRIPT} --help`
