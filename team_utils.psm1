# Team Utils Module - shared functions for team process management
# Dot-source: . "C:\实盘\team_utils.psm1"

function Convert-TeamTimestamp {
    param([Int64]$JsEpochMs)
    if ($JsEpochMs -gt 1000000000000) {
        return [DateTimeOffset]::FromUnixTimeMilliseconds($JsEpochMs).LocalDateTime
    }
    return [DateTimeOffset]::FromUnixTimeSeconds($JsEpochMs).LocalDateTime
}

function Get-ProcessAge {
    param([int]$ProcessId)
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if (-not $proc) { return $null }
    $creation = Get-Date $proc.CreationDate
    return (Get-Date) - $creation
}

function Get-AncestorChain {
    param([int]$StartPid)
    $chain = @($StartPid)
    $current = Get-CimInstance Win32_Process -Filter "ProcessId=$StartPid" -ErrorAction SilentlyContinue
    if (-not $current) { return $chain }
    $parentPid = $current.ParentProcessId
    while ($parentPid -and $parentPid -ne 0) {
        $chain += $parentPid
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$parentPid" -ErrorAction SilentlyContinue
        if (-not $parent) { break }
        $parentPid = $parent.ParentProcessId
    }
    return $chain
}

function Get-StaleClaudeProcesses {
    param([int[]]$CurrentChain)
    $currentSet = @{}
    foreach ($p in $CurrentChain) { $currentSet[$p] = $true }

    $stale = @()
    Get-CimInstance Win32_Process -Filter "Name='claude.exe'" | ForEach-Object {
        $proc = $_
        if (-not $currentSet.ContainsKey([int]$proc.ProcessId)) {
            $creation = Get-Date $proc.CreationDate
            $stale += [PSCustomObject]@{
                PID = $proc.ProcessId
                Age = (Get-Date) - $creation
                CommandLine = $proc.CommandLine
            }
        }
    }
    return $stale
}

function Get-OrphanMcpNodes {
    param([int[]]$ClaudePidsToKill)
    $killSet = @{}
    foreach ($p in $ClaudePidsToKill) { $killSet[$p] = $true }

    $orphans = @()
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" | ForEach-Object {
        $node = $_
        if ($node.CommandLine -match 'mcp-mysql') {
            $parentAlive = $null -ne (Get-Process -Id $node.ParentProcessId -ErrorAction SilentlyContinue)
            $parentWillDie = $killSet.ContainsKey($node.ParentProcessId)
            if (-not $parentAlive -or $parentWillDie) {
                $orphans += [PSCustomObject]@{
                    PID = $node.ProcessId
                    ParentPID = $node.ParentProcessId
                    ParentDead = -not $parentAlive
                }
            }
        }
    }
    return $orphans
}

function Get-CountClaudeProcesses {
    return @(Get-Process claude -ErrorAction SilentlyContinue).Count
}

function Get-CountMcpNodes {
    $count = 0
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" | ForEach-Object {
        if ($_.CommandLine -match 'mcp-mysql') { $script:count++ }
    }
    return $count
}

function Read-TeamConfig {
    param([string]$TeamDir)
    $configPath = Join-Path $TeamDir "config.json"
    if (-not (Test-Path $configPath)) { return $null }
    $config = Get-Content $configPath -Encoding UTF8 | ConvertFrom-Json
    $config.createdAt = Convert-TeamTimestamp ([Int64]$config.createdAt)
    return $config
}

function Read-InboxMessages {
    param([string]$InboxPath)
    if (-not (Test-Path $InboxPath)) { return @() }
    try {
        $raw = Get-Content $InboxPath -Raw -Encoding UTF8
        $parsed = ConvertFrom-Json $raw
        return @($parsed)
    } catch {
        return @()
    }
}

function Classify-InboxMessages {
    param([object[]]$Messages)
    $result = @{
        taskAssignments = 0
        idleNotifications = 0
        shutdownRequests = 0
        shutdownResponses = 0
        contentOutputs = 0
        contentAuthors = @{}
    }

    foreach ($msg in $Messages) {
        $t = $msg.text
        if (-not $t) { continue }

        if ($t -match '"type":"task_assignment"') {
            $result.taskAssignments++
        }
        elseif ($t -match '"type":"idle_notification"') {
            $result.idleNotifications++
        }
        elseif ($t -match '"type":"shutdown_request"') {
            $result.shutdownRequests++
        }
        elseif ($t -match '"type":"shutdown_response"') {
            $result.shutdownResponses++
        }
        elseif ($t.Length -gt 100) {
            $result.contentOutputs++
            $from = $msg.from
            if ($from) {
                if (-not $result.contentAuthors.ContainsKey($from)) {
                    $result.contentAuthors[$from] = 0
                }
                $result.contentAuthors[$from]++
            }
        }
    }
    return $result
}

function Get-AgentHealth {
    param([object]$TeamConfig)
    $teamsDir = "$env:USERPROFILE\.claude\teams"
    $teamPath = Join-Path $teamsDir $TeamConfig.name

    # Read team-lead inbox for agent outputs
    $tlInbox = Join-Path $teamPath "inboxes\team-lead.json"
    $tlMsgs = Read-InboxMessages $tlInbox
    $tlClass = Classify-InboxMessages $tlMsgs

    $agents = @()
    foreach ($member in $TeamConfig.members) {
        if ($member.name -eq 'team-lead') { continue }

        $inbox = Join-Path $teamPath "inboxes\$($member.name).json"
        $msgs = Read-InboxMessages $inbox
        $class = Classify-InboxMessages $msgs

        $outputCount = 0
        if ($tlClass.contentAuthors.ContainsKey($member.name)) {
            $outputCount = $tlClass.contentAuthors[$member.name]
        }

        $agents += [PSCustomObject]@{
            Name = $member.name
            TasksAssigned = $class.taskAssignments
            OutputCount = $outputCount
            HasOutput = ($outputCount -gt 0)
            TotalInboxMsgs = $msgs.Count
            Backend = $member.backendType
        }
    }
    return $agents
}
