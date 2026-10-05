# WINDOWS-ONLY (Windows PowerShell 5.1 or PowerShell 7).
# harness-audit.ps1: monthly wrapper around two audits: branch-divergence-audit.ps1
# and permissions-secrets-sweep.ps1. It only works if both of those scripts are
# installed next to it (both ship in this kit).
#
# Register it as a user-level scheduled task, for example "HarnessMonthlyAudit"
# (1st of the month, 08:30). It pops a dismissable alert only when something is
# found; reports always land in ~\.claude\logs\ (hooks\audit-report.mjs announces
# them once at the next session start). Set KIT_REPOS_ROOT for the repo scan.
$scripts = Join-Path $env:USERPROFILE '.claude\scripts'
$alerts = @()

& (Join-Path $scripts 'branch-divergence-audit.ps1') | Out-Null
if ($LASTEXITCODE -ne 0) { $alerts += 'Branch divergence found in repos (see ~\.claude\logs\branch-divergence-latest.txt)' }

& (Join-Path $scripts 'permissions-secrets-sweep.ps1') | Out-Null
if ($LASTEXITCODE -ne 0) { $alerts += 'Secret-shaped strings in Claude permission rules (see ~\.claude\logs\permissions-secrets-latest.txt)' }

if ($alerts.Count) {
    $msg = "Kit audit:`n`n" + ($alerts -join "`n")
    # WScript popup: dependency-free, auto-dismisses after 60s, works user-level
    (New-Object -ComObject WScript.Shell).Popup($msg, 60, 'Kit audit', 48) | Out-Null
    exit 1
}
exit 0
