#!/usr/bin/env bash

# True when NAME is a token worktrunk resolves itself — a branch shortcut
# (^ default, - previous) or `:` syntax (pr:N, mr:N, or a PR/MR URL). Git branch
# names can't be these bare symbols or contain `:`, so these must be passed to
# `wt switch` as-is, never with --create. `@` (current) is omitted: switching to
# the current worktree is a no-op, and its only real use is as a --base.
worktrunk_is_shortcut() {
  case $1 in
    '^'|'-'|*:*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when NAME is an existing local branch or remote-tracking branch. Such refs
# are checked out directly by `wt switch NAME` (worktrunk creates the worktree if
# one doesn't exist yet), so they must never be passed with --create.
worktrunk_ref_exists() {
  git show-ref --quiet --verify "refs/heads/$1" \
    || git show-ref --quiet --verify "refs/remotes/$1"
}

# Emit one worktrunk list item per line with the schema 1 location fields
# (`kind`, `path`, and `is_main`) available at the top level. Worktrunk's JSON
# schema 2 wraps items in an envelope and nests those fields under `worktree`.
worktrunk_list_items() {
  jq -c '
    def normalize:
      . + {
        kind: (.kind // (if (.worktree | type) == "object" then "worktree" else "branch" end)),
        path: (.path // .worktree.path // null),
        is_main: (.is_main // .worktree.main // false)
      };

    if type == "array" then
      .[] | normalize
    elif type == "object" and ((.items | type) == "array") then
      .items[] | normalize
    else
      error("unsupported worktrunk list JSON schema")
    end
  '
}

# Print the GitHub CLI to run for the issue/PR pickers: the GH_BIN environment
# variable (also how the tests stub it), then gh_bin in the plugin config.toml,
# then `gh` on PATH. Prints nothing when none is found; callers report it.
# Needs config.sh sourced first for worktrunk_config_value.
worktrunk_gh_bin() {
  local configured

  if [[ -n ${GH_BIN:-} ]]; then
    printf '%s\n' "$GH_BIN"
    return
  fi

  configured=$(worktrunk_config_value gh_bin)
  if [[ -n $configured ]]; then
    printf '%s\n' "$configured"
    return
  fi

  if command -v gh >/dev/null; then
    printf '%s\n' gh
  fi
}

# Print a branch-safe slug for an issue title: lowercase, every run of
# non-alphanumeric characters folded to a single dash, trimmed. Truncated to the
# second argument (default 36) on a dash boundary so the branch name stays
# readable and never ends in a separator.
worktrunk_slug() {
  local title=$1 max=${2:-36} slug

  slug=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')

  if [[ $max -gt 0 && ${#slug} -gt $max ]]; then
    slug=${slug:0:max}
    while [[ $slug == *- ]]; do
      slug=${slug%-}
    done
  fi

  printf '%s\n' "$slug"
}

# Print TEMPLATE with its {{number}}/{{slug}} placeholders filled in. Both values
# are already constrained to digits and [a-z0-9-] by the callers, so neither can
# carry sed metacharacters into the substitution. An issue whose title slugs to
# nothing (emoji only, say) would leave a dangling separator behind, so trailing
# dashes and slashes are trimmed off the result.
worktrunk_issue_branch_name() {
  local template=$1 number=$2 slug=$3

  printf '%s' "$template" \
    | sed -E "s/\{\{[[:space:]]*number[[:space:]]*\}\}/$number/g
              s/\{\{[[:space:]]*slug[[:space:]]*\}\}/$slug/g
              s/[-/]+$//"
}

# Print the existing local or remote-tracking branch for issue NUMBER, or nothing
# when there is none. This is what makes the issue action "open OR create": a
# second run for the same issue switches to the branch you already have instead
# of creating a near-duplicate under the current template. Matches `issue-N`
# (also issue_N, issueN) as a whole token, so issue-4 never matches issue-42.
# Local branches win over remote-tracking ones; `wt switch` checks out either.
worktrunk_find_issue_branch() {
  local number=$1 refs branch lower

  [[ $number =~ ^[0-9]+$ ]] || return 0

  for refs in refs/heads refs/remotes; do
    while IFS= read -r branch; do
      [[ -z $branch || $branch == */HEAD ]] && continue
      lower=$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]')
      if [[ $lower =~ (^|[^0-9a-z])issue[-_]?${number}($|[^0-9]) ]]; then
        printf '%s\n' "$branch"
        return 0
      fi
    done < <(git for-each-ref --format='%(refname:short)' "$refs" 2>/dev/null)
  done
}
