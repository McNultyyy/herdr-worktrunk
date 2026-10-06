#!/usr/bin/env bash
# Picker for the worktrunk herdr plugin. Picks a branch via fzf (fast), then either
# lets worktrunk create/switch the checkout and registers it as a native worktree
# workspace (the default), or — in tab mode — opens a new tab and types `wt switch`
# into THAT tab's shell, so the worktree creation and any hook output happen in the
# pane you keep and the shell's own `wt` integration cd's it into the worktree.

source_kind="branches"
create_base=""
create_base_label="default branch"
case ${1:-} in
  ""|--create-base=default|--show-with-remotes)
    ;;
  --source=issues)
    source_kind="issues"
    ;;
  --source=prs)
    source_kind="prs"
    ;;
  --create-base=current)
    create_base="@"
    current_branch=$(git branch --show-current 2>/dev/null || true)
    if [[ -n $current_branch ]]; then
      create_base_label="current branch (${current_branch})"
    else
      current_commit=$(git rev-parse --short HEAD 2>/dev/null || true)
      if [[ -n $current_commit ]]; then
        create_base_label="current HEAD (${current_commit})"
      else
        create_base_label="current branch"
      fi
    fi
    ;;
  *)
    printf '\033[31m%s\033[0m\n' "unsupported picker option: $1" >&2
    exit 2
    ;;
esac

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./config.sh
source "$plugin_root/config.sh"
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"

# Branch refs to offer alongside `wt list`: always local heads, plus
# remote-tracking branches when requested by this dedicated picker or config.
branch_refs=(refs/heads)
if [[ ${1:-} == --show-with-remotes || $(worktrunk_show_remote_branches) == true ]]; then
  branch_refs+=(refs/remotes)
fi

worktrunk_fzf_layout

# Each source decides what the picker lists and how a pick reads back. The
# branch picker offers refs and worktree branches; the gh pickers offer issues
# or pull requests as "#N  context" lines whose leading number is parsed below.
if [[ $source_kind == branches ]]; then
  fzf_prompt='worktree ❯ '
  header="↵ on a match → switch · type a new name + ↵ → create from ${create_base_label} · alt-↵ → force typed name · esc → cancel"
  read_prompt="Branch (existing → switch · new → create from ${create_base_label}): "
  candidates() {
    # Refs first: `git for-each-ref` answers instantly and in refname order,
    # while `wt list` stats every checkout — seconds on a repo with many
    # worktrees. Drop origin/HEAD: its short form is bare "origin", so filter
    # on the full refname (refs/remotes/origin/HEAD), then emit the short name.
    git for-each-ref --format='%(refname) %(refname:short)' "${branch_refs[@]}" 2>/dev/null \
      | awk '$1 !~ /\/HEAD$/ {print $2}'
    wt list --format=json 2>/dev/null \
      | worktrunk_list_items \
      | jq -r 'select(.branch != null) | .branch'
  }
else
  # Issues and pull requests come from the GitHub CLI, which carries its own jq,
  # so gh formats the lines rather than this script parsing JSON.
  gh_bin=$(worktrunk_gh_bin)
  if [[ -z $gh_bin ]]; then
    printf '\033[31m%s\033[0m\n' 'GitHub CLI not found. Install it (https://cli.github.com), run `gh auth login`, and either put it on PATH as `gh` or set gh_bin in the plugin config.toml / the GH_BIN environment variable.' >&2
    sleep 2
    exit 1
  fi
  gh_limit=$(worktrunk_gh_list_limit)
  if [[ $source_kind == issues ]]; then
    noun="issue"
    gh_filter=$(worktrunk_gh_filter issue_filter)
    gh_args=(issue list --limit "$gh_limit" --json number,title
             --jq '.[] | "#\(.number)  \(.title)"')
  else
    noun="pr"
    gh_filter=$(worktrunk_gh_filter pr_filter)
    gh_args=(pr list --limit "$gh_limit" --json number,headRefName,title
             --jq '.[] | "#\(.number)  \(.headRefName)  \(.title)"')
  fi
  case $gh_filter in
    assigned) gh_args+=(--assignee '@me') ;;
    created) gh_args+=(--author '@me') ;;
  esac

  # Fetched up front instead of streamed into fzf: these lists are small, and a
  # gh failure (not authenticated, no GitHub remote) has to be readable rather
  # than showing up as an empty picker.
  if ! gh_out=$("$gh_bin" "${gh_args[@]}" 2>&1); then
    printf '\033[31m%s\033[0m\n' "gh ${gh_args[0]} list failed:" >&2
    printf '%s\n' "$gh_out" >&2
    printf '\npress any key to close'
    read -n1
    exit 1
  fi
  fzf_prompt="${noun} ❯ "
  header="↵ → open or create the worktree for that ${noun} · type a number + ↵ → use it directly · esc → cancel"
  read_prompt="${noun} number: "
  candidates() {
    [[ -n $gh_out ]] && printf '%s\n' "$gh_out"
  }
fi

# A link handler hands the picker the number it parsed out of the clicked URL,
# so Ctrl+clicking an issue/PR link skips the list entirely.
prefill=""
[[ $source_kind != branches ]] && prefill=${WT_PICKER_PREFILL:-}

# fzf over the candidates; --print-query returns a typed-but-unmatched entry so we
# can create it, and alt-↵ (print-query) forces the typed name even when it
# fuzzy-matches an existing one (fzf then prints only the query, so the last-line
# parse below lands on it). Falls back to a plain read if fzf isn't on PATH.
if [[ -n $prefill ]]; then
  name=$prefill
elif command -v fzf >/dev/null; then
  choice=$(
    candidates | awk '!seen[$0]++ { print; fflush() }' \
      | fzf --print-query --reverse --info=inline "${WORKTRUNK_FZF_LAYOUT[@]}" \
            --bind=alt-enter:print-query \
            --prompt="$fzf_prompt" \
            --header="$header"
  )
  ret=$?
  [[ $ret -gt 1 ]] && exit 0      # 130 = esc/abort → cancel (0 = picked, 1 = typed-new)
  name=${choice##*$'\n'}          # last line: the selection if any, else the typed query
else
  printf '%s' "$read_prompt"
  read -r name
fi
[[ -z $name ]] && exit 0

# Map a picked issue/PR onto something `wt switch` understands. A PR has a native
# worktrunk shortcut — pr:N, which also handles fork PRs and sets pushRemote. An
# issue has none, so it resolves to the branch that already exists for it, or to
# a new name built from the configured template: that is what makes the action
# "open OR create", and it keeps the issue number in the branch so worktrunk
# hooks keyed on `issue-N` still fire. Anything that isn't a number (a typed
# pr:16, ^, or a branch name) falls through to the branch handling untouched.
if [[ $source_kind != branches && $name =~ ^[[:space:]]*#?([0-9]+)([[:space:]]+(.*))?$ ]]; then
  number=${BASH_REMATCH[1]}
  title=${BASH_REMATCH[3]}
  if [[ $source_kind == prs ]]; then
    name="pr:$number"
  else
    existing=$(worktrunk_find_issue_branch "$number")
    if [[ -n $existing ]]; then
      name=$existing
    else
      # Typed or prefilled rather than picked, so no list line carried a title.
      if [[ -z $title ]]; then
        title=$("$gh_bin" issue view "$number" --json title --jq '.title' 2>/dev/null) || title=""
      fi
      name=$(worktrunk_issue_branch_name \
        "$(worktrunk_issue_branch_template)" "$number" "$(worktrunk_slug "$title")")
    fi
  fi
fi

# Slugify a new branch name. The slug may name an existing branch, which the
# check below then switches to.
if [[ $(worktrunk_slugify_new_branches) == true ]] \
  && ! worktrunk_is_shortcut "$name" && ! worktrunk_ref_exists "$name"; then
  if ! slug=$(worktrunk_branch_slug "$name"); then
    printf '\033[31m%s\033[0m press any key to close' "no valid branch name in: $name"
    read -n1
    exit 1
  fi
  name=$slug
fi

open_mode=$(worktrunk_open_mode)

# Existing local or remote-tracking branch → switch (wt creates the worktree if
# it doesn't exist yet, and checks out a remote ref like origin/foo directly).
# worktrunk shortcuts (^ default, - previous, pr:N/mr:N, PR/MR URL) are resolved
# by worktrunk itself, so pass them through as-is — never --create.
# Anything else is a new branch → create it.
if worktrunk_is_shortcut "$name" || worktrunk_ref_exists "$name"; then
  wtargs=(switch "$name")
else
  wtargs=(switch --create "$name")
  [[ -n $create_base ]] && wtargs+=(--base "$create_base")
fi

herdr=${HERDR_BIN_PATH:-herdr}

if [[ $open_mode == tab ]]; then
  # Run wt in a new tab's interactive shell rather than here: only that shell can
  # cd itself into the worktree (through worktrunk's shell integration), and the
  # hook output then lands in the pane the user keeps, not in this transient one.
  tab_json=$("$herdr" tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$PWD" --label "$name" --focus)
  newpane=$(printf '%s\n' "$tab_json" | jq -r '.result.root_pane.pane_id // empty')
  tab_id=$(printf '%s\n' "$tab_json" | jq -r '.result.root_pane.tab_id // empty')
  [[ -z $newpane || -z $tab_id ]] && { printf '\033[31m%s\033[0m\n' "failed to open worktree tab"; sleep 2; exit 1; }

  # The line is typed into that tab's own shell, so it is generated in that shell's
  # syntax (see worktrunk_tab_command). The label above is a placeholder — $name may
  # be a shortcut — that tab-relabel.sh replaces once the switch lands.
  shell=$(worktrunk_pane_shell "$herdr" "$newpane")
  family=$(worktrunk_shell_family "$shell")
  line=$(worktrunk_tab_command "$family" "$plugin_root/tab-relabel.sh" "$herdr" "$tab_id" "$name" "$PWD" -- "${wtargs[@]}")

  # pane run sends the line to the tab's interactive shell; the terminal buffers it
  # until the shell finishes loading, so its `wt` command is in place when it runs.
  "$herdr" pane run "$newpane" "$line"
  exit
fi

# Native workspace mode: let worktrunk create/switch the checkout and run hooks,
# then register the resulting existing checkout through herdr's worktree API.
if ! result=$(wt "${wtargs[@]}" --no-cd --format=json); then
  printf '\n\033[31m%s\033[0m press any key to close' "wt switch failed (see above)."
  read -n1
  exit 1
fi

# $name may be a worktrunk shortcut rather than the actual branch: label with what
# it resolved to (see worktrunk_switch_label).
branch=$(printf '%s\n' "$result" | jq -r '.branch // empty' 2>/dev/null)
label=$(worktrunk_switch_label "$branch" "$name")

wtpath=$(printf '%s\n' "$result" | jq -r '.path // empty' 2>/dev/null)
if [[ -z $wtpath ]]; then
  wtpath=$(wt list --format=json 2>/dev/null \
    | worktrunk_list_items \
    | jq -r --arg b "$name" 'select(.branch == $b and .kind == "worktree") | .path' \
    | head -n1)
fi
if [[ -z $wtpath ]]; then
  printf '\033[31m%s\033[0m\n' "worktrunk returned no worktree path for: $name"
  sleep 2
  exit 1
fi

# Only a worktree worktrunk just created has hook output worth reading; a switch to
# an existing one opens straight away. Hold before the workspace opens below — it
# takes the focus with it.
if [[ $(printf '%s\n' "$result" | jq -r '.action // empty' 2>/dev/null) == created ]]; then
  worktrunk_hold_pane create "created worktree $label."
fi

# Register the worktree under the repo's ROOT workspace, not the picker pane's
# current workspace. When the picker runs from inside an existing worktree
# workspace, $HERDR_WORKSPACE_ID is that worktree's own (linked-worktree)
# workspace, which `worktree open` rejects. Resolve the repository root instead;
# Herdr reuses its parent workspace or creates one when absent.
source_json=$("$herdr" worktree list --cwd "$PWD" --json 2>/dev/null)
repo_root=$(printf '%s\n' "$source_json" | jq -r '.result.source.repo_root')

# When no workspace covers the root yet, herdr's own auto-created label falls back
# to the checkout directory's basename verbatim (e.g. "repo.git" for a bare repo)
# rather than the repository's name. Pre-create it labeled correctly so the
# `worktree open` below reuses it as-is instead of defaulting the label.
root_workspace_id=$(printf '%s\n' "$source_json" | jq -r '.result.source.source_workspace_id // empty')
if [[ -z $root_workspace_id ]]; then
  repo_label=$(printf '%s\n' "$source_json" | jq -r '.result.source.repo_name // empty')
  repo_label=${repo_label%.git}
  [[ -n $repo_label ]] && "$herdr" workspace create --cwd "$repo_root" --label "$repo_label" --no-focus >/dev/null
fi

# Picking the main/root branch itself resolves wtpath to repo_root — there's no
# separate linked-worktree workspace to label, it's the repo's own workspace.
# Passing --label here would rename that workspace to the branch (e.g. "main"),
# clobbering the repo-name label set above. Compare canonicalized paths since
# repo_root and wtpath may resolve symlinks differently (e.g. macOS /tmp).
label_args=(--label "$label")
if [[ "$(cd "$wtpath" 2>/dev/null && pwd -P)" == "$(cd "$repo_root" 2>/dev/null && pwd -P)" ]]; then
  label_args=()
fi

exec "$herdr" worktree open --cwd "$repo_root" \
  --path "$wtpath" "${label_args[@]}" --focus --json
