#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

stub_dir=$(mktemp -d)
work_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir" "$work_dir"' EXIT

config_dir="$stub_dir/config"
mkdir -p "$config_dir"

# A real repo: picker.sh lists refs with `git for-each-ref` and helpers.sh resolves
# existing branches with `git show-ref`, so git is never stubbed.
git init --quiet --initial-branch=main "$work_dir/repo"
git -C "$work_dir/repo" -c user.email=t@example.com -c user.name=test \
  commit --quiet --allow-empty -m init
git -C "$work_dir/repo" branch silas/foo-bar

# fzf stub: records the candidate list and its argv, then replays the output the
# real picker would produce for the scripted keypress.
cat > "$stub_dir/fzf" <<'EOF'
#!/usr/bin/env bash
cat > "$STUB_DIR/fzf.stdin"
printf '%s\n' "$@" > "$STUB_DIR/fzf.args"
printf '%s' "$FZF_STUB_OUT"
exit "${FZF_STUB_EXIT:-0}"
EOF

# wt stub: `list` feeds the picker, `switch` records the argv under test.
cat > "$stub_dir/wt" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == list ]]; then
  printf '%s\n' "$WT_STUB_LIST"
  exit 0
fi
printf '%s ' "$@" > "$STUB_DIR/wt.args"
printf '{"branch":"%s","path":"%s"}\n' "${2:-}" "$STUB_DIR/checkout"
EOF

# gh stub: the two list commands feed the issue/PR pickers, and `issue view`
# answers the title lookup for an issue number typed rather than picked.
cat > "$stub_dir/gh" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == issue && ${2:-} == list ]]; then
  printf '%s\n' "$GH_STUB_ISSUES"
  exit 0
fi
if [[ ${1:-} == pr && ${2:-} == list ]]; then
  printf '%s\n' "$GH_STUB_PRS"
  exit 0
fi
if [[ ${1:-} == issue && ${2:-} == view ]]; then
  printf '%s\n' "$GH_STUB_TITLE"
  exit 0
fi
exit 1
EOF

# herdr stub: `worktree list` locates the repo root, `worktree open` is the result.
cat > "$stub_dir/herdr" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == worktree && ${2:-} == list ]]; then
  printf '{"result":{"source":{"repo_root":"%s","repo_name":"repo","source_workspace_id":"w1"}}}\n' "$REPO_CWD"
  exit 0
fi
printf '%s ' "$@" > "$STUB_DIR/herdr.args"
EOF

chmod +x "$stub_dir/fzf" "$stub_dir/wt" "$stub_dir/herdr" "$stub_dir/gh"

# Two worktree branches from `wt list`, one of them already a local head.
wt_list='[{"branch":"silas/foo-bar","path":"/tmp/a","kind":"worktree"},
          {"branch":"pr-42","path":"/tmp/b","kind":"worktree"}]'

gh_issues='#42  Fix the thing
#9  Old work'
gh_prs='#16  feat/eager-worktree-focus  Eager worktree focus'

run_picker() {
  local out=$1 exit_code=$2
  shift 2
  rm -f "$stub_dir/wt.args" "$stub_dir/herdr.args"
  (
    cd "$work_dir/repo"
    PATH="$stub_dir:$PATH" \
    STUB_DIR="$stub_dir" \
    REPO_CWD="$work_dir/repo" \
    FZF_STUB_OUT="$out" \
    FZF_STUB_EXIT="$exit_code" \
    WT_STUB_LIST="$wt_list" \
    HERDR_PLUGIN_ROOT="$repo_root" \
    HERDR_BIN_PATH="$stub_dir/herdr" \
    HERDR_PLUGIN_CONFIG_DIR="$config_dir" \
    HERDR_WORKSPACE_ID=w1 \
    GH_BIN="$stub_dir/gh" \
    GH_STUB_ISSUES="$gh_issues" \
    GH_STUB_PRS="$gh_prs" \
    GH_STUB_TITLE="Add a widget" \
    WT_PICKER_PREFILL="${WT_PICKER_PREFILL:-}" \
      bash "$repo_root/picker.sh" "$@" >/dev/null 2>&1
  )
}

wt_args() { cat "$stub_dir/wt.args" 2>/dev/null || true; }

assert_eq() {
  local expected=$1 actual=$2 what=${3:-value}
  if [[ $actual != "$expected" ]]; then
    printf 'expected %s %q, got %q\n' "$what" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_contains() {
  local needle=$1 haystack=$2 what=${3:-output}
  if [[ $haystack != *"$needle"* ]]; then
    printf 'expected %q in %s %q\n' "$needle" "$what" "$haystack" >&2
    exit 1
  fi
}

# Plain ↵ on a match switches to the match, not to the query.
run_picker $'silas/foo\nsilas/foo-bar' 0
assert_eq 'switch silas/foo-bar --no-cd --format=json ' "$(wt_args)" 'wt argv'

# Plain ↵ with nothing matched creates the typed name (fzf exits 1).
run_picker $'silas/brand-new' 1
assert_eq 'switch --create silas/brand-new --no-cd --format=json ' "$(wt_args)" 'wt argv'

# alt-↵ prints the query alone, so the typed name is created even though the list
# had a fuzzy match highlighted.
run_picker $'silas/foo' 0
assert_eq 'switch --create silas/foo --no-cd --format=json ' "$(wt_args)" 'wt argv'

# ...and the base is carried through when creating from the current branch.
run_picker $'silas/foo' 0 --create-base=current
assert_eq 'switch --create silas/foo --base @ --no-cd --format=json ' "$(wt_args)" 'wt argv'

# A name that is an existing branch is switched to, never created: worktrunk checks
# out existing refs and --create would fail.
run_picker $'silas/foo-bar' 0
assert_eq 'switch silas/foo-bar --no-cd --format=json ' "$(wt_args)" 'wt argv'

# esc cancels without touching worktrunk.
run_picker '' 130
assert_eq '' "$(wt_args)" 'wt argv'

# The binding the header advertises is the one fzf is asked for.
assert_contains '--bind=alt-enter:print-query' "$(cat "$stub_dir/fzf.args")" 'fzf argv'

# Refs are offered before the slow `wt list` source and deduped without sorting, so
# the picker fills in before worktrunk has finished stat-ing every checkout.
assert_eq $'main\nsilas/foo-bar\npr-42' "$(cat "$stub_dir/fzf.stdin")" 'candidate list'

# --- issue and PR sources ----------------------------------------------------
# (after the branch-source assertions: the extra branch below would otherwise
# show up in the branch picker's candidate list)

# An issue with no branch yet is created under the configured template, with the
# number kept in the name so worktrunk hooks keyed on `issue-N` still fire.
run_picker '#42  Fix the thing' 0 --source=issues
assert_eq 'switch --create feature/issue-42-fix-the-thing --no-cd --format=json ' "$(wt_args)" 'wt argv'

# gh's lines are what the picker offers, verbatim.
assert_eq "$gh_issues" "$(cat "$stub_dir/fzf.stdin")" 'issue candidate list'

# An issue that already has a branch is switched to, never created again.
git -C "$work_dir/repo" branch feature/issue-9-old
run_picker '#9  Old work' 0 --source=issues
assert_eq 'switch feature/issue-9-old --no-cd --format=json ' "$(wt_args)" 'wt argv'

# A number typed rather than picked (fzf exits 1) carries no title, so the slug
# comes from `gh issue view`.
run_picker '77' 1 --source=issues
assert_eq 'switch --create feature/issue-77-add-a-widget --no-cd --format=json ' "$(wt_args)" 'wt argv'

# A configured template is honored, including one that leaves no slug.
printf 'issue_branch_template = "wt/{{number}}"\n' > "$config_dir/config.toml"
run_picker '#42  Fix the thing' 0 --source=issues
assert_eq 'switch --create wt/42 --no-cd --format=json ' "$(wt_args)" 'wt argv'
rm -f "$config_dir/config.toml"

# A PR goes through worktrunk's own pr:N shortcut, which handles fork PRs and
# pushRemote — so it is passed as-is, never with --create.
run_picker '#16  feat/eager-worktree-focus  Eager worktree focus' 0 --source=prs
assert_eq 'switch pr:16 --no-cd --format=json ' "$(wt_args)" 'wt argv'

# A link handler prefills the number, so the picker skips fzf entirely — the
# scripted fzf abort below would cancel the run if it were consulted.
WT_PICKER_PREFILL=16 run_picker '' 130 --source=prs
assert_eq 'switch pr:16 --no-cd --format=json ' "$(wt_args)" 'wt argv'

# The prefill only applies to the gh sources; the branch picker still asks.
WT_PICKER_PREFILL=16 run_picker '' 130
assert_eq '' "$(wt_args)" 'wt argv'

printf 'picker_test: ok\n'
