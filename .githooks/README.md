# Git hooks

Tracked git hooks for Trailblazer. Kept in-repo (not `.git/hooks/`) so they survive fresh clones and stay in sync across machines.

## Setup

Once per clone, wire git to look here instead of `.git/hooks/`:

```bash
git config core.hooksPath .githooks
```

On Unix (macOS/Linux) also make sure hooks are executable:

```bash
chmod +x .githooks/*
```

On Windows/Git Bash the executable bit isn't strictly required — Git honors the shebang line.

## Hooks

### `pre-push`

Runs before `git push`. Ralph Loop tier boundary — the **full test suite runs here**, not on every commit.

- `flutter analyze --fatal-infos`
- `flutter test`

Push is blocked if either fails.

**Bypass** (rare — CI is your safety net):
```bash
git push --no-verify
# or
TRAILBLAZER_SKIP_PREPUSH=1 git push
```

## Rationale

See the "Ralph Loop tiering" section of `CLAUDE.md` in the repo root. In brief: commits run only `flutter analyze` (fast, ~5s warm) so tight iteration inside a plan stays snappy; the ~10s test run only pays off at the push boundary.
