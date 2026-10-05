# WINDOWS-ONLY (Windows PowerShell 5.1 or PowerShell 7).
# branch-divergence-audit.ps1: periodic check that no repo has a diverged main/master.
# Having both branches with different commits sends deploys and debugging down the
# wrong branch, so this audit lists repos where origin/main and origin/master differ.
#
# Parameter: KIT_REPOS_ROOT (env). Folder that contains your repos (scanned two
# levels deep, so container folders holding several repos work too). Required;
# when unset the script reports SKIP and exits 0.
# Exit 0 = clean, 1 = divergence found. Writes a report to ~\.claude\logs\.
$ErrorActionPreference = 'Continue'
$logDir = Join-Path $env:USERPROFILE '.claude\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$report = @("branch-divergence-audit $(Get-Date -Format 'yyyy-MM-dd HH:mm')")

$root = $env:KIT_REPOS_ROOT
if (-not $root -or -not (Test-Path $root)) {
    $report += 'SKIP: KIT_REPOS_ROOT is not set or does not exist'
    $report += 'RESULT: clean'
    $report | Set-Content (Join-Path $logDir 'branch-divergence-latest.txt')
    $report | ForEach-Object { Write-Output $_ }
    exit 0
}

$divergent = @()
# Known limitations are logged but never alerted. Add a repo folder name here to
# defer it, and remove the entry once the branches are reconciled.
$knownIssues = @()
$env:GIT_TERMINAL_PROMPT = '0'   # never hang on a credential prompt

# Depth-2 scan: container dirs hold several repos one level down
$candidates = @(Get-ChildItem $root -Directory)
$candidates += Get-ChildItem $root -Directory | ForEach-Object {
    if (-not (Test-Path (Join-Path $_.FullName '.git'))) { Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue }
}
foreach ($repo in $candidates) {
    if (-not (Test-Path (Join-Path $repo.FullName '.git'))) { continue }
    $p = $repo.FullName
    git -C $p fetch --quiet --prune origin 2>$null
    $hasMain   = (git -C $p rev-parse --verify --quiet refs/remotes/origin/main 2>$null)
    $hasMaster = (git -C $p rev-parse --verify --quiet refs/remotes/origin/master 2>$null)
    if ($hasMain -and $hasMaster) {
        $onlyMaster = [int](git -C $p rev-list --count origin/main..origin/master 2>$null)
        $onlyMain   = [int](git -C $p rev-list --count origin/master..origin/main 2>$null)
        if ($onlyMaster -gt 0 -or $onlyMain -gt 0) {
            if ($knownIssues -contains $repo.Name) {
                $report += "KNOWN (deferred, no alert): $($repo.Name): $onlyMaster commit(s) only on master, $onlyMain only on main"
            } else {
                $divergent += $repo.Name
                $report += "DIVERGED: $($repo.Name): $onlyMaster commit(s) only on master, $onlyMain only on main"
            }
        } else {
            $report += "ok (main==master): $($repo.Name)"
        }
    } else {
        $branch = if ($hasMain) { 'main' } elseif ($hasMaster) { 'master' } else { 'no origin main/master' }
        $report += "ok ($branch): $($repo.Name)"
    }
}

$report += if ($divergent.Count) { "RESULT: $($divergent.Count) divergent repo(s): $($divergent -join ', ')" } else { 'RESULT: clean' }
$report | Set-Content (Join-Path $logDir 'branch-divergence-latest.txt')
$report | ForEach-Object { Write-Output $_ }
if ($divergent.Count) { exit 1 } else { exit 0 }
