# WINDOWS-ONLY (Windows PowerShell 5.1 or PowerShell 7).
# permissions-secrets-sweep.ps1: detect secrets captured into Claude Code permission rules.
# Rationale: when a command containing an inline secret is approved once, the
# harness can store it as a durable allow rule, so the secret then sits in a
# settings file in clear text. This sweep finds secret-shaped strings there.
#
# Parameter: KIT_REPOS_ROOT (env). Folder whose child repos are scanned for
# project-level .claude\settings*.json files. Unset means only the user-level
# files are scanned.
# Exit 0 = clean, 1 = suspect rules found. Writes a report to ~\.claude\logs\.
$ErrorActionPreference = 'Continue'
$logDir = Join-Path $env:USERPROFILE '.claude\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$targets = @(
    (Join-Path $env:USERPROFILE '.claude\settings.json'),
    (Join-Path $env:USERPROFILE '.claude\settings.local.json')
)
if ($env:KIT_REPOS_ROOT -and (Test-Path $env:KIT_REPOS_ROOT)) {
    $targets += Get-ChildItem $env:KIT_REPOS_ROOT -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem (Join-Path $_.FullName '.claude') -Filter 'settings*.json' -ErrorAction SilentlyContinue } |
        ForEach-Object { $_.FullName }
}

# Secret-shaped patterns; placeholders (YOUR_TOKEN, xxx, <...>) are excluded below.
$patterns = @(
    'sk-[A-Za-z0-9_-]{16,}', 'pk_(live|test)_[A-Za-z0-9]{16,}',
    'ghp_[A-Za-z0-9]{30,}', 'github_pat_[A-Za-z0-9_]{30,}',
    'AKIA[0-9A-Z]{16}', 'xox[abps]-[A-Za-z0-9-]{10,}',
    'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}',
    '(?i)(token|secret|password|api_?key)\s*[=:]\s*[A-Za-z0-9+/_-]{12,}',
    '\b[a-f0-9]{40,}\b'
)
$placeholder = '(?i)(YOUR_|<[A-Z_]+>|\bxxx+\b|\$\{|\$env:|placeholder|example)'
$report = @("permissions-secrets-sweep $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
$hits = @()

foreach ($file in ($targets | Where-Object { $_ -and (Test-Path $_) })) {
    try { $json = Get-Content $file -Raw | ConvertFrom-Json } catch { $report += "WARN: unparseable $file"; continue }
    $rules = @()
    foreach ($k in 'allow', 'deny', 'ask') { $rules += @($json.permissions.$k) }
    foreach ($rule in ($rules | Where-Object { $_ })) {
        if ($rule -match $placeholder) { continue }
        foreach ($pat in $patterns) {
            if ($rule -match $pat) {
                $masked = if ($rule.Length -gt 70) { $rule.Substring(0, 40) + '...' + $rule.Substring($rule.Length - 12) } else { $rule }
                $hits += "SUSPECT: $file :: $masked (pattern: $pat)"
                break
            }
        }
    }
    $report += "scanned: $file"
}

$report += $hits
$report += if ($hits.Count) { "RESULT: $($hits.Count) suspect rule(s), review and remove, then rotate the exposed secret" } else { 'RESULT: clean' }
$report | Set-Content (Join-Path $logDir 'permissions-secrets-latest.txt')
$report | ForEach-Object { Write-Output $_ }
if ($hits.Count) { exit 1 } else { exit 0 }
