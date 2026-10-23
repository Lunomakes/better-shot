# BetterShot — Claude Code

Read and follow the shared repository rules before making changes:

@AGENTS.md

Use the contributor guide for the architecture, build commands, and validation:

@CONTRIBUTING.md

Keep UI policy in `AGENTS.md`; do not duplicate it here. Use the existing native
clover assets for app/menu-tray identity and SF Symbols for controls. Current
work belongs to the unreleased 0.5.0 section of `CHANGELOG.md`.

## Personal fork publishing (confirmed 2026-10-23)

- `origin` is upstream (read-only). Publish to remote `fork` = https://github.com/Lunomakes/better-shot,
  a public fork whose default branch is `personal`. Push only when the user asks; never force-push it.
- Sync upstream into `personal` by merging `origin/main` (no rebase), so published history is never rewritten.
- Release: `scripts/fork-release.sh` builds `release/BetterShot-Plus-<version>.dmg` (universal, ad-hoc signed,
  bundle ID `com.lunomakes.bettershot`), then `gh release create v<version>-plusN --repo Lunomakes/better-shot`.
  Keep `-plusN` without a dot: the updater only compares the numeric dot-separated parts.
- Commit as `lihongkun <79370026+Lunomakes@users.noreply.github.com>` (set in this repo's git config).
