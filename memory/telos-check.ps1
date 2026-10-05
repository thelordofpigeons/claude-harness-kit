# telos-check.ps1: validates the telos/ folder structure and frontmatter.
# Exits 0 on success, non-zero on any failure. Windows PowerShell or PowerShell 7.
#
# Locations (first match wins):
#   $env:TELOS_DIR   the telos folder itself
#   $env:BRAIN_DIR   memory folder; telos is BRAIN_DIR\telos
#   default          $env:USERPROFILE\brain\telos
# The .gitignore check looks for a line covering telos/sensitive/ in BRAIN_DIR\.gitignore.

$ErrorActionPreference = 'Stop'

$BrainDir = if ($env:BRAIN_DIR) { $env:BRAIN_DIR } else { Join-Path $env:USERPROFILE 'brain' }
$TelosDir = if ($env:TELOS_DIR) { $env:TELOS_DIR } else { Join-Path $BrainDir 'telos' }
$Failures = @()

$RequiredFiles = @(
    '00-index.md',
    '10-identity.md',
    '20-context.md',
    '30-projects.md',
    '40-people.md',
    '50-goals.md',
    '60-skills.md',
    '70-preferences.md',
    '80-history.md',
    '90-patterns.md'
)

# Tier C files are optional: validated only when present.
$OptionalSensitive = @()
$SensitiveDir = Join-Path $TelosDir 'sensitive'
if (Test-Path $SensitiveDir) {
    $OptionalSensitive = @(Get-ChildItem -Path $SensitiveDir -Filter '*.md' -File | ForEach-Object { 'sensitive\' + $_.Name })
}

# 1. File existence
foreach ($f in $RequiredFiles) {
    $path = Join-Path $TelosDir $f
    if (-not (Test-Path $path)) {
        $Failures += "MISSING: $f"
    }
}

# 2. Frontmatter validation
$RequiredKeys = @('telos_section', 'sensitivity', 'stability', 'last_reviewed')
$ToCheck = @($RequiredFiles)
foreach ($f in $OptionalSensitive) {
    if (Test-Path (Join-Path $TelosDir $f)) { $ToCheck += $f }
}
foreach ($f in $ToCheck) {
    $path = Join-Path $TelosDir $f
    if (-not (Test-Path $path)) { continue }
    $content = Get-Content $path -Raw
    if ($content -notmatch '(?s)^---\s*\r?\n(.*?)\r?\n---') {
        $Failures += "NO FRONTMATTER: $f"
        continue
    }
    $fm = $Matches[1]
    foreach ($k in $RequiredKeys) {
        if ($fm -notmatch "(?m)^\s*${k}\s*:") {
            $Failures += "MISSING KEY '$k' in $f"
        }
    }
    # last_reviewed must be an ISO date YYYY-MM-DD
    if ($fm -match '(?m)^\s*last_reviewed\s*:\s*([^\r\n]+)') {
        $date = $Matches[1].Trim()
        if ($date -notmatch '^\d{4}-\d{2}-\d{2}$') {
            $Failures += "INVALID last_reviewed '$date' in $f (expected YYYY-MM-DD)"
        }
    }
}

# 3. Sensitive tier is gitignored
$gitignorePath = Join-Path $BrainDir '.gitignore'
if (-not (Test-Path $gitignorePath)) {
    $Failures += "MISSING: .gitignore in the memory folder"
} else {
    $gi = Get-Content $gitignorePath -Raw
    if ($gi -notmatch 'telos/sensitive/?') {
        $Failures += "GITIGNORE does not exclude telos/sensitive/"
    } else {
        Write-Output "OK: telos/sensitive/ is gitignored"
    }
}

# 4. Staleness: warn (not fail) for files past their cadence
$Today = Get-Date
$CadenceDays = @{
    'stable'   = 90
    'changing' = 30
    'volatile' = 7
}
foreach ($f in $RequiredFiles) {
    $path = Join-Path $TelosDir $f
    if (-not (Test-Path $path)) { continue }
    $content = Get-Content $path -Raw
    if ($content -match '(?m)^\s*stability\s*:\s*(\w+)') {
        $stab = $Matches[1]
        if ($content -match '(?m)^\s*last_reviewed\s*:\s*(\d{4}-\d{2}-\d{2})') {
            $reviewed = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null)
            $days = ($Today - $reviewed).Days
            $limit = $CadenceDays[$stab]
            if ($limit -and $days -gt $limit) {
                Write-Output "STALE: $f ($days days since review, limit $limit for $stab)"
            }
        }
    }
}

# Report
if ($Failures.Count -gt 0) {
    Write-Output ""
    Write-Output "FAILURES ($($Failures.Count)):"
    foreach ($x in $Failures) { Write-Output "  - $x" }
    exit 1
}

Write-Output "telos-check: OK"
exit 0
