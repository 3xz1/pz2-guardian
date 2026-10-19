# Working on Guardian

## Layout

| Path | What |
|---|---|
| `Manifest.xml` | content pack name (`PZ2Guardian`) |
| `lua/` | game-side Lua, packed into `Main.ovl` |
| `ui/UIGameface/` | panel HTML/CSS/JS, packed into `UI/PZ2GuardianUI.ovl` |
| `tests/test_guard.py` | lupa harness for the Lua (no game needed) |
| `tools/` | `check_mod.sh`, `build_mod.sh`, `ppuipkg.py` |
| `release/nexus_page.txt` | Nexus page text |

Never committed (see `.gitignore`): `dist/`, zips, `.ovl`, `toolchain/`,
anything from the game's files.

## Toolchain (once)

Needs Python 3.12, Node 22, git, Git Bash. `build_mod.sh` expects
`toolchain/` next to `tools/`: a venv with cobra-tools' dependencies plus
`lupa` and `luaparser`, and a cobra-tools checkout (commit
`f1d5dbaedfcef6d71ac38e972c7590c9fb57bcb3`). `.github/workflows/release.yml`
("Toolchain" step) shows the exact commands. A local build also wants the
game's `oo2core_9_win64.dll` copied to
`toolchain/cobra-tools/modules/formats/utils/oodle/oo2core_8_win64.dll`.

## Day to day

```bash
git switch -c fix-something          # never work on main directly
# ...edit lua/ or ui/...
bash tools/check_mod.sh .            # Lua/JS syntax, version numbers, tests
bash tools/build_mod.sh .            # -> dist/Win64/ovldata/PZ2Guardian/
# copy dist/Win64 into the game folder, try it in-game
git commit -am "Fix ..."
git push -u origin fix-something
gh pr create --fill                  # the "checks" workflow runs on the PR
gh pr merge --squash --delete-branch # once checks are green
```

## Releasing

1. Bump the version in three places (`check_mod.sh` fails if they differ):
   - `lua/pz2guardian.core.lua`: `Core.sVersion = "X.Y.Z"`
   - `ui/UIGameface/js/mods/pz2guardian/main.js`: `const VERSION = 'X.Y.Z';`
   - `README.md` line 1: `(version X.Y.Z)`
2. Add a `### X.Y.Z` entry at the top of "Changes" in `README.md`.
   The release notes are taken from it.
3. Merge to main, then tag:
   ```bash
   git switch main && git pull
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```
4. The "release" workflow builds the zip and creates a **draft** release.
   Download the zip, try it in-game, then publish the draft
   (`gh release edit vX.Y.Z --draft=false`) and upload the same zip to Nexus.

## Protecting main (once, repo admin)

Requires the PR + green "checks" before anything lands on main, and blocks
force pushes and deleting main. Rulesets are enforced on public repos with a
free account.

```bash
gh api repos/3xz1/pz2-guardian/rulesets -X POST --input - <<'EOF'
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [ { "context": "checks" } ] } }
  ]
}
EOF
```

Or in the browser: Settings > Rules > Rulesets > New branch ruleset, target
the default branch, tick "Restrict deletions", "Block force pushes",
"Require a pull request before merging" (0 approvals) and "Require status
checks to pass" with `checks`.
