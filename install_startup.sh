#!/usr/bin/env bash
# install_startup.sh
# Download the startup.lua raw file into this directory using wget (curl fallback).

set -eu
URL="https://raw.githubusercontent.com/kami-tsuki/cc-atm10-music/main/startup.lua"
OUT="startup.lua"

echo "Installing startup.lua from: $URL"

if command -v wget >/dev/null 2>&1; then
  wget -q --show-progress -O "$OUT" "$URL"
elif command -v curl >/dev/null 2>&1; then
  curl -# -L -o "$OUT" "$URL"
else
  echo "Error: neither wget nor curl is installed on this system." >&2
  exit 1
fi

echo "Downloaded $OUT"
echo "You can now copy this file into your ComputerCraft computer folder or push to your world save as needed."

# Optional: make script executable (startup.lua itself doesn't need exec bit)
chmod 644 "$OUT" || true

exit 0
