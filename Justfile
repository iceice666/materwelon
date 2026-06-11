# materwelon — build, flash, and test pipeline for the RP2350 Mango brick
#
# Prerequisites (all in flake.nix devshell):
#   zig, cmake, gcc-arm-embedded, picocom, python3 + pyserial
#
# Mango brick USB IDs:
#   firmware mode  → CH340 UART bridge  1a86:55d3  (/dev/ttyUSB*)
#   BOOTSEL mode   → RP2350 boot ROM    2e8a:000f  (/dev/disk/by-label/RP2350*)

uf2        := "firmware/build/materwelon.uf2"
baud       := "115200"
probe_py   := "../mangoblock-lite/probe_ports.py"

# ── Private helpers ───────────────────────────────────────────────────────────

# Resolve /dev/ttyUSB* or /dev/ttyACM* for the Mango brick (CH340, 1a86:55d3).
[private]
serial:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build find-port
    exec zig-out/bin/find-port

# Find the RP2350 BOOTSEL block device; waits up to 30 s if not yet present.
[private]
bootsel-dev:
    #!/usr/bin/env bash
    set -euo pipefail
    for i in $(seq 1 30); do
        dev=$(readlink -f /dev/disk/by-label/RP2350 2>/dev/null || true)
        [[ -b "$dev" ]] && echo "$dev" && exit 0
        [[ $i -eq 1 ]] && echo "Waiting for RP2350 BOOTSEL drive — hold BOOTSEL + tap RESET…" >&2
        sleep 1
    done
    echo "ERROR: BOOTSEL drive not found after 30 s." >&2; exit 1

# Mount the BOOTSEL block device with udisksctl; print the mount path.
[private]
do-mount:
    #!/usr/bin/env bash
    set -euo pipefail
    dev=$(just bootsel-dev)
    mp=$(findmnt -rno TARGET "$dev" 2>/dev/null || true)
    if [[ -n "$mp" ]]; then
        echo "$mp"
    else
        udisksctl mount -b "$dev" | awk '{print $NF}' | tr -d '.'
    fi

# ── Public recipes ────────────────────────────────────────────────────────────

# Probe board state (BOOTSEL or firmware mode, serial port, response)
probe:
    python3 {{probe_py}}

# Build RP2350 firmware
build:
    zig build firmware

# Mount the BOOTSEL drive (idempotent; waits up to 30 s for the board)
mount:
    @just do-mount

# Build then flash (put board in BOOTSEL mode before or within 30 s)
flash: build
    #!/usr/bin/env bash
    set -euo pipefail
    mp=$(just do-mount)
    echo "Flashing {{uf2}} → $mp"
    cp "{{uf2}}" "$mp/"
    sync
    echo "Flashed. Board rebooting into firmware…"

# Open an interactive serial terminal (Ctrl-A X to quit)
terminal:
    #!/usr/bin/env bash
    port=$(just serial)
    echo "Connecting to $port at {{baud}} baud  (Ctrl-A X to quit)"
    exec picocom -b "{{baud}}" --imap lfcrlf "$port"

# Send a single command over serial and print the response
send cmd:
    #!/usr/bin/env bash
    set -euo pipefail
    port=$(just serial)
    ./scripts/send.py "$port" {{baud}} "{{cmd}}"

# Test gpio get: configure pin 15 as input then read it
# (avoid GPIO 0/1 — those are UART0 TX/RX)
test-gpio-get:
    @just send "gpio in 15"
    @just send "gpio get 15"
