param(
    [string]$Target,
    [switch]$Claude
)

$ErrorActionPreference = 'Stop'

$src = $PSScriptRoot
if (-not $Target) {
    if ($Claude) {
        $Target = Join-Path $HOME '.claude\skills\codex-bridge'
    } else {
        $Target = Join-Path $HOME '.dsh\skills\codex-bridge'
    }
}

New-Item -ItemType Directory -Force -Path $Target | Out-Null
foreach ($item in @('SKILL.md', 'README.md', 'scripts', 'references', 'examples')) {
    $from = Join-Path $src $item
    if (Test-Path -LiteralPath $from) {
        Copy-Item -LiteralPath $from -Destination $Target -Recurse -Force
    }
}
Remove-Item -LiteralPath (Join-Path $Target 'scripts\.run') -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "installed -> $Target"
Write-Host "verify   -> powershell -NoProfile -ExecutionPolicy Bypass -File `"$Target\scripts\codex-run.ps1`" -Doctor"
