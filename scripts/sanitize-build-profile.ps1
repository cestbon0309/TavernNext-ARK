$ErrorActionPreference = 'Stop'

$content = [Console]::In.ReadToEnd()

$replacements = @{
  'certpath' = '<local-ohos-cert.cer>'
  'keyPassword' = '<local-key-password>'
  'profile' = '<local-ohos-profile.p7b>'
  'storeFile' = '<local-ohos-keystore.p12>'
  'storePassword' = '<local-store-password>'
}

foreach ($key in $replacements.Keys) {
  $pattern = '("' + [Regex]::Escape($key) + '"\s*:\s*")[^"]*(")'
  $content = [Regex]::Replace($content, $pattern, '${1}' + $replacements[$key] + '${2}')
}

[Console]::Out.Write($content)
