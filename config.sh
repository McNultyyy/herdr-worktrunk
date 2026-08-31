#!/usr/bin/env bash

# Print the configured worktree presentation mode. Native workspace mode is the
# default; set open_mode = "tab" to keep the original tab-based behavior.
worktrunk_config_value() {
  local key=$1 config_file

  if [[ -z ${HERDR_PLUGIN_CONFIG_DIR:-} ]]; then
    return
  fi

  config_file="$HERDR_PLUGIN_CONFIG_DIR/config.toml"
  if [[ ! -f $config_file ]]; then
    return
  fi

  # Accept both quoted strings (open_mode = "tab") and bare TOML scalars
  # (show_remote_branches = false); \2 is the quoted body, \3 the unquoted token.
  sed -nE \
    "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(\"([^\"]*)\"|([^[:space:]#\"]+))[[:space:]]*(#.*)?$/\\2\\3/p" \
    "$config_file" | tail -n1
}

# Print "true"/"false" for whether the picker lists remote-tracking branches
# (origin/foo). Disabled by default; set show_remote_branches = true to show them.
worktrunk_show_remote_branches() {
  local value

  value=$(worktrunk_config_value show_remote_branches)

  case "$value" in
    ""|false)
      printf '%s\n' false
      ;;
    true)
      printf '%s\n' true
      ;;
    *)
      printf '\033[33mWarning:\033[0m unsupported show_remote_branches %q; hiding remote branches\n' "$value" >&2
      printf '%s\n' false
      ;;
  esac
}

worktrunk_open_mode() {
  local mode

  mode=$(worktrunk_config_value open_mode)

  case "$mode" in
    ""|workspace)
      printf '%s\n' workspace
      ;;
    tab)
      printf '%s\n' tab
      ;;
    *)
      printf '\033[33mWarning:\033[0m unsupported open_mode %q; using workspace\n' "$mode" >&2
      printf '%s\n' workspace
      ;;
  esac
}

# Print how the picker itself is presented: a split pane below the workspace
# (the default) or a session-modal popup over it. Popups need herdr 0.7.4.
worktrunk_picker_placement() {
  local placement

  placement=$(worktrunk_config_value picker_placement)

  case "$placement" in
    ""|split)
      printf '%s\n' split
      ;;
    popup)
      printf '%s\n' popup
      ;;
    *)
      printf '\033[33mWarning:\033[0m unsupported picker_placement %q; using split\n' "$placement" >&2
      printf '%s\n' split
      ;;
  esac
}

# Set WORKTRUNK_FZF_LAYOUT to the fzf chrome that suits the picker placement. A
# split pane is full-width, so the picker draws its own inset box to read as a
# dialog. A popup already is one, and herdr frames it with the pane title. Both
# are stated outright so a border in the user's FZF_DEFAULT_OPTS can't double up
# on the frame herdr draws.
# shellcheck disable=SC2034  # read by the scripts that source this file
worktrunk_fzf_layout() {
  case $(worktrunk_picker_placement) in
    popup)
      WORKTRUNK_FZF_LAYOUT=(--border=none --margin=0)
      ;;
    *)
      WORKTRUNK_FZF_LAYOUT=(--border=rounded '--margin=20%,30%')
      ;;
  esac
}

# Print the configured popup_width/popup_height, or nothing when unset. herdr
# takes a popup dimension as terminal cells (24) or a percentage of the window
# ("80%"), and falls back to a half-size popup when one is omitted. Drop a
# malformed value rather than passing it on and failing the open.
worktrunk_popup_dimension() {
  local key=$1 value

  value=$(worktrunk_config_value "$key")

  case "$value" in
    "")
      ;;
    *[!0-9%]*|*%?*|%*)
      printf '\033[33mWarning:\033[0m unsupported %s %q; using the default popup size\n' "$key" "$value" >&2
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

# Print the extra flags to pass to `wt merge`, one per line, from the
# whitespace-separated merge_flags value. Only flags that leave the merger's own
# contract intact are accepted: -C, --no-remove and --format are the merger's to
# set — it removes the worktree in a second step so it can close herdr's workspace
# afterwards — and an unrecognized flag is dropped rather than handed to wt as a
# broken argv. --yes is excluded on purpose: hook approval is the user's call.
worktrunk_merge_flags() {
  local value flag

  value=$(worktrunk_config_value merge_flags)

  # shellcheck disable=SC2086  # whitespace-separated flags, split on purpose
  for flag in $value; do
    case "$flag" in
      --no-squash|--no-rebase|--no-ff|--no-commit|--no-hooks)
        printf '%s\n' "$flag"
        ;;
      --stage=all|--stage=tracked|--stage=none)
        printf '%s\n' "$flag"
        ;;
      *)
        printf '\033[33mWarning:\033[0m unsupported merge_flags entry %q; ignoring it\n' "$flag" >&2
        ;;
    esac
  done
}

# Print the branch name template for a worktree created from a GitHub issue.
# {{number}} and {{slug}} are substituted; the slug comes from the issue title.
# Keyed off the issue number so hooks that key on `issue-N` (a task brief, say)
# fire for these worktrees too. A template without {{number}} would collapse
# every issue onto one branch, so it is refused rather than honored.
worktrunk_issue_branch_template() {
  local value default='feature/issue-{{number}}-{{slug}}'

  value=$(worktrunk_config_value issue_branch_template)

  if [[ -z $value ]]; then
    printf '%s\n' "$default"
  elif [[ $value =~ \{\{[[:space:]]*number[[:space:]]*\}\} ]]; then
    printf '%s\n' "$value"
  else
    printf '\033[33mWarning:\033[0m issue_branch_template %q has no {{number}} placeholder; using %q\n' \
      "$value" "$default" >&2
    printf '%s\n' "$default"
  fi
}

# Print how many issues/PRs to ask `gh` for. gh's own default is 30; 50 fills a
# picker without making the list feel truncated. Capped at four digits: the list
# is fuzzy-searched, not paged, and gh fetches every page up to the limit.
worktrunk_gh_list_limit() {
  local value

  value=$(worktrunk_config_value gh_list_limit)

  if [[ -z $value ]]; then
    printf '%s\n' 50
  elif [[ $value =~ ^[1-9][0-9]{0,3}$ ]]; then
    printf '%s\n' "$value"
  else
    printf '\033[33mWarning:\033[0m unsupported gh_list_limit %q; using 50\n' "$value" >&2
    printf '%s\n' 50
  fi
}

# Print which issues/PRs the picker lists: everything open (the default), the
# ones assigned to you, or the ones you opened. KEY is issue_filter or pr_filter.
# A fixed set rather than free-form gh flags: the value is passed to gh as argv.
worktrunk_gh_filter() {
  local key=$1 value

  value=$(worktrunk_config_value "$key")

  case "$value" in
    ""|all)
      printf '%s\n' all
      ;;
    assigned)
      printf '%s\n' assigned
      ;;
    created)
      printf '%s\n' created
      ;;
    *)
      printf '\033[33mWarning:\033[0m unsupported %s %q; listing all open items\n' "$key" "$value" >&2
      printf '%s\n' all
      ;;
  esac
}
