#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/bin/apple-silicon-thermals"
ASSET="apple-silicon-thermals-aarch64-linux-musl"
RELEASES_URL="https://github.com/cristim/AppleSiliconThermals/releases/download"
UNIT="applesiliconthermals-curve.service"

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
  die "run setup.sh as your normal user; it only downloads the binary and never needs root"
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

echo "Binary installed. Manual fan control also needs the root-owned fan broker; install it with the"
echo "sudo commands in the README section 'One-Time Setup for Manual Fan Control'."
