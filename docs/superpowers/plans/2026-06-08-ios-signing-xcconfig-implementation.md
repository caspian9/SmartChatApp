# iOS Signing xcconfig Layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Rebased against latest main (2026-06-08).** No commits since the design was finalized; the steps below stand as written.

**Goal:** Decouple iOS signing configuration from `project.yml`. `make build` / `make install` should "just work" on any Mac that has an Xcode account configured, with no manual `project.yml` edits.

**Architecture:** Three-layer xcconfig (`Signing.xcconfig` shared default → `.local-signing.xcconfig` auto-generated → `LocalSigning.xcconfig` manual override) referenced from `project.yml` via `$(SMARTCHATAPP_*)` substitutions. `scripts/ios-team-id.sh` auto-detects the Apple Team from Xcode preferences / installed profiles / keychain. `scripts/ios-configure-signing.sh` writes the local override. Makefile chains `configure-signing` into `build` / `install` / `compile-only`.

**Tech Stack:** Bash 3.2+, xcconfig, XcodeGen, GNU Make

---

## File Map

**New files:**
- `config/Signing.xcconfig` — shared defaults (empty Team, canonical Bundle IDs, three-layer include chain)
- `config/LocalSigning.xcconfig.example` — committed template for manual local overrides
- `config/.gitignore` — ignores `.local-signing.xcconfig`
- `scripts/ios-team-id.sh` — Team ID auto-detect (port from OpenClaw, no preferred Team)
- `scripts/ios-configure-signing.sh` — write `.local-signing.xcconfig` (port from OpenClaw, no Bundle ID suffix)

**Modified files:**
- `project.yml` — replace 4 hardcoded signing values with `$(SMARTCHATAPP_*)` xcconfig references; add `configFiles: base: config/Signing.xcconfig` to all targets
- `Makefile` — add 3 new targets (`configure-signing`, `detect-team`, `clean-signing`); chain `configure-signing` into `build` / `install` / `compile-only`

**No deletions.**

---

## Task 1: Create `config/` directory and base files

**Files:**
- Create: `config/Signing.xcconfig`
- Create: `config/LocalSigning.xcconfig.example`
- Create: `config/.gitignore`

- [ ] **Step 1: Create the directory and base xcconfig**

Run from repo root:

```bash
mkdir -p config
```

Create `config/Signing.xcconfig`:

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

- [ ] **Step 2: Create the manual override template**

Create `config/LocalSigning.xcconfig.example`:

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

- [ ] **Step 3: Create the local-override gitignore**

Create `config/.gitignore`:

```
.local-signing.xcconfig
```

- [ ] **Step 4: Verify the layout**

Run:

```bash
ls -la config/
```

Expected output (3 files):

```
LocalSigning.xcconfig.example
Signing.xcconfig
.gitignore
```

---

## Task 2: Add `scripts/ios-team-id.sh`

**Files:**
- Create: `scripts/ios-team-id.sh`

- [ ] **Step 1: Create the directory and the script**

Run from repo root:

```bash
mkdir -p scripts
```

Create `scripts/ios-team-id.sh` with the full content from the design doc (the ported version of `openclaw/scripts/ios-team-id.sh` with the OpenClaw-specific bits removed). The complete file content is reproduced below.

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

- [ ] **Step 2: Make the script executable**

```bash
chmod +x scripts/ios-team-id.sh
```

- [ ] **Step 3: Verify the script runs and detects your Team**

```bash
./scripts/ios-team-id.sh
```

Expected: prints a 10-character Team ID (`24X2NMFQUY` in this environment, assuming Xcode is signed in). If it prints nothing or errors, the script's stderr will tell you which detection step failed.

- [ ] **Step 4: Verify env var override works**

```bash
IOS_DEVELOPMENT_TEAM=AAAAAAAAAA ./scripts/ios-team-id.sh
```

Expected: prints `AAAAAAAAAA` (env var wins over detection).

---

## Task 3: Add `scripts/ios-configure-signing.sh`

**Files:**
- Create: `scripts/ios-configure-signing.sh`

- [ ] **Step 1: Create the script**

Create `scripts/ios-configure-signing.sh` with the full content from the design doc. The complete file content is reproduced below.

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${ROOT_DIR}/config"
TEAM_ID_SCRIPT="${ROOT_DIR}/scripts/ios-team-id.sh"
LOCAL_SIGNING_FILE="${CONFIG_DIR}/.local-signing.xcconfig"

sanitize_identifier_segment() {
  local raw="${1:-}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  raw="$(printf '%s' "$raw" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$raw" ]]; then
    raw="local"
  fi
  printf '%s\n' "$raw"
}

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

- [ ] **Step 2: Make the script executable**

```bash
chmod +x scripts/ios-configure-signing.sh
```

- [ ] **Step 3: Run the script and verify the file is written**

```bash
./scripts/ios-configure-signing.sh
cat config/.local-signing.xcconfig
```

Expected: script prints `Configured iOS signing: team=24X2NMFQUY app=com.smartchat.SmartChatApp` (or your actual team). The file contains 6 `SMARTCHATAPP_*` assignments matching the design doc.

- [ ] **Step 4: Verify idempotency**

```bash
./scripts/ios-configure-signing.sh
```

Expected: prints `iOS signing config already up to date: ...` (no file write because `cmp -s` matched).

- [ ] **Step 5: Verify git ignores the file**

```bash
git check-ignore -v config/.local-signing.xcconfig
```

Expected: prints something like `config/.gitignore:1:.local-signing.xcconfig config/.local-signing.xcconfig` (the file is ignored by the new `config/.gitignore`).

---

## Task 4: Wire xcconfig into `project.yml`

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Inspect the current signing block**

```bash
grep -n -E "DEVELOPMENT_TEAM|CODE_SIGN_STYLE|PRODUCT_BUNDLE_IDENTIFIER" project.yml
```

Expected: 4 lines (lines 16, 17, 36, 80 — verified during design phase).

- [ ] **Step 2: Replace the project-level defaults**

In `project.yml`, around line 16-17, change:

```yaml
    DEVELOPMENT_TEAM: "24X2NMFQUY"
    CODE_SIGN_STYLE: Automatic
```

to:

```yaml
    DEVELOPMENT_TEAM: "$(SMARTCHATAPP_DEVELOPMENT_TEAM)"
    CODE_SIGN_STYLE: "$(SMARTCHATAPP_CODE_SIGN_STYLE)"
```

- [ ] **Step 3: Replace the main app's Bundle ID**

In `project.yml`, around line 36, change:

```yaml
        PRODUCT_BUNDLE_IDENTIFIER: com.smartchat.SmartChatApp
```

to:

```yaml
        PRODUCT_BUNDLE_IDENTIFIER: "$(SMARTCHATAPP_APP_BUNDLE_ID)"
```

- [ ] **Step 4: Replace the tests target's Bundle ID**

In `project.yml`, around line 80, change:

```yaml
        PRODUCT_BUNDLE_IDENTIFIER: com.smartchat.SmartChatAppTests
```

to:

```yaml
        PRODUCT_BUNDLE_IDENTIFIER: "$(SMARTCHATAPP_TESTS_BUNDLE_ID)"
```

- [ ] **Step 5: Add `configFiles: base` to each target**

For each top-level target entry in `project.yml` (search for `targets:` → `  - name:` → look for the `settings:` block under each target), add a `configFiles:` block right before the `settings:` line. Example for the main app target:

```yaml
  - name: SmartChatApp
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    configFiles:
      base: config/Signing.xcconfig
    settings:
      base:
        ...
```

Apply the same `configFiles: base: config/Signing.xcconfig` block to:
- The main app target
- The tests target
- Any extension / widget targets (verify by `grep -n 'name:' project.yml` and check for entries other than `SmartChatApp` / `SmartChatAppTests`)

If a target already has a `configFiles:` block, add the `base` key to the existing map rather than overwriting it.

- [ ] **Step 6: Verify xcodegen still accepts the project**

```bash
xcodegen generate
```

Expected: `Created project at /Users/kk/workspace/github/SmartChatApp/SmartChatApp.xcodeproj` with no errors. If xcconfig variables fail to resolve, the error will be specific (e.g., `error: Unable to find settings named "SMARTCHATAPP_DEVELOPMENT_TEAM"`).

- [ ] **Step 7: Verify the rendered project has the right values**

```bash
grep -E "DEVELOPMENT_TEAM|PRODUCT_BUNDLE_IDENTIFIER" SmartChatApp.xcodeproj/project.pbxproj | head -20
```

Expected: each match shows the resolved value (`24X2NMFQUY` for `DEVELOPMENT_TEAM`, `com.smartchat.SmartChatApp` for `PRODUCT_BUNDLE_IDENTIFIER`), not `$(SMARTCHATAPP_*)`. If you see the unresolved variables, the `configFiles: base` reference isn't reaching xcodegen — re-check Step 5.

---

## Task 5: Add Makefile targets and chain them

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Inspect the current Makefile**

```bash
cat Makefile
```

- [ ] **Step 2: Add the three new targets**

Add these targets near the top of the Makefile (before `build` / `install` / `compile-only`):

```makefile
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
```

- [ ] **Step 3: Chain `configure-signing` into `compile-only`**

Find the `compile-only` target. Change its first line from:

```makefile
compile-only:
```

to:

```makefile
compile-only: configure-signing
```

- [ ] **Step 4: Chain `configure-signing` into `build`**

Find the `build` target. Change its first line from:

```makefile
build:
```

to:

```makefile
build: configure-signing
```

- [ ] **Step 5: Verify `install` inherits the chain**

`install` should already list `build` (or a chain that ends in `build`) as a prerequisite. Verify with:

```bash
grep -A 3 "^install:" Makefile
```

If `install:` does NOT depend on `build:`, add `build` as a prerequisite of `install`. (Per the design doc, `install` is expected to chain through `build`, which is why no separate change is needed.)

- [ ] **Step 6: Verify the Makefile parses**

```bash
make -n configure-signing
make -n detect-team
make -n clean-signing
make -n build
make -n install
```

Expected: each `make -n` prints the commands that would run, including `bash scripts/ios-configure-signing.sh` as the first line of `build` / `install` / `compile-only`.

---

## Task 6: End-to-end verification

- [ ] **Step 1: Confirm `make detect-team` works**

```bash
make detect-team
```

Expected: prints the 10-character Team ID, exits 0.

- [ ] **Step 2: Confirm `make configure-signing` writes the local override**

```bash
rm -f config/.local-signing.xcconfig
make configure-signing
cat config/.local-signing.xcconfig
```

Expected: file is created with the 6 `SMARTCHATAPP_*` assignments.

- [ ] **Step 3: Confirm `make compile-only` still builds (no signing required)**

```bash
make compile-only 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. (This was already passing before this change — we're verifying we didn't break it.)

- [ ] **Step 4: Confirm `make build` resolves Team ID and tries to sign**

```bash
make build 2>&1 | tail -20
```

Expected: build attempts to sign with `24X2NMFQUY` (or your detected Team). If your keychain has a valid certificate, `** BUILD SUCCEEDED **`. If the certificate is revoked or missing, the error will be the same as before this change — `Signing certificate is invalid` or `No Accounts` — but with the Team ID auto-populated, fixing it is now a matter of fixing the Apple account, not the project.

- [ ] **Step 5: Confirm `make install` chains through correctly**

```bash
make -n install
```

Expected: first command is `bash scripts/ios-configure-signing.sh`, then `xcodegen generate` (if present in `build`), then `xcodebuild`, then `xcrun devicectl device install app`.

- [ ] **Step 6: Confirm `git status` does not track the local override**

```bash
git status
```

Expected: `config/.local-signing.xcconfig` does NOT appear in the untracked files list (it is ignored by `config/.gitignore`). Other modified files (`project.yml`, `Makefile`, `config/Signing.xcconfig`, etc.) DO appear.

---

## Verification Summary

| Check | Command | Expected |
|---|---|---|
| Detect team | `make detect-team` | Prints 10-char Team ID |
| Auto-write override | `make configure-signing` | Creates `config/.local-signing.xcconfig` |
| Idempotent | Run `configure-signing` twice | Second run prints "already up to date" |
| xcconfig ignored | `git check-ignore config/.local-signing.xcconfig` | Exits 0 with the ignore path |
| xcodegen valid | `xcodegen generate` | Succeeds |
| Variables resolved | `grep DEVELOPMENT_TEAM *.pbxproj` | Shows real Team ID, not `$(...)` |
| `compile-only` still works | `make compile-only` | `** BUILD SUCCEEDED **` |
| `build` uses detected team | `make build` | Build log shows detected Team ID |
| `install` chains | `make -n install` | First line is `bash scripts/ios-configure-signing.sh` |

## Out of Scope

- Simulator build target (`make run-sim`). Not asked for; would route through `xcodebuild -destination 'platform=iOS Simulator'` with no signing.
- TestFlight / App Store Connect upload automation. Personal app, no TestFlight need.
- Multi-Apple-ID profile switching UI. `LocalSigning.xcconfig` covers the manual case.
- Re-introducing the per-user Bundle ID suffix. Deferred until a second developer joins.
- `Info.plist` re-generation. The current `info.properties` block in `project.yml` is unrelated to signing and stays as-is.
