$ErrorActionPreference = 'Stop'

$repoRoot = git rev-parse --show-toplevel
Set-Location $repoRoot

git config filter.ohos-build-profile.clean "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sanitize-build-profile.ps1"
git config filter.ohos-build-profile.smudge cat
git config filter.ohos-build-profile.required true

$hookDir = Join-Path $repoRoot '.git/hooks'
New-Item -ItemType Directory -Force -Path $hookDir | Out-Null
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
'@

Set-Content -Path $hookPath -Value $hook -Encoding ascii
Write-Host "Installed Git clean filter and pre-commit hook for build-profile.json5."
