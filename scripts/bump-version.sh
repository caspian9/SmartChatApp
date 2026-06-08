#!/usr/bin/env bash
# Bump SMARTCHATAPP_MARKETING_VERSION and pre-fill CHANGELOG.md.
# Usage: scripts/bump-version.sh <major|minor|patch> [--dry-run]
#
# Idempotent on the version field; non-idempotent on CHANGELOG
# (always inserts a new section). Run with --dry-run first to
# preview. Does not auto-commit or auto-tag.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
XCCONFIG="$REPO_ROOT/config/Version.xcconfig"
PROJECT_YML="$REPO_ROOT/project.yml"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"

LEVEL="${1:-}"
DRY_RUN="false"
if [[ "${2:-}" == "--dry-run" ]]; then
  DRY_RUN="true"
fi

if [[ ! "$LEVEL" =~ ^(major|minor|patch)$ ]]; then
  echo "Usage: $0 <major|minor|patch> [--dry-run]" >&2
  exit 1
fi

# Read current version
CURRENT="$(grep -E '^SMARTCHATAPP_MARKETING_VERSION[[:space:]]*=' "$XCCONFIG" \
  | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//')"
if [[ -z "$CURRENT" ]]; then
  echo "ERROR: could not read SMARTCHATAPP_MARKETING_VERSION from $XCCONFIG" >&2
  exit 1
fi
IFS='.' read -r MAJOR MINOR PATCH <<<"$CURRENT"

case "$LEVEL" in
  major) MAJOR=$((MAJOR+1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR+1)); PATCH=0 ;;
  patch) PATCH=$((PATCH+1)) ;;
esac
NEW="$MAJOR.$MINOR.$PATCH"
TODAY="$(date +%Y-%m-%d)"

echo "Bump $CURRENT → $NEW  ($LEVEL)"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "Would write to $XCCONFIG and $PROJECT_YML"
  echo "Would insert [Unreleased] content under [${NEW}] - $TODAY in $CHANGELOG"
  exit 0
fi

# Patch the xcconfig
sed -i.bak -E "s|^SMARTCHATAPP_MARKETING_VERSION[[:space:]]*=.*$|SMARTCHATAPP_MARKETING_VERSION = ${NEW}|" "$XCCONFIG"
rm -f "$XCCONFIG.bak"

# Patch project.yml (mirror)
sed -i.bak -E "s|^[[:space:]]*MARKETING_VERSION:[[:space:]]*\"[^\"]*\"$|    MARKETING_VERSION: \"${NEW}\"|" "$PROJECT_YML"
rm -f "$PROJECT_YML.bak"

# Pre-fill CHANGELOG: split [Unreleased] into a new dated version
python3 - "$CHANGELOG" "$NEW" "$TODAY" <<'PY'
import sys, re, pathlib
path = pathlib.Path(sys.argv[1])
new_ver = sys.argv[2]
today = sys.argv[3]
text = path.read_text()

# Capture the [Unreleased] section's body
m = re.search(
    r"(## \[Unreleased\]\n\n)(.*?)(\n## \[)",
    text,
    re.DOTALL,
)
if not m:
    print("ERROR: could not find [Unreleased] section in CHANGELOG.md", file=sys.stderr)
    sys.exit(1)
unreleased_body = m.group(2).rstrip()

new_text = text[:m.start()] + (
    "## [Unreleased]\n\n"
    "### Added\n"
    "### Changed\n"
    "### Removed\n"
    "\n## [" + new_ver + "] - " + today + "\n\n"
    + unreleased_body + "\n"
) + text[m.start(3):]
path.write_text(new_text)
PY

echo "Wrote $XCCONFIG, $PROJECT_YML, $CHANGELOG."
echo "Next: review 'git diff', commit with 'docs(version): bump $LEVEL to $NEW',"
echo "then 'git tag v$NEW && git push origin v$NEW' to trigger release.yml."
