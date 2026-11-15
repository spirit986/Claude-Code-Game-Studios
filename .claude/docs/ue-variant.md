# UE-only variant

This is Claude Code Game Studios with Unreal Engine only: Donchitos's template
with the Godot and Unity parts removed, `/setup-engine` defaulting to Unreal
Engine 5.8, and its own model and effort tiers. Upstream releases arrive as pull
requests, and `tools/ue/install.sh` copies the result into your UE project.

## Branches

| Branch | Holds | Changed by |
|---|---|---|
| `main` | An exact copy of Donchitos's `main` | Only the Upstream sync workflow, by fast-forward |
| `unreal-engine` (default) | The UE-only variant | Pull requests: upstream syncs and your own changes |

- Never commit to `main`, and never merge `unreal-engine` into it.
- Merge pull requests into `unreal-engine` with a merge commit. Squash and rebase
  are turned off: a squashed sync loses the record of what was merged, and the
  next sync conflicts.
- Never hand-edit a file `convert.sh` rebuilds (listed below). Change
  `tools/ue/lib.sh` or `tools/ue/convert.sh`, run `bash tools/ue/convert.sh`, and
  commit. `bash tools/ue/convert.sh --check` says whether the branch matches what
  the script builds, and `sync.sh` refuses to run until it does.
- Put UE-only additions (agents, rules, docs) in new files. A file upstream does
  not have can never conflict.

## What differs from upstream

**Removed:** the 10 Godot and Unity agents, `docs/engine-reference/godot/` and
`unity/`, their test specs in `studio-tests/agents/engine/`,
`.claude/scripts/godot-parse-check.gd`,
`.claude/skills/setup-engine/references/godot-language-config.md` and
`production/.gdignore`. The list is `UE_DENY` in `tools/ue/lib.sh`.

**Kept:** the Web engine. `/prototype`, `/start` and `/setup-engine` are built
around it. `install.sh` sets `engine.name: Unreal` in a project that has no
engine, so those skills take the Unreal route.

**Rebuilt by `tools/ue/convert.sh`** from upstream's copy at the release this
branch last merged, then edited:

| File | Change |
|---|---|
| `CLAUDE.md` | Unreal Engine 5.8 tech stack, the `@docs/engine-reference/unreal/VERSION.md` import, the agent count, and a note that only the Unreal specialists are installed |
| `.claude/skills/setup-engine/SKILL.md` | Unreal description, and no arguments means `/setup-engine unreal 5.8` instead of the Web default |
| `.claude/skills/setup-engine/references/7.5-scaffold.md` | The `.uproject` must sit at the repo root |
| `.claude/hooks/update-check.sh` | The new-release notice sends you to this repository and `install.sh`, not to upstream's upgrade steps |
| `.claude/settings.json`, 9 skills, 4 agents | Model and effort (below) |
| `.claude/docs/model-tiers.md` | A generated summary of this tree's tiers at the top |
| `.claude/docs/agent-roster.md` | The Godot and Unity agents removed |
| `director-gates/lp-*.md`, the `lead-programmer` test spec | `lead-programmer` on Opus |
| `studio-tests/catalog.yaml` | The deleted agents' entries removed |
| `README.md` | A banner: the counts and lists below it describe upstream |

**Added:** `tools/ue/`, `.github/workflows/upstream-sync.yml` and this file.

**Hand edits in upstream files:** 45 lines of UE 5.8 notes in five
`docs/engine-reference/unreal/` files (`PLUGINS.md`, `breaking-changes.md`,
`deprecated-apis.md`, `modules/audio.md`, `modules/rendering.md`). If upstream
changes the same lines, the sync stops and lists them for you.

## Model and effort

| What | Upstream | Here | Set in |
|---|---|---|---|
| Sonnet's effort | `medium`, Claude Code's default | `high` | `.claude/settings.json`: `modelSettings` → `claude-sonnet-5-5` → `effortLevel` |
| `creative-director`, `producer`, `technical-director` | Your session's level | `xhigh` | `effort: xhigh` in each agent file |
| `lead-programmer` | Sonnet | Opus | `model: opus` in its agent file |
| `/brainstorm`, `/code-review`, `/create-architecture`, `/create-epics`, `/create-stories`, `/design-review`, `/design-system`, `/tech-debt`, `/vertical-slice` | Sonnet | Opus | `model: opus` in each `SKILL.md` |

The lists live in `tools/ue/lib.sh` (`UE_OPUS_SKILLS`, `UE_OPUS_AGENTS`,
`UE_XHIGH_AGENTS`, `UE_SONNET_MODEL_ID`, `UE_SONNET_EFFORT`). Every other skill
and agent keeps upstream's `model:` and `effort:` lines: take a name off a list,
run `convert.sh`, and that file goes back to upstream's value. The summary at the
top of `model-tiers.md` is generated from the tree; the lists below it describe
upstream.

- Effort is set separately from the model. Claude Code's default is `medium` on
  Opus 5.5, Sonnet 5.5 and Haiku 5.5.
- Everything else on Opus, `lead-programmer` and the Opus skills included, uses
  the level you saved for Opus with `/effort`, or `medium` if you saved none.
  `CLAUDE_CODE_EFFORT_LEVEL` outranks all of these.
- A skill's `model:` applies until your next prompt, and a `sonnet` skill changes
  effort too. In a skill Claude starts, the conversation stays on Opus but
  reports Sonnet's level, `high`.
- `modelSettings` names one model version. When the `sonnet` alias moves to a
  new model, set `UE_SONNET_MODEL_ID` to its ID, run `bash tools/ue/convert.sh`
  and commit, or Sonnet falls back to that model's default effort.
- More work runs on Opus and Sonnet runs at a higher effort, so usage is higher.

## Syncing with upstream

The **Upstream sync** workflow runs daily and from the Actions tab's *Run
workflow* button. It fast-forwards `main` to Donchitos's `main`, and if
`unreal-engine` is behind, merges the release on a `sync/<version>` branch with
`tools/ue/sync.sh` and opens a pull request. It never merges.

- **One sync pull request at a time.** A newer release closes the older sync
  pull request the workflow opened as superseded; the new one contains both. A
  sync pull request you opened yourself is never closed: the new one names it.
- **An open `sync/*` pull request that already contains the release covers it**,
  whatever its branch is called, so a manual sync on `sync/manual` stops the
  workflow from syncing that release again.
- **A pull request you close without merging** turns that version down: the
  workflow skips it while its branch exists. Reopen the pull request, or delete
  the branch to get a fresh one.

For each pull request:

1. Read its summary and the release's section of `UPGRADING.md`.
2. Merge it with a merge commit.
3. Update your UE project with `tools/ue/install.sh`.

**When the workflow fails with files that need you**, do the sync locally. It
names each file and why (changed on both sides, or deleted on one side):

```bash
git fetch origin
git switch -c sync/manual origin/unreal-engine
bash tools/ue/sync.sh origin/main
# resolve the files it lists, git add (or git rm) them, then:
bash tools/ue/convert.sh --check
git commit
git push -u origin sync/manual
gh pr create --repo spirit986/Claude-Code-Game-Studios --base unreal-engine --fill
```

Open the pull request as soon as you push: until it is open, the daily run keeps
trying the release and failing.

- GitHub pauses a scheduled workflow after 60 days without repository activity.
  Upstream has gone longer than that between releases; re-enable the workflow in
  the Actions tab when it happens.
- If Donchitos ever adds a file under `.github/workflows/`, the workflow's token
  cannot push it to `main`. Update `main` yourself (`git fetch upstream`, then
  `git push origin upstream/main:main`), or give the workflow a fine-grained
  token with Workflows write access.
- In an installed project, the session-start notice for a new release points
  here: wait for (or merge) the sync pull request, then run the install. Never
  follow upstream's `UPGRADING.md` steps in the project; they bring Godot and
  Unity back.

## Installing into a UE project

```bash
bash tools/ue/install.sh --dry-run "/path/to/YourProject"
bash tools/ue/install.sh "/path/to/YourProject"
```

Point it at the folder that holds the `.uproject`. It installs the template's
committed `HEAD`, so check out `unreal-engine` and pull first.

| Files | What happens |
|---|---|
| The framework: `.claude/` (agents, skills, hooks, scripts, rules, docs, genres, engines, `settings.json`), `docs/`, the `CLAUDE.md` files | Added, or updated if you have not changed them. Files you changed are three-way merged with the template's new version; a clash is written with conflict markers and reported (exit 3). Files upstream deleted are removed unless you changed them. An installed file you deleted stays deleted (`--restore-deleted` brings them back) |
| `project.yaml`, `technical-preferences.md`, the three registries | Added once, then never replaced: your skills write them. When `project.yaml` has no engine, `engine.name: Unreal`, the version and the Unreal specialists are added to it |
| `.gitignore`, `.gitattributes` | Your files; a marked CCGS block is added and kept current. The LF rules in it keep the hooks working on Windows |
| `LICENSE` | Copied as `.claude/CCGS-LICENSE.txt`: the MIT licence asks for its notice in every copy |
| `README.md`, `CHANGELOG.md`, `UPGRADING.md`, `.github/`, `tools/` | Not copied |
| `studio-tests/` | Only with `--with-studio-tests`, which later updates remember; `--without-studio-tests` stops it |
| Anything it did not install | Never touched: your own skills and agents, `settings.local.json`, agent memory |

- It records what it installed in `.claude/ccgs-install.txt`; commit that file
  with the rest.
- Line endings do not matter: files are compared and merged without CRs, so a
  project checked out by Git for Windows works the same.
- If a file cannot be written (read-only, or open in another program), it says
  which, records nothing and exits 4. Fix the cause and run it again.

**First install:**

1. Put the project under git (with Git LFS for `.uasset` and `.umap`), or back it
   up: without git there is no diff to review and no undo.
2. Close Claude Code in the project, then run the install.
3. Open Claude Code in the project from Windows, not WSL: under WSL the UE test
   runner builds Linux commands. Run `/setup-engine unreal 5.8` to finish the
   engine setup (language, editor path, commands).

**Blueprint-only projects** have no `Source/`, so `Source/CLAUDE.md` is skipped,
and CCGS's UE test tools expect a C++ module (`Source/<Module>/Private/Tests/`).
Adding any C++ class to the project creates one.

**After each sync:** pull `unreal-engine`, run the install again, and read the
release's section of `UPGRADING.md`. The install does not migrate
`project.yaml`, so new settings and one-off steps reach you only that way.

## Changing the UE version

Set `UE_VERSION` in `tools/ue/lib.sh`, run `bash tools/ue/convert.sh`, and open a
pull request. Then, in each project, run `/setup-engine upgrade` (or
`/setup-engine unreal <version>`). The reference docs in
`docs/engine-reference/unreal/` come from upstream; `/setup-engine refresh`
updates a project's copy, and the next install merges with it.
