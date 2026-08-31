# Windows PowerShell 5.1 port of picker_test.sh: picker argument checks against
# a real git repo, with wt/fzf/herdr stubbed as .cmd shims.
$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path -Parent $PSScriptRoot

function Fail([string]$Message) {
  [Console]::Error.WriteLine($Message)
  exit 1
}

$stubDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-picker-test-" + [guid]::NewGuid().ToString('N'))
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-picker-work-" + [guid]::NewGuid().ToString('N'))
$configDir = Join-Path $stubDir 'config'
New-Item -ItemType Directory -Path $configDir | Out-Null
New-Item -ItemType Directory -Path $workDir | Out-Null
$origPath = $env:Path
try {
  # A real repo: picker.ps1 lists refs with `git for-each-ref` and helpers.ps1
  # resolves existing branches with `git show-ref`, so git is never stubbed.
  $repo = Join-Path $workDir 'repo'
  git init --quiet --initial-branch=main $repo
  git -C $repo -c user.email=t@example.com -c user.name=test commit --quiet --allow-empty -m init
  git -C $repo branch silas/foo-bar

  # fzf stub: records the candidate list and its argv, then replays the output
  # the real picker would produce for the scripted keypress.
  Set-Content -LiteralPath (Join-Path $stubDir 'fzf.cmd') -Value @(
    '@echo off',
    'findstr "^" > "%STUB_DIR%\fzf.stdin"',
    '> "%STUB_DIR%\fzf.args" echo %*',
    'type "%FZF_STUB_OUT_FILE%"',
    'exit /b %FZF_STUB_EXIT%'
  )

  # wt stub: `list` feeds the picker, `switch` records the argv under test.
  # PR-42 next to pr-42 checks that dedup keeps branches that differ only in
  # case - they are distinct git refs.
  $listFile = Join-Path $stubDir 'wt-list.json'
  Set-Content -LiteralPath $listFile -Value '[{"branch":"silas/foo-bar","path":"/tmp/a","kind":"worktree"},{"branch":"pr-42","path":"/tmp/b","kind":"worktree"},{"branch":"PR-42","path":"/tmp/c","kind":"worktree"}]'
  $switchJson = Join-Path $stubDir 'wt-switch.json'
  @{ branch = 'x'; path = (Join-Path $stubDir 'checkout') } | ConvertTo-Json -Compress |
    Set-Content -LiteralPath $switchJson
  Set-Content -LiteralPath (Join-Path $stubDir 'wt.cmd') -Value @(
    '@echo off',
    'if "%~1"=="list" (',
    'type "%WT_STUB_LIST_FILE%"',
    'exit /b 0',
    ')',
    '> "%STUB_DIR%\wt.args" echo %*',
    'type "%WT_STUB_SWITCH_JSON%"',
    'exit /b 0'
  )

  # gh stub: the two list commands feed the issue/PR pickers, and `issue view`
  # answers the title lookup for an issue number typed rather than picked. It
  # answers in JSON, like the real gh, and records its argv one argument per
  # line — the picker must never hand gh a `--jq` program, because Windows
  # PowerShell garbles a native argument that has both spaces and quotes.
  $issuesFile = Join-Path $stubDir 'gh-issues.json'
  Set-Content -LiteralPath $issuesFile -Value '[{"number":42,"title":"Fix the thing"},{"number":9,"title":"Old work"}]'
  $prsFile = Join-Path $stubDir 'gh-prs.json'
  Set-Content -LiteralPath $prsFile -Value '[{"number":16,"headRefName":"feat/eager-worktree-focus","title":"Eager worktree focus"}]'
  $titleFile = Join-Path $stubDir 'gh-title.json'
  Set-Content -LiteralPath $titleFile -Value '{"title":"Add a widget"}'
  Set-Content -LiteralPath (Join-Path $stubDir 'gh.cmd') -Value @(
    '@echo off',
    '> "%STUB_DIR%\gh.args" echo %*',
    'if "%~1 %~2"=="issue list" (',
    'type "%GH_STUB_ISSUES%"',
    'exit /b 0',
    ')',
    'if "%~1 %~2"=="pr list" (',
    'type "%GH_STUB_PRS%"',
    'exit /b 0',
    ')',
    'if "%~1 %~2"=="issue view" (',
    'type "%GH_STUB_TITLE_JSON%"',
    'exit /b 0',
    ')',
    'exit /b 1'
  )

  # herdr stub: `worktree list` locates the repo root, `worktree open` is the result.
  $worktreeJson = Join-Path $stubDir 'worktrees.json'
  @{ result = @{ source = @{ repo_root = $repo; repo_name = 'repo'; source_workspace_id = 'w1' } } } |
    ConvertTo-Json -Compress -Depth 5 | Set-Content -LiteralPath $worktreeJson
  Set-Content -LiteralPath (Join-Path $stubDir 'herdr.cmd') -Value @(
    '@echo off',
    'if "%~1 %~2"=="worktree list" (',
    'type "%HERDR_WORKTREE_JSON%"',
    'exit /b 0',
    ')',
    '>> "%STUB_DIR%\herdr.args" echo %*',
    'exit /b 0'
  )

  $env:Path = "$stubDir;$origPath"
  $env:STUB_DIR = $stubDir
  $env:WT_STUB_LIST_FILE = $listFile
  $env:WT_STUB_SWITCH_JSON = $switchJson
  $env:HERDR_WORKTREE_JSON = $worktreeJson
  $env:WORKTRUNK_BIN = Join-Path $stubDir 'wt.cmd'
  $env:HERDR_PLUGIN_ROOT = $repoRoot
  $env:HERDR_BIN_PATH = Join-Path $stubDir 'herdr.cmd'
  $env:HERDR_PLUGIN_CONFIG_DIR = $configDir
  $env:HERDR_WORKSPACE_ID = 'w1'
  $env:GH_BIN = Join-Path $stubDir 'gh.cmd'
  $env:GH_STUB_ISSUES = $issuesFile
  $env:GH_STUB_PRS = $prsFile
  $env:GH_STUB_TITLE_JSON = $titleFile
  $outFile = Join-Path $stubDir 'fzf-out.txt'
  $env:FZF_STUB_OUT_FILE = $outFile

  function Invoke-Picker([string[]]$FzfOut, [string]$FzfExit, [string[]]$Extra = @()) {
    $extra = @($Extra)
    Remove-Item (Join-Path $stubDir 'wt.args'), (Join-Path $stubDir 'herdr.args') -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $outFile -Value $FzfOut
    $env:FZF_STUB_EXIT = $FzfExit
    Push-Location $repo
    # Empty pipeline input closes the child's stdin so failure paths that read
    # a key can never block the test run.
    try { $null = @() | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'picker.ps1') @extra 2>&1 }
    finally { Pop-Location }
  }

  function Get-GhArgs {
    $line = Get-Content -LiteralPath (Join-Path $stubDir 'gh.args') -ErrorAction SilentlyContinue
    return [string]@($line)[0]
  }

  function Get-WtArgs {
    $line = Get-Content -LiteralPath (Join-Path $stubDir 'wt.args') -ErrorAction SilentlyContinue
    return [string]@($line)[0]
  }

  function Assert-Eq($Expected, $Actual, $What = 'value') {
    if ([string]$Actual -cne [string]$Expected) {
      Fail "expected $What '$Expected', got '$Actual'"
    }
  }

  # Plain enter on a match switches to the match, not to the query.
  Invoke-Picker @('silas/foo', 'silas/foo-bar') '0'
  Assert-Eq 'switch silas/foo-bar --no-cd --format=json' (Get-WtArgs) 'wt argv'

  # Plain enter with nothing matched creates the typed name (fzf exits 1).
  Invoke-Picker @('silas/brand-new') '1'
  Assert-Eq 'switch --create silas/brand-new --no-cd --format=json' (Get-WtArgs) 'wt argv'

  # alt-enter prints the query alone, so the typed name is created even though
  # the list had a fuzzy match highlighted.
  Invoke-Picker @('silas/foo') '0'
  Assert-Eq 'switch --create silas/foo --no-cd --format=json' (Get-WtArgs) 'wt argv'

  # ...and the base is carried through when creating from the current branch.
  Invoke-Picker @('silas/foo') '0' @('--create-base=current')
  Assert-Eq 'switch --create silas/foo --base @ --no-cd --format=json' (Get-WtArgs) 'wt argv'

  # A name that is an existing branch is switched to, never created: worktrunk
  # checks out existing refs and --create would fail.
  Invoke-Picker @('silas/foo-bar') '0'
  Assert-Eq 'switch silas/foo-bar --no-cd --format=json' (Get-WtArgs) 'wt argv'

  # esc cancels without touching worktrunk.
  Invoke-Picker @() '130'
  Assert-Eq '' (Get-WtArgs) 'wt argv'

  # The binding the header advertises is the one fzf is asked for.
  $fzfArgs = (Get-Content -LiteralPath (Join-Path $stubDir 'fzf.args') -ErrorAction SilentlyContinue) -join ' '
  if ($fzfArgs -notlike '*--bind=alt-enter:print-query*') {
    Fail "expected --bind=alt-enter:print-query in fzf argv '$fzfArgs'"
  }

  # Refs are offered before the slow `wt list` source and deduped without
  # sorting, so the picker fills in before worktrunk has finished stat-ing
  # every checkout.
  $stdin = @(Get-Content -LiteralPath (Join-Path $stubDir 'fzf.stdin') -ErrorAction SilentlyContinue) -join "`n"
  Assert-Eq "main`nsilas/foo-bar`npr-42`nPR-42" $stdin 'candidate list'

  # --- issue and PR sources -------------------------------------------------
  # (after the branch-source assertions: the extra branch below would otherwise
  # show up in the branch picker's candidate list)

  # An issue with no branch yet is created under the configured template, with
  # the number kept in the name so worktrunk hooks keyed on `issue-N` still fire.
  Invoke-Picker @('#42  Fix the thing') '0' @('--source=issues')
  Assert-Eq 'switch --create feature/issue-42-fix-the-thing --no-cd --format=json' (Get-WtArgs) 'wt argv'

  # gh answers in JSON and the picker formats the lines itself. No --jq: Windows
  # PowerShell garbles a native argument carrying both spaces and quotes, which
  # is exactly what a jq program is, and gh rejects the fragments.
  Assert-Eq 'issue list --limit 50 --json number,title' (Get-GhArgs) 'gh argv'
  $stdin = @(Get-Content -LiteralPath (Join-Path $stubDir 'fzf.stdin') -ErrorAction SilentlyContinue) -join "`n"
  Assert-Eq "#42  Fix the thing`n#9  Old work" $stdin 'issue candidate list'

  # An issue that already has a branch is switched to, never created again.
  git -C $repo branch feature/issue-9-old
  Invoke-Picker @('#9  Old work') '0' @('--source=issues')
  Assert-Eq 'switch feature/issue-9-old --no-cd --format=json' (Get-WtArgs) 'wt argv'

  # A number typed rather than picked (fzf exits 1) carries no title, so the
  # slug comes from `gh issue view`.
  Invoke-Picker @('77') '1' @('--source=issues')
  Assert-Eq 'switch --create feature/issue-77-add-a-widget --no-cd --format=json' (Get-WtArgs) 'wt argv'
  Assert-Eq 'issue view 77 --json title' (Get-GhArgs) 'gh argv'

  # A configured template is honored, including one that leaves no slug.
  Set-Content -LiteralPath (Join-Path $configDir 'config.toml') -Value 'issue_branch_template = "wt/{{number}}"'
  Invoke-Picker @('#42  Fix the thing') '0' @('--source=issues')
  Assert-Eq 'switch --create wt/42 --no-cd --format=json' (Get-WtArgs) 'wt argv'
  Remove-Item -LiteralPath (Join-Path $configDir 'config.toml') -ErrorAction SilentlyContinue

  # A PR goes through worktrunk's own pr:N shortcut, which handles fork PRs and
  # pushRemote - so it is passed as-is, never with --create.
  Invoke-Picker @('#16  feat/eager-worktree-focus  Eager worktree focus') '0' @('--source=prs')
  Assert-Eq 'switch pr:16 --no-cd --format=json' (Get-WtArgs) 'wt argv'
  Assert-Eq 'pr list --limit 50 --json number,headRefName,title' (Get-GhArgs) 'gh argv'
  $stdin = @(Get-Content -LiteralPath (Join-Path $stubDir 'fzf.stdin') -ErrorAction SilentlyContinue) -join "`n"
  Assert-Eq '#16  feat/eager-worktree-focus  Eager worktree focus' $stdin 'pr candidate list'

  # The configured filter reaches gh as its own flag pair.
  Set-Content -LiteralPath (Join-Path $configDir 'config.toml') -Value @('issue_filter = "assigned"', 'gh_list_limit = 7')
  Invoke-Picker @('#42  Fix the thing') '0' @('--source=issues')
  Assert-Eq 'issue list --limit 7 --json number,title --assignee @me' (Get-GhArgs) 'gh argv'
  Remove-Item -LiteralPath (Join-Path $configDir 'config.toml') -ErrorAction SilentlyContinue

  # A link handler prefills the number, so the picker skips fzf entirely - the
  # scripted fzf abort below would cancel the run if it were consulted.
  $env:WT_PICKER_PREFILL = '16'
  try {
    Invoke-Picker @() '130' @('--source=prs')
    Assert-Eq 'switch pr:16 --no-cd --format=json' (Get-WtArgs) 'wt argv'
  } finally {
    Remove-Item Env:\WT_PICKER_PREFILL -ErrorAction SilentlyContinue
  }

  # The prefill only applies to the gh sources; the branch picker still asks.
  $env:WT_PICKER_PREFILL = '16'
  try {
    Invoke-Picker @() '130'
    Assert-Eq '' (Get-WtArgs) 'wt argv'
  } finally {
    Remove-Item Env:\WT_PICKER_PREFILL -ErrorAction SilentlyContinue
  }
} finally {
  $env:Path = $origPath
  foreach ($name in 'STUB_DIR', 'WT_STUB_LIST_FILE', 'WT_STUB_SWITCH_JSON', 'HERDR_WORKTREE_JSON',
                    'WORKTRUNK_BIN', 'HERDR_PLUGIN_ROOT', 'HERDR_BIN_PATH', 'HERDR_PLUGIN_CONFIG_DIR',
                    'HERDR_WORKSPACE_ID', 'FZF_STUB_OUT_FILE', 'FZF_STUB_EXIT',
                    'GH_BIN', 'GH_STUB_ISSUES', 'GH_STUB_PRS', 'GH_STUB_TITLE_JSON', 'WT_PICKER_PREFILL') {
    Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
  }
  Remove-Item -Recurse -Force -LiteralPath $stubDir, $workDir -ErrorAction SilentlyContinue
}

Write-Output 'picker tests passed'
exit 0
