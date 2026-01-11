#!/usr/bin/env bash
set -euo pipefail

SCHEME=${SCHEME:-kyouku}
SIM_NAME=${SIM_NAME:-"iPhone 17"}

default_conf_from_scheme() {
  local scheme_file="$PWD/kyouku.xcodeproj/xcshareddata/xcschemes/${SCHEME}.xcscheme"
  if [[ ! -f "$scheme_file" ]]; then
    echo "Debug"
    return
  fi
  /usr/bin/python3 -c 'import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
try:
    root = ET.parse(path).getroot()
except Exception:
    print("Debug")
    sys.exit(0)

launch = root.find("LaunchAction")
conf = (launch.get("buildConfiguration") if launch is not None else None)
print(conf or "Debug")
' "$scheme_file"
}

CONF=${CONF:-$(default_conf_from_scheme)}
DERIVED_DATA_PATH=${DERIVED_DATA_PATH:-"$PWD/.derivedData-sim"}

SIM_UDID=$(xcrun simctl list devices -j | /usr/bin/python3 -c 'import json, sys, os
data = json.load(sys.stdin)
devices = data.get("devices", {})
name = os.environ.get("SIM_NAME", "iPhone 17")

candidates = []
for runtime, devs in devices.items():
  for d in devs:
    if d.get("name") != name:
      continue
    if not d.get("isAvailable", False):
      continue
    candidates.append(d)

if not candidates:
  sys.stdout.write("")
  sys.exit(0)

booted = [d for d in candidates if d.get("state") == "Booted"]
chosen = booted[0] if booted else candidates[0]
sys.stdout.write(chosen.get("udid", ""))
')

if [[ -z "$SIM_UDID" ]]; then
  echo "Could not find an available simulator named: $SIM_NAME" >&2
  exit 1
fi

echo "Using simulator: $SIM_NAME ($SIM_UDID)"

xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null

# Resolve build settings for bundle id + app output path
BUILD_SETTINGS=$(xcodebuild -scheme "$SCHEME" -destination "id=$SIM_UDID" -configuration "$CONF" -derivedDataPath "$DERIVED_DATA_PATH" -showBuildSettings)

BUNDLE_ID=$(echo "$BUILD_SETTINGS" | awk -F ' = ' '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=/ {print $2; exit}')
TARGET_BUILD_DIR=$(echo "$BUILD_SETTINGS" | awk -F ' = ' '/TARGET_BUILD_DIR/ {print $2; exit}')
FULL_PRODUCT_NAME=$(echo "$BUILD_SETTINGS" | awk -F ' = ' '/FULL_PRODUCT_NAME/ {print $2; exit}')

if [[ -z "$BUNDLE_ID" || -z "$TARGET_BUILD_DIR" || -z "$FULL_PRODUCT_NAME" ]]; then
  echo "Failed to resolve build settings (bundle id / build dir / product name)." >&2
  exit 1
fi

APP_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"

echo "Building ($CONF)…"
xcodebuild -scheme "$SCHEME" -destination "id=$SIM_UDID" -configuration "$CONF" -derivedDataPath "$DERIVED_DATA_PATH" -quiet build

echo "Installing: $APP_PATH"
xcrun simctl install "$SIM_UDID" "$APP_PATH" >/dev/null

echo "Launching: $BUNDLE_ID"
LAUNCH_ARGS=()

# Strict TextKit 2 mode: crash immediately if any TextKit 1 API is accessed.
# Default ON for these scripts; override by exporting KYOUKU_STRICT_TEXTKIT2=0.
if [[ "${KYOUKU_STRICT_TEXTKIT2:-}" == "" ]]; then
  KYOUKU_STRICT_TEXTKIT2=1
fi
if [[ "${KYOUKU_STRICT_TEXTKIT2:-}" != "0" ]]; then
  LAUNCH_ARGS+=(--env "KYOUKU_STRICT_TEXTKIT2=1")
fi

# If RUBY_TRACE=1 is set, enable very verbose per-ruby logging inside the app.
# This maps to DiagnosticsLogging's override key.
if [[ "${RUBY_TRACE:-}" == "1" ]]; then
  LAUNCH_ARGS+=(--env "DiagnosticsLogging.furiganaRubyTrace=1")
fi

LAUNCH_ARGS+=("$SIM_UDID" "$BUNDLE_ID")

xcrun simctl launch "${LAUNCH_ARGS[@]}" >/dev/null

echo "OK"
