# Windows PowerShell 5.1 port of helpers_test.sh: helper function checks, plus
# the path helpers only the Windows side has.
$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'config.ps1')
. (Join-Path $repoRoot 'helpers.ps1')

function Fail([string]$Message) {
  [Console]::Error.WriteLine($Message)
  exit 1
}

foreach ($tok in @('^', '-', 'pr:123', 'mr:45', 'https://github.com/o/r/pull/7')) {
  if (-not (Test-WorktrunkShortcut $tok)) { Fail "expected '$tok' to be a worktrunk shortcut" }
}

# @ (current) is intentionally not a shortcut - see helpers.ps1.
foreach ($tok in @('my-feature', 'main', 'feature/foo', '@')) {
  if (Test-WorktrunkShortcut $tok) { Fail "expected '$tok' not to be a worktrunk shortcut" }
}

# Test-WorktrunkRefExists resolves both local heads and remote-tracking branches.
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-helpers-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
try {
  Push-Location $sandbox
  git init -q | Out-Null
  git config user.email test@example.com
  git config user.name test
  git commit -q --allow-empty -m init | Out-Null
  git branch feature
  git update-ref refs/remotes/origin/remote-feat HEAD

  foreach ($ref in @('feature', 'origin/remote-feat')) {
    if (-not (Test-WorktrunkRefExists $ref)) { Fail "expected '$ref' to be an existing ref" }
  }

  foreach ($ref in @('does-not-exist', 'origin/nope')) {
    if (Test-WorktrunkRefExists $ref) { Fail "expected '$ref' not to be an existing ref" }
  }
} finally {
  Pop-Location
  Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

$schemaOne = @'
[
  {"branch":"main","kind":"worktree","path":"/repo","is_main":true},
  {"branch":"feature","kind":"worktree","path":"/repo.feature","is_main":false},
  {"branch":"ready","kind":"branch"}
]
'@
$schemaTwo = @'
{
  "schema":2,
  "items":[
    {"branch":"main","worktree":{"path":"/repo","main":true}},
    {"branch":"feature","worktree":{"path":"/repo.feature","main":false}},
    {"branch":"ready"}
  ]
}
'@
$expectedItems = @(
  'main|worktree|/repo|true',
  'feature|worktree|/repo.feature|false',
  'ready|branch|null|false'
) -join "`n"

foreach ($listJson in @($schemaOne, $schemaTwo)) {
  $actualItems = @(Get-WorktrunkListItems $listJson | ForEach-Object {
    $path = if ($null -eq $_.path) { 'null' } else { [string]$_.path }
    $isMain = ([string]$_.is_main).ToLowerInvariant()
    "$($_.branch)|$($_.kind)|$path|$isMain"
  }) -join "`n"
  if ($actualItems -cne $expectedItems) {
    Fail "unexpected normalized worktrunk list items:`n$actualItems"
  }
}

$schemaFailed = $false
try { Get-WorktrunkListItems '{"schema":3}' | Out-Null } catch { $schemaFailed = $true }
if (-not $schemaFailed) { Fail 'expected unsupported worktrunk list schema to fail' }

# Branch slugs. The right single quote is built from its code point: this file
# stays ASCII so Windows PowerShell can't misread it.
$rsquo = [string][char]0x2019
foreach ($case in @(
    @('optimize Stripe loading waterfall', 'optimize-stripe-loading-waterfall'),
    @("  Fix: user's LOGIN bug!! ", 'fix-user-s-login-bug'),
    @("fix user${rsquo}s login", 'fix-user-s-login'),
    @('Feat / Add API v2', 'feat/add-api-v2'),
    @('//a//b//', 'a/b'),
    @('v1..2_FIX.', 'v1.2_fix'),
    @('a/.b', 'a/b'),
    @('already-a-slug', 'already-a-slug'))) {
  $slug = ConvertTo-WorktrunkBranchSlug $case[0]
  if ($slug -cne $case[1]) { Fail "expected branch slug '$($case[1])' for '$($case[0])', got '$slug'" }
}

# No valid name left: nothing comes back.
foreach ($text in @('', '!!!', ' - / . ', 'foo.lock')) {
  $slug = ConvertTo-WorktrunkBranchSlug $text
  if ($slug -cne '') { Fail "expected no branch slug for '$text', got '$slug'" }
}

# Windows-side path helpers: herdr mixes \ and / in its JSON, worktrunk emits
# native separators, and Windows paths compare case-insensitively.
if ((ConvertTo-WtComparablePath 'C:\Users\x\repo\') -cne 'C:/Users/x/repo') { Fail 'expected backslashes normalized and trailing slash trimmed' }
if ((ConvertTo-WtComparablePath '\\?\C:\Users\x\repo') -cne 'C:/Users/x/repo') { Fail 'expected \\?\ prefix dropped' }
if ((ConvertTo-WtComparablePath 'C:/') -cne 'C:/') { Fail 'expected drive root kept intact' }
if (-not (Test-WtPathPrefix 'C:\Repo.Feature\sub' 'C:/repo.feature')) { Fail 'expected mixed-separator, mixed-case containment to match' }
if (Test-WtPathPrefix 'C:/repo.feature-two' 'C:/repo.feature') { Fail 'expected sibling with a shared prefix not to match' }
if (-not (Test-WtPathPrefix 'C:/repo.feature' 'C:\repo.feature')) { Fail 'expected the path itself to match' }
foreach ($root in @('/', 'C:', 'C:\', 'c:/', '')) {
  if (-not (Test-WtRootPath $root)) { Fail "expected '$root' to be treated as a root path" }
}
if (Test-WtRootPath 'C:\repo') { Fail 'expected a real path not to be treated as a root' }

Write-Output 'helpers tests passed'
exit 0
