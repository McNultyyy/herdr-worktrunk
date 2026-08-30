# Windows PowerShell 5.1 port of config_test.sh: configuration parser checks.
$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'config.ps1')

function Assert-Eq($Expected, $Actual, $What = 'value') {
  if ([string]$Actual -cne [string]$Expected) {
    [Console]::Error.WriteLine("expected $What '$Expected', got '$Actual'")
    exit 1
  }
}

$configDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-config-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $configDir | Out-Null
try {
  $env:HERDR_PLUGIN_CONFIG_DIR = $null
  Assert-Eq 'workspace' (Get-WorktrunkOpenMode) 'mode'

  $env:HERDR_PLUGIN_CONFIG_DIR = $configDir
  $configFile = Join-Path $configDir 'config.toml'

  Assert-Eq 'workspace' (Get-WorktrunkOpenMode) 'mode'

  Set-Content -LiteralPath $configFile -Value 'open_mode = "tab"'
  Assert-Eq 'tab' (Get-WorktrunkOpenMode) 'mode'

  Set-Content -LiteralPath $configFile -Value 'open_mode = "workspace" # native worktree workspace'
  Assert-Eq 'workspace' (Get-WorktrunkOpenMode) 'mode'

  Set-Content -LiteralPath $configFile -Value 'open_mode = "unsupported"'
  Assert-Eq 'workspace' (Get-WorktrunkOpenMode) 'mode'

  Set-Content -LiteralPath $configFile -Value 'open_mode = "tab"'   # unrelated key -> default
  Assert-Eq 'false' (Get-WorktrunkShowRemoteBranches) 'show_remote_branches'

  Set-Content -LiteralPath $configFile -Value 'show_remote_branches = true'    # bare TOML bool
  Assert-Eq 'true' (Get-WorktrunkShowRemoteBranches) 'show_remote_branches'

  Set-Content -LiteralPath $configFile -Value 'show_remote_branches = "false"' # quoted also ok
  Assert-Eq 'false' (Get-WorktrunkShowRemoteBranches) 'show_remote_branches'

  Set-Content -LiteralPath $configFile -Value 'show_remote_branches = maybe'   # unsupported -> default
  Assert-Eq 'false' (Get-WorktrunkShowRemoteBranches) 'show_remote_branches'

  Set-Content -LiteralPath $configFile -Value 'open_mode = "tab"'   # unrelated key -> default
  Assert-Eq 'split' (Get-WorktrunkPickerPlacement) 'picker_placement'

  Set-Content -LiteralPath $configFile -Value 'picker_placement = "popup"'
  Assert-Eq 'popup' (Get-WorktrunkPickerPlacement) 'picker_placement'

  Set-Content -LiteralPath $configFile -Value 'picker_placement = split'       # bare TOML also ok
  Assert-Eq 'split' (Get-WorktrunkPickerPlacement) 'picker_placement'

  Set-Content -LiteralPath $configFile -Value 'picker_placement = "overlay"'   # unsupported -> default
  Assert-Eq 'split' (Get-WorktrunkPickerPlacement) 'picker_placement'

  Set-Content -LiteralPath $configFile -Value 'picker_placement = "split"'
  Assert-Eq '--border=rounded --margin=20%,30%' ((Get-WorktrunkFzfLayout) -join ' ') 'fzf layout'

  Set-Content -LiteralPath $configFile -Value 'picker_placement = "popup"'
  Assert-Eq '--border=none --margin=0' ((Get-WorktrunkFzfLayout) -join ' ') 'fzf layout'

  Set-Content -LiteralPath $configFile -Value 'picker_placement = "popup"'     # unset -> herdr's default
  Assert-Eq '' (Get-WorktrunkPopupDimension 'popup_width') 'popup_width'
  Assert-Eq '' (Get-WorktrunkPopupDimension 'popup_height') 'popup_height'

  Set-Content -LiteralPath $configFile -Value @('popup_width = "80%"', 'popup_height = 24')
  Assert-Eq '80%' (Get-WorktrunkPopupDimension 'popup_width') 'popup_width'
  Assert-Eq '24' (Get-WorktrunkPopupDimension 'popup_height') 'popup_height'

  Set-Content -LiteralPath $configFile -Value 'popup_width = "80 %"'           # malformed -> dropped
  Assert-Eq '' (Get-WorktrunkPopupDimension 'popup_width') 'popup_width'

  Set-Content -LiteralPath $configFile -Value 'popup_height = "%50"'           # malformed -> dropped
  Assert-Eq '' (Get-WorktrunkPopupDimension 'popup_height') 'popup_height'

  Set-Content -LiteralPath $configFile -Value 'open_mode = "tab"'   # unrelated key -> no flags
  Assert-Eq '' ((Get-WorktrunkMergeFlags) -join ' ') 'merge_flags'

  Set-Content -LiteralPath $configFile -Value 'merge_flags = "--no-squash"'
  Assert-Eq '--no-squash' ((Get-WorktrunkMergeFlags) -join ' ') 'merge_flags'

  Set-Content -LiteralPath $configFile -Value 'merge_flags = "--no-squash --no-rebase --stage=tracked"'
  Assert-Eq '--no-squash --no-rebase --stage=tracked' ((Get-WorktrunkMergeFlags) -join ' ') 'merge_flags'

  # Unrecognized entries are dropped, the rest still pass through.
  Set-Content -LiteralPath $configFile -Value 'merge_flags = "--no-squash --wat --stage=some"'
  Assert-Eq '--no-squash' ((Get-WorktrunkMergeFlags) -join ' ') 'merge_flags'

  # Flags the merger owns can't be overridden from config.
  Set-Content -LiteralPath $configFile -Value 'merge_flags = "--no-remove --format=json -C /tmp --yes"'
  Assert-Eq '' ((Get-WorktrunkMergeFlags) -join ' ') 'merge_flags'
} finally {
  Remove-Item -Recurse -Force -LiteralPath $configDir -ErrorAction SilentlyContinue
}

Write-Output 'config tests passed'
exit 0
