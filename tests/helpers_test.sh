#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config.sh
source "$repo_root/config.sh"   # worktrunk_gh_bin reads the plugin config
# shellcheck source=../helpers.sh
source "$repo_root/helpers.sh"

for tok in '^' '-' 'pr:123' 'mr:45' 'https://github.com/o/r/pull/7'; do
  if ! worktrunk_is_shortcut "$tok"; then
    printf 'expected %q to be a worktrunk shortcut\n' "$tok" >&2
    exit 1
  fi
done

# @ (current) is intentionally not a shortcut — see helpers.sh.
for tok in 'my-feature' 'main' 'feature/foo' '@'; do
  if worktrunk_is_shortcut "$tok"; then
    printf 'expected %q not to be a worktrunk shortcut\n' "$tok" >&2
    exit 1
  fi
done

# worktrunk_ref_exists resolves both local heads and remote-tracking branches.
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
(
  cd "$sandbox"
  git init -q
  git config user.email test@example.com
  git config user.name test
  git commit -q --allow-empty -m init
  git branch feature
  git update-ref refs/remotes/origin/remote-feat HEAD
)
cd "$sandbox"

for ref in 'feature' 'origin/remote-feat'; do
  if ! worktrunk_ref_exists "$ref"; then
    printf 'expected %q to be an existing ref\n' "$ref" >&2
    exit 1
  fi
done

for ref in 'does-not-exist' 'origin/nope'; do
  if worktrunk_ref_exists "$ref"; then
    printf 'expected %q not to be an existing ref\n' "$ref" >&2
    exit 1
  fi
done

# worktrunk_find_issue_branch is what makes the issue action "open OR create":
# it finds the branch already carrying the issue number, local first, then remote.
git branch work/issue-42-old-work
git update-ref refs/remotes/origin/issue-7-remote HEAD

found=$(worktrunk_find_issue_branch 42)
if [[ $found != 'work/issue-42-old-work' ]]; then
  printf 'expected the local issue-42 branch, got %q\n' "$found" >&2
  exit 1
fi

found=$(worktrunk_find_issue_branch 7)
if [[ $found != 'origin/issue-7-remote' ]]; then
  printf 'expected the remote issue-7 branch, got %q\n' "$found" >&2
  exit 1
fi

# issue-4 must not match issue-42, and an issue with no branch finds none.
for number in 4 2 99 not-a-number; do
  found=$(worktrunk_find_issue_branch "$number")
  if [[ -n $found ]]; then
    printf 'expected no branch for issue %q, got %q\n' "$number" "$found" >&2
    exit 1
  fi
done

cd - >/dev/null

schema_one='[
  {"branch":"main","kind":"worktree","path":"/repo","is_main":true},
  {"branch":"feature","kind":"worktree","path":"/repo.feature","is_main":false},
  {"branch":"ready","kind":"branch"}
]'
schema_two='{
  "schema":2,
  "items":[
    {"branch":"main","worktree":{"path":"/repo","main":true}},
    {"branch":"feature","worktree":{"path":"/repo.feature","main":false}},
    {"branch":"ready"}
  ]
}'
expected_items='main|worktree|/repo|true
feature|worktree|/repo.feature|false
ready|branch|null|false'

for list_json in "$schema_one" "$schema_two"; do
  actual_items=$(printf '%s\n' "$list_json" \
    | worktrunk_list_items \
    | jq -r '[.branch, .kind, (.path | tostring), (.is_main | tostring)] | join("|")')
  if [[ $actual_items != "$expected_items" ]]; then
    printf 'unexpected normalized worktrunk list items:\n%s\n' "$actual_items" >&2
    exit 1
  fi
done

if printf '%s\n' '{"schema":3}' | worktrunk_list_items >/dev/null 2>&1; then
  printf 'expected unsupported worktrunk list schema to fail\n' >&2
  exit 1
fi

# Issue title -> branch-safe slug, and the branch name built from it.
assert_helper() {
  local expected=$1 actual=$2 what=$3
  if [[ $actual != "$expected" ]]; then
    printf 'expected %s %q, got %q\n' "$what" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_helper 'fix-the-thing' "$(worktrunk_slug 'Fix THE thing!')" 'slug'
assert_helper 'a-b' "$(worktrunk_slug '  a  &  b  ')" 'slug'
assert_helper '' "$(worktrunk_slug '***')" 'slug'
# Truncation lands on a dash boundary rather than leaving a trailing separator.
assert_helper 'one-two' "$(worktrunk_slug 'one two three' 8)" 'truncated slug'

assert_helper 'feature/issue-42-fix-it' \
  "$(worktrunk_issue_branch_name 'feature/issue-{{number}}-{{slug}}' 42 fix-it)" 'branch name'
assert_helper 'wt/42-fix-it' \
  "$(worktrunk_issue_branch_name 'wt/{{ number }}-{{ slug }}' 42 fix-it)" 'branch name'
# An empty slug would otherwise leave the separator dangling.
assert_helper 'feature/issue-42' \
  "$(worktrunk_issue_branch_name 'feature/issue-{{number}}-{{slug}}' 42 '')" 'branch name'

# GH_BIN wins over PATH lookup, which is how the tests stub gh.
assert_helper '/stub/gh' "$(GH_BIN=/stub/gh worktrunk_gh_bin)" 'gh bin'

printf 'helpers tests passed\n'
