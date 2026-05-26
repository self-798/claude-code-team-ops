# Team Utils Tests - Pester 3.4
# Run: Invoke-Pester (Join-Path $PSScriptRoot "team_utils.tests.ps1")

$modulePath = Join-Path $PSScriptRoot "team_utils.psm1"
Remove-Module team_utils -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -ErrorAction Stop

Describe "Convert-TeamTimestamp" {
    It "converts JS epoch milliseconds to LocalDateTime" {
        $result = Convert-TeamTimestamp 1778467247446
        $result.Year | Should Be 2026
        $result.Month | Should Be 5
        $result.Day | Should Be 11
    }

    It "converts JS epoch seconds (small timestamps) correctly" {
        $result = Convert-TeamTimestamp 1715472000
        $result.Year | Should Be 2024
        $result.Month | Should Be 5
    }

    It "returns DateTime type" {
        $result = Convert-TeamTimestamp 1778467247446
        $result | Should BeOfType DateTime
    }
}

Describe "Get-AncestorChain" {
    It "includes the start PID as first element" {
        $chain = Get-AncestorChain $pid
        $chain[0] | Should Be $pid
    }

    It "returns at least one element" {
        $chain = Get-AncestorChain $pid
        $chain.Count | Should BeGreaterThan 0
    }

    It "returns array of integers" {
        $chain = Get-AncestorChain $pid
        $chain -is [Array] | Should Be $true
        $chain[0] -is [int] | Should Be $true
    }
}

Describe "Get-ProcessAge" {
    It "returns TimeSpan for current process" {
        $age = Get-ProcessAge $pid
        $age | Should BeOfType TimeSpan
        $age.TotalSeconds | Should BeGreaterThan 0
        $age.TotalMinutes | Should BeLessThan 10
    }

    It "returns null for non-existent PID" {
        $age = Get-ProcessAge 99999999
        $age | Should Be $null
    }
}

Describe "Get-StaleClaudeProcesses" {
    It "handles UInt32 PID type mismatch from CimInstance" {
        # CimInstance ProcessId is UInt32, chain may use int - must match correctly
        $u32pid = [UInt32]99999999
        $chain = @([int]$u32pid, $pid)
        $stale = Get-StaleClaudeProcesses $chain
        foreach ($s in $stale) {
            $chain -contains $s.PID | Should Be $false
        }
    }

    It "does not flag current claude process as stale" {
        # Find the actual claude.exe PID(s) for current session
        $claudeProcs = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" |
            Select-Object ProcessId, ParentProcessId
        $claudePids = @($claudeProcs | ForEach-Object { $_.ProcessId })
        # Build chain from each claude process to find the session root
        $allChainPids = @{}
        foreach ($cp in $claudePids) {
            $chain = Get-AncestorChain $cp
            foreach ($p in $chain) { $allChainPids[$p] = $true }
        }
        $chainList = @($allChainPids.Keys)

        $stale = Get-StaleClaudeProcesses $chainList
        foreach ($s in $stale) {
            $allChainPids.ContainsKey($s.PID) | Should Be $false
        }
    }

    It "returns PSCustomObject array with correct fields" {
        $stale = Get-StaleClaudeProcesses @()
        $stale -is [Array] | Should Be $true
        if ($stale.Count -gt 0) {
            $stale[0].PID | Should BeGreaterThan 0
            $stale[0].Age -is [TimeSpan] | Should Be $true
        }
    }
}

Describe "Classify-InboxMessages" {
    It "classifies task_assignment messages" {
        $msgs = @(
            [PSCustomObject]@{text='{"type":"task_assignment","taskId":"1","description":"test"}'; from="lead"}
        )
        $result = Classify-InboxMessages $msgs
        $result.taskAssignments | Should Be 1
        $result.idleNotifications | Should Be 0
        $result.contentOutputs | Should Be 0
    }

    It "classifies idle_notification messages" {
        $msgs = @(
            [PSCustomObject]@{text='{"type":"idle_notification","from":"agent1","idleReason":"available"}'; from="agent1"}
        )
        $result = Classify-InboxMessages $msgs
        $result.idleNotifications | Should Be 1
        $result.taskAssignments | Should Be 0
        $result.contentOutputs | Should Be 0
    }

    It "classifies shutdown messages" {
        $msgs = @(
            [PSCustomObject]@{text='{"type":"shutdown_request","reason":"test"}'; from="lead"},
            [PSCustomObject]@{text='{"type":"shutdown_response","approve":true}'; from="agent1"}
        )
        $result = Classify-InboxMessages $msgs
        $result.shutdownRequests | Should Be 1
        $result.shutdownResponses | Should Be 1
        $result.contentOutputs | Should Be 0
    }

    It "detects content output (long text without system type)" {
        $longContent = "A" * 200
        $msgs = @(
            [PSCustomObject]@{text=$longContent; from="agent1"}
        )
        $result = Classify-InboxMessages $msgs
        $result.contentOutputs | Should Be 1
        $result.contentAuthors["agent1"] | Should Be 1
    }

    It "tracks multiple authors in content output" {
        $content1 = "B" * 200
        $content2 = "C" * 200
        $msgs = @(
            [PSCustomObject]@{text=$content1; from="agent1"},
            [PSCustomObject]@{text=$content2; from="agent2"},
            [PSCustomObject]@{text=$content2; from="agent2"}
        )
        $result = Classify-InboxMessages $msgs
        $result.contentOutputs | Should Be 3
        $result.contentAuthors["agent1"] | Should Be 1
        $result.contentAuthors["agent2"] | Should Be 2
    }

    It "ignores short non-system messages" {
        $msgs = @(
            [PSCustomObject]@{text="short msg"; from="agent1"}
        )
        $result = Classify-InboxMessages $msgs
        $result.contentOutputs | Should Be 0
        $result.taskAssignments | Should Be 0
        $result.idleNotifications | Should Be 0
    }

    It "handles empty message array" {
        $result = Classify-InboxMessages @()
        $result.taskAssignments | Should Be 0
        $result.idleNotifications | Should Be 0
        $result.contentOutputs | Should Be 0
    }

    It "handles null text field" {
        $msgs = @(
            [PSCustomObject]@{text=$null; from="agent1"}
        )
        $result = Classify-InboxMessages $msgs
        $result.taskAssignments | Should Be 0
        $result.contentOutputs | Should Be 0
    }

    It "classifies mixed inbox correctly" {
        $realContent = "Real audit report: " + ("D" * 150)
        $msgs = @(
            [PSCustomObject]@{text='{"type":"task_assignment","taskId":"1"}'; from="lead"},
            [PSCustomObject]@{text='{"type":"idle_notification","from":"agent1","idleReason":"available"}'; from="agent1"},
            [PSCustomObject]@{text=$realContent; from="agent1"},
            [PSCustomObject]@{text='{"type":"shutdown_request"}'; from="lead"},
            [PSCustomObject]@{text='{"type":"idle_notification","from":"agent1","idleReason":"available"}'; from="agent1"}
        )
        $result = Classify-InboxMessages $msgs
        $result.taskAssignments | Should Be 1
        $result.idleNotifications | Should Be 2
        $result.shutdownRequests | Should Be 1
        $result.contentOutputs | Should Be 1
        $result.contentAuthors["agent1"] | Should Be 1
    }

    It "correctly identifies agent with output vs agents without" {
        $report = "Report: " + ("E" * 150)
        $msgs = @(
            [PSCustomObject]@{text='{"type":"idle_notification","idleReason":"available"}'; from="agent1"},
            [PSCustomObject]@{text='{"type":"idle_notification","idleReason":"available"}'; from="agent2"},
            [PSCustomObject]@{text=$report; from="agent2"},
            [PSCustomObject]@{text='{"type":"idle_notification","idleReason":"available"}'; from="agent3"}
        )
        $result = Classify-InboxMessages $msgs
        $result.contentAuthors.ContainsKey("agent1") | Should Be $false
        $result.contentAuthors.ContainsKey("agent2") | Should Be $true
        $result.contentAuthors.ContainsKey("agent3") | Should Be $false
    }
}

Describe "Read-InboxMessages" {
    It "returns empty array for non-existent path" {
        $msgs = Read-InboxMessages "C:\nonexistent\path.json"
        $msgs.Count | Should Be 0
    }

    It "returns correct count for valid inbox" {
        $testPath = "$env:TEMP\test_inbox_$(Get-Random).json"
        $testData = @(
            @{text="msg1"; from="a"; read=$true},
            @{text="msg2"; from="b"; read=$false}
        )
        $testData | ConvertTo-Json | Set-Content $testPath -Encoding UTF8

        $msgs = Read-InboxMessages $testPath
        $msgs.Count | Should Be 2
        $msgs[0].text | Should Be "msg1"

        Remove-Item $testPath -Force -ErrorAction SilentlyContinue
    }

    It "returns empty array for malformed JSON" {
        $testPath = "$env:TEMP\test_bad_$(Get-Random).json"
        "not valid json {{{" | Set-Content $testPath -Encoding UTF8
        $msgs = Read-InboxMessages $testPath
        $msgs.Count | Should Be 0
        Remove-Item $testPath -Force -ErrorAction SilentlyContinue
    }
}

Describe "Get-OrphanMcpNodes" {
    It "returns array" {
        $orphans = @(Get-OrphanMcpNodes @())
        $orphans -is [Array] | Should Be $true
    }

    It "each orphan has required properties" {
        $orphans = @(Get-OrphanMcpNodes @(99999999))
        foreach ($o in $orphans) {
            $o.PID | Should BeGreaterThan 0
            $o.ParentPID | Should BeGreaterThan 0
            $o.ParentDead -is [bool] | Should Be $true
        }
    }
}

Describe "Read-TeamConfig" {
    It "returns null for non-existent directory" {
        $config = Read-TeamConfig "C:\nonexistent\team"
        $config | Should Be $null
    }

    It "returns converted createdAt as DateTime for valid team" {
        $testDir = "$env:TEMP\test_team_$(Get-Random)"
        New-Item -ItemType Directory $testDir -Force | Out-Null
        New-Item -ItemType Directory "$testDir\inboxes" -Force | Out-Null

        $config = @{
            name = "test-team"
            createdAt = 1778467247446
            leadAgentId = "team-lead@test-team"
            members = @(
                @{name="team-lead"; agentType="team-lead"}
            )
        }
        $config | ConvertTo-Json -Depth 4 | Set-Content "$testDir\config.json" -Encoding UTF8

        $result = Read-TeamConfig $testDir
        $result.name | Should Be "test-team"
        $result.createdAt.Year | Should Be 2026
        $result.createdAt -is [DateTime] | Should Be $true

        Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Get-AgentHealth" {
    It "returns empty array when team has only team-lead" {
        $testDir = "$env:TEMP\test_team2_$(Get-Random)"
        New-Item -ItemType Directory $testDir -Force | Out-Null
        New-Item -ItemType Directory "$testDir\inboxes" -Force | Out-Null

        $config = [PSCustomObject]@{
            name = "test-team2"
            createdAt = (Get-Date)
            members = @(
                [PSCustomObject]@{name="team-lead"; agentType="team-lead"}
            )
        }

        "[]" | Set-Content "$testDir\inboxes\team-lead.json" -Encoding UTF8

        $envTeamDir = "$env:USERPROFILE\.claude\teams"
        $realTeamDir = Join-Path $envTeamDir "test-team2"
        Copy-Item $testDir $realTeamDir -Recurse -Force -ErrorAction SilentlyContinue

        try {
            $agents = @(Get-AgentHealth $config)
            $agents.Count | Should Be 0
        } finally {
            Remove-Item $realTeamDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "detects agent with task assignment but no output" {
        $testDir = "$env:TEMP\test_team3_$(Get-Random)"
        New-Item -ItemType Directory $testDir -Force | Out-Null
        New-Item -ItemType Directory "$testDir\inboxes" -Force | Out-Null

        $config = [PSCustomObject]@{
            name = "test-team3"
            createdAt = (Get-Date)
            members = @(
                [PSCustomObject]@{name="team-lead"; agentType="team-lead"},
                [PSCustomObject]@{name="worker1"; agentType="general-purpose"; backendType="in-process"}
            )
        }

        $workerInbox = @(
            @{text='{"type":"task_assignment","taskId":"1"}'; from="team-lead"; read=$true}
        )
        $tlInbox = @(
            @{text='{"type":"idle_notification","idleReason":"available"}'; from="worker1"; read=$true}
        )

        $workerInbox | ConvertTo-Json | Set-Content "$testDir\inboxes\worker1.json" -Encoding UTF8
        $tlInbox | ConvertTo-Json | Set-Content "$testDir\inboxes\team-lead.json" -Encoding UTF8

        $envTeamDir = "$env:USERPROFILE\.claude\teams"
        $realTeamDir = Join-Path $envTeamDir "test-team3"
        Copy-Item $testDir $realTeamDir -Recurse -Force -ErrorAction SilentlyContinue

        try {
            $agents = @(Get-AgentHealth $config)
            $agents.Count | Should Be 1
            $agents[0].Name | Should Be "worker1"
            $agents[0].TasksAssigned | Should Be 1
            $agents[0].HasOutput | Should Be $false
        } finally {
            Remove-Item $realTeamDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "detects agent with successful output" {
        $testDir = "$env:TEMP\test_team4_$(Get-Random)"
        New-Item -ItemType Directory $testDir -Force | Out-Null
        New-Item -ItemType Directory "$testDir\inboxes" -Force | Out-Null

        $config = [PSCustomObject]@{
            name = "test-team4"
            createdAt = (Get-Date)
            members = @(
                [PSCustomObject]@{name="team-lead"; agentType="team-lead"},
                [PSCustomObject]@{name="worker1"; agentType="general-purpose"; backendType="in-process"}
            )
        }

        $report = "Task completed: " + ("F" * 150)
        $workerInbox = @(
            @{text='{"type":"task_assignment","taskId":"1"}'; from="team-lead"; read=$true}
        )
        $tlInbox = @(
            @{text=$report; from="worker1"; read=$true}
        )

        $workerInbox | ConvertTo-Json | Set-Content "$testDir\inboxes\worker1.json" -Encoding UTF8
        $tlInbox | ConvertTo-Json | Set-Content "$testDir\inboxes\team-lead.json" -Encoding UTF8

        $envTeamDir = "$env:USERPROFILE\.claude\teams"
        $realTeamDir = Join-Path $envTeamDir "test-team4"
        Copy-Item $testDir $realTeamDir -Recurse -Force -ErrorAction SilentlyContinue

        try {
            $agents = @(Get-AgentHealth $config)
            $agents.Count | Should Be 1
            $agents[0].HasOutput | Should Be $true
            $agents[0].OutputCount | Should Be 1
        } finally {
            Remove-Item $realTeamDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
