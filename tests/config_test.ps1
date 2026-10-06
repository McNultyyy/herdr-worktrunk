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

  # Single-quoted TOML literals are the natural form for Windows paths (no
  # backslash escaping) - including ones with spaces - and must not keep their
  # quotes. Double-quoted and bare values still work alongside.
  Set-Content -LiteralPath $configFile -Value "worktrunk_bin = 'C:\path\to\wt.exe'"
  Assert-Eq 'C:\path\to\wt.exe' (Get-WorktrunkConfigValue 'worktrunk_bin') 'worktrunk_bin'
  Set-Content -LiteralPath $configFile -Value "worktrunk_bin = 'C:\Program Files\worktrunk\wt.exe' # literal"
  Assert-Eq 'C:\Program Files\worktrunk\wt.exe' (Get-WorktrunkConfigValue 'worktrunk_bin') 'worktrunk_bin'
  Set-Content -LiteralPath $configFile -Value 'worktrunk_bin = "C:\\tools\\wt.exe"'
  Assert-Eq 'C:\\tools\\wt.exe' (Get-WorktrunkConfigValue 'worktrunk_bin') 'worktrunk_bin'
  Set-Content -LiteralPath $configFile -Value "worktrunk_bin = ''"
  Assert-Eq '' (Get-WorktrunkConfigValue 'worktrunk_bin') 'worktrunk_bin'

  # GitHub issue/PR picker settings.
  Set-Content -LiteralPath $configFile -Value 'open_mode = "tab"'   # unrelated key -> defaults
  Assert-Eq 'feature/issue-{{number}}-{{slug}}' (Get-WorktrunkIssueBranchTemplate) 'issue_branch_template'
  Assert-Eq '50' (Get-WorktrunkGhListLimit) 'gh_list_limit'
  Assert-Eq 'all' (Get-WorktrunkGhFilter 'issue_filter') 'issue_filter'

  Set-Content -LiteralPath $configFile -Value 'issue_branch_template = "wt/{{ number }}-{{ slug }}"'
  Assert-Eq 'wt/{{ number }}-{{ slug }}' (Get-WorktrunkIssueBranchTemplate) 'issue_branch_template'

  # A template without {{number}} would collapse every issue onto one branch.
  Set-Content -LiteralPath $configFile -Value 'issue_branch_template = "feature/{{slug}}"'
  Assert-Eq 'feature/issue-{{number}}-{{slug}}' (Get-WorktrunkIssueBranchTemplate) 'issue_branch_template'

  Set-Content -LiteralPath $configFile -Value 'gh_list_limit = 200'
  Assert-Eq '200' (Get-WorktrunkGhListLimit) 'gh_list_limit'
  Set-Content -LiteralPath $configFile -Value 'gh_list_limit = 0'          # unsupported -> default
  Assert-Eq '50' (Get-WorktrunkGhListLimit) 'gh_list_limit'
  Set-Content -LiteralPath $configFile -Value 'gh_list_limit = "lots"'     # unsupported -> default
  Assert-Eq '50' (Get-WorktrunkGhListLimit) 'gh_list_limit'

  Set-Content -LiteralPath $configFile -Value 'pr_filter = "assigned"'
  Assert-Eq 'assigned' (Get-WorktrunkGhFilter 'pr_filter') 'pr_filter'
  Assert-Eq 'all' (Get-WorktrunkGhFilter 'issue_filter') 'issue_filter'    # keys are independent
  Set-Content -LiteralPath $configFile -Value 'issue_filter = created'     # bare TOML also ok
  Assert-Eq 'created' (Get-WorktrunkGhFilter 'issue_filter') 'issue_filter'
  Set-Content -LiteralPath $configFile -Value 'issue_filter = "mine"'      # unsupported -> default
  Assert-Eq 'all' (Get-WorktrunkGhFilter 'issue_filter') 'issue_filter'

  Set-Content -LiteralPath $configFile -Value 'open_mode = "tab"'   # unrelated key -> default
  Assert-Eq 'false' (Get-WorktrunkSlugifyNewBranches) 'slugify_new_branches'
  Set-Content -LiteralPath $configFile -Value 'slugify_new_branches = true'
  Assert-Eq 'true' (Get-WorktrunkSlugifyNewBranches) 'slugify_new_branches'
  Set-Content -LiteralPath $configFile -Value 'slugify_new_branches = "false"'
  Assert-Eq 'false' (Get-WorktrunkSlugifyNewBranches) 'slugify_new_branches'
  Set-Content -LiteralPath $configFile -Value 'slugify_new_branches = yes'      # unsupported -> default
  Assert-Eq 'false' (Get-WorktrunkSlugifyNewBranches 2>$null) 'slugify_new_branches'

  function Assert-Hold([string]$Action, [string]$Expected) {
    Assert-Eq $Expected (Get-WorktrunkHoldOn $Action 2>$null) "hold on $Action"
  }

  Set-Content -LiteralPath $configFile -Value 'open_mode = "tab"'   # unrelated key -> default
  Assert-Hold create false
  Assert-Hold merge false
  Assert-Hold remove false

  Set-Content -LiteralPath $configFile -Value 'hold_on_success = true'          # covers every action
  Assert-Hold create true
  Assert-Hold merge true
  Assert-Hold remove true

  Set-Content -LiteralPath $configFile -Value 'hold_on_merge = "true"'          # one action, quoted also ok
  Assert-Hold create false
  Assert-Hold merge true
  Assert-Hold remove false

  # The action's own key wins over hold_on_success, in either direction.
  Set-Content -LiteralPath $configFile -Value @('hold_on_success = true', 'hold_on_remove = false')
  Assert-Hold create true
  Assert-Hold merge true
  Assert-Hold remove false

  Set-Content -LiteralPath $configFile -Value @('hold_on_success = false', 'hold_on_create = true')
  Assert-Hold create true
  Assert-Hold merge false

  # An unsupported value is ignored, so the next key in line still decides.
  Set-Content -LiteralPath $configFile -Value @('hold_on_success = true', 'hold_on_merge = maybe')
  Assert-Hold merge true

  Set-Content -LiteralPath $configFile -Value 'hold_on_success = maybe'
  Assert-Hold merge false

  # herdr may hand the config dir over in extended-length form (\\?\C:\...),
  # like it does the plugin root; values must still be found.
  Set-Content -LiteralPath $configFile -Value 'open_mode = "tab"'
  $env:HERDR_PLUGIN_CONFIG_DIR = '\\?\' + $configDir
  Assert-Eq 'tab' (Get-WorktrunkOpenMode) 'mode'
  $env:HERDR_PLUGIN_CONFIG_DIR = $configDir
} finally {
  Remove-Item -Recurse -Force -LiteralPath $configDir -ErrorAction SilentlyContinue
}

Write-Output 'config tests passed'
exit 0
