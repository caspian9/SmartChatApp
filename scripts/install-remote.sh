#!/usr/bin/env bash
#
# install-remote.sh — invoked by `make install-remote`. Builds locally,
# scp's the .app to a remote box where the iPhone is paired, then runs
# `xcrun devicectl device install app` there.
#
# Required env vars:
#   REMOTE_TARGET      ssh/scp target (IP, hostname, or ~/.ssh/config alias)
#
# Optional env vars:
#   REMOTE_DEVICE_NAME  iPhone name as `xcrun devicectl list devices` shows it.
#                       If unset, auto-detects the first paired device on
#                       REMOTE_TARGET via SSH (single-iPhone case).
#   REMOTE_APP_DIR      scratch directory on REMOTE_TARGET for the uploaded
#                       .app (default: /tmp/smartchatapp-build).
#   APP_PATH            override the auto-detected .app path (smoke-test hook).

set -euo pipefail

REMOTE_TARGET="${REMOTE_TARGET:-}"
REMOTE_DEVICE_NAME="${REMOTE_DEVICE_NAME:-}"
REMOTE_APP_DIR="${REMOTE_APP_DIR:-/tmp/smartchatapp-build}"
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

# --- 2. Resolve REMOTE_DEVICE_NAME / REMOTE_APP_DIR --------------------------
#
# REMOTE_APP_DIR: from env (LocalRemoteBuild.mk / CLI) or default.
# REMOTE_DEVICE_NAME: from env, else auto-detect from devicectl.

remote_app_dir="$REMOTE_APP_DIR"

if [[ -n "$REMOTE_DEVICE_NAME" ]]; then
  remote_device_name="$REMOTE_DEVICE_NAME"
  echo ">>> Using REMOTE_DEVICE_NAME from local config"
  echo "    REMOTE_DEVICE_NAME=$remote_device_name"
else
  echo ">>> Auto-detecting iPhone via xcrun devicectl list devices on $REMOTE_TARGET ..."

  paired_devices="$(ssh "${SSH_OPTS[@]}" "$REMOTE_TARGET" \
    'xcrun devicectl list devices 2>/dev/null' | awk '/available \(paired\)/')"

  if [[ -z "$paired_devices" ]]; then
    echo "❌ No paired iPhone found on $REMOTE_TARGET." >&2
    echo "  Pair your iPhone (USB or Wi-Fi) and re-run." >&2
    exit 1
  fi

  paired_count="$(printf '%s\n' "$paired_devices" | wc -l | tr -d ' ')"

  if (( paired_count > 1 )); then
    echo "❌ Multiple paired iPhones ($paired_count) on $REMOTE_TARGET." >&2
    echo "  Auto-detect is ambiguous. Set REMOTE_DEVICE_NAME in" >&2
    echo "  config/LocalRemoteBuild.mk and re-run." >&2
    echo "" >&2
    echo "  Available paired devices:" >&2
    printf '%s\n' "$paired_devices" | awk '{sub(/[[:space:]]{2,}.*/,""); print "    " $0}' >&2
    exit 1
  fi

  # devicectl output is columnar (Name | Hostname | Identifier | State | Model);
  # the first field is the device name. Trim at the first 2+ space gap.
  remote_device_name="$(printf '%s' "$paired_devices" | sed -E 's/[[:space:]]{2,}.*//')"
  echo "    auto-detected: REMOTE_DEVICE_NAME=$remote_device_name"
fi

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