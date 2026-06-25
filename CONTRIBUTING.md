# Contributing to SmartChatApp

Thanks for considering a contribution. This guide is short on
purpose — the rest of the project docs (especially
[CLAUDE.md](CLAUDE.md), the AI-assistant project notes kept at
the repo root) explain the architecture in depth.

## Before you start

The repo has a **sibling-checkout layout**. SmartChatApp
expects an OpenClawKit fork at `../openclaw/apps/shared/
OpenClawKit/`:

```
workspace/
├── SmartChatApp/    ← this repo
└── openclaw/        ← OpenClawKit fork
    └── apps/shared/OpenClawKit/
```

CI clones `caspian9/openclaw` automatically into `../openclaw`
before `xcodegen generate`; locally, clone (or symlink) the
fork into the sibling position before running `make build`. See
[README.md → Quick Start → 1. Get the code](README.md#get-the-code)
for details.

## Local setup

```bash
# 1. Get the code
git clone https://github.com/caspian9/SmartChatApp.git
cd SmartChatApp

# 2. Get the OpenClaw sibling (see layout above)
git clone https://github.com/caspian9/openclaw.git ../openclaw

# 3. Generate the Xcode project + build
xcodegen generate
make build
```

`make build` auto-runs `scripts/ios-team-id.sh` to detect
your Apple Developer Team ID and writes it (plus canonical
bundle IDs) into the git-ignored
`config/.local-signing.xcconfig`. Override manually via
`config/LocalSigning.xcconfig` (see the `.example` template).

## Picking an issue

Issues tagged `good first issue` are scoped, well-described,
and a maintainer can review them in one sitting. Issues
tagged `help wanted` are larger and may need design input —
leave a comment before starting so we can agree on the
approach.

If you want to scratch your own itch, the
[Roadmap](README.md#roadmap) lists what's NOT done. Pick one,
open an issue describing your approach, and link the PR to it.

## Making a change

1. **Branch from `main`.** Keep your branch narrow — one
   logical change per PR. Rebase against `main` before
   requesting review so the diff is clean.

2. **Match the existing code style.** Swift code follows the
   default `swift-format` style; the project does not pin a
   custom `.swift-format` file. `xcodebuild` warnings are
   treated as errors in CI (`GCC_TREAT_WARNINGS_AS_ERRORS=YES`)
   so any new warning fails the build.

3. **Tests.** New behavior needs a unit test in
   `SmartChatAppTests/`. Run the full suite locally before
   pushing:

   ```bash
   xcodebuild test \
     -scheme SmartChatApp \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
     -derivedDataPath build \
     -skipMacroValidation \
     CODE_SIGNING_ALLOWED=NO
   ```

   The matrix runs on iPhone 16 (iOS 18 penultimate) too; if
   your change targets a specific iOS version, run both
   destinations locally before pushing.

4. **Privacy-protected APIs.** If your change touches a
   privacy-protected capability (camera, photos, contacts,
   calendar, microphone, etc.), add the matching
   `NS*UsageDescription` to `project.yml`
   (`info.properties`) and re-run `xcodegen generate`.
   Without the key, iOS silently ignores the permission
   request and no prompt appears — easy to miss in testing.
   The current list lives in
   [CLAUDE.md → Privacy Usage Descriptions](CLAUDE.md#privacy-usage-descriptions).

5. **Update CHANGELOG.md** under the next-version heading
   (or `[Unreleased]` if no version bump is planned). One
   line per change is enough; the maintainer curates the
   final wording at release time.

## Submitting a PR

Use the [PR template](.github/PULL_REQUEST_TEMPLATE.md) —
it has a checklist that mirrors the requirements above
(prerequisites, screenshots for UI changes, changelog
entry, test pass, etc.). Branch protection on `main`
requires 1 approving review and a green CI; the runbook
for the protected-branch config is in
[`docs/BRANCH_PROTECTION.md`](docs/BRANCH_PROTECTION.md).

## Coding conventions

- **State management:** `@MainActor @Observable` classes,
  one per feature, with stored properties for state and
  methods for actions. Matches the iOS 17 Observation
  pattern (the project does not use TCA).
- **Logging:** `AppLogger.log(...)` only. Direct
  `os_log` / `Logger(subsystem:)` calls in app code are
  not permitted.
- **No new SPM dependencies without a design note.** SPM
  packages are versioned in `project.yml`'s `packages:`
  block and are tricky to bump cleanly (the manifest lives
  in `SmartChatApp.xcodeproj/.../swiftpm/Package.resolved`,
  not at the repo root). If your feature truly needs a new
  dependency, open an issue first.

## Reporting a security issue

Please do **not** open a public issue. Use the
[GitHub private advisory](https://github.com/caspian9/SmartChatApp/security/advisories/new)
or follow the workflow in
[SECURITY.md](.github/SECURITY.md).

## License

By submitting a contribution, you agree that your work will
be licensed under the project's [MIT License](LICENSE).
