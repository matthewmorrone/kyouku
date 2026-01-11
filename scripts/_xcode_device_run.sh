#!/usr/bin/env bash
set -euo pipefail

SCHEME=${SCHEME:-kyouku}

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
DERIVED_DATA_PATH=${DERIVED_DATA_PATH:-"$PWD/.derivedData-device"}

# You can set DEVICE to any identifier devicectl accepts: udid, name, etc.
# If omitted, the script will auto-detect the first available connected iPhone.
DEVICE=${DEVICE:-}
DEVICE_UDID=${DEVICE_UDID:-}

resolve_device_udid() {
  # `xcdevice list` outputs JSON; use it to find a connected physical iPhone.
  # Optionally, you can set DEVICE_NAME to select a specific device by name.
  local device_name=${DEVICE_NAME:-}
  xcrun xcdevice list | /usr/bin/python3 -c 'import json, sys, os
data = json.load(sys.stdin)
want_name = os.environ.get("DEVICE_NAME")

def is_ios_phone(d):
    return (not d.get("simulator", False)) and d.get("platform") == "com.apple.platform.iphoneos"

devices = [d for d in data if d.get("available", False) and not d.get("ignored", False) and is_ios_phone(d)]
if want_name:
    devices = [d for d in devices if d.get("name") == want_name]

if not devices:
    sys.stdout.write("")
    sys.exit(0)

sys.stdout.write(devices[0].get("identifier", ""))
'
}

if [[ -z "$DEVICE_UDID" ]]; then
  DEVICE_UDID=$(resolve_device_udid)
fi

if [[ -z "$DEVICE_UDID" ]]; then
  echo "No connected iPhone found. Connect a device or set DEVICE_UDID (and optionally DEVICE_NAME)." >&2
  exit 1
fi

# devicectl accepts UDID directly, so default DEVICE to the UDID (avoids leaking a device name).
if [[ -z "$DEVICE" ]]; then
  DEVICE="$DEVICE_UDID"
fi

DESTINATION=${DESTINATION:-"platform=iOS,id=$DEVICE_UDID"}

echo "Destination: $DESTINATION"

# Build settings (bundle id + product path)
BUILD_SETTINGS=$(xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONF" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -showBuildSettings)

BUNDLE_ID=$(echo "$BUILD_SETTINGS" | awk -F ' = ' '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=/ {print $2; exit}')
TARGET_BUILD_DIR=$(echo "$BUILD_SETTINGS" | awk -F ' = ' '/TARGET_BUILD_DIR/ {print $2; exit}')
FULL_PRODUCT_NAME=$(echo "$BUILD_SETTINGS" | awk -F ' = ' '/FULL_PRODUCT_NAME/ {print $2; exit}')

if [[ -z "$BUNDLE_ID" || -z "$TARGET_BUILD_DIR" || -z "$FULL_PRODUCT_NAME" ]]; then
  echo "Failed to resolve build settings (bundle id / build dir / product name)." >&2
  exit 1
fi

APP_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"

echo "Bundle ID: $BUNDLE_ID"
echo "App path: $APP_PATH"

echo "Building ($CONF)…"
# -allowProvisioningUpdates lets Xcode update profiles/certs if needed.
# If you are already running from Xcode successfully, this should be safe.
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONF" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -allowProvisioningUpdates \
  -quiet \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found at: $APP_PATH" >&2
  exit 1
fi

echo "Installing to device…"
xcrun devicectl device install app --device "$DEVICE" "$APP_PATH" >/dev/null

echo "Launching…"
# Strict TextKit 2 mode: crash immediately if any TextKit 1 API is accessed.
# Default ON for these scripts; override by exporting KYOUKU_STRICT_TEXTKIT2=0.
if [[ "${KYOUKU_STRICT_TEXTKIT2:-}" == "" ]]; then
  KYOUKU_STRICT_TEXTKIT2=1
fi

# --terminate-existing makes iterative runs behave more like Xcode Run.
if [[ "${KYOUKU_STRICT_TEXTKIT2:-}" != "0" ]]; then
  xcrun devicectl device process launch --terminate-existing --device "$DEVICE" \
    --environment-variables '{"KYOUKU_STRICT_TEXTKIT2":"1"}' \
    "$BUNDLE_ID" >/dev/null
else
  xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE_ID" >/dev/null
fi

echo "OK"
