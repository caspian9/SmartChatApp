# Branch protection — `main`

## What this applies

The `main` branch is the default and the only deployment surface.
The rules below match the project's "everything via PR" stance
(even though it's a single-user repo for now; this keeps a
multi-contributor path cheap when it happens).

## Rules

| Setting | Value | Why |
|---|---|---|
| Require a pull request before merging | Yes | Forces review trail; even solo, the diff is reviewed before push. |
| Required approving reviews | 1 | Cheap insurance. Bump to 2 if a co-maintainer joins. |
| Dismiss stale pull request approvals when new commits are pushed | Yes | Re-review after force-push / new commits. |
| Require status checks to pass before merging | Yes | `build` (the job name in `ci.yml`) must be green. |
| Require branches to be up to date before merging | Yes | Avoids the "PR was green at HEAD~3" surprise. |
| Require linear history | Yes | Keeps `main` a straight line; no merge commits from feature branches. |
| Include administrators | Yes | Don't let admins bypass the rules. |
| Allow force pushes | No | Don't rewrite published history. |
| Allow deletions | No | The default branch shouldn't be deletable. |

## Apply via `gh api`

Run this once from a machine that has `gh` authenticated as a repo
admin (i.e. the user, on their own machine). The user invokes
the prefix `! gh ...` in the Claude Code prompt so the output
lands in the conversation and is easy to verify.

```bash
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  /repos/caspian9/SmartChatApp/branches/main/protection \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["build"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismissal_restrictions": {},
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": false,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON
```

Verify the rules landed:

```bash
gh api /repos/caspian9/SmartChatApp/branches/main/protection | jq
```

## Toggling off

To temporarily allow a force-push (e.g. for an emergency revert
when CI is wedged), use:

```bash
gh api -X DELETE /repos/caspian9/SmartChatApp/branches/main/protection
```

…then re-apply with the command above. Don't leave main
unprotected.

## Why not automate this from a workflow?

A workflow that calls `PUT /branches/main/protection` would need
`contents: write` *and* a long-lived admin PAT — a larger
credential surface than the rules themselves are worth for a
single-user repo. Apply once, document, done.
