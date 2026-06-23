#!/usr/bin/env bash
#
# install-remote.sh — invoked by `make install-remote`. Builds locally,
# scp's the .app to a remote box where the iPhone is paired, then runs
# `xcrun devicectl device install app` there.
#
# Required env vars:
#   REMOTE_TARGET      ssh/scp target (IP, hostname, or ~/.ssh/config alias)
#   REMOTE_CONFIG_PATH path on the REMOTE machine to the build-remote.conf file
#                      (default: ~/.config/smartchatapp/build-remote.conf)
#
# The remote file must contain (KEY=VALUE per line):
#   REMOTE_DEVICE_NAME=<xcrun devicectl --device value>
#   REMOTE_APP_DIR=<user-writable scratch directory>
#
# Optional env vars:
#   APP_PATH     override the auto-detected .app path (smoke-test hook)

set -euo pipefail

REMOTE_TARGET="${REMOTE_TARGET:-}"
REMOTE_CONFIG_PATH="${REMOTE_CONFIG_PATH:-~/.config/smartchatapp/build-remote.conf}"
APP_PATH="${APP_PATH:-}"

# --- 1. Validate inputs -----------------------------------------------------

if [[ -z "$REMOTE_TARGET" ]]; then
  echo "Usage: REMOTE_TARGET=<host-or-alias> $0" >&2
  echo "  Or set REMOTE_TARGET in config/RemoteBuild.mk (CLI args override)." >&2
  exit 1
fi

if [[ -z "$APP_PATH" ]]; then
  APP_PATH="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/SmartChatApp-*/Build/Products/Debug-iphoneos/SmartChatApp.app 2>/dev/null | head -1 || true)"
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "No built .app found. Run \`make build\` first." >&2
  exit 1
fi

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)

# --- 2. Read remote config --------------------------------------------------

echo ">>> Reading $REMOTE_CONFIG_PATH on $REMOTE_TARGET ..."

remote_config="$(ssh "${SSH_OPTS[@]}" "$REMOTE_TARGET" "cat '$REMOTE_CONFIG_PATH'")"
remote_device_name="$(printf '%s\n' "$remote_config" | awk -F= '/^[[:space:]]*REMOTE_DEVICE_NAME[[:space:]]*=/{sub(/^[[:space:]]+/,"",$2); print $2; exit}')"
remote_app_dir="$(printf '%s\n' "$remote_config"   | awk -F= '/^[[:space:]]*REMOTE_APP_DIR[[:space:]]*=/{sub(/^[[:space:]]+/,"",$2); print $2; exit}')"

if [[ -z "$remote_device_name" || -z "$remote_app_dir" ]]; then
  echo "On $REMOTE_TARGET, create $REMOTE_CONFIG_PATH with REMOTE_DEVICE_NAME and REMOTE_APP_DIR set." >&2
  echo "  Example:" >&2
  echo "    REMOTE_DEVICE_NAME=iPhone" >&2
  echo "    REMOTE_APP_DIR=/tmp/smartchatapp-build" >&2
  exit 1
fi

echo "    REMOTE_DEVICE_NAME=$remote_device_name"
echo "    REMOTE_APP_DIR=$remote_app_dir"

# --- 3. Ensure remote dir exists -------------------------------------------

echo ">>> Ensuring $remote_app_dir exists on $REMOTE_TARGET ..."
ssh "${SSH_OPTS[@]}" "$REMOTE_TARGET" "mkdir -p '$remote_app_dir'"

# --- 4. scp the .app -------------------------------------------------------

echo ">>> Uploading $(basename "$APP_PATH") to $REMOTE_TARGET:$remote_app_dir/ ..."
scp -O "${SSH_OPTS[@]}" -r "$APP_PATH" "$REMOTE_TARGET:$remote_app_dir/"

# --- 5. devicectl install on the remote -----------------------------------

echo ">>> Installing on $remote_device_name via xcrun devicectl ..."
if ! ssh "${SSH_OPTS[@]}" "$REMOTE_TARGET" \
    "xcrun devicectl device install app --device '$remote_device_name' '$remote_app_dir/$(basename "$APP_PATH")'"; then
  echo "Install failed. If this is a signing error, both machines must share the same Apple Developer Team ID." >&2
  exit 1
fi

# --- 6. Cleanup uploaded .app ---------------------------------------------

echo ">>> Cleaning up uploaded .app on $REMOTE_TARGET ..."
ssh "${SSH_OPTS[@]}" "$REMOTE_TARGET" "rm -rf '$remote_app_dir/$(basename "$APP_PATH")'"

echo ">>> Done."
