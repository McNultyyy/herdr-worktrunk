# Windows PowerShell 5.1 port of helpers.sh, plus the helpers only Windows
# needs: path normalization (herdr and worktrunk mix \ and / in their JSON on
# Windows) and explicit worktrunk resolution (bare `wt` is Windows Terminal's
# launcher on a stock Windows PATH). Dot-source config.ps1 first.

# True when NAME is a token worktrunk resolves itself - a branch shortcut
# (^ default, - previous) or `:` syntax (pr:N, mr:N, or a PR/MR URL). Git branch
# names can't be these bare symbols or contain `:`, so these must be passed to
# `wt switch` as-is, never with --create. `@` (current) is omitted: switching to
# the current worktree is a no-op, and its only real use is as a --base.
function Test-WorktrunkShortcut([string]$Name) {
  return ($Name -ceq '^' -or $Name -ceq '-' -or $Name.Contains(':'))
}

# True when NAME is an existing local branch or remote-tracking branch. Such refs
# are checked out directly by `wt switch NAME` (worktrunk creates the worktree if
# one doesn't exist yet), so they must never be passed with --create.
function Test-WorktrunkRefExists([string]$Name) {
  git show-ref --quiet --verify "refs/heads/$Name" 2>$null
  if ($LASTEXITCODE -eq 0) { return $true }
  git show-ref --quiet --verify "refs/remotes/$Name" 2>$null
  return ($LASTEXITCODE -eq 0)
}

# TEXT as a lowercase, hyphenated branch name, e.g. "Fix Login Bug" ->
# "fix-login-bug". Keeps `/`, `.` and `_`; returns '' when no valid name is
# left. Only A-Z is lowercased, as `LC_ALL=C tr` does in helpers.sh: every other
# character outside [a-z0-9._/] folds into a dash either way, and a culture-aware
# lowercase could turn some of them into ASCII letters instead.
function ConvertTo-WorktrunkBranchSlug([string]$Text) {
  $slug = [regex]::Replace($Text, '[A-Z]', { param($m) $m.Value.ToLowerInvariant() })
  $slug = $slug -creplace '[^a-z0-9._/]+', '-'
  $slug = $slug -creplace '-*/+-*', '/'
  $slug = $slug -creplace '\.{2,}', '.'
  $slug = $slug -creplace '/\.+', '/'
  $slug = $slug -creplace '^[-/.]+', ''
  $slug = $slug -creplace '[-/.]+$', ''

  if (-not $slug) { return '' }
  git check-ref-format "refs/heads/$slug" 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { return '' }
  return $slug
}

# Normalize the worktrunk list JSON into objects with the schema 1 location
# fields (`kind`, `path`, `is_main`) plus `branch` at the top level. Worktrunk's
# JSON schema 2 wraps items in an envelope and nests those fields under
# `worktree`. Throws on any other shape.
function Get-WorktrunkListItems([string]$Json) {
  $data = ConvertFrom-Json -InputObject $Json
  if ($data -is [System.Array]) {
    $items = $data
  } elseif ($data -is [System.Management.Automation.PSCustomObject] -and
            $data.PSObject.Properties['items'] -and $data.items -is [System.Array]) {
    $items = $data.items
  } else {
    throw 'unsupported worktrunk list JSON schema'
  }

  foreach ($item in $items) {
    $worktree = $null
    if ($item.PSObject.Properties['worktree']) { $worktree = $item.worktree }

    $kind = $item.kind
    if ($null -eq $kind) {
      if ($worktree -is [System.Management.Automation.PSCustomObject]) { $kind = 'worktree' }
      else { $kind = 'branch' }
    }

    $path = $item.path
    if ($null -eq $path -and $null -ne $worktree) { $path = $worktree.path }

    $isMain = $item.is_main
    if ($null -eq $isMain -and $null -ne $worktree) { $isMain = $worktree.main }
    if ($null -eq $isMain) { $isMain = $false }

    $branch = $null
    if ($item.PSObject.Properties['branch']) { $branch = $item.branch }

    [pscustomobject]@{ kind = $kind; path = $path; is_main = $isMain; branch = $branch }
  }
}

# Keep the pane up with MESSAGE until a key is pressed, when the configuration
# holds ACTION (see Get-WorktrunkHoldOn in config.ps1). Call it once worktrunk
# has succeeded and before herdr is asked to change anything: the pane can sit
# in a workspace that is about to close or lose focus.
function Wait-WorktrunkHoldPane([string]$Action, [string]$Message) {
  if ((Get-WorktrunkHoldOn $Action) -eq 'true') {
    [Console]::Out.Write("`n$WtEsc[32m$Message$WtEsc[0m press any key to continue")
    Wait-WtAnyKey
  }
}

# A path shaped for comparison: `\\?\` prefix dropped, separators forward, no
# trailing slash (drive roots keep theirs). Needed because herdr's own JSON
# mixes styles on Windows - repo_root comes back as C:\Users\... while
# worktrees[].path is C:/Users/... - and worktrunk emits its own flavor.
# Compare results with -eq (case-insensitive in PowerShell), or via
# Test-WtPathPrefix for containment.
function ConvertTo-WtComparablePath([string]$Path) {
  if (-not $Path) { return '' }
  $p = $Path
  if ($p.StartsWith('\\?\')) { $p = $p.Substring(4) }
  $p = $p -replace '\\', '/'
  while ($p.Length -gt 1 -and $p.EndsWith('/') -and -not ($p -match '^[A-Za-z]:/$')) {
    $p = $p.Substring(0, $p.Length - 1)
  }
  return $p
}

# True when CHILD is PARENT or lives under it. Both are normalized here, so
# callers can pass raw JSON values.
function Test-WtPathPrefix([string]$Child, [string]$Parent) {
  $c = ConvertTo-WtComparablePath $Child
  $p = ConvertTo-WtComparablePath $Parent
  if (-not $c -or -not $p) { return $false }
  if ($c -eq $p) { return $true }
  if (-not $p.EndsWith('/')) { $p = $p + '/' }
  return $c.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)
}

# True when PATH normalizes to a filesystem root ('/', 'C:' or 'C:/') - the
# guard the pane-closing cleanup uses so a degenerate worktree path can never
# match every pane on the drive.
function Test-WtRootPath([string]$Path) {
  $p = ConvertTo-WtComparablePath $Path
  return ($p -eq '' -or $p -match '^([A-Za-z]:)?/?$')
}

# The worktrunk executable to run. On a stock Windows PATH, `wt` is Windows
# Terminal's launcher alias (...\Microsoft\WindowsApps\wt.exe), so bare `wt`
# is never trusted blindly. Resolution order:
#   1. WORKTRUNK_BIN environment variable (also how the tests stub wt)
#   2. worktrunk_bin in the plugin's managed config.toml
#   3. `worktrunk` on PATH
#   4. `wt` on PATH, skipping the WindowsApps alias directory
#   5. ~\.cargo\bin\wt.exe (a cargo install not yet on PATH)
# Returns '' when nothing is found; callers print the actionable error.
function Get-WorktrunkBin {
  if ($env:WORKTRUNK_BIN) { return $env:WORKTRUNK_BIN }

  $configured = Get-WorktrunkConfigValue 'worktrunk_bin'
  if ($configured) { return $configured }

  $cmd = Get-Command 'worktrunk' -CommandType Application -ErrorAction SilentlyContinue
  if ($cmd) { return @($cmd)[0].Source }

  foreach ($candidate in @(Get-Command 'wt' -CommandType Application -All -ErrorAction SilentlyContinue)) {
    if ($candidate.Source -notmatch '\\Microsoft\\WindowsApps\\') { return $candidate.Source }
  }

  $cargoWt = Join-Path $env:USERPROFILE '.cargo\bin\wt.exe'
  if (Test-Path -LiteralPath $cargoWt) { return $cargoWt }

  return ''
}

# Resolve worktrunk or fail the pane with an actionable message. Entry scripts
# call this once and pass the result around.
function Resolve-WorktrunkBinOrExit {
  $bin = Get-WorktrunkBin
  if ($bin) { return $bin }
  Write-WtError 'worktrunk not found. Install it (https://github.com/max-sixty/worktrunk) and either put its binary on PATH as `worktrunk`, or set worktrunk_bin in the plugin config.toml / the WORKTRUNK_BIN environment variable. Note: `wt` under ...\Microsoft\WindowsApps is Windows Terminal, not worktrunk.'
  Start-Sleep -Seconds 2
  exit 1
}

# The GitHub CLI to run for the issue/PR pickers. Resolution mirrors
# Get-WorktrunkBin: GH_BIN environment variable (also how the tests stub it),
# then gh_bin in the plugin config.toml, then `gh` on PATH. Returns '' when
# nothing is found; callers print the actionable error.
function Get-GhBin {
  if ($env:GH_BIN) { return $env:GH_BIN }

  $configured = Get-WorktrunkConfigValue 'gh_bin'
  if ($configured) { return $configured }

  $cmd = Get-Command 'gh' -CommandType Application -ErrorAction SilentlyContinue
  if ($cmd) { return @($cmd)[0].Source }

  return ''
}

# Resolve the GitHub CLI or fail the pane with an actionable message.
function Resolve-GhBinOrExit {
  $bin = Get-GhBin
  if ($bin) { return $bin }
  Write-WtError 'GitHub CLI not found. Install it (https://cli.github.com), run `gh auth login`, and either put it on PATH as `gh` or set gh_bin in the plugin config.toml / the GH_BIN environment variable.'
  Start-Sleep -Seconds 2
  exit 1
}

# A branch-safe slug from an issue title: lowercase, every run of non-alphanumeric
# characters folded to a single dash, trimmed. Truncated to MaxLength on a dash
# boundary so the branch name stays readable and never ends in a separator.
function ConvertTo-WtSlug([string]$Title, [int]$MaxLength = 36) {
  if (-not $Title) { return '' }
  $slug = $Title.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
  $slug = $slug.Trim('-')
  if ($MaxLength -gt 0 -and $slug.Length -gt $MaxLength) {
    $slug = $slug.Substring(0, $MaxLength).Trim('-')
  }
  return $slug
}

# Fill TEMPLATE's {{number}}/{{slug}} placeholders. An issue with a title that
# slugs to nothing (emoji only, say) would otherwise leave a dangling separator,
# so trailing dashes and slashes are trimmed off the result.
function New-WtIssueBranchName([string]$Template, [string]$Number, [string]$Slug) {
  $name = $Template -replace '\{\{\s*number\s*\}\}', $Number
  $name = $name -replace '\{\{\s*slug\s*\}\}', $Slug
  return ($name -replace '[-/]+$', '')
}

# The existing local or remote-tracking branch for issue NUMBER, or '' when there
# is none. This is what makes the issue action "open OR create": a second run for
# the same issue switches to the branch you already have instead of creating a
# near-duplicate under the current template. Matches `issue-N` (also issue_N,
# issueN) as a whole token, so issue-4 never matches issue-42. Local branches
# win over remote-tracking ones; both are checked out directly by `wt switch`.
function Find-WtIssueBranch([string]$Number) {
  if ($Number -notmatch '^[0-9]+$') { return '' }
  $pattern = '(^|[^0-9a-z])issue[-_]?' + $Number + '($|[^0-9])'
  foreach ($refs in @('refs/heads', 'refs/remotes')) {
    foreach ($branch in (git for-each-ref --format='%(refname:short)' $refs 2>$null)) {
      if (-not $branch -or $branch -match '/HEAD$') { continue }
      if ($branch.ToLowerInvariant() -match $pattern) { return $branch }
    }
  }
  return ''
}
