# Team Ops — Claude Code Team Operations

Manage and diagnose [Claude Code](https://www.anthropic.com/claude-code) team mode agents. Provides process cleanup for in-process backend orphans and inbox-based communication health checks.

## Problem

Claude Code's in-process team backend has two known bugs ([#62364](https://github.com/anthropics/claude-code/issues/62364)):

1. **Process residue**: `TeamDelete` does not kill child `claude.exe` / `node.exe` processes — they remain as orphans consuming memory indefinitely.
2. **Communication dead-loop**: In-process agents send `idle_notification` but never consume `task_assignment` messages — 78% failure rate observed.

This skill provides workaround tooling until the upstream fixes land.

## Quick Start

```powershell
# 1. Check team health (read-only, safe)
powershell -ExecutionPolicy Bypass -File .\check_team_health.ps1

# 2. Preview process cleanup (dry-run, safe)
powershell -ExecutionPolicy Bypass -File .\cleanup_team_processes.ps1 -DryRun

# 3. Execute process cleanup
powershell -ExecutionPolicy Bypass -File .\cleanup_team_processes.ps1
```

### Using as a Claude Code Skill

Place in `~/.claude/skills/team-ops/` and invoke with `/team-ops`. The skill auto-triggers when Claude Code detects team disband or process residue issues.

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

| Icon | Meaning |
|---|---|
| `[OK]` | Agent produced output |
| `[FAIL]` | Agent received task but produced no output |
| `[--]` | No task assigned (inactive) |

## Architecture

```
team-ops/
├── SKILL.md                   # Skill definition
├── README.md                  # This file
├── team_utils.psm1            # Shared PowerShell module (11 functions)
├── check_team_health.ps1      # Health check entry point
├── cleanup_team_processes.ps1 # Process cleanup entry point
├── team_utils.tests.ps1       # Pester tests (31 test cases)
└── LICENSE                    # MIT
```

### Module Functions

| Function | Description |
|---|---|
| `Convert-TeamTimestamp` | JS epoch ms to DateTime |
| `Get-AncestorChain` | Trace PID parent chain |
| `Get-ProcessAge` | Time since process start |
| `Get-StaleClaudeProcesses` | Find claude.exe not in current session |
| `Get-OrphanMcpNodes` | Find node.exe MCP with dead parent |
| `Get-CountClaudeProcesses` | Count running claude.exe |
| `Get-CountMcpNodes` | Count running MCP node processes |
| `Read-TeamConfig` | Parse team config.json |
| `Read-InboxMessages` | Safe JSON inbox reader |
| `Classify-InboxMessages` | Categorize inbox messages (task/idle/shutdown/content) |
| `Get-AgentHealth` | Per-agent task/output assessment |

## Message Classification

Each inbox message is classified into one of five categories:

| Category | Pattern | Meaning |
|---|---|---|
| Task Assignment | `"type":"task_assignment"` | Agent received work |
| Idle Notification | `"type":"idle_notification"` | Agent reports idle |
| Shutdown Request | `"type":"shutdown_request"` | Team-lead requested shutdown |
| Shutdown Response | `"type":"shutdown_response"` | Agent acknowledged shutdown |
| Content Output | Text > 100 chars, not system | Agent produced real output |

## Running Tests

```powershell
Invoke-Pester .\team_utils.tests.ps1
```

31 test cases covering 8 describe blocks. All tests are **small** (no I/O beyond temp file creation, milliseconds each).

## Platform

- Windows PowerShell 5.1+ (tested on Windows 11 Pro 10.0.26200)
- Pester 3.4+ for testing
- No external dependencies beyond Windows built-ins

## Workaround for Upstream Bugs

Use `isolation: "worktree"` instead of `backendType: "in-process"` when creating teams. Worktree agents have proper lifecycle management and don't suffer from process residue.

## License

MIT — see [LICENSE](LICENSE)
