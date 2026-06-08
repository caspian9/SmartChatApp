# iOS Signing xcconfig Layer — Design

## Context

`SmartChatApp/project.yml` hardcodes iOS signing values directly in XcodeGen's target config:

- `project.yml:16-17` — `DEVELOPMENT_TEAM: "24X2NMFQUY"`, `CODE_SIGN_STYLE: Automatic`
- `project.yml:36` — `PRODUCT_BUNDLE_IDENTIFIER: com.smartchat.SmartChatApp`
- `project.yml:80` — `PRODUCT_BUNDLE_IDENTIFIER: com.smartchat.SmartChatAppTests`

Problems with the current setup:

1. **Hardcoded Team ID leaks into git** — `24X2NMFQUY` is a personal Apple Developer account. Cloning the repo on a different Mac (different Apple ID) requires editing `project.yml`.
2. **No local override path** — every signing tweak (switching to a different Apple ID for testing, pointing at a different profile for a CI build, debugging a profile mismatch) requires editing the committed `project.yml`.
3. **No automatic detection of available Teams** — `xcodebuild` fails with "No Accounts" / "Signing certificate is invalid" because the build doesn't know how to find a usable Team on the current Mac.
4. **Build/install commands have to be re-invoked manually after each signing change** — there's no Makefile target that does the "resolve Team → write xcconfig → regenerate project" pipeline.

The reference architecture in `openclaw/apps/ios/` solves this with a three-layer xcconfig + auto-detect-script pattern. This plan adopts that pattern with project-specific changes:

- Bundle IDs **do not** get a per-user suffix (we keep `com.smartchat.SmartChatApp` to preserve upgrade continuity with the app already installed on a developer iPhone).
- The OpenClaw-specific preferred Team ID (`Y5PE65HELJ`) is removed — local Team ID comes from Xcode's own account list or `.local-signing.xcconfig`.
- `Signing.xcconfig` shared defaults ship with the team field **empty** (no developer-specific value in git history).

**Goal:** Decouple iOS signing configuration from `project.yml`. `make build` / `make install` should "just work" on any Mac that has an Xcode account configured, with no manual `project.yml` edits.

**Non-Goals:**

- No new signing modes (App Store / Enterprise / Ad-hoc). Automatic + Manual only, as Xcode already supports.
- No Simulator support in this layer. `make build` continues to target a real device. (Simulator build works unchanged — it never needed signing.)
- No TestFlight / App Store Connect automation. SmartChatApp is a personal app, no `fastlane` lane for this.
- No CI integration in this change. The xcconfig layer is local-only; CI (if added later) can use `IOS_DEVELOPMENT_TEAM` env var override.

## Current State

### `project.yml` signing fields (4 sites)

| File:Line | Field | Value |
|---|---|---|
| `project.yml:16` | `DEVELOPMENT_TEAM` | `"24X2NMFQUY"` |
| `project.yml:17` | `CODE_SIGN_STYLE` | `Automatic` |
| `project.yml:36` | `PRODUCT_BUNDLE_IDENTIFIER` (main app) | `com.smartchat.SmartChatApp` |
| `project.yml:80` | `PRODUCT_BUNDLE_IDENTIFIER` (tests) | `com.smartchat.SmartChatAppTests` |

(Confirmed via `grep -n -E "PRODUCT_BUNDLE_IDENTIFIER\|DEVELOPMENT_TEAM\|CODE_SIGN_STYLE" project.yml`.)

### Build entry points (all need to call the configure-signing step)

| Makefile target | Currently | After this plan |
|---|---|---|
| `make compile-only` | `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` | same + calls `scripts/ios-configure-signing.sh` first |
| `make build` | `xcodebuild ... -allowProvisioningUpdates build` | same + calls configure-signing first |
| `make install` | depends on `make build` + `xcrun devicectl` | same + transitive dependency on configure-signing |
| `make list-devices` | `xcrun devicectl list devices` | unchanged (no signing needed) |

### What "auto sign + install" means in practice

`xcodebuild -allowProvisioningUpdates` requires:

1. A Team ID known to the build (via `DEVELOPMENT_TEAM` xcconfig value)
2. A valid `Apple Development` certificate in the login keychain
3. For the chosen Bundle ID, either a downloaded `.mobileprovision` in `~/Library/MobileDevice/Provisioning Profiles/` OR Automatic mode permission to create one on the fly

This plan addresses #1. #2 and #3 are the user's responsibility (Xcode account + Automatic signing handles profile creation).

## Target Architecture

### Three-layer xcconfig (OpenClaw pattern, simplified)

```
┌────────────────────────────────────────────────────────────────┐
│ project.yml (committed)                                        │
│   CODE_SIGN_STYLE: "$(SMARTCHATAPP_CODE_SIGN_STYLE)"          │
│   DEVELOPMENT_TEAM: "$(SMARTCHATAPP_DEVELOPMENT_TEAM)"        │
│   PRODUCT_BUNDLE_IDENTIFIER: "$(SMARTCHATAPP_APP_BUNDLE_ID)"   │
│   PRODUCT_BUNDLE_IDENTIFIER: "$(SMARTCHATAPP_TESTS_BUNDLE_ID)"│
└──────────────────────────┬─────────────────────────────────────┘
                           │ XcodeGen renders with these xcconfig refs
┌──────────────────────────▼─────────────────────────────────────┐
│ config/Signing.xcconfig (committed)                            │
│   // Shared defaults — Team left empty                        │
│   SMARTCHATAPP_CODE_SIGN_STYLE = Automatic                     │
│   SMARTCHATAPP_DEVELOPMENT_TEAM =                              │
│   SMARTCHATAPP_APP_BUNDLE_ID = com.smartchat.SmartChatApp      │
│   SMARTCHATAPP_TESTS_BUNDLE_ID = com.smartchat.SmartChatAppTests│
│   SMARTCHATAPP_APP_PROFILE =                                   │
│   SMARTCHATAPP_TESTS_PROFILE =                                 │
│                                                                │
│   #include? ".local-signing.xcconfig"  ← optional, auto-gen   │
│   #include? "LocalSigning.xcconfig"    ← optional, manual     │
└──────────────────────────┬─────────────────────────────────────┘
                           │ xcconfig evaluates top-to-bottom, later wins
┌──────────────────────────▼─────────────────────────────────────┐
│ config/.local-signing.xcconfig (git-ignored, auto-generated)   │
│   SMARTCHATAPP_CODE_SIGN_STYLE = Automatic                     │
│   SMARTCHATAPP_DEVELOPMENT_TEAM = 24X2NMFQUY                   │
│   SMARTCHATAPP_APP_BUNDLE_ID = com.smartchat.SmartChatApp      │
│   SMARTCHATAPP_TESTS_BUNDLE_ID = com.smartchat.SmartChatAppTests│
│   SMARTCHATAPP_APP_PROFILE =                                   │
│   SMARTCHATAPP_TESTS_PROFILE =                                 │
└────────────────────────────────────────────────────────────────┘
```

**Why the include is optional and at the bottom:** xcconfig is evaluated top-to-bottom, so assignments in the included file override the shared defaults. `#include?` (with the question mark) silently skips missing files, so a fresh clone without a local override still resolves shared defaults (with `DEVELOPMENT_TEAM` empty — `xcodebuild` will then fail with a clear "no team" error pointing the user at the configure step).

### `scripts/ios-team-id.sh` — auto-detect pipeline

Detection order (first non-empty wins):

1. `$IOS_DEVELOPMENT_TEAM` environment variable (CI override hook)
2. `~/Library/Preferences/com.apple.dt.Xcode.plist` → `IDEProvisioningTeams` (Xcode 16+ location; JSON-decoded via `python3`)
3. `~/Library/Preferences/com.apple.dt.Xcode.plist` → `IDEProvisioningTeamIdentifiers` (legacy Xcode key, regex-extracted)
4. `~/Library/MobileDevice/Provisioning Profiles/*.mobileprovision` → `TeamIdentifier` plist field (any team in an installed profile)
5. `security find-identity -p codesigning` (only with `IOS_ALLOW_KEYCHAIN_TEAM_FALLBACK=1`)

Of detected teams, prefer the first **non-free** team (Apple Developer Program team over a free provisioning team). Free teams are valid for dev installs but cause `xcodebuild` to re-create profiles on every build.

This is a near-verbatim port of `openclaw/scripts/ios-team-id.sh` with two changes:

- `IOS_PREFERRED_TEAM_ID` / `OPENCLAW_IOS_DEFAULT_TEAM_ID` default removed (was `Y5PE65HELJ`). No preferred Team — any non-free team wins.
- `IOS_PREFERRED_TEAM_NAME` lookup removed.
- Error message simplified to "Open Xcode → Settings → Accounts and sign in, then retry."

### `scripts/ios-configure-signing.sh` — write the local override

Detection → file write pipeline:

1. Call `ios-team-id.sh` to resolve Team ID
2. Sanitize user identity: `${USER}-${team_segment}` becomes the suffix candidate (but **in this project we do NOT append the suffix to Bundle IDs** — see below)
3. Compute canonical Bundle IDs by taking the shared default from `Signing.xcconfig` values
4. Write `config/.local-signing.xcconfig` with all SMARTCHATAPP_* fields filled in
5. If the file exists with identical content, skip the write (idempotent — `cmp -s`)

**Key difference from OpenClaw:** OpenClaw appends `-${user}-${team}` to Bundle IDs so multiple developers sharing the same Apple Team don't collide on the App Store. **We do not append** because:

- This is a single-developer project (per the user's "C: 去掉防冲突" decision in the design discussion)
- A developer iPhone already has `com.smartchat.SmartChatApp` installed; appending a suffix would force a manual uninstall of the old app
- If a second developer joins later, the suffix logic can be re-introduced by toggling an env var in `ios-configure-signing.sh`

### Makefile integration

Three new Makefile targets, all chained into existing entry points:

```makefile
# (new) Resolve Team ID → write .local-signing.xcconfig
.PHONY: configure-signing
configure-signing:
	@bash scripts/ios-configure-signing.sh

# (new) Just print the detected Team ID, do not write
.PHONY: detect-team
detect-team:
	@bash scripts/ios-team-id.sh

# (new) Remove local override; fall back to shared defaults
.PHONY: clean-signing
clean-signing:
	@rm -f config/.local-signing.xcconfig

# (modified) all xcodebuild targets depend on configure-signing
.PHONY: build
build: configure-signing
	xcodebuild ...

.PHONY: install
install: configure-signing build
	...

.PHONY: compile-only
compile-only: configure-signing
	xcodebuild ... CODE_SIGNING_ALLOWED=NO build
```

`compile-only` also depends on `configure-signing` because `xcodegen generate` evaluates xcconfig while rendering `project.yml`, and the empty shared `DEVELOPMENT_TEAM` would otherwise leave all targets with an unresolved `$(SMARTCHATAPP_DEVELOPMENT_TEAM)` substitution.

## File Map

**New files:**

- `config/Signing.xcconfig` — shared defaults (empty Team, canonical Bundle IDs, three-layer include chain)
- `config/LocalSigning.xcconfig.example` — committed template users can copy for manual local overrides
- `config/.gitignore` — ignores `.local-signing.xcconfig`
- `scripts/ios-team-id.sh` — Team ID auto-detect (port from OpenClaw, no preferred Team)
- `scripts/ios-configure-signing.sh` — write `.local-signing.xcconfig` (port from OpenClaw, no Bundle ID suffix)
- `docs/superpowers/specs/2026-06-08-ios-signing-xcconfig-design.md` — this file
- `docs/superpowers/plans/2026-06-08-ios-signing-xcconfig-implementation.md` — step-by-step implementation

**Modified files:**

- `project.yml` — replace 6 hardcoded signing values with `$(SMARTCHATAPP_*)` xcconfig references; add `configFiles: base: config/Signing.xcconfig` to all targets
- `Makefile` — add 3 new targets (`configure-signing`, `detect-team`, `clean-signing`); chain `configure-signing` into `build` / `install` / `compile-only`

**No deletions.**

## Decisions Locked In

- **Default `DEVELOPMENT_TEAM` is empty** in `Signing.xcconfig`. Personal Team ID lives only in `.local-signing.xcconfig`. `git log` never sees a specific developer's Team ID.
- **`CODE_SIGN_STYLE` stays `Automatic`** (matches current `project.yml:17`). No need to support Manual in this layer; Manual is an edge case for shared provisioning profiles, which we don't have.
- **Bundle IDs keep their canonical names** (no `${user}-${team}` suffix). The "second developer collision" problem is deferred to when it actually occurs.
- **Tests target gets its own `SMARTCHATAPP_TESTS_BUNDLE_ID`** variable so tests can be customized independently of the main app.
- **No Simulator support** in this layer. `make build` targets a real device only.
- **Local Team ID is auto-detected** on first build (Q9 = A). The user does not copy `LocalSigning.xcconfig.example` by hand.

## Complete File Previews

### `config/Signing.xcconfig`

```xcconfig
// Default signing values for shared/repo builds.
// Auto-generated local overrides live in .local-signing.xcconfig (git-ignored).
// Manual local overrides can go in LocalSigning.xcconfig (git-ignored).

// Shared defaults. Team is intentionally empty — your real Team ID
// is written by scripts/ios-configure-signing.sh into .local-signing.xcconfig.
SMARTCHATAPP_CODE_SIGN_STYLE = Automatic
SMARTCHATAPP_DEVELOPMENT_TEAM =

SMARTCHATAPP_APP_BUNDLE_ID = com.smartchat.SmartChatApp
SMARTCHATAPP_TESTS_BUNDLE_ID = com.smartchat.SmartChatAppTests

// Profile names — leave empty to let Automatic mode create profiles on demand.
SMARTCHATAPP_APP_PROFILE =
SMARTCHATAPP_TESTS_PROFILE =

// xcconfig evaluates top-to-bottom: later includes override earlier values.
#include? ".local-signing.xcconfig"
#include? "LocalSigning.xcconfig"
```

### `config/LocalSigning.xcconfig.example`

```xcconfig
// Copy to LocalSigning.xcconfig (NOT .local-signing.xcconfig) for hand-maintained
// personal overrides. This file is just a template and should stay committed.
//
// Use case: you want a different Apple ID or a specific provisioning profile
// for a focused test, and the auto-detect picks the wrong team.
//
// 1. Copy this file:   cp config/LocalSigning.xcconfig.example config/LocalSigning.xcconfig
// 2. Edit the values below.
// 3. Re-run `make build`. LocalSigning.xcconfig wins over .local-signing.xcconfig
//    because it is included later.

SMARTCHATAPP_CODE_SIGN_STYLE = Automatic
SMARTCHATAPP_DEVELOPMENT_TEAM = YOUR_10_CHAR_TEAM_ID

SMARTCHATAPP_APP_BUNDLE_ID = com.smartchat.SmartChatApp
SMARTCHATAPP_TESTS_BUNDLE_ID = com.smartchat.SmartChatAppTests

// Leave empty for Automatic mode.
SMARTCHATAPP_APP_PROFILE =
SMARTCHATAPP_TESTS_PROFILE =
```

### `config/.gitignore`

```
.local-signing.xcconfig
```

### `scripts/ios-team-id.sh` (port from OpenClaw, OpenClaw-specific bits stripped)

```bash
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${IOS_DEVELOPMENT_TEAM:-}" ]]; then
  printf '%s\n' "${IOS_DEVELOPMENT_TEAM}"
  exit 0
fi

preferred_team="${IOS_PREFERRED_TEAM_ID:-}"
allow_keychain_fallback="${IOS_ALLOW_KEYCHAIN_TEAM_FALLBACK:-0}"
prefer_non_free_team="${IOS_PREFER_NON_FREE_TEAM:-1}"
preferred_team="${preferred_team//$'\r'/}"

declare -a team_ids=()
declare -a team_is_free=()
declare -a team_names=()
python_cmd=""

detect_python() {
  local candidate
  for candidate in "${IOS_PYTHON_BIN:-}" python3 python /usr/bin/python3; do
    [[ -n "$candidate" ]] || continue
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

python_cmd="$(detect_python || true)"

append_team() {
  local candidate_id="$1"
  local candidate_is_free="$2"
  local candidate_name="$3"
  candidate_id="${candidate_id//$'\r'/}"
  candidate_is_free="${candidate_is_free//$'\r'/}"
  candidate_name="${candidate_name//$'\r'/}"
  [[ -z "$candidate_id" ]] && return

  local i
  for i in "${!team_ids[@]}"; do
    if [[ "${team_ids[$i]}" == "$candidate_id" ]]; then
      return
    fi
  done

  team_ids+=("$candidate_id")
  team_is_free+=("$candidate_is_free")
  team_names+=("$candidate_name")
}

load_teams_from_xcode_preferences() {
  local plist_path="${HOME}/Library/Preferences/com.apple.dt.Xcode.plist"
  [[ -f "$plist_path" ]] || return 0
  [[ -n "$python_cmd" ]] || return 0

  while IFS=$'\t' read -r team_id is_free team_name; do
    [[ -z "$team_id" ]] && continue
    append_team "$team_id" "${is_free:-0}" "${team_name:-}"
  done < <(
    plutil -extract IDEProvisioningTeams json -o - "$plist_path" 2>/dev/null \
      | "$python_cmd" -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)

if not isinstance(data, dict):
    raise SystemExit(0)

for teams in data.values():
    if not isinstance(teams, list):
        continue
    for team in teams:
        if not isinstance(team, dict):
            continue
        team_id = str(team.get("teamID", "")).strip()
        if not team_id:
            continue
        is_free = "1" if bool(team.get("isFreeProvisioningTeam", False)) else "0"
        team_name = str(team.get("teamName", "")).replace("\t", " ").strip()
        print(f"{team_id}\t{is_free}\t{team_name}")
'
  )
}

load_teams_from_legacy_defaults_key() {
  while IFS= read -r team; do
    [[ -z "$team" ]] && continue
    append_team "$team" "0" ""
  done < <(
    defaults read com.apple.dt.Xcode IDEProvisioningTeamIdentifiers 2>/dev/null \
      | grep -Eo '[A-Z0-9]{10}' || true
  )
}

load_teams_from_xcode_managed_profiles() {
  local profiles_dir="${HOME}/Library/MobileDevice/Provisioning Profiles"
  [[ -d "$profiles_dir" ]] || return 0
  [[ -n "$python_cmd" ]] || return 0

  while IFS= read -r team; do
    [[ -z "$team" ]] && continue
    append_team "$team" "0" ""
  done < <(
    for p in "${profiles_dir}"/*.mobileprovision; do
      [[ -f "$p" ]] || continue
      security cms -D -i "$p" 2>/dev/null \
        | "$python_cmd" -c '
import plistlib, sys
try:
    raw = sys.stdin.buffer.read()
    if not raw:
        raise SystemExit(0)
    d = plistlib.loads(raw)
    for tid in d.get("TeamIdentifier", []):
        print(tid)
except Exception:
    pass
' 2>/dev/null
    done | sort -u
  )
}

has_xcode_account() {
  local plist_path="${HOME}/Library/Preferences/com.apple.dt.Xcode.plist"
  [[ -f "$plist_path" ]] || return 1
  local accts
  accts="$(defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists 2>/dev/null || true)"
  [[ -n "$accts" ]] && [[ "$accts" != *"does not exist"* ]] && grep -q 'identifier' <<< "$accts"
}

load_teams_from_xcode_preferences
load_teams_from_legacy_defaults_key

if [[ ${#team_ids[@]} -eq 0 ]]; then
  load_teams_from_xcode_managed_profiles
fi

if [[ ${#team_ids[@]} -eq 0 && "$allow_keychain_fallback" == "1" ]]; then
  while IFS= read -r team; do
    [[ -z "$team" ]] && continue
    append_team "$team" "0" ""
  done < <(
    security find-identity -p codesigning -v 2>/dev/null \
      | grep -Eo '\([A-Z0-9]{10}\)' \
      | tr -d '()' || true
  )
fi

if [[ ${#team_ids[@]} -eq 0 ]]; then
  if has_xcode_account; then
    echo "An Apple account is signed in to Xcode, but no Team ID could be resolved." >&2
    echo "" >&2
    echo "On Xcode 16+, team data is not written until you build a project." >&2
    echo "To fix this, do ONE of the following:" >&2
    echo "" >&2
    echo "  1. Open the iOS project in Xcode, select your Team in Signing &" >&2
    echo "     Capabilities, and build once. Then re-run this script." >&2
    echo "" >&2
    echo "  2. Set your Team ID directly:" >&2
    echo "       export IOS_DEVELOPMENT_TEAM=<your-10-char-team-id>" >&2
    echo "     Find your Team ID at: https://developer.apple.com/account#MembershipDetailsCard" >&2
  else
    echo "No Apple Team ID found in Xcode accounts. Open Xcode → Settings → Accounts and sign in, then retry." >&2
    echo "(Set IOS_ALLOW_KEYCHAIN_TEAM_FALLBACK=1 to allow keychain-only team detection.)" >&2
  fi
  exit 1
fi

for i in "${!team_ids[@]}"; do
  if [[ "${team_ids[$i]}" == "$preferred_team" ]]; then
    printf '%s\n' "${team_ids[$i]}"
    exit 0
  fi
done

if [[ "$prefer_non_free_team" == "1" ]]; then
  for i in "${!team_ids[@]}"; do
    if [[ "${team_is_free[$i]}" == "0" ]]; then
      printf '%s\n' "${team_ids[$i]}"
      exit 0
    fi
  done
fi

printf '%s\n' "${team_ids[0]}"
```

### `scripts/ios-configure-signing.sh` (port from OpenClaw, no Bundle ID suffix)

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${ROOT_DIR}/config"
TEAM_ID_SCRIPT="${ROOT_DIR}/scripts/ios-team-id.sh"
LOCAL_SIGNING_FILE="${CONFIG_DIR}/.local-signing.xcconfig"

# Sanitize a user-provided string for use as a path/identifier segment.
sanitize_identifier_segment() {
  local raw="${1:-}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  raw="$(printf '%s' "$raw" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$raw" ]]; then
    raw="local"
  fi
  printf '%s\n' "$raw"
}

# Sanitize a Bundle ID segment (keep dots, hyphens, alphanumerics).
normalize_bundle_id() {
  local raw="${1:-}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  raw="$(printf '%s' "$raw" | sed -E 's/[^a-z0-9.-]+/-/g; s/\.+/./g; s/^-+//; s/[.-]+$//')"
  if [[ -z "$raw" ]]; then
    raw="com.smartchat.app.test.local"
  fi
  printf '%s\n' "$raw"
}

if [[ ! -x "${TEAM_ID_SCRIPT}" ]]; then
  echo "ERROR: Missing team detection helper: ${TEAM_ID_SCRIPT}" >&2
  exit 1
fi

team_id=""
if team_id="$("${TEAM_ID_SCRIPT}" 2>/dev/null)"; then
  :
else
  if [[ "${IOS_SIGNING_REQUIRED:-0}" == "1" ]]; then
    "${TEAM_ID_SCRIPT}"
    exit 1
  fi

  echo "WARN: Unable to detect an Apple Team ID; keeping existing iOS signing override (if any)." >&2
  exit 0
fi

# Canonical Bundle IDs — for SmartChatApp we deliberately do NOT append
# a per-user suffix, to preserve upgrade continuity with the app already
# installed on devices. If multi-developer collision becomes an issue,
# re-introduce the suffix by setting SMARTCHATAPP_IOS_BUNDLE_SUFFIX.
if [[ -n "${SMARTCHATAPP_IOS_BUNDLE_SUFFIX:-}" ]]; then
  bundle_suffix="$(sanitize_identifier_segment "${SMARTCHATAPP_IOS_BUNDLE_SUFFIX}")"
  bundle_base="${SMARTCHATAPP_IOS_APP_BUNDLE_ID_BASE:-com.smartchat.SmartChatApp}"
  bundle_base="$(normalize_bundle_id "${bundle_base}.${bundle_suffix}")"
else
  bundle_base="${SMARTCHATAPP_IOS_APP_BUNDLE_ID:-com.smartchat.SmartChatApp}"
  bundle_base="$(normalize_bundle_id "${bundle_base}")"
fi

tests_bundle_id="${SMARTCHATAPP_IOS_TESTS_BUNDLE_ID:-${bundle_base}Tests}"
tests_bundle_id="$(normalize_bundle_id "${tests_bundle_id}")"

code_sign_style="${SMARTCHATAPP_IOS_CODE_SIGN_STYLE:-Automatic}"
app_profile="${SMARTCHATAPP_IOS_APP_PROFILE:-}"
tests_profile="${SMARTCHATAPP_IOS_TESTS_PROFILE:-}"

tmp_file="$(mktemp "${TMPDIR:-/tmp}/smartchatapp-ios-signing.XXXXXX")"
cat >"${tmp_file}" <<EOF
// Auto-generated by scripts/ios-configure-signing.sh.
// This file is local-only and should not be committed.
// Override values with env vars if needed:
// SMARTCHATAPP_IOS_APP_BUNDLE_ID / SMARTCHATAPP_IOS_TESTS_BUNDLE_ID
// SMARTCHATAPP_IOS_CODE_SIGN_STYLE / SMARTCHATAPP_IOS_APP_PROFILE
SMARTCHATAPP_CODE_SIGN_STYLE = ${code_sign_style}
SMARTCHATAPP_DEVELOPMENT_TEAM = ${team_id}
SMARTCHATAPP_IOS_SELECTED_TEAM = ${team_id}
SMARTCHATAPP_APP_BUNDLE_ID = ${bundle_base}
SMARTCHATAPP_TESTS_BUNDLE_ID = ${tests_bundle_id}
SMARTCHATAPP_APP_PROFILE = ${app_profile}
SMARTCHATAPP_TESTS_PROFILE = ${tests_profile}
EOF

if [[ -f "${LOCAL_SIGNING_FILE}" ]] && cmp -s "${tmp_file}" "${LOCAL_SIGNING_FILE}"; then
  rm -f "${tmp_file}"
  echo "iOS signing config already up to date: team=${team_id} app=${bundle_base}"
  exit 0
fi

mv "${tmp_file}" "${LOCAL_SIGNING_FILE}"
echo "Configured iOS signing: team=${team_id} app=${bundle_base}"
```

### `project.yml` diff (signature)

```yaml
# 6 sites, all changed from literal to $(SMARTCHATAPP_*) reference:

# At project root (configDefaults), around line 16-17:
-    DEVELOPMENT_TEAM: "24X2NMFQUY"
-    CODE_SIGN_STYLE: Automatic
+    DEVELOPMENT_TEAM: "$(SMARTCHATAPP_DEVELOPMENT_TEAM)"
+    CODE_SIGN_STYLE: "$(SMARTCHATAPP_CODE_SIGN_STYLE)"

# Main app target, around line 36:
-    PRODUCT_BUNDLE_IDENTIFIER: com.smartchat.SmartChatApp
+    PRODUCT_BUNDLE_IDENTIFIER: "$(SMARTCHATAPP_APP_BUNDLE_ID)"

# Tests target, around line 80:
-    PRODUCT_BUNDLE_IDENTIFIER: com.smartchat.SmartChatAppTests
+    PRODUCT_BUNDLE_IDENTIFIER: "$(SMARTCHATAPP_TESTS_BUNDLE_ID)"

# Each target's `configFiles` block (main app + tests + any extensions):
#  configFiles:
#    base: config/Signing.xcconfig
# (added; currently absent)
```

### `Makefile` diff

```makefile
# (new) 3 targets added:
.PHONY: configure-signing
configure-signing:
	@bash scripts/ios-configure-signing.sh

.PHONY: detect-team
detect-team:
	@bash scripts/ios-team-id.sh

.PHONY: clean-signing
clean-signing:
	@rm -f config/.local-signing.xcconfig
	@echo "Removed config/.local-signing.xcconfig"

# (modified) `compile-only` gains a prerequisite:
-.PHONY: compile-only
-compile-only:
+.PHONY: compile-only
+compile-only: configure-signing
	xcodebuild ... (unchanged)

# (modified) `build` gains a prerequisite:
-.PHONY: build
-build:
+.PHONY: build
+build: configure-signing
	xcodebuild ... (unchanged)

# `install` already depends on `build`, so configure-signing is transitive.
# No change needed in `install`'s recipe.
```

## Verification (post-implementation)

1. `make compile-only` succeeds with no signing required.
2. `make detect-team` prints `24X2NMFQUY` (or whatever Xcode's current account resolves to).
3. `make configure-signing` writes `config/.local-signing.xcconfig` with the Team ID populated.
4. `cat config/.local-signing.xcconfig` shows the expected SMARTCHATAPP_* fields.
5. `xcodegen generate` succeeds (validates xcconfig variables are wired correctly).
6. `make build` (with valid Apple certificate in keychain) succeeds end-to-end.
7. `git status` shows `config/.local-signing.xcconfig` is ignored (not staged).

## Out of Scope

- Simulator build target (`make run-sim`). Not asked for; would route through `xcodebuild -destination 'platform=iOS Simulator'` with no signing.
- TestFlight / App Store Connect upload automation. Personal app, no TestFlight need.
- Multi-Apple-ID profile switching UI. `LocalSigning.xcconfig` covers the manual case.
- Re-introducing the per-user Bundle ID suffix. Deferred until a second developer joins.
- `Info.plist` re-generation. The current `info.properties` block in `project.yml` is unrelated to signing and stays as-is.
