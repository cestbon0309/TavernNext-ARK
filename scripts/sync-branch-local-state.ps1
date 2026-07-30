param(
  [ValidateSet('Initialize', 'PostCheckout')]
  [string]$Mode = 'PostCheckout'
)

$ErrorActionPreference = 'Stop'

$repoRoot = (& git rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {
  throw 'Unable to locate the Git repository root.'
}

$stateRoot = Join-Path $repoRoot '.local\branch-state'
$markerPath = Join-Path $stateRoot 'current-branch.txt'
$managedFiles = @(
  @{ Source = 'build-profile.json5'; State = 'build-profile.json5' },
  @{ Source = 'AppScope\app.json5'; State = 'app.json5' }
)

function Get-BranchIdentifier {
  $branch = (& git branch --show-current).Trim()
  if (-not [string]::IsNullOrWhiteSpace($branch)) {
    return $branch
  }
  $revision = (& git rev-parse --short HEAD).Trim()
  return "detached@$revision"
}

function Get-BranchStateDirectory([string]$branch) {
  $bytes = [Text.Encoding]::UTF8.GetBytes($branch)
  $key = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
  return Join-Path $stateRoot $key
}

function Save-BranchState([string]$branch) {
  $directory = Get-BranchStateDirectory $branch
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $directory 'branch-name.txt') -Value $branch -Encoding utf8
  foreach ($file in $managedFiles) {
    $source = Join-Path $repoRoot $file.Source
    if (Test-Path -LiteralPath $source) {
      Copy-Item -LiteralPath $source -Destination (Join-Path $directory $file.State) -Force
    }
  }
}

function Restore-BranchState([string]$branch) {
  $directory = Get-BranchStateDirectory $branch
  foreach ($file in $managedFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $directory $file.State))) {
      return $false
    }
  }
  foreach ($file in $managedFiles) {
    Copy-Item -LiteralPath (Join-Path $directory $file.State) -Destination (Join-Path $repoRoot $file.Source) -Force
  }
  return $true
}

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$currentBranch = Get-BranchIdentifier

if ($Mode -eq 'Initialize') {
  Save-BranchState $currentBranch
  Set-Content -LiteralPath $markerPath -Value $currentBranch -Encoding utf8
  Write-Host "Initialized local branch state for '$currentBranch'."
  exit 0
}

$previousBranch = ''
if (Test-Path -LiteralPath $markerPath) {
  $previousBranch = (Get-Content -LiteralPath $markerPath -Raw).Trim()
}

if (-not [string]::IsNullOrWhiteSpace($previousBranch) -and $previousBranch -ne $currentBranch) {
  Save-BranchState $previousBranch
}

if ($previousBranch -ne $currentBranch) {
  if (-not (Restore-BranchState $currentBranch)) {
    Save-BranchState $currentBranch
  }
  Set-Content -LiteralPath $markerPath -Value $currentBranch -Encoding utf8
  Write-Host "Applied local branch state for '$currentBranch'."
}

& git update-index --skip-worktree -- build-profile.json5 AppScope/app.json5
