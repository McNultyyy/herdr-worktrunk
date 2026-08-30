# Windows PowerShell 5.1 port of lifecycle.sh: shared steps for the actions that
# destroy a worktree (remove.ps1, merge.ps1): listing what they can act on,
# resolving what herdr has open for it, and closing that UI once worktrunk is
# done. Dot-sourced after config.ps1 and helpers.ps1; entry scripts set $WtBin
# (via Resolve-WorktrunkBinOrExit) before calling into here.

# The normalized `wt list` items as an array, or $null after printing the pane
# message for whichever step broke.
function Get-WorktrunkWorktreeItems {
  $json = & $WtBin list --format=json 2>$null | Out-String
  if ($LASTEXITCODE -ne 0) {
    Write-WtError 'failed to list worktrees'
    Start-Sleep -Seconds 2
    return $null
  }

  try {
    return , @(Get-WorktrunkListItems $json)
  } catch {
    Write-WtError 'unsupported worktrunk list output'
    Start-Sleep -Seconds 2
    return $null
  }
}

# One branch per line for every worktree these actions can act on: any real
# worktree except the main one (the primary checkout can't be removed, and it's
# the merge target rather than a merge source). The current worktree IS included
# - worktrunk switches you back to the root repo.
function Get-WorktrunkWorktreeBranches($Items) {
  return , @($Items |
    Where-Object { $_.kind -ceq 'worktree' -and $null -ne $_.branch -and $_.is_main -ne $true } |
    ForEach-Object { $_.branch })
}

# The path of the worktree checked out at BRANCH, or $null.
function Get-WorktrunkWorktreePath($Items, [string]$Branch) {
  foreach ($item in $Items) {
    if ($item.kind -ceq 'worktree' -and $item.branch -ceq $Branch) { return $item.path }
  }
  return $null
}

# The id of the native herdr workspace open on the worktree at PATH, or '' (tab
# mode, or a worktree herdr never opened as a workspace). Resolve this before
# the worktree is destroyed - herdr forgets the mapping along with it. Paths are
# compared normalized: on Windows, herdr's worktrees[].path uses forward
# slashes while worktrunk reports native separators.
function Get-WorktrunkOpenWorkspaceId([string]$WtPath) {
  $herdr = $env:HERDR_BIN_PATH
  if (-not $herdr) { $herdr = 'herdr' }

  $json = & $herdr worktree list --cwd "$PWD" --json 2>$null | Out-String
  try { $worktrees = (ConvertFrom-Json -InputObject $json).result.worktrees } catch { return '' }

  $wanted = ConvertTo-WtComparablePath $WtPath
  foreach ($worktree in @($worktrees)) {
    if ((ConvertTo-WtComparablePath $worktree.path) -eq $wanted -and $worktree.open_workspace_id) {
      return [string]$worktree.open_workspace_id
    }
  }
  return ''
}

# fzf over the branches in CANDIDATES with PROMPT and HEADER, in the chrome that
# suits the picker placement. Returns '' when the user cancels.
function Invoke-WorktrunkPickBranch($Candidates, [string]$Prompt, [string]$Header) {
  $layout = Get-WorktrunkFzfLayout
  $picked = $Candidates | fzf --reverse --info=inline @layout --prompt="$Prompt" --header="$Header"
  if ($LASTEXITCODE -ne 0 -or $null -eq $picked) { return '' }
  return [string](@($picked)[-1])
}

# Remove BRANCH's worktree with the herdr UI already out of the way, and put
# the UI back if the removal fails. On Windows a directory cannot be deleted
# while any process has it as its cwd - and the worktree's own workspace pane
# (or its tab-mode panes) is exactly such a process - so unlike the Unix
# scripts, the UI has to close BEFORE `wt remove` deletes the checkout, not
# after. When worktrunk then refuses or fails, the workspace is reopened so a
# failed removal doesn't also cost the user their UI.
function Invoke-WorktrunkGuardedRemove([string]$Branch, [string]$WorkspaceId, [string]$WtPath) {
  $herdr = $env:HERDR_BIN_PATH
  if (-not $herdr) { $herdr = 'herdr' }

  Close-WorktrunkWorktreeUi $WorkspaceId $WtPath
  # The closed panes' shells need a moment to exit and release their cwd locks.
  Start-Sleep -Seconds 2

  & $WtBin remove --foreground $Branch
  if ($LASTEXITCODE -eq 0) { return $true }

  if ($WorkspaceId -and (Test-Path -LiteralPath $WtPath)) {
    & $herdr worktree open --cwd "$PWD" --path $WtPath --no-focus | Out-Null
  }
  return $false
}

# Close the herdr UI a destroyed worktree left behind: its native workspace as a
# unit, or - for the original tab-based mode and worktrees opened by older
# plugin versions - the panes sitting in it. Leaves the calling pane alone.
function Close-WorktrunkWorktreeUi([string]$WorkspaceId, [string]$WtPath) {
  $herdr = $env:HERDR_BIN_PATH
  if (-not $herdr) { $herdr = 'herdr' }

  if ($WorkspaceId) {
    & $herdr workspace close $WorkspaceId
    return
  }

  if (Test-WtRootPath $WtPath) { return }

  $json = & $herdr pane list 2>$null | Out-String
  try { $panes = (ConvertFrom-Json -InputObject $json).result.panes } catch { return }

  foreach ($pane in @($panes)) {
    if ($pane.pane_id -eq $env:HERDR_PANE_ID) { continue }
    if (Test-WtPathPrefix $pane.cwd $WtPath) {
      & $herdr pane close $pane.pane_id
    }
  }
}
