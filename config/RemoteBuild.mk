# Defaults used by `make install-remote`. Override with
# `config/LocalRemoteBuild.mk` (gitignored; see .gitignore) or via
# `make REMOTE_TARGET=...` etc. on the command line. CLI args win
# because all variables use `?=`.
#
# REMOTE_TARGET: the ssh/scp target (literal IP/hostname, or a
# ~/.ssh/config alias). Empty by default — set it locally per
# machine so you can run `make install-remote` with no args.
#
# REMOTE_DEVICE_NAME: iPhone name as `xcrun devicectl list devices`
# shows it. If empty, install-remote.sh auto-detects the first
# paired device on REMOTE_TARGET via SSH (single-iPhone case).
#
# REMOTE_APP_DIR: scratch directory on REMOTE_TARGET for the
# uploaded .app. Defaults to /tmp/smartchatapp-build. Override
# locally if /tmp is non-writable or you want a different path.
#
# Pattern parallels config/Signing.xcconfig + config/LocalSigning.xcconfig.

REMOTE_TARGET      ?=
REMOTE_DEVICE_NAME ?=
REMOTE_APP_DIR     ?= /tmp/smartchatapp-build