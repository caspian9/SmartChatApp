# Defaults used by `make install-remote`. Override with
# `config/LocalRemoteBuild.mk` (gitignored; see .gitignore) or via
# `make REMOTE_TARGET=...` / `make REMOTE_CONFIG_PATH=...` on the
# command line. CLI args win because both variables use `?=`.
#
# REMOTE_TARGET: the ssh/scp target (literal IP/hostname, or a
# ~/.ssh/config alias). Empty by default — set it locally per
# machine so you can run `make install-remote` with no args.
#
# REMOTE_CONFIG_PATH: path on the REMOTE machine (not this one) to
# the build-remote.conf file containing REMOTE_DEVICE_NAME and
# REMOTE_APP_DIR — see scripts/install-remote.sh for the format.
#
# Pattern parallels config/Signing.xcconfig + config/LocalSigning.xcconfig.

REMOTE_TARGET      ?=
REMOTE_CONFIG_PATH ?= ~/.config/smartchatapp/build-remote.conf
