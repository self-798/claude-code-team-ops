param([switch]$DryRun, [switch]$KeepCurrentSession)
$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot "team_utils.psm1"
Remove-Module team_utils -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -ErrorAction Stop

# Find current session's claude.exe PIDs
$claudeProcs = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" | Select-Object ProcessId, ParentProcessId)
$currentChain = @{}
foreach ($cp in $claudeProcs) {
    $chain = Get-AncestorChain ([int]$cp.ProcessId)
    foreach ($p in $chain) { $currentChain[$p] = $true }
}
$chainList = @($currentChain.Keys)

Write-Host "=== Current session PIDs: $($chainList -join ', ') ===" -ForegroundColor Cyan

$stale = Get-StaleClaudeProcesses $chainList
Write-Host "`nStale claude.exe processes: $($stale.Count)" -ForegroundColor Yellow

foreach ($s in $stale) {
    $ageStr = "$($s.Age.Days)d $($s.Age.Hours)h $($s.Age.Minutes)m"
    Write-Host "  [KILL] PID $($s.PID) (age=$ageStr)" -ForegroundColor Red
    if ($s.CommandLine) {
        $short = $s.CommandLine
        if ($short.Length -gt 120) { $short = $short.Substring(0, 120) + "..." }
        Write-Host "         $short" -ForegroundColor DarkGray
    }
}

$stalePids = @($stale | ForEach-Object { $_.PID })
$orphans = @(Get-OrphanMcpNodes $stalePids)

if ($orphans.Count -gt 0) {
    Write-Host "`nOrphan MCP node processes: $($orphans.Count)" -ForegroundColor Magenta
    foreach ($o in $orphans) {
        $reason = if ($o.ParentDead) { "parent dead" } else { "parent will be killed" }
        Write-Host "  [MCP] PID $($o.PID) (parent $($o.ParentPID) - $reason)" -ForegroundColor Magenta
    }
}

$total = $stale.Count + $orphans.Count
Write-Host ""

if ($total -eq 0) {
    Write-Host "No orphan processes found." -ForegroundColor Green
    exit 0
}

if ($DryRun) {
    Write-Host "[DRY RUN] Would kill $($stale.Count) claude + $($orphans.Count) MCP processes" -ForegroundColor Yellow
    exit 0
}

Write-Host "=== Killing $total processes ===" -ForegroundColor Yellow

foreach ($s in $stale) {
    try {
        Stop-Process -Id $s.PID -Force -ErrorAction Stop
        Write-Host "  [OK] Killed claude PID $($s.PID)" -ForegroundColor Green
    } catch {
        Write-Host "  [ERR] PID $($s.PID): $_" -ForegroundColor Red
    }
}
foreach ($o in $orphans) {
    try {
        Stop-Process -Id $o.PID -Force -ErrorAction Stop
        Write-Host "  [OK] Killed node MCP PID $($o.PID)" -ForegroundColor Green
    } catch {
        Write-Host "  [ERR] PID $($o.PID): $_" -ForegroundColor Red
    }
}

Write-Host "`n=== Cleanup complete ===" -ForegroundColor Cyan
Write-Host "Remaining claude processes: $(Get-CountClaudeProcesses)"
