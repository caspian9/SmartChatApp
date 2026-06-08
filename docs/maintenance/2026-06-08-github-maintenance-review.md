# GitHub Maintenance Review

**Date:** 2026-06-08
**Repo:** `caspian9/SmartChatApp` (currently `private`)
**Scope:** README, Actions, Release/Package, Templates, Hardening-for-Public, Extra Config
**Method:** Static review of the working tree (`main` @ `169812e`); no GitHub-side checks.

> TL;DR — the repo is **publishable in shape** but a small set of high-leverage edits
> will materially improve maintainability: fix one stale claim in the README (TCA →
> `@Observable`), parameterize the `openclaw` sibling in CI, add a few community-health
> files, and decide whether you want Releases / changelogs / TestFlight in scope.
> All findings below are **advisory** — implement when you're ready.

---

## Inventory of what already exists

```
.github/
├── ISSUE_TEMPLATE/
│   ├── bug_report.md          (✅ present, well-shaped)
│   └── feature_request.md     (✅ present, well-shaped)
├── PULL_REQUEST_TEMPLATE.md   (✅ present, has checklist)
└── workflows/
    └── ci.yml                 (✅ build + test on macos-15)
```

| Asset | Present | Notes |
|---|---|---|
| `README.md` | ✅ | Stale "TCA" claim; missing scripts/config/ version pipeline |
| `CLAUDE.md` | ✅ | Internal — keep in repo, link from a public note if making public |
| `LICENSE` | ✅ | MIT, but copyright holder is the literal string `"SmartChatApp"` |
| `CODEOWNERS` | ❌ | |
| `CONTRIBUTING.md` | ❌ | Embedded in README; no standalone file |
| `SECURITY.md` | ❌ | No disclosure process for a chat app that handles tokens |
| `SUPPORT.md` | ❌ | No help/contact channel |
| `CHANGELOG.md` | ❌ | |
| `dependabot.yml` | ❌ | No automated dep-update PRs |
| `codeql.yml` | ❌ | No SAST scanning |
| `.github/ISSUE_TEMPLATE/config.yml` | ❌ | No template chooser / external link |
| Releases / `git tag` strategy | ❌ | Tags exist implicitly; no `release.yml` automation |
| Fastlane / TestFlight / `exportOptions.plist` | ❌ | None in tree |
| Branch protection | ❌ (GitHub-side) | Not set on `main` |
| Secret scanning | ❌ (GitHub-side) | Off by default for private repos |
| `Settings → Code security → Private vulnerability reporting` | ❌ | Off |

---

## 1. README — accuracy and gaps

The README is mostly accurate, but a few items have drifted out of sync with the code.

### Must fix (factually wrong)

1. **State-management tech stack is wrong.** README says:

   > **The Composable Architecture** 1.9.3 for state management

   The actual code is `@MainActor @Observable` (iOS 17 Observation). See
   `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift:32`
   (`@Observable final class NativeChatViewModel`) and
   `SmartChatApp/Core/Network/ConnectionState.swift:10`. The only TCA mention in
   the source tree is a *comment* describing a previous design
   (`NativeChatViewModel.swift:36-37` "The previous @Reducer version had…").

   `Package.resolved` contains `swift-concurrency-extras` (a tiny utility) but
   **no** `swift-composable-architecture` pin. Fix:

   ```diff
   - **The Composable Architecture** 1.9.3 for state management
   + **iOS 17 Observation** (`@Observable` + `@MainActor`) for state management
   ```

2. **Tests are more extensive than the roadmap admits.** `Roadmap` says
   "Test coverage for `NativeChatViewModel` agent event stream handling" is
   *not* done. But there are 9 test files (incl. `NativeChatScrollRequestTests`,
   `ChatMessageConverterTests`, `ConnectionCoordinatorCoalescingTests`,
   `ConnectionStateTests`, `GatewayChatTransportTests`,
   `NativeChatViewModelFormatterTests`, `AppLoggerTests`, `SessionKeyTests`).
   Replace the unchecked box with a checked one and add the new
   `NativeChatViewModel`/event-stream suite to the doc.

3. **Required Xcode version drifted.** README says "Xcode 15+", but
   `project.yml:6` requires `xcodeVersion: "15.0"`, deployment target is
   **iOS 18.0** (not 18+), and the CI workflow pins **Xcode 26.3** (Swift 6.2+).
   iOS 18 deployment on a macOS-15 runner with Xcode 16.4 (Swift 6.1) will
   *fail* to build the `openclaw` sibling, which is exactly the problem the
   `setup-xcode` step is solving. So "Xcode 15+" understates the floor for
   this exact configuration; state the actual minimum:

   ```diff
   - macOS with **Xcode 15+**
   - iOS **18.0+** deployment target
   + macOS with **Xcode 16.4** (project) / **Xcode 26.3** (CI to match
   +   the OpenClaw sibling's swift-tools-version 6.2)
   + iOS **18.0** deployment target
   ```

### Should add

4. **Sibling-repo requirement.** `project.yml:27` path-links `OpenClawKit`
   from `../openclaw/apps/shared/OpenClawKit`, and CI mirrors this with
   `git clone … ../openclaw`. Anyone cloning the repo and running
   `make build` outside this layout will fail. Add a sentence in **Build**:

   > **Prerequisite directory layout:** SmartChatApp must live at
   > `…/SmartChatApp/` with the OpenClawKit fork at `…/openclaw/apps/shared/OpenClawKit/`
   > (sibling, not nested). See "Sourcing OpenClawKit" below.

   And add a "Sourcing OpenClawKit" section explaining both the local-checkout
   option and the CI clone.

5. **Scripts and config layer are invisible.** `Makefile` exposes
   `configure-signing`, `detect-team`, `clean-signing`, `inject-build-timestamp`,
   but the README never links to `scripts/`. A one-liner that says

   > `make build` auto-runs `scripts/ios-team-id.sh` (signing) and
   > `scripts/inject-build-timestamp.sh` (Apple-standard CFBundleVersion).
   > Override locally via `config/LocalSigning.xcconfig` /
   > `config/LocalVersion.xcconfig` (both git-ignored, `.example` files
   > show the schema).

   …avoids the "where does `TEAM_ID` come from?" question a new contributor
   will hit on first build.

6. **Version display convention.** With the new pipeline the device shows
   `Version 0.0.1  Build 348.abc1234` in Debug, `348` in Release. A short
   "Versioning" section in the README explaining the rule will save a future
   bug report ("why does my build number keep changing?").

### Nice to have

7. **iOS device requirement bullet is misleading.** "A connected iPhone for
   device builds" suggests device is needed for *any* build, but
   `make compile-only` runs without a device. Mention both.

8. **`make list-devices` is duplicated.** Both `xcdevice list` (JSON
   filter) and `devicectl` are run. Fine for now, but call it out so the
   output isn't a surprise.

---

## 2. GitHub Actions — what to improve

`ci.yml` is functional and the inject-build-number / clear-Stale-SwiftPM /
`setup-xcode 26.3` workarounds are well-commented. The suggestions below are
about making the workflow *robust across contributors* and *useful as a
quality gate*.

### High priority

1. **Parameterize the `openclaw` fork owner.** Hardcoded as `caspian9`:
   ```yaml
   "https://x-access-token:${GITHUB_TOKEN}@github.com/caspian9/openclaw.git" \
   ```
   - Forks of the repo (PRs from non-`caspian9` users) will try to clone a
     *private* `caspian9/openclaw` and 404 — every contributor-facing PR will
     break CI.
   - Mirror this from a single env: `OPENCLAW_REPO: ${{ vars.OPENCLAW_REPO ||
     'caspian9/openclaw' }}`, or use an `org/…` variable so it can be
     re-pointed without editing the file. Alternatively, treat `openclaw` as
     a *vendored* Swift package and embed it under `Vendor/` to remove the
     network dependency entirely.

2. **Pin the `setup-xcode` action to a SHA, not a version tag.** `26.3` is a
   *Xcode version string*, not a release of `maxim-lobanov/setup-xcode`. The
   action does handle the right syntax, but pinning the action commit (e.g.
   `@<full-sha>`) is the standard supply-chain hardening step. Same for
   `actions/checkout@v4`.

3. **Caching.** `DerivedData` and SwiftPM caches are wiped on every run.
   Add a keyed cache keyed on `Package.resolved` to keep build times down:
   ```yaml
   - uses: actions/cache@v4
     with:
       path: |
         build/SourcePackages
         build/Build/Intermediates.noindex
         ~/Library/Caches/org.swift.swiftpm
         ~/Library/org.swift.swiftpm
       key: ${{ runner.os }}-spm-${{ hashFiles('**/Package.resolved') }}
       restore-keys: |
         ${{ runner.os }}-spm-
   ```
   The `Clear stale SwiftPM artifacts` step is still useful as a *first*
   run; gate the clear behind `hashFiles` changing.

### Medium priority

4. **Test result reporting.** `xcodebuild test` writes a `.xcresult`
   bundle but no `xcodebuild-test-without-building` style report is
   uploaded. Add `testflightgh/xcodebuild-test-report` or
   `dduan/xcbeautify` + upload the `.xcresult` as a build artifact for
   post-mortem debugging.

5. **Concurrency controls.** `concurrency: { group: ci-${{
   github.ref }}, cancel-in-progress: true }` saves runner minutes on
   rapid pushes to the same PR. Trivial to add, no downsides.

6. **Branch / `paths` filter.** `on: push: branches: [main]` is fine; add
   `pull_request: branches: [main]` (already present, good). Consider
   ignoring `docs/**` and `*.md` so docs PRs don't queue a 25-minute build.

7. **Permissions block.** Add top-level `permissions:` minimal grants
   (currently relying on default `GITHUB_TOKEN` perms, which is `read-all`
   on private repos — too broad for a public one):
   ```yaml
   permissions:
     contents: read
   ```

8. **`xcode-version: '26.3'` will stop being installable.** Xcode is pinned
   by version string, not by a GitHub-known SKU. When Apple renames /
   re-bundles, the install will fail loudly. Add a fallback or a smoke
   test ("did the install succeed?") so the failure is caught locally
   before merge.

### Low priority

9. **Matrix on iOS simulator destination.** `iPhone 17 Pro` is fine; adding
   `iPhone 16` as a second matrix entry would catch SDK-target mismatches
   on devices that are more conservative on iOS 18 features.

10. **Status badge.** Add a `[![CI](…)](…)` line to the README so
    contributors see at a glance whether `main` is green.

11. **Dependabot for GitHub Actions.** When you add `dependabot.yml`, set
    `package-ecosystem: github-actions` so `setup-xcode` and
    `actions/checkout` get auto-PRs.

---

## 3. Release & packaging — what's missing

There is **no** release process today. `git tag` is implied but no
automation drives it. For an iOS app the realistic options are:

### Option A — minimal (recommended for now)

- Add `CHANGELOG.md` (Keep-a-Changelog style). Update by hand per release.
  Cheapest way to give users "what changed".
- Add a lightweight `release.yml` workflow that:
  - triggers on `push: tags: ['v*']`
  - runs `xcodebuild archive -scheme SmartChatApp -archivePath build/SmartChatApp.xcarchive`
  - exports an `.ipa` with an `ExportOptions.plist` (`method: development`)
  - uploads the `.xcarchive` and `.ipa` as workflow artifacts
- Add a `v0.0.2` tag to mark the first public release.

### Option B — full TestFlight lane (only when ready)

- `Gemfile` + `fastlane/` directory
- `match` for signing-cert + provisioning-profile sync (the
  `config/Signing.xcconfig` + `scripts/ios-configure-signing.sh` work
  already handles local dev signing; `match` adds the CI / store path)
- `pilot` lane: `build → upload → distribute_external` (TestFlight)
- App Store Connect API key via OIDC (`./AppStoreConnect_API_Key.p8` in
  a GitHub Environment secret, not a long-lived JWT)

### Option C — open-source distribution only (no App Store)

- Skip TestFlight. Just produce the `.ipa` + `.xcarchive` and attach to
  the GitHub Release. Users install via `xcrun devicectl device install app`.
  Good for an early / sideload-only project.

### Independent of which option

12. **`ExportOptions.plist`** in repo (gitignored if it embeds
    `provisioningProfiles.<bundle-id>.{name,UUID}`). A *template* with
    the bundle id filled in and the profile data left as `$(…)` placeholders
    is the right pattern.

13. **Tag-driven versioning.** `make bump-patch` (or hand-rolled
    `scripts/bump-version.sh`) that:
    - updates `config/Version.xcconfig` `SMARTCHATAPP_MARKETING_VERSION`
    - mirrors it in `project.yml` `settings.base.MARKETING_VERSION`
    - appends to `CHANGELOG.md`
    - commits + tags

    The current pipeline already gives you a monotonic `BUILD_NUMBER`
    (`github.run_number` on CI) without intervention; the missing piece
    is the *marketing* version bump and the `CHANGELOG.md` line.

14. **DSA / signing for release builds.** The current Signing.xcconfig
    auto-detects the *first* Team in the user's account list. For
    release builds you almost always want to *pin* the team via
    `IOS_DEVELOPMENT_TEAM` env (the script already honors it — first
    `if`). Document that in the release workflow.

15. **"Package" output.** The repo is *not* a Swift package
    (no `Package.swift` at the root). If you mean "distribute as an SPM
    library", that's a larger refactor (split `Core/…` into a `Library/`
    target with a `Package.swift`). Most likely you don't need this;
    clarify the intent.

---

## 4. Issue & PR templates — coverage

Templates are present and well-structured. Gaps:

16. **Missing template types.** Add:
    - **`security.md`** — separate intake for auth-token / TLS /
      PII issues. Funnels to `SECURITY.md`, not a public tracker.
    - **`docs.md`** — typoes, broken links, unclear wording in
      `README.md` / `docs/`. Lightweight, no env-block required.
    - **`question.md`** — "How do I…?" funneled to GitHub Discussions
      once you enable it.

17. **Add `.github/ISSUE_TEMPLATE/config.yml`** to:
    - make the chooser ("Bug / Feature / Question / Docs / Security")
    - link to Discussions (when enabled)
    - link to SECURITY.md for private reporting
    - set default `assignees: []` / `labels: []` behavior
    ```yaml
    blank_issues_enabled: false
    contact_links:
      - name: GitHub Discussions
        url: https://github.com/caspian9/SmartChatApp/discussions
        about: Questions and open-ended discussion
      - name: Security issue
        url: https://github.com/caspian9/SmartChatApp/security/advisories/new
        about: Please report security issues privately, not as a public bug.
    ```

18. **PR template is good but missing:**
    - "Migration / install impact" — required when the change is
      `BREAKING` and old users might be on the previous build.
    - "Linked issues" — `Fixes #N` line, like GitLab does by default.
    - "Screenshot / Recording" — bigger barrier for UI changes, but
      the current "Screenshots / Logs" is one block, not labeled
      required.

19. **`PULL_REQUEST_TEMPLATE.md` references `make build`** but not the
    sibling-checkout prerequisite. Add:

    > The `../openclaw` sibling must be present (or CI will fail at
    > `git clone` step). See README → Sourcing OpenClawKit.

20. **Changelog requirement.** Add a checkbox:

    ```
    - [ ] `CHANGELOG.md` updated under the next-version heading
          (or `[Unreleased]` if no version bump yet)
    ```

---

## 5. Hardening for public release

If you flip the repo to `public`, scan the working tree for anything that
shouldn't ship.

### Code-level findings

21. **`SmartChatApp/Features/Home/DeviceInfoView.swift:5`** — ~~hardcodes
    the device name:~~ **Resolved 2026-06-08 by deletion.** The view was
    dead code: no `.swift` file imported or instantiated it; the
    `connectionBanner` in `HomeView` already shows
    `connectionState.connectedDeviceName + host`. Plan doc
    `2026-05-18-homescreen-redesign-implementation.md:144` referenced
    it but the call was never wired in. Deleting avoids the risk of
    someone re-importing the hardcoded string later. Removed in commit
    `refactor(home): remove unused DeviceInfoView`.

22. **Auth-token logging discipline is good, but check the ring buffer.**
    `AppLogger` writes to OSLog and a 2000-line `LogRingBuffer`
    (`Core/Services/AppLogger.swift`). A user looking at *Settings → Debug
    Logs Viewer* could see URL strings, server responses, etc. A grep for
    `AppLogger.log(.*profile` and `AppLogger.log(.*url` would confirm.
    Add a `redact(token:)` helper that prefixes `[REDACTED]` and call
    it from any site that could leak a token.

23. **`24X2NMFQUY` is in `git log`** even though the current
    `project.yml` no longer has it. `git log -p --all -S 24X2NMFQUY`
    will surface the historical leak. For *some* definitions of
    "personal info" the Team ID is fine; treat this as "be aware
    before going public with a username-mapped commit graph".

24. **`docs/superpowers/specs/2026-06-08-ios-signing-xcconfig-design.md`**
    and other design docs are *internal thinking* documents. They
    mention `Hai's iPhone`, `caspian9`, etc. Decide whether to:
    - keep `docs/` public and scrub the personal references, or
    - move them to a `docs-internal/` (gitignored) tree, or
    - leave them; they read as a development journal, not customer docs.

    The current `docs/README.md` does say "preserved as a record of
    original design intent" which is fine, but `Hai's iPhone` and
    `caspian9` are still searchable in plaintext.

### Repo-level

25. **`.DS_Store` and similar macOS metadata.** Confirm with
    `git ls-files | grep -E '\.DS_Store|Icon\r'` (none expected — the
    `.gitignore` covers `.DS_Store`).

26. **License copyright holder.** `LICENSE` says
    `Copyright (c) 2026 SmartChatApp`. If the legal entity is your name
    or a company, replace `"SmartChatApp"` (the project name) with the
    actual copyright holder. Without it, the MIT license is technically
    still valid but the enforcement picture is murkier.

27. **Third-party attribution.** `Package.resolved` pulls in 9 SPM
    packages (ElevenLabsKit, Kingfisher, MarkdownDisplayView,
    swift-cmark, swift-concurrency-extras, swift-markdown, swiftui-math,
    textual) and path-links to `openclaw/apps/shared/OpenClawKit`. All
    are MIT / Apache-2.0, so a NOTICE / THIRD_PARTY_LICENSES file is
    *not strictly required* by every license, but the Apache-2.0 ones
    (e.g. `Kingfisher` is MIT, `swift-markdown` is Apache-2.0) require
    preserving the copyright notice and the license text. Add
    `THIRD_PARTY_LICENSES.md` to be safe; script it via
    `acknowledgementBundler` or a hand-rolled `make licenses`.

28. **`config/LocalSigning.xcconfig.example` and
    `config/LocalVersion.xcconfig.example`** are committed. **Make sure
    the `.example` files contain no real values.** Currently they
    contain only commented-out schema, which is correct.

29. **Branch protection (Settings → Branches → main).** For a public
    repo before going public:
    - Require PR + 1 review
    - Require status checks: `build-and-test` (the CI job name)
    - Require linear history (no merge commits in `main` going forward;
      the existing merge commit is fine as a one-off)
    - Do **not** allow force-pushes
    - Include administrators (don't let yourself bypass)

30. **Secret scanning.** Enable on the repo. Run
    `gitleaks detect --no-banner` locally first to catch any token that
    snuck in (likely clean, but a single check is cheap).

31. **Private vulnerability reporting.**
    `Settings → Code security → Enable private vulnerability reporting`.
    Required for any project that handles auth tokens
    (`ProfileManager` does, even if they're stored in UserDefaults).

---

## 6. Extra GitHub-side config

32. **Dependabot (`dependabot.yml`)**:
    ```yaml
    version: 2
    updates:
      - package-ecosystem: "github-actions"
        directory: "/"
        schedule: { interval: "weekly" }
      - package-ecosystem: "swift"
        directory: "/"
        schedule: { interval: "weekly" }
        # Package.resolved updates; review for SwiftUI / iOS API breakage
        groups:
          swiftui:
            patterns: ["*"]
    ```
    SPM updates can break iOS-targeted APIs without warning; review each
    PR rather than auto-merge.

33. **CodeQL (`codeql.yml`)** — a one-liner `.github/workflows/codeql.yml`:
    ```yaml
    name: CodeQL
    on: { push: { branches: [main] }, pull_request: { branches: [main] } }
    jobs:
      analyze:
        uses: github/codeql-action/init-codeql@v3
        with: { languages: swift }
      analyze-runs:
        uses: github/codeql-action/analyze@v3
    ```
    For an iOS app the security surface is small (no auth-server code
    lives in the repo), but CodeQL still catches things like insecure
    deserialization in the message-cache layer and `URL(string:)` traps.

34. **GitHub Environments.** Create a `release` environment (Settings →
    Environments). Restrict who can approve a deployment; gate the
    TestFlight / archive upload job behind it.

35. **OIDC for future App Store Connect auth** (when you go to Option B
    in §3). Long-lived `APP_STORE_CONNECT_API_KEY_ID` +
    `APP_STORE_CONNECT_API_ISSUER_ID` + the `.p8` private key are
    risky to keep as repo / org secrets. Apple's
    `appstoreconnect-auth` action supports OIDC.

36. **Discussions.** Enable (Settings → General → Features →
    Discussions). Useful for "How do I…?" questions that don't belong
    in issues. Add categories: `General`, `Q&A`, `Show and tell`,
    `Node capabilities` (since stubs are a known entry point for
    questions).

37. **Labels (color-coded, consistent prefix).** Current `bug`,
    `enhancement` is fine for a 2-template setup. When you add security
    / docs / question templates, add labels: `security`, `docs`,
    `question`, `node-capability`, `good first issue`, `help wanted`,
    `priority: high/medium/low`.

38. **GitHub Wiki vs `docs/`.** For a public repo, prefer `docs/` in
    the repo (the wiki is search-engine-invisible, forks-don't-inherit,
    no PR review). The current `docs/` layout is good.

39. **`FUNDING.yml`** — only if you want sponsorship buttons. Skip
    unless you do.

40. **`/docs` GitHub Pages site (optional).** If `docs/` grows
    (architectural decision records, runbooks), `mkdocs` or
    `swift-doc` for a static site is nice. Out of scope for now.

41. **Project board.** A single "Roadmap" project with columns
    `Backlog / In progress / Review / Done` mapping to the
    `Roadmap` checklist in the README. Skip until the checklist
    stops fitting in one section.

42. **Renaming the default branch from `main`.** No reason to; leave
    it.

43. **`xcodebuild` warnings gate.** The CI job currently doesn't fail
    on warnings. Add `GCC_TREAT_WARNINGS_AS_ERRORS=YES` for the
    `Release` build (and the test build) to catch ABI / deprecation
    issues early. Optional but cheap.

44. **`.swift-version` / `Package.resolved` strategy.** The repo
    has `Package.resolved` committed (good — reproducible builds).
    Confirm Dependabot config (§32) uses `version: 2` with
    `rebase-strategy: "auto"` so PRs target the existing range, not
    a hard pin bump.

45. **`xcode-version: '26.3'` won't exist forever.** When Apple
    releases Xcode 27 the workflow silently installs a wrong version
    (or fails). Add a smoke test (run `xcodebuild -version` after
    `setup-xcode`) and fail the job if the version doesn't match a
    regex. Use the regex as a *minimum*, not exact match.

---

## Prioritized checklist

The list below is ordered by **effort → impact** (quick wins first). Each
item references the section number above for context.

### Now (≤ 1 hour total)

- [ ] **1** — README: fix TCA → `@Observable` line.
- [ ] **1** — README: mark the test-coverage roadmap item as done.
- [ ] **1** — README: correct the Xcode / iOS version floor.
- [ ] **1** — README: add a "Sourcing OpenClawKit" section.
- [ ] **2** — CI: add `permissions: contents: read`.
- [ ] **2** — CI: add `concurrency:` block.
- [x] **21** — `DeviceInfoView.swift`: removed (was dead code). Done 2026-06-08.
- [ ] **19** — PR template: add the `../openclaw` sibling note.
- [ ] **17** — add `.github/ISSUE_TEMPLATE/config.yml`.
- [ ] **16** — add `docs.md` and `question.md` issue templates.

### This week (1–4 hours)

- [ ] **1** — README: add "Versioning" + "scripts/" + "config/" sections.
- [ ] **2** — CI: cache `~/Library/Caches/org.swift.swiftpm` + `build/SourcePackages`.
- [ ] **2** — CI: parameterize `OPENCLAW_REPO` env.
- [ ] **2** — CI: pin `actions/checkout`, `setup-xcode`, `cache` to commit SHAs.
- [ ] **10** — Add CI status badge to README.
- [ ] **30** — Enable secret scanning.
- [ ] **31** — Enable private vulnerability reporting.
- [ ] **29** — Configure branch protection on `main`.
- [ ] **27** — Add `THIRD_PARTY_LICENSES.md`.
- [ ] **37** — Standardize labels (`bug`, `enhancement`, `security`,
            `docs`, `question`, `node-capability`, `good first issue`,
            `help wanted`, `priority: high/medium/low`).

### When you're ready for releases

- [ ] **3** — Add `CHANGELOG.md` (Keep-a-Changelog format).
- [ ] **13** — `scripts/bump-version.sh` + `make bump-patch`.
- [ ] **3** — Add `release.yml` workflow (archive + `.ipa` artifact on `v*` tags).
- [ ] **3** — Add `ExportOptions.plist` (template, profile-id placeholders).
- [ ] **34** — Create a `release` GitHub Environment.
- [ ] **14** — Document `IOS_DEVELOPMENT_TEAM` env override for CI/release builds.

### Optional / nice-to-have

- [ ] **9** — Matrix build on `iPhone 16` + `iPhone 17 Pro` simulators.
- [ ] **4** — Upload `.xcresult` test report as CI artifact.
- [ ] **33** — Add `codeql.yml` for Swift.
- [ ] **32** — Add `dependabot.yml` for `github-actions` and `swift`.
- [ ] **36** — Enable Discussions with categories.
- [ ] **43** — Treat warnings as errors on `Release` builds.
- [ ] **35** — OIDC for App Store Connect when TestFlight is added.
- [ ] **40** — GitHub Pages site from `docs/` (only if `docs/` grows).

### Security / privacy review before flipping to public

- [ ] **22** — Add `AppLogger.redact(token:)` helper; grep and wrap
            any site that logs profile data.
- [ ] **23** — Decide whether to scrub `Hai's iPhone` / `caspian9`
            references from `docs/superpowers/`.
- [ ] **24** — Decide whether to move `docs/superpowers/` to a
            gitignored internal tree.
- [ ] **25** — `git ls-files | grep -E '\.DS_Store|Icon\r'`.
- [ ] **26** — Replace `"SmartChatApp"` in `LICENSE` with the
            actual legal copyright holder.
- [ ] **30** — `gitleaks detect` sweep.

---

## Summary

The repo is **internally coherent and ready for everyday dev use** —
the version pipeline, signing layer, CI build/test, and templates all
do their job. The gaps fall into three buckets:

1. **Stale docs that misrepresent the code** (TCA, Xcode floor,
   roadmap item). 30 minutes of edits.
2. **CI/branch hygiene for multi-contributor use** (parameterize the
   sibling repo, permissions, concurrency, secret scanning, branch
   protection). Half a day.
3. **Public-release readiness** (DeviceInfoView hardcoded name,
   third-party licenses, LICENSE copyright holder, scrubbing personal
   references from internal docs). Another half-day.

Releases / TestFlight / fastlane are intentionally **out of scope**
for this review — they belong in a separate plan once you decide
whether SmartChatApp ships through the App Store, sideload, or both.
