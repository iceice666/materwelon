#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3Packages.pyserial
"""Send a command over serial and print the response.

Usage: send.py <port> <baud> <command>
"""
import serial
import sys
import time

port, baud, cmd = sys.argv[1], int(sys.argv[2]), sys.argv[3]

with serial.Serial(port, baud, timeout=1) as s:
    # Flush any partial line left by a previous session (e.g. probe bytes
    # without a terminating newline).  Send \r\n, wait briefly, discard
    # the response (could be an empty-line echo or a stale-byte error).
    s.reset_input_buffer()
    s.write(b"\r\n")
    time.sleep(0.15)
    s.reset_input_buffer()
    s.write((cmd + "\r\n").encode())
    time.sleep(0.4)
    sys.stdout.buffer.write(s.read(512))
