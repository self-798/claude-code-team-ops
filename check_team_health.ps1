param([switch]$Json)
$ErrorActionPreference = "SilentlyContinue"

$modulePath = Join-Path $PSScriptRoot "team_utils.psm1"
Remove-Module team_utils -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -ErrorAction Stop

$claudeCount = Get-CountClaudeProcesses
$nodeMcpCount = Get-CountMcpNodes

Write-Host "=== Claude Team Health Check ===" -ForegroundColor Cyan
Write-Host "Processes: claude=$claudeCount  node_mcp=$nodeMcpCount"
if ($claudeCount -gt 1) { Write-Host "  [WARN] Multiple claude processes - possible orphans" -ForegroundColor Yellow }
Write-Host ""

$teamsDir = "$env:USERPROFILE\.claude\teams"
$allResults = @()

Get-ChildItem $teamsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $config = Read-TeamConfig $_.FullName
    if (-not $config) { return }

    Write-Host "--- Team: $($config.name) ---" -ForegroundColor Green
    Write-Host "  Created: $($config.createdAt)  Members: $($config.members.Count)"

    $agents = @(Get-AgentHealth $config)
    $ok = 0; $fail = 0

    foreach ($a in $agents) {
        if ($a.HasOutput) {
            Write-Host "  [OK] $($a.Name) | tasks=$($a.TasksAssigned) output=$($a.OutputCount)" -ForegroundColor Green
            $ok++
        } elseif ($a.TasksAssigned -gt 0) {
            Write-Host "  [FAIL] $($a.Name) | tasks=$($a.TasksAssigned) output=0" -ForegroundColor Red
            $fail++
        } else {
            Write-Host "  [--] $($a.Name) - no tasks assigned" -ForegroundColor DarkGray
        }
    }

    $total = $ok + $fail
    if ($total -gt 0) { Write-Host "  Done: $ok / $total" }
    $allResults += @{ team=$config.name; ok=$ok; fail=$fail }
}

$totalOk = 0; $totalFail = 0
foreach ($r in $allResults) { $totalOk += $r.ok; $totalFail += $r.fail }
$total = $totalOk + $totalFail

if ($total -gt 0) {
    Write-Host "`n=== Summary: $totalOk / $total agents OK ===" -ForegroundColor Cyan
    if ($totalFail -gt 0) {
        $pct = [Math]::Round($totalOk / $total * 100)
        Write-Host "[WARN] Comm success rate: ${pct}% - in-process backend has issues" -ForegroundColor Yellow
    }
}

if ($Json) {
    @{ processes=@{claude=$claudeCount;nodeMcp=$nodeMcpCount}; teams=$allResults; summary=@{total=$total;ok=$totalOk;fail=$totalFail} } | ConvertTo-Json -Depth 4
}
