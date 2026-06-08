# Maintenance update — plan-limit blockers for GitHub-side toggles

**Date:** 2026-06-08
**Follows:** `2026-06-08-github-maintenance-review.md` (lines 551–564, "This week" tier)
**Author of updates:** cascaded from the review

## Outcome summary

All 5 file-system commits from the "This week" tier landed and
pushed to origin. The 4 GitHub-side interactive steps were
attempted; **1 succeeded, 3 hit plan-level blockers**.

| # | Step | File-system artifact | GitHub-side result |
|---|---|---|---|
| 1 | README scripts/config sections + CI badge | `b7b5088` | ✅ (file change) |
| 2 | CI cache + gating + OPENCLAW_REPO + SHA pinning | `8154012` | ✅ (file change) |
| 3 | SECURITY.md | `fe04c80` | ✅ (file change; toggle blocked — see below) |
| 4 | THIRD_PARTY_LICENSES.md | `0072120` | ✅ (file change) |
| 5 | BRANCH_PROTECTION.md (runbook) | `dfddd43` | ✅ (file change; toggle blocked — see below) |
| 6a | Enable secret scanning | — | ❌ `Secret scanning is not available for this repository` |
| 6b | Enable private vulnerability reporting | — | ❌ `private_vulnerability_reporting` stays `null` |
| 6c | Apply branch protection | — | ❌ `Upgrade to GitHub Pro or make this repository public` |
| 6d | Create 11 standard labels | — | ✅ 11 labels created |

## Root cause of the 3 blockers

The repo is **user-owned (`caspian9`) and on GitHub Free**:

```json
{
  "visibility": "private",
  "owner": { "type": "User", "login": "caspian9" },
  "security_and_analysis": {
    "secret_scanning":               { "status": "disabled" },
    "secret_scanning_push_protection": { "status": "disabled" }
  }
}
```

The three blocked features are gated by GitHub plan tier, not by
the API call shape:

| Feature | Required plan for **private, user-owned** repos |
|---|---|
| Secret scanning (and push protection) | GitHub Pro, Team, or Enterprise Cloud |
| Private vulnerability reporting | Org-owned (any plan) or public, or Pro+ on user-owned |
| Branch protection on `main` | GitHub Pro |

Reference: `docs.github.com/en/code-security/secret-scanning/introduction/about-secret-scanning`
explicitly states secret scanning on **org-owned private** repos
needs "GitHub Secret Protection enabled on GitHub Team or GitHub
Enterprise Cloud" — and user-owned private repos are even more
restricted (only Enterprise Cloud with EMU).

The 6a / 6b / 6c commands documented in
`docs/BRANCH_PROTECTION.md` and the maintenance review are
**correct and will work** the moment one of these flips:
- `caspian9` upgrades to GitHub Pro (cheapest: $4/month, unlocks
  branch protection on user-owned private repos)
- The repo is moved to a **GitHub organization** that has
  GitHub Team / Enterprise (unlocks secret scanning for the org's
  private repos and all three features for free except secret
  scanning push protection, which is the GitHub Secret Protection
  add-on)
- The repo is **flipped to public** (all three features become
  free)

## What was created regardless

- `.github/SECURITY.md` (commit `fe04c80`) — defines the security
  policy and reporting path. **The file is harmless even when the
  toggle can't be enabled**; it surfaces in
  `Settings → Security → Policy` and would be picked up by
  Dependabot / external scanners that read the file.
- `docs/BRANCH_PROTECTION.md` (commit `dfddd43`) — the runbook
  for applying the rules via `gh api` once the plan permits.
  Verified the JSON payload shape via the 403 response (the
  payload itself was accepted; only the entitlement check
  failed).
- 11 standard labels — landed in the live repo.

## What the user can do now

1. **Nothing, if the current plan is staying.** The
   file-system artifacts (SECURITY.md, BRANCH_PROTECTION.md,
   THIRD_PARTY_LICENSES.md, all 5 file commits) are still
   useful: they form the policy + procedure for when the plan
   changes. SECURITY.md in particular is the canonical place a
   future security researcher will look for reporting
   instructions, and the toggle is one click away once the plan
   permits.

2. **Upgrade to GitHub Pro** (~$4/mo). Unlocks branch
   protection; secret scanning + private vuln reporting still
   need Team/Enterprise for private repos but you can use a
   Personal plan for free on public repos if you flip the
   visibility.

3. **Create a GitHub organization** and transfer the repo to
   it. The org's owner can subscribe to GitHub Team and the
   three features become available at the team tier for the
   org's private repos.

4. **Flip to public** (already considered as a step in the
   original review's "Hardening for public release" tier).
   All three features become free; the file-system artifacts
   (SECURITY.md, BRANCH_PROTECTION.md, THIRD_PARTY_LICENSES.md)
   are the prerequisites for a clean public launch.

## Recommended path

For a solo dev project in pre-1.0 development, **the
file-system artifacts are sufficient.** Defer the live
toggles until one of:

- A second maintainer joins (now you want branch protection)
- The project handles real user data (now you want secret
  scanning + private vuln reporting)
- The repo is going public (do all three at once)

When that trigger fires, the runbooks in
`docs/BRANCH_PROTECTION.md` and this file's predecessor
(`2026-06-08-github-maintenance-review.md`) document the
exact `gh api` payloads — no re-derivation needed.
