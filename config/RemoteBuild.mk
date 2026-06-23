# Default REMOTE_CONFIG_PATH used by `make install-remote`. Points to a
# file on the REMOTE machine (not this one) that contains REMOTE_DEVICE_NAME
# and REMOTE_APP_DIR — see scripts/install-remote.sh for the format.
#
# Override with `config/LocalRemoteBuild.mk` (gitignored; see .gitignore)
# or via `make REMOTE_CONFIG_PATH=...` on the command line.
#
# Pattern parallels config/Signing.xcconfig + config/LocalSigning.xcconfig.

REMOTE_CONFIG_PATH ?= ~/.config/smartchatapp/build-remote.conf
