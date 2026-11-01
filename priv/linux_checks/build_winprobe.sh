#!/bin/sh
set -e
cd "$(dirname "$0")"
zig cc -target x86_64-windows-gnu -O2 -s -Wall -Wl,--subsystem,windows -o winprobe.exe winprobe.c -luser32 -lkernel32 -lgdi32
