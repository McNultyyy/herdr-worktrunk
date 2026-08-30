# Windows PowerShell 5.1 port of merge_test.sh: merge argument and failure-path
# checks. Runs merge.ps1 as a child process with wt/fzf/herdr stubbed as .cmd
# shims; JSON payloads travel through files so cmd quoting can't mangle them.
$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path -Parent $PSScriptRoot

function Fail([string]$Message) {
  [Console]::Error.WriteLine($Message)
  exit 1
}

$stubDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-merge-test-" + [guid]::NewGuid().ToString('N'))
$configDir = Join-Path $stubDir 'config'
New-Item -ItemType Directory -Path $configDir | Out-Null
$origPath = $env:Path
try {
  $wtLog = Join-Path $stubDir 'wt.log'
  $herdrLog = Join-Path $stubDir 'herdr.log'
  $listFile = Join-Path $stubDir 'wt-list.json'
  $worktreeJson = Join-Path $stubDir 'worktrees.json'
  $pickFile = Join-Path $stubDir 'fzf-pick.txt'

  # Stand in for `wt`: list answers with one mergeable worktree, and
  # merge/remove record their argv and fail when the test asks them to. The
  # feature worktree is a real directory: a failed removal only reopens the
  # workspace when the checkout still exists on disk. herdr reports it with
  # forward slashes (as it does live) while wt hands out native separators.
  $fakeWt = Join-Path $stubDir 'repo.feature'
  New-Item -ItemType Directory -Path $fakeWt | Out-Null
  $fakeWtFwd = $fakeWt -replace '\\', '/'
  Set-Content -LiteralPath $listFile -Value (ConvertTo-Json -Compress -Depth 5 -InputObject @(
    @{ branch = 'main'; kind = 'worktree'; path = '/repo'; is_main = $true },
    @{ branch = 'feature'; kind = 'worktree'; path = $fakeWt; is_main = $false }
  ))
  Set-Content -LiteralPath (Join-Path $stubDir 'wt.cmd') -Value @(
    '@echo off',
    '>> "%WT_STUB_LOG%" echo %*',
    'if "%~1"=="list" (',
    'type "%WT_STUB_LIST_FILE%"',
    'exit /b 0',
    ')',
    'if "%~1"=="merge" exit /b %WT_STUB_MERGE_STATUS%',
    'if "%~1"=="remove" exit /b %WT_STUB_REMOVE_STATUS%',
    'exit /b 0'
  )

  # fzf picks whatever the pick file holds; the picker's stdin is drained either way.
  Set-Content -LiteralPath (Join-Path $stubDir 'fzf.cmd') -Value @(
    '@echo off',
    'findstr "^" > nul 2> nul',
    'type "%FZF_STUB_PICK_FILE%"',
    'exit /b 0'
  )

  Set-Content -LiteralPath $worktreeJson -Value "{`"result`":{`"worktrees`":[{`"path`":`"$fakeWtFwd`",`"open_workspace_id`":`"ws-feature`"}]}}"
  Set-Content -LiteralPath (Join-Path $stubDir 'herdr.cmd') -Value @(
    '@echo off',
    'if "%~1 %~2"=="worktree list" (',
    'type "%HERDR_WORKTREE_JSON%"',
    'exit /b 0',
    ')',
    '>> "%HERDR_STUB_LOG%" echo %*',
    'exit /b 0'
  )

  $env:Path = "$stubDir;$origPath"
  $env:WORKTRUNK_BIN = Join-Path $stubDir 'wt.cmd'
  $env:WT_STUB_LOG = $wtLog
  $env:WT_STUB_LIST_FILE = $listFile
  $env:HERDR_BIN_PATH = Join-Path $stubDir 'herdr.cmd'
  $env:HERDR_WORKTREE_JSON = $worktreeJson
  $env:HERDR_STUB_LOG = $herdrLog
  $env:HERDR_PLUGIN_ROOT = $repoRoot
  $env:HERDR_PLUGIN_CONFIG_DIR = $configDir
  $env:FZF_STUB_PICK_FILE = $pickFile
  $configFile = Join-Path $configDir 'config.toml'

  # Run merge.ps1 with the given argv and the config already in place; the wt
  # and herdr logs then expose what each was asked to do.
  function Invoke-Merge {
    Set-Content -LiteralPath $env:WT_STUB_LOG -Value $null
    Set-Content -LiteralPath $env:HERDR_STUB_LOG -Value $null
    if (-not (Test-Path -LiteralPath $pickFile)) { Set-Content -LiteralPath $pickFile -Value 'feature' }
    # Empty pipeline input closes the child's stdin (the bash test's </dev/null):
    # the failure paths print "press any key" and read a line, which must not block.
    $null = @() | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'merge.ps1') @args 2>&1
    return $LASTEXITCODE
  }

  function Get-LogLines([string]$Log) {
    return @(Get-Content -LiteralPath $Log -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' })
  }
  function Assert-Log([string]$Label, [string]$Expected, [string]$Log) {
    if (@(Get-LogLines $Log) -cnotcontains $Expected) {
      Fail "expected $Label call '$Expected', got:`n$(@(Get-LogLines $Log) -join "`n")"
    }
  }
  # Matches on the start of a recorded argv, so refuting `remove` can't trip
  # over the `--no-remove` flag the merge call carries.
  function Refute-Log([string]$Label, [string]$Unexpected, [string]$Log) {
    foreach ($line in (Get-LogLines $Log)) {
      if ($line.StartsWith($Unexpected)) {
        Fail "unexpected $Label call '$Unexpected' in:`n$(@(Get-LogLines $Log) -join "`n")"
      }
    }
  }

  # Default action: merge the picked worktree by path, close its UI, then
  # remove it in the foreground. The UI closes before the removal because
  # Windows refuses to delete a directory that is any process's cwd - and a
  # successful removal must not reopen anything.
  Set-Content -LiteralPath $configFile -Value $null
  Set-Content -LiteralPath $pickFile -Value 'feature'
  $env:WT_STUB_MERGE_STATUS = '0'
  $env:WT_STUB_REMOVE_STATUS = '0'
  [void](Invoke-Merge)
  Assert-Log wt "merge --no-remove -C $fakeWt" $wtLog
  Assert-Log wt 'remove --foreground feature' $wtLog
  Assert-Log herdr 'workspace close ws-feature' $herdrLog
  Refute-Log herdr 'worktree open' $herdrLog

  # The no-squash variant adds its flag; config flags come along too, once each.
  Set-Content -LiteralPath $configFile -Value 'merge_flags = "--no-rebase"'
  [void](Invoke-Merge '--no-squash')
  Assert-Log wt "merge --no-remove -C $fakeWt --no-rebase --no-squash" $wtLog

  Set-Content -LiteralPath $configFile -Value 'merge_flags = "--no-squash"'
  [void](Invoke-Merge '--no-squash')
  Assert-Log wt "merge --no-remove -C $fakeWt --no-squash" $wtLog

  # An unsupported option is a plugin bug, not a merge to attempt.
  Set-Content -LiteralPath $configFile -Value $null
  $code = Invoke-Merge '--no-such-flag'
  if ($code -eq 0) { Fail 'expected merge.ps1 to reject an unsupported option' }
  Refute-Log wt 'merge' $wtLog

  # Cancelling the picker touches nothing.
  Set-Content -LiteralPath $pickFile -Value $null
  [void](Invoke-Merge)
  Refute-Log wt 'merge' $wtLog
  Refute-Log herdr 'workspace close' $herdrLog
  Set-Content -LiteralPath $pickFile -Value 'feature'

  # A failed merge leaves the worktree and its workspace alone.
  $env:WT_STUB_MERGE_STATUS = '1'
  [void](Invoke-Merge)
  Refute-Log wt 'remove' $wtLog
  Refute-Log herdr 'workspace close' $herdrLog
  $env:WT_STUB_MERGE_STATUS = '0'

  # A merge that landed but a removal that didn't reopens the workspace - the
  # UI was closed up front (Windows cwd locking), but the checkout still exists.
  $env:WT_STUB_REMOVE_STATUS = '1'
  [void](Invoke-Merge)
  Assert-Log wt 'remove --foreground feature' $wtLog
  Assert-Log herdr 'workspace close ws-feature' $herdrLog
  $reopened = @(Get-LogLines $herdrLog) | Where-Object { $_ -clike "worktree open*--path $fakeWt*--no-focus*" }
  if (-not $reopened) {
    Fail "expected the workspace to be reopened after a failed removal, got:`n$(@(Get-LogLines $herdrLog) -join "`n")"
  }
  $env:WT_STUB_REMOVE_STATUS = '0'

  # Acting on the worktree whose workspace this very script runs in: closing
  # that workspace first would kill the script, so it closes only once the
  # removal has succeeded...
  $env:HERDR_WORKSPACE_ID = 'ws-feature'
  [void](Invoke-Merge)
  Assert-Log wt 'remove --foreground feature' $wtLog
  Assert-Log herdr 'workspace close ws-feature' $herdrLog
  Refute-Log herdr 'worktree open' $herdrLog

  # ...and a failed removal there neither closes nor reopens it.
  $env:WT_STUB_REMOVE_STATUS = '1'
  [void](Invoke-Merge)
  Assert-Log wt 'remove --foreground feature' $wtLog
  Refute-Log herdr 'workspace close' $herdrLog
  Refute-Log herdr 'worktree open' $herdrLog
  $env:WT_STUB_REMOVE_STATUS = '0'
  Remove-Item Env:\HERDR_WORKSPACE_ID -ErrorAction SilentlyContinue
} finally {
  $env:Path = $origPath
  foreach ($name in 'WORKTRUNK_BIN', 'WT_STUB_LOG', 'WT_STUB_LIST_FILE', 'WT_STUB_MERGE_STATUS',
                    'WT_STUB_REMOVE_STATUS', 'HERDR_BIN_PATH', 'HERDR_WORKTREE_JSON',
                    'HERDR_STUB_LOG', 'HERDR_PLUGIN_ROOT', 'HERDR_PLUGIN_CONFIG_DIR',
                    'FZF_STUB_PICK_FILE') {
    Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
  }
  Remove-Item -Recurse -Force -LiteralPath $stubDir -ErrorAction SilentlyContinue
}

Write-Output 'merge tests passed'
exit 0
