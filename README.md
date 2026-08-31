# Worktrunk

A [herdr](https://herdr.dev) plugin for switching, creating, merging, and
removing git worktrees through [worktrunk](https://github.com/max-sixty/worktrunk). Pick (or
type) a branch in an fzf picker and open the worktree as a herdr tab or a native
worktree workspace — with worktrunk's hooks running along the way.

## Why this plugin

herdr already ships with its own worktree management (`herdr worktree
create/open/remove/list`), and it works fine. But worktrunk is a dedicated
worktree manager that does more — most importantly, **lifecycle hooks**: run
setup when a worktree is created (install deps, copy `.env` files, bootstrap
services) and teardown when it's removed, with template variables like
`{{ branch }}` and `{{ worktree_path }}`. herdr's built-in worktree commands
have no hook system.

Rather than reimplement hooks inside herdr, this plugin wires worktrunk's `wt`
into herdr: you get worktrunk's hook-driven workflow (plus its niceties — base
branch selection, PR shortcuts, live preview) while choosing whether the
resulting worktree opens as a tab or as a native linked-worktree workspace.

## What it does

Eight workspace actions:

- **Worktree: switch / create from default branch** — opens an fzf picker over
  your existing worktrees and local branches without worktrees (remote-tracking
  branches too, if enabled — see [Remote branches in the picker](#remote-branches-in-the-picker)).
  Press `Enter` on a match to switch to it, or type a new name and press `Enter`
  to create it from worktrunk's default base branch. When the name you want
  fuzzy-matches an existing branch (e.g. you want `pgx` but `pgx-bump` exists),
  press `Alt+Enter` to force the typed name instead of the highlighted match.

- **Worktree: switch / create from current branch** — the same picker, but typed
  new branch names are created with `wt switch --create --base @`, i.e. from the
  currently checked-out branch/worktree.

- **Worktree: switch / create from local or remote branches** — the default-base
  picker with remote-tracking branches included for this invocation.

The pickers support [worktrunk syntax for PR/MR along with other shortcuts](https://worktrunk.dev/switch/#shortcuts).
Worktrunk's lifecycle hooks run in either presentation mode, and the checkout
opens as a tab or a native worktree workspace according to plugin configuration.

- **Worktree: open / create from a GitHub issue** — an fzf picker over the
  repository's open issues (`gh issue list`). Picking one switches to the branch
  that already carries that issue number, or creates a new branch named from the
  issue's number and title. See
  [GitHub issues and pull requests](#github-issues-and-pull-requests).

- **Worktree: open / create from a pull request** — the same picker over open
  pull requests (`gh pr list`), then `wt switch pr:N`, so worktrunk handles fork
  PRs and `pushRemote` itself.

- **Worktree: remove** — opens an fzf picker over removable worktrees
  (everything except the main checkout). Pick one; worktrunk prompts for
  confirmation and gates unmerged branches / untracked files itself, then
  removes it. The native workspace or any legacy tab panes associated with the
  deleted worktree are closed automatically.

- **Worktree: merge into the target branch** — the same picker over removable
  worktrees, then `wt merge` on the one you pick, then removal. The native
  workspace or legacy tab panes are closed once the worktree is gone.

- **Worktree: merge into the target branch, keeping every commit** — the same
  merge with `--no-squash`. See [Merge flags](#merge-flags) for the rest.

## Worktree presentation

By default the plugin organizes worktrees the same way as herdr's built-in
worktree support: each checkout becomes a nested worktree workspace in the
sidebar. To restore the original tab-based behavior, set `open_mode` to `"tab"`
in the plugin's managed configuration directory:

```bash
config_dir=$(herdr plugin config-dir worktrunk)
mkdir -p "$config_dir"
${EDITOR:-vi} "$config_dir/config.toml"
```

```toml
open_mode = "tab"
```

Supported values:

- `open_mode = "workspace"` — let Worktrunk create or switch the checkout and
  run its hooks, then register that checkout with `herdr worktree open`. Herdr
  displays it as a nested worktree workspace in the sidebar. This is the default.
- `open_mode = "tab"` — open a new tab in the current workspace and run `wt`
  there. This preserves the original plugin behavior.

The config file is read each time the picker runs, so changing the mode does
not require reinstalling or reloading the plugin.

## Remote branches in the picker

By default the picker lists only your worktrees and local branches. To also
offer remote-tracking branches (e.g. `origin/foo`; run `git fetch` yourself to
refresh these), set `show_remote_branches` to `true` in the same `config.toml`:

```toml
show_remote_branches = true
```

Local branches without worktrees always appear regardless of this setting.

## Merge flags

The merge actions pass no flags to `wt merge` beyond the variant's `--no-squash`.
To change what every merge does, list flags in `merge_flags` in the same
`config.toml`:

```toml
merge_flags = "--no-squash --no-rebase"
```

Accepted: `--no-squash`, `--no-rebase`, `--no-ff`, `--no-commit`, `--no-hooks`,
`--stage=all|tracked|none` (see `wt merge --help`).

A merge that fails leaves the worktree and its workspace alone, with worktrunk's
output on screen.

## GitHub issues and pull requests

The two GitHub actions need the [GitHub CLI](https://cli.github.com) on `PATH`
and authenticated (`gh auth login`); nothing else in the plugin does, so they
report a missing or unauthenticated `gh` in the picker pane rather than being
hidden. On Windows, or when `gh` lives somewhere unusual, point at it
explicitly:

```toml
gh_bin = 'C:\path\to\gh.exe'
```

**Pull requests** go through worktrunk's own `pr:N` shortcut, which resolves the
head branch, fetches `refs/pull/N/head` for a fork PR, and sets `pushRemote`.

**Issues** have no worktrunk shortcut, so the picker resolves one itself:

1. If a local branch already carries that issue number (`issue-42`, `issue_42`
   or `issue42` as a whole token — `issue-4` never matches `issue-42`), the
   picker switches to it. A remote-tracking branch is the next choice.
2. Otherwise it creates a branch from the issue's number and title:
   `feature/issue-42-the-issue-title`. The title is lowercased, punctuation runs
   fold to single dashes, and it is trimmed to 36 characters on a dash boundary.

That is what makes the action *open or create*: running it twice for the same
issue lands you back in the first worktree instead of creating a near-duplicate.
Keeping the number in the branch name is also what lets worktrunk hooks keyed on
`issue-N` (a task brief, say) fire for these worktrees.

Both pickers also accept a typed number for an item the list does not show (a
closed issue, or one beyond the fetch limit), and still pass any worktrunk
shortcut or branch name through untouched.

Four settings, all optional:

```toml
issue_branch_template = "feature/issue-{{number}}-{{slug}}"  # the default
gh_list_limit = 50        # how many issues/PRs to fetch
issue_filter = "all"      # all | assigned | created
pr_filter = "all"         # all | assigned | created
```

`{{number}}` and `{{slug}}` are the only placeholders. A template without
`{{number}}` is refused — it would collapse every issue onto one branch — and a
title that slugs to nothing leaves no dangling separator behind.

### Ctrl+click an issue or PR link

The plugin also registers link handlers, so Ctrl+clicking a GitHub issue or pull
request URL in any pane opens the worktree for it directly, skipping the picker.
The URL's number is handed to the same flows described above.

## Picker presentation

The picker opens in a split pane below the workspace. To open it as a
session-modal popup over the current layout instead, set `picker_placement` in
the same `config.toml`:

```toml
picker_placement = "popup"
```

Supported values:

- `picker_placement = "split"` — a pane split below the workspace, closed when
  the picker exits. This is the default.
- `picker_placement = "popup"` — a floating terminal centered over the tab,
  leaving the tiled layout alone. Needs herdr ≥ 0.7.4.

A popup is half the window by default. Size it with `popup_width` and
`popup_height`, either as terminal cells or as a percentage of the window:

```toml
picker_placement = "popup"
popup_width = "70%"
popup_height = 24
```

In a split the picker draws its own rounded border and inset margin, which a
popup does not need, so the list fills the popup frame herdr already draws.

## Requirements

- [**herdr**](https://herdr.dev) ≥ 0.8.0 (the manifest relies on per-item
  `platforms` overrides)
- [**worktrunk**](https://github.com/max-sixty/worktrunk) ≥ 0.60.0 — the `wt` CLI on your `PATH`
- **fzf** — the interactive picker
- **jq** — JSON parsing (macOS/Linux only; the Windows scripts parse JSON natively)
- [**gh**](https://cli.github.com) — the GitHub CLI, authenticated with
  `gh auth login`. Needed only by the two GitHub actions; every other action
  works without it.
- **bash** — the scripts run with `/bin/bash` (macOS/Linux only)

Platforms: macOS, Linux, and Windows (herdr's Windows plugin support is in
preview).

### Windows

The actions run as Windows PowerShell 5.1 scripts (`*.ps1`) — nothing beyond
stock Windows is needed for the scripts themselves, and jq is not used. Install
the two external tools with winget:

```powershell
winget install max-sixty.worktrunk junegunn.fzf
```

Add `GitHub.cli` to that list to use the issue and pull request actions.

Worktrunk's binary is named `wt.exe`, which collides with Windows Terminal's
`wt.exe` launcher alias — and the alias usually wins on `PATH`. The plugin
resolves worktrunk itself: it tries the `WORKTRUNK_BIN` environment variable,
then `worktrunk_bin` in the plugin's `config.toml`, then a `worktrunk`/`wt` on
`PATH` that is not the Windows Terminal alias, then `~\.cargo\bin\wt.exe`. If
worktrunk lives somewhere unusual, point at it explicitly:

```toml
worktrunk_bin = 'C:\path\to\wt.exe'
```

Two Windows behaviors differ by design:

- **Removal order.** Windows refuses to delete a directory that is any
  process's cwd — and the worktree's own workspace pane is exactly such a
  process. The remove and merge actions therefore close the worktree's herdr
  UI *before* `wt remove` runs (the reverse of the Unix scripts), and reopen
  the workspace if the removal then fails or is declined. Panes closed in tab
  mode cannot be brought back that way — decline a removal there and its
  shells stay closed. When the action runs from inside the worktree's own
  workspace, that workspace is closed only after the removal succeeds.
- **Tab mode** (`open_mode = "tab"`) sends a PowerShell command into the new
  tab, so it expects a PowerShell-family default shell. It does not rely on
  worktrunk's shell integration: the sent command switches with `--no-cd` and
  changes into the worktree directory itself.

## Installation

From the herdr CLI:

```bash
herdr plugin install devashish2203/herdr-worktrunk
```

Or, for local development, clone and link:

```bash
git clone https://github.com/devashish2203/herdr-worktrunk
herdr plugin link /path/to/herdr-worktrunk
```

## Usage

On Windows, append `-windows` to every action id below (`open-windows`,
`open-current-windows`, `open-with-remotes-windows`, `from-issue-windows`,
`from-pr-windows`, `remove-windows`, `merge-windows`,
`merge-no-squash-windows`) — they are the same actions backed by the PowerShell
scripts.

### Create/Switch a worktree from the default branch

```
herdr plugin action invoke open --plugin worktrunk
```

### Create/Switch a worktree from the current branch

```
herdr plugin action invoke open-current --plugin worktrunk
```

### Create/Switch a worktree from local or remote branches

```
herdr plugin action invoke open-with-remotes --plugin worktrunk
```

### Open/Create a worktree from a GitHub issue

```
herdr plugin action invoke from-issue --plugin worktrunk
```

### Open/Create a worktree from a pull request

```
herdr plugin action invoke from-pr --plugin worktrunk
```

### Remove Worktree

```
herdr plugin action invoke remove --plugin worktrunk
```

## Keybindings

To drive the plugin from the keyboard, add `[[keys.command]]` entries to
`~/.config/herdr/config.toml` (`%APPDATA%\herdr\config.toml` on Windows) with
`type = "plugin_action"`. The `command` is the plugin's action id qualified
with the plugin id (`worktrunk.<action>`; run `herdr plugin action list` to see
the ids — on Windows use the `-windows` ids, e.g. `worktrunk.open-windows`):

```toml
# Override herdr's built-in "new worktree" key (prefix+shift+g) with worktrunk's
# default-branch switch/create picker:
[[keys.command]]
key = "prefix+shift+g"
type = "plugin_action"
command = "worktrunk.open"
description = "Worktree: switch / create from default branch"

# Optional: bind current-branch creation separately.
[[keys.command]]
key = "prefix+shift+c"
type = "plugin_action"
command = "worktrunk.open-current"
description = "Worktree: switch / create from current branch"

# Optional: include remote-tracking branches for this picker.
[[keys.command]]
key = "prefix+shift+r"
type = "plugin_action"
command = "worktrunk.open-with-remotes"
description = "Worktree: switch / create from local or remote branches"

# Optional: the GitHub issue and pull request pickers.
[[keys.command]]
key = "prefix+shift+i"
type = "plugin_action"
command = "worktrunk.from-issue"
description = "Worktree: open / create from a GitHub issue"

[[keys.command]]
key = "prefix+shift+p"
type = "plugin_action"
command = "worktrunk.from-pr"
description = "Worktree: open / create from a pull request"

[[keys.command]]
key = "prefix+shift+d"
type = "plugin_action"
command = "worktrunk.remove"
description = "Worktree: remove"

[[keys.command]]
key = "prefix+shift+m"
type = "plugin_action"
command = "worktrunk.merge"
description = "Worktree: merge into the target branch"
```

**Recommended:** override herdr's built-in worktree management with these. herdr
binds `prefix+shift+g` to "new worktree" by default, and a custom keybinding takes
precedence over the built-in on the same key — so mapping `worktrunk.open`
to `prefix+shift+g` replaces it with worktrunk's switch/create picker, hooks
included. Pick matching keys for `worktrunk.open-current`,
`worktrunk.open-with-remotes`, `worktrunk.from-issue`, `worktrunk.from-pr`,
`worktrunk.remove`, `worktrunk.merge`, and `worktrunk.merge-no-squash` to round
out the workflow.

Reload the config after editing it:

```bash
herdr server reload-config
```

## Development

The plugin is a manifest plus small bash scripts (macOS/Linux) and their
Windows PowerShell 5.1 ports (`*.ps1`, Windows). The manifest declares every
action and pane twice — once per platform set, with `-windows`-suffixed ids for
the PowerShell twins — using herdr's item-level `platforms` overrides.

- `herdr-plugin.toml` — actions and panes
- `config.sh` / `config.ps1` — worktree and picker presentation configuration
- `helpers.sh` / `helpers.ps1` — shared helpers (worktrunk shortcut detection;
  on Windows also path normalization and worktrunk binary resolution)
- `open.sh` / `open.ps1` — the action entrypoint that opens a picker in its
  configured placement
- `picker.sh` / `picker.ps1` — the switch / create picker
- `remove.sh` / `remove.ps1` — the remove picker
- `merge.sh` / `merge.ps1` — the merge picker
- `lifecycle.sh` / `lifecycle.ps1` — shared steps for the actions that destroy
  a worktree: candidate listing, herdr workspace resolution, UI cleanup
- `tests/config_test.sh` — configuration parser checks
- `tests/helpers_test.sh` — helper function checks
- `tests/lifecycle_test.sh` — candidate/workspace resolution and cleanup checks
- `tests/merge_test.sh` — merge argument and failure-path checks
- `tests/open_test.sh` — picker placement / open argument checks
- `tests/*_test.ps1` — Windows ports of the same checks (stubbing wt, fzf, and
  herdr with generated `.cmd` shims); run them all with
  `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run_tests.ps1`

herdr caches the manifest when a plugin is linked, so after editing
`herdr-plugin.toml` you must relink for changes to take effect:

```bash
herdr plugin unlink worktrunk && herdr plugin link "$PWD"
```

Edits to the bash scripts are picked up on the next run — no relink needed.

## License

[MIT](LICENSE.md) © Devashish Chandra
