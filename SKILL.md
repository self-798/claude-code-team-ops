---
name: team-ops
description: Team agent process management — cleanup stale processes, diagnose inbox communication health. CRITICAL: invoke this skill after EVERY TeamDelete or team disband operation. Use when agents linger after disband, teams stop responding, or you need to verify team communication status.
---

# Team Ops — Claude Code Team Operations

Manage and diagnose Claude Code team mode agents. Provides process cleanup for in-process backend orphans and inbox-based communication health checks.

**IMPORTANT**: After any TeamDelete or team disband operation, stale agent processes (claude.exe, node.exe) are NOT automatically cleaned up by Claude Code's in-process backend. Always run cleanup after disbanding a team.

## When to Use

- **After ANY TeamDelete or team disband** — invoke cleanup to kill orphan processes
- Team disbanded but `claude.exe` / `node.exe` processes still running
- Agents not responding to task assignments
- Diagnosing why team members produce no output
- Verifying team communication health before/after sessions

## Quick Start

```powershell
# Check team health (read-only, safe)
powershell -ExecutionPolicy Bypass -File <skill-dir>\check_team_health.ps1

# Preview process cleanup (dry-run, safe)
powershell -ExecutionPolicy Bypass -File <skill-dir>\cleanup_team_processes.ps1 -DryRun

# Execute process cleanup
powershell -ExecutionPolicy Bypass -File <skill-dir>\cleanup_team_processes.ps1
```

## How It Works

```
                   check_team_health.ps1
                          │
         ┌────────────────┼────────────────┐
         ▼                ▼                ▼
   Process count    Team configs     Inbox analysis
   (claude/node)    (JSON parse)    (message classify)
         │                │                │
         └────────────────┼────────────────┘
                          ▼
              Per-agent status report
              [OK] / [FAIL] / [--]


                cleanup_team_processes.ps1
                          │
         ┌────────────────┼────────────────┐
         ▼                ▼                ▼
   Ancestor chain   Stale detection   Orphan MCP find
   (PID tracing)   (exclude current)  (node.exe MCP)
         │                │                │
         └────────────────┼────────────────┘
                          ▼
                   Kill orphan tree
```

## Architecture

```
team-ops/
├── SKILL.md                      # This file
├── team_utils.psm1               # Shared PowerShell module (11 functions)
├── check_team_health.ps1         # Health check entry point
├── cleanup_team_processes.ps1    # Process cleanup entry point
└── team_utils.tests.ps1          # Pester tests (31 test cases)
```

### Core Module Functions

| Function | Description |
|---|---|
| `Convert-TeamTimestamp` | JS epoch ms → DateTime |
| `Get-AncestorChain` | Trace PID parent chain |
| `Get-ProcessAge` | Time since process start |
| `Get-StaleClaudeProcesses` | Find claude.exe not in current session |
| `Get-OrphanMcpNodes` | Find node.exe MCP with dead parent |
| `Get-CountClaudeProcesses` | Count running claude.exe |
| `Get-CountMcpNodes` | Count running MCP node processes |
| `Read-TeamConfig` | Parse team config.json |
| `Read-InboxMessages` | Safe JSON inbox reader |
| `Classify-InboxMessages` | Categorize inbox messages |
| `Get-AgentHealth` | Per-agent task/output assessment |

## Message Classification

The `Classify-InboxMessages` function categorizes each inbox message:

| Category | Detection | Meaning |
|---|---|---|
| `taskAssignments` | `"type":"task_assignment"` | Agent was assigned work |
| `idleNotifications` | `"type":"idle_notification"` | Agent reports idle |
| `shutdownRequests` | `"type":"shutdown_request"` | Team-lead requested shutdown |
| `shutdownResponses` | `"type":"shutdown_response"` | Agent acknowledged shutdown |
| `contentOutputs` | Text > 100 chars, not system | Agent produced real output |

An agent is **OK** if it has `contentOutputs` in the team-lead inbox.
An agent is **FAIL** if it has `taskAssignments` but no `contentOutputs`.

## Health Check Output

```
=== Claude Team Health Check ===
Processes: claude=1  node_mcp=4

--- Team: factor-mining-phase1 ---
  Created: 05/11/2026 10:40:47  Members: 11
  [FAIL] audit-datasource | tasks=1 output=0
  [OK] phase2-minute-search | tasks=1 output=1
  [--] phase5-l1-ch - no tasks assigned
  Done: 1 / 8

=== Summary: 1 / 8 agents OK ===
[WARN] Comm success rate: 12% - in-process backend has issues
```

### Status Legend

| Icon | Meaning |
|---|---|
| `[OK]` | Agent produced output (task complete) |
| `[FAIL]` | Agent received task but no output |
| `[--]` | No task assigned (idle/inactive) |

## Running Tests

```powershell
Invoke-Pester <skill-dir>\team_utils.tests.ps1
```

## Platform

- Windows PowerShell 5.1+ (tested on Win11 Pro)
- Pester 3.4+ for testing
- No external dependencies beyond Windows built-ins

## Known Issues

The in-process team backend in Claude Code has two known bugs (reported as [#62364](https://github.com/anthropics/claude-code/issues/62364)):

1. **Process residue**: TeamDelete does not kill child agent processes
2. **Communication dead-loop**: In-process agents only send idle notifications, never consume task_assignments

**Workaround**: Use `isolation: "worktree"` instead of `backendType: "in-process"` when creating teams.
