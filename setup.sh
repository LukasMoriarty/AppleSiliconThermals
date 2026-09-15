#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/bin/apple-silicon-thermals"
ASSET="apple-silicon-thermals-aarch64-linux-musl"
RELEASES_URL="https://github.com/cristim/AppleSiliconThermals/releases/download"
UNIT="applesiliconthermals-curve.service"
FAN_CONTROL_PARAM="/sys/module/macsmc_hwmon/parameters/fan_control"

die() {
  echo "Error: $*" >&2
  exit 1
}

find_macsmc_hwmon() {
  local dir
  for dir in /sys/class/hwmon/hwmon*; do
    if [[ -f "$dir/name" ]] && grep -qx "macsmc_hwmon" "$dir/name" 2>/dev/null; then
      echo "$dir"
      return 0
    fi
  done
  return 1
}

is_apple_silicon() {
  if [[ -f /proc/device-tree/compatible ]] && grep -q "apple," /proc/device-tree/compatible 2>/dev/null; then
    return 0
  fi
  if [[ -f /proc/device-tree/model ]] && grep -q "^Apple" /proc/device-tree/model 2>/dev/null; then
    return 0
  fi
  find_macsmc_hwmon > /dev/null
}

if (( EUID == 0 )); then
  die "run setup.sh as your normal user (no sudo); it asks for sudo when it needs it"
fi
if [[ "$(uname -m)" != "aarch64" ]]; then
  die "this plugin needs an aarch64 Apple Silicon Mac (found $(uname -m))"
fi
if ! is_apple_silicon; then
  die "Apple Silicon hardware (macsmc_hwmon) not detected. This plugin is designed only for Apple Silicon Macs running Linux."
fi

[[ -f "$DIR/release.env" ]] || die "$DIR/release.env is missing"
VERSION=""
SHA256=""
# shellcheck source=release.env
source "$DIR/release.env"
[[ -n "$VERSION" ]] || die "release.env does not set VERSION"
if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  die "release.env has no pinned SHA256 for v$VERSION yet. Build and install the binary from source instead (see README)."
fi

echo "1. Downloading apple-silicon-thermals v$VERSION..."
mkdir -p "$DIR/bin"
tmp="$(mktemp "$DIR/bin/.apple-silicon-thermals.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
curl -fL --proto '=https' -o "$tmp" "$RELEASES_URL/v$VERSION/$ASSET"
echo "$SHA256  $tmp" | sha256sum -c -
chmod 755 "$tmp"
mv -f "$tmp" "$BIN"

# try-restart exits 5 when the unit does not exist.
if systemctl --user cat "$UNIT" > /dev/null 2>&1; then
  echo "   Restarting the temperature curve service on the new binary..."
  systemctl --user try-restart "$UNIT"
fi

echo "2. Enabling fan_control module parameter in runtime (sudo)..."
if [[ -f "$FAN_CONTROL_PARAM" && $(cat "$FAN_CONTROL_PARAM") != Y ]]; then
  echo 1 | sudo tee "$FAN_CONTROL_PARAM" > /dev/null
fi

echo "3. Persisting fan_control parameter across reboots in /etc/tmpfiles.d/macsmc-fan.conf..."
persisted="w $FAN_CONTROL_PARAM - - - - 1"
if ! cmp -s /etc/tmpfiles.d/macsmc-fan.conf <(printf '%s\n' "$persisted"); then
  sudo mkdir -p /etc/tmpfiles.d
  printf '%s\n' "$persisted" | sudo tee /etc/tmpfiles.d/macsmc-fan.conf > /dev/null
fi

echo "4. Configuring udev rule for fan permissions..."
# 0666 lets every local user set fan targets; kept as upstream has it.
rule="ACTION==\"add|change\", SUBSYSTEM==\"hwmon\", ATTRS{name}==\"macsmc_hwmon\", RUN+=\"/usr/bin/sh -c 'chmod 0666 /sys%p/fan*_target 2>/dev/null || true'\""
if ! cmp -s /etc/udev/rules.d/99-macsmc-fan.rules <(printf '%s\n' "$rule"); then
  sudo mkdir -p /etc/udev/rules.d
  printf '%s\n' "$rule" | sudo tee /etc/udev/rules.d/99-macsmc-fan.rules > /dev/null
  sudo udevadm control --reload-rules
fi

echo "5. Applying immediate permissions..."
hw="$(find_macsmc_hwmon || true)"
if [[ -n "$hw" ]]; then
  for target in "$hw"/fan*_target; do
    [[ -f "$target" ]] || continue
    if [[ $(stat -c %a "$target") != 666 ]]; then
      sudo chmod 0666 "$target"
    fi
  done
fi

echo "Setup complete! Manual fan control is now active and accessible to regular users."
