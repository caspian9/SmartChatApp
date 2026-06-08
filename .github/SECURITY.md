# Security Policy

## Reporting a vulnerability

**Please don't open a public issue for security bugs.** Use one of:

- **GitHub private advisory** (preferred): https://github.com/caspian9/SmartChatApp/security/advisories/new
- **Direct contact:** open an issue tagged `@caspian9` and request
  a private channel — the maintainer will share a PGP key or
  switch to email at that point. The repo has no published
  contact email by design (avoids spam scraping on a public
  address). If you specifically need an email channel for a
  coordinated disclosure timeline, mention it in the issue and
  a key-exchange method will be provided.

You should hear back within 72 hours. If you don't, please follow up
on the advisory thread (or by `@`-mentioning a maintainer on a
neutral issue if absolutely necessary).

## What to include

A useful report has:

- The build + commit SHA the bug was found in (Settings → About
  on a Debug build shows it; in a Release build, the App Store
  version + device are enough).
- A minimal reproduction: which gateway command, which node
  command, or which app screen.
- The expected behavior vs. the observed behavior.
- A log excerpt from the affected subsystem (filter
  `subsystem:SmartChatApp` in Console.app; category like
  `network` or `nativeChat` is fine — but please **redact any
  gateway auth tokens** before pasting).

## Supported versions

Only the latest commit on `main` receives security fixes. There is
no LTS branch and no backport policy at the moment. The repo is
in pre-1.0 development; old builds are not patched.

When the project ships a tagged release, this section will list
the supported version range.

## Scope

In scope:

- Auth-token handling (`ProfileManager` stores gateway tokens in
  UserDefaults; check for unredacted logging, weak storage, or
  over-the-wire leaks in `Core/Network/ConnectionCoordinator.swift`).
- URL scheme handlers / deep links that bypass auth.
- TLS handling on the gateway connection (no certificate pinning
  yet — pinning is a known TODO).

Out of scope:

- Bugs in the upstream `OpenClawKit` SDK — file those at
  https://github.com/openclaw/openclaw.
- Issues that only affect the user (e.g. "my gateway URL is
  wrong" → that's a configuration question, not a security
  report).
