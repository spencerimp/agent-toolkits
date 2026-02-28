# agent-toolkits

A single source of truth for AI coding agent configuration — skills and MCP servers — shared across **Claude Code**, **GitHub Copilot in VS Code**, and **GitHub Copilot CLI**.

**Claude Code format is the source of truth.** Sync scripts convert and distribute configuration to the equivalent locations for other tools.


---

## Structure

```
agent-toolkits/
│
├── .mcp.json                    # MCP server definitions — Claude Code format (source of truth)
│
├── .claude/
│   └── skills/                  # Skill definitions (source of truth)
│
├── AGENTS.md                    # Shared instructions (all tools)
├── CLAUDE.md                    # Claude Code specific instructions
│
├── sync_mcp.sh                  # Sync .mcp.json → Claude, VSCode Copilot, Copilot CLI
└── sync_skills.sh               # Sync .claude/skills/ → user-level and project-level
```

**Requirements for the sync scripts:** `jq` (`brew install jq`), `bash` 3.2+

---

## MCP Servers

Source of truth: **`.mcp.json`** (Claude Code format). Run `sync_mcp.sh` to propagate to other tools.

### Config paths

#### User-level

| Tool | Path | Schema key |
|------|------|-----------|
| Claude Code | `~/.claude.json` | `mcpServers` |
| VSCode Copilot | `~/Library/Application Support/Code/User/settings.json` (macOS), `~/.config/Code/User/settings.json` (Linux) | `mcp.servers` |
| Copilot CLI | `~/.copilot/mcp-config.json` | `mcpServers` |

#### Project-level

| Tool | Path | Schema key |
|------|------|-----------|
| Claude Code | `.mcp.json` ← **source of truth** | `mcpServers` |
| VSCode Copilot | `.vscode/mcp.json` | `servers` |
| Copilot CLI | `.vscode/mcp.json` (read natively) | `servers` |

### Sync

```bash
./sync_mcp.sh --claude                                       # Claude Code user-level
./sync_mcp.sh --copilot-cli-user                             # Copilot CLI user-level
./sync_mcp.sh --vscode-user                                  # VSCode autostart setting
./sync_mcp.sh --vscode-project --project-dir ~/proj/myapp    # VSCode + Copilot CLI project-level
./sync_mcp.sh --all --project-dir ~/proj/myapp               # All of the above
./sync_mcp.sh --all --project-dir ~/proj/myapp --dry-run     # Preview
```

> Existing server entries are never overwritten — only new servers are appended.

### Adaptors

Some servers require different config per tool (e.g. OAuth not universally supported):

| Server | Claude Code | VSCode Copilot / Copilot CLI |
|--------|------------|------------------------------|
| `atlassian` | OAuth via remote MCP | `mcp-remote` proxy |

---

## Skills

Source of truth: **`.claude/skills/`** (same format for all tools — no conversion needed).

Each skill is a subdirectory with a `SKILL.md` file:

```
.claude/skills/<skill-name>/SKILL.md
```

### Config paths

#### User-level

| Tool | Path |
|------|------|
| Claude Code | `~/.claude/skills/` |
| VSCode Copilot | `~/.claude/skills/` or `~/.copilot/skills/` |
| Copilot CLI | `~/.claude/skills/` or `~/.copilot/skills/` |

> Syncing to `~/.claude/skills/` covers all three tools.

#### Project-level

| Tool | Path |
|------|------|
| Claude Code | `.claude/skills/` ← **source of truth** |
| VSCode Copilot | `.claude/skills/` (read natively) |
| Copilot CLI | `.claude/skills/` (read natively) |

> All three tools read `.claude/skills/` at project level — no sync needed.

### Sync

```bash
./sync_skills.sh --user                                      # User-level (all tools)
./sync_skills.sh --project --project-dir ~/proj/myapp        # Project-level (all tools)
./sync_skills.sh --all --project-dir ~/proj/myapp            # Both
./sync_skills.sh --user --force                              # Overwrite existing
./sync_skills.sh --list                                      # List available skills
```

> Existing skills are skipped by default. Use `--force` to overwrite.
