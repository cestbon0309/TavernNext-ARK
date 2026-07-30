$ErrorActionPreference = 'Stop'

$content = [Console]::In.ReadToEnd()
$pattern = '("bundleName"\s*:\s*")[^"]*(")'
$content = [Regex]::Replace($content, $pattern, '${1}com.esoteric.ark.tavernnext${2}')

[Console]::Out.Write($content)
