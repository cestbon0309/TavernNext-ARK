$ErrorActionPreference = 'Stop'

$repoRoot = git rev-parse --show-toplevel
Set-Location $repoRoot

$hookDir = (& git rev-parse --git-path hooks).Trim()
if (-not [IO.Path]::IsPathRooted($hookDir)) {
  $hookDir = Join-Path $repoRoot $hookDir
}
New-Item -ItemType Directory -Force -Path $hookDir | Out-Null

$localBuildSanitizer = Join-Path $hookDir 'sanitize-build-profile.ps1'
$localAppSanitizer = Join-Path $hookDir 'sanitize-app-profile.ps1'
$localBranchState = Join-Path $hookDir 'sync-branch-local-state.ps1'
Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\sanitize-build-profile.ps1') -Destination $localBuildSanitizer -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\sanitize-app-profile.ps1') -Destination $localAppSanitizer -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\sync-branch-local-state.ps1') -Destination $localBranchState -Force

$buildSanitizerCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($localBuildSanitizer.Replace('\', '/'))`""
$appSanitizerCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($localAppSanitizer.Replace('\', '/'))`""
git config filter.ohos-build-profile.clean $buildSanitizerCommand
git config filter.ohos-build-profile.smudge cat
git config filter.ohos-build-profile.required true
git config filter.ohos-app-profile.clean $appSanitizerCommand
git config filter.ohos-app-profile.smudge cat
git config filter.ohos-app-profile.required true

$infoDir = (& git rev-parse --git-path info).Trim()
if (-not [IO.Path]::IsPathRooted($infoDir)) {
  $infoDir = Join-Path $repoRoot $infoDir
}
New-Item -ItemType Directory -Force -Path $infoDir | Out-Null

function Add-LocalGitRule([string]$path, [string]$rule) {
  if (-not (Test-Path -LiteralPath $path)) {
    New-Item -ItemType File -Path $path -Force | Out-Null
  }
  $content = Get-Content -LiteralPath $path -Raw
  if ($content -notmatch "(?m)^$([Regex]::Escape($rule))$") {
    Add-Content -LiteralPath $path -Value $rule -Encoding ascii
  }
}

Add-LocalGitRule (Join-Path $infoDir 'attributes') 'build-profile.json5 filter=ohos-build-profile'
Add-LocalGitRule (Join-Path $infoDir 'attributes') 'AppScope/app.json5 filter=ohos-app-profile'
Add-LocalGitRule (Join-Path $infoDir 'exclude') '/.local/'

$hookPath = Join-Path $hookDir 'pre-commit'

$hook = @'
#!/bin/sh
set -eu

if git show :build-profile.json5 2>/dev/null | grep -E '"(keyPassword|storePassword)"[[:space:]]*:[[:space:]]*"[^<][^"]+"' >/dev/null; then
  echo "Refusing to commit real HarmonyOS signing passwords in build-profile.json5." >&2
  echo "Run: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-git-hooks.ps1" >&2
  echo "Then re-add build-profile.json5 so the clean filter stores the sanitized version." >&2
  exit 1
fi

if git show :build-profile.json5 2>/dev/null | grep -E 'C:\\Users\\|\.p12"|\.p7b"|\.cer"' >/dev/null; then
  echo "Refusing to commit local HarmonyOS signing paths in build-profile.json5." >&2
  echo "Run: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-git-hooks.ps1" >&2
  echo "Then re-add build-profile.json5 so the clean filter stores the sanitized version." >&2
  exit 1
fi

if git show :AppScope/app.json5 2>/dev/null | grep -E '"bundleName"[[:space:]]*:[[:space:]]*"' | grep -v '"com.esoteric.ark.tavernnext"' >/dev/null; then
  echo "Refusing to commit a local HarmonyOS bundle name in AppScope/app.json5." >&2
  echo "Run: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-git-hooks.ps1" >&2
  echo "Then re-add AppScope/app.json5 so the clean filter stores the canonical bundle name." >&2
  exit 1
fi
'@

Set-Content -Path $hookPath -Value $hook -Encoding ascii

$postCheckoutPath = Join-Path $hookDir 'post-checkout'
$localBranchStateForShell = $localBranchState.Replace('\', '/')
$postCheckoutHook = @'
#!/bin/sh
set -eu

if [ "${3:-0}" = "1" ]; then
  powershell -NoProfile -ExecutionPolicy Bypass -File "__BRANCH_STATE_SCRIPT__" -Mode PostCheckout
fi
'@
$postCheckoutHook = $postCheckoutHook.Replace('__BRANCH_STATE_SCRIPT__', $localBranchStateForShell)
Set-Content -Path $postCheckoutPath -Value $postCheckoutHook -Encoding ascii

git update-index --no-assume-unchanged -- build-profile.json5 AppScope/app.json5
git update-index --skip-worktree -- build-profile.json5 AppScope/app.json5
& $localBranchState -Mode Initialize

Write-Host 'Installed signing filters, branch-local state management, and Git hooks.'
