#!/usr/bin/env bash
# sync_mcp.sh — Sync this repo's .mcp.json to user-level and project-level MCP configs.
#
# OVERVIEW
#   This repo's .mcp.json (Claude Code format) is the single source of truth for MCP
#   server definitions. This script propagates those definitions to other tools, converting
#   schemas as needed and applying per-server adaptors for known incompatibilities.
#
# SOURCE FORMAT (Claude Code / .mcp.json)
#   {
#     "mcpServers": {
#       "<name>": { "command": "...", "args": [...], "env": {...} }
#     }
#   }
#
# TARGETS
#   --claude          ~/.claude.json
#                     Claude Code user-level config. Same mcpServers schema — merged as-is.
#                     No schema conversion, no adaptors needed (Claude is the source format).
#
#   --copilot-cli-user  ~/.copilot/mcp-config.json
#                     Copilot CLI user-level config. Same mcpServers schema as Claude Code,
#                     but some servers need adapting (e.g. OAuth not supported → mcp-remote).
#
#   --vscode-project  [PROJECT_DIR]/.vscode/mcp.json  +  [PROJECT_DIR]/.vscode/settings.json
#                     VSCode Copilot project-level config. Requires schema conversion:
#                       mcpServers → servers, adds "type": "stdio" per entry.
#                     Also used by Copilot CLI at project-level (reads .vscode/mcp.json).
#                     Also sets "chat.mcp.autostart": true in .vscode/settings.json so
#                     servers start automatically without a manual "Start" click in the UI.
#
#   --vscode-user     ~/Library/Application Support/Code/User/settings.json  (macOS)
#                     ~/.config/Code/User/settings.json                       (Linux)
#                     Sets "chat.mcp.autostart": true in VSCode user settings globally,
#                     so MCP servers auto-start across all workspaces.
#
# ADAPTORS
#   Some servers require different configs in non-Claude targets (e.g. OAuth not supported).
#   Each adaptor_<name>_core() returns the replacement in Claude format (no "type" field).
#   apply_vscode_adaptors() wraps them with "type":"stdio" for VSCode targets.
#   sync_copilot_cli_user() applies them directly in Claude schema for the Copilot CLI target.
#   Claude target never uses adaptors — it is the source.
#
# USAGE
#   sync_mcp.sh [--all] [--claude] [--copilot-cli-user] [--vscode-project] [--vscode-user]
#               [--project-dir <path>] [--source <path>] [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${SCRIPT_DIR}/.mcp.json"

COPILOT_CLI_CONFIG="$HOME/.copilot/mcp-config.json"
case "$(uname -s)" in
  Darwin) VSCODE_USER_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json" ;;
  Linux)  VSCODE_USER_SETTINGS="$HOME/.config/Code/User/settings.json" ;;
  *)      VSCODE_USER_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json" ;;
esac

DRY_RUN=false
PROJECT_DIR=""
SYNC_CLAUDE=false
SYNC_COPILOT_CLI_USER=false
SYNC_VSCODE_USER=false
SYNC_VSCODE_PROJECT=false

# ── Helpers ────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Sync .mcp.json (Claude Code format) to MCP configs for Claude Code, Copilot CLI, and VSCode Copilot.
Existing server entries are never overwritten — only new servers are appended.

Source: <script-dir>/.mcp.json

TARGETS:
  --claude               ~/.claude.json
                         Claude Code user-level. No conversion (same format as source).

  --copilot-cli-user     ~/.copilot/mcp-config.json
                         Copilot CLI user-level. Same mcpServers schema, adaptors applied
                         for servers with known incompatibilities (e.g. OAuth → mcp-remote).

  --vscode-project       [PROJECT_DIR]/.vscode/mcp.json
                         VSCode Copilot + Copilot CLI project-level. Converts mcpServers →
                         servers with "type":"stdio". Also sets chat.mcp.autostart=true in
                         [PROJECT_DIR]/.vscode/settings.json.

  --vscode-user          ~/Library/Application Support/Code/User/settings.json  (macOS)
                         ~/.config/Code/User/settings.json                       (Linux)
                         Sets chat.mcp.autostart=true in VSCode user settings so MCP servers
                         auto-start globally across all workspaces.

  --all                  All four targets (--vscode-project requires --project-dir).

OPTIONS:
  --project-dir <path>   Target project directory for --vscode-project (required with that flag)
  --source <path>        Override source .mcp.json path (default: <script-dir>/.mcp.json)
  --dry-run              Preview changes without writing any files
  -h, --help             Show this help

EXAMPLES:
  $(basename "$0") --all --project-dir ~/proj/myapp
  $(basename "$0") --claude --dry-run
  $(basename "$0") --copilot-cli-user
  $(basename "$0") --vscode-project --project-dir ~/proj/myapp
  $(basename "$0") --vscode-user
EOF
  exit 0
}

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "$*"; }

backup() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  if [[ "$DRY_RUN" == false ]]; then
    cp "$file" "${file}.bak"
    info "  backed up → ${file}.bak"
  fi
}

write_file() {
  local path="$1"
  local content="$2"
  if [[ "$DRY_RUN" == true ]]; then
    info "  [dry-run] would write → $path"
    echo "$content" | jq .
  else
    mkdir -p "$(dirname "$path")"
    echo "$content" > "$path"
    info "  written  → $path"
  fi
}

# Print list of server names that would be added (keys in $new not present in $existing).
added_keys() {
  local new="$1"
  local existing="$2"
  jq -n --argjson new "$new" --argjson existing "$existing" '
    [$new | keys[] | select(. as $k | $existing | has($k) | not)]
  '
}

# ── Argument parsing ───────────────────────────────────────────────────────────

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)               SYNC_CLAUDE=true; SYNC_COPILOT_CLI_USER=true; SYNC_VSCODE_USER=true; SYNC_VSCODE_PROJECT=true ;;
    --claude)            SYNC_CLAUDE=true ;;
    --copilot-cli-user)  SYNC_COPILOT_CLI_USER=true ;;
    --vscode-user)       SYNC_VSCODE_USER=true ;;
    --vscode-project)    SYNC_VSCODE_PROJECT=true ;;
    --project-dir)       [[ -n "${2:-}" ]] || die "--project-dir requires a path"; PROJECT_DIR="$2"; shift ;;
    --source)            [[ -n "${2:-}" ]] || die "--source requires a path"; SOURCE="$2"; shift ;;
    --dry-run)           DRY_RUN=true ;;
    -h|--help)           usage ;;
    *) die "Unknown option: $1  (use --help for usage)" ;;
  esac
  shift
done

# ── Pre-flight checks ──────────────────────────────────────────────────────────

command -v jq >/dev/null 2>&1 || die "jq is required but not installed (brew install jq)"
[[ -f "$SOURCE" ]] || die "Source not found: $SOURCE"
[[ "$SYNC_CLAUDE" == true || "$SYNC_COPILOT_CLI_USER" == true || "$SYNC_VSCODE_USER" == true || "$SYNC_VSCODE_PROJECT" == true ]] \
  || die "No target specified. Use --all, --claude, --copilot-cli-user, --vscode-user, or --vscode-project."
if [[ "$SYNC_VSCODE_PROJECT" == true && -z "$PROJECT_DIR" ]]; then
  die "--project-dir is required when using --vscode-project (or --all)"
fi
if [[ -n "$PROJECT_DIR" && ! -d "$PROJECT_DIR" ]]; then
  die "Project directory does not exist: $PROJECT_DIR"
fi

[[ "$DRY_RUN" == true ]] && info "[dry-run mode — no files will be modified]"
info "Source: $SOURCE"
info ""

# ── Target: Claude Code user-level (~/.claude.json) ───────────────────────────
# No schema conversion or adaptors — Claude Code is the source format.

sync_claude_user() {
  local target="$HOME/.claude.json"
  info "==> Claude Code user-level: $target"

  local existing="{}"
  [[ -f "$target" ]] && existing="$(cat "$target")"

  local src_servers
  src_servers="$(jq '.mcpServers // {}' "$SOURCE")"

  local existing_servers
  existing_servers="$(echo "$existing" | jq '.mcpServers // {}')"

  local to_add
  to_add="$(added_keys "$src_servers" "$existing_servers")"
  info "  servers to add: $to_add"

  # Merge: existing entries take priority ($src + $existing, so existing wins on collision)
  local merged
  merged="$(echo "$existing" | jq --argjson src "$src_servers" '
    .mcpServers = ($src + (.mcpServers // {}))
  ')"

  backup "$target"
  write_file "$target" "$merged"
}

# ── Target: VSCode user settings (…/Code/User/settings.json) ─────────────────
# Sets "chat.mcp.autostart": true so MCP servers start automatically without
# requiring a manual "Start" click in the VSCode UI. Applies globally across
# all workspaces. All other VSCode settings are preserved.

sync_vscode_user() {
  local target="$VSCODE_USER_SETTINGS"
  info "==> VSCode user settings: $target"

  local existing="{}"
  [[ -f "$target" ]] && existing="$(cat "$target")"

  if echo "$existing" | jq -e '.["chat.mcp.autostart"] == true' >/dev/null 2>&1; then
    info "  chat.mcp.autostart already enabled, nothing to do"
    return
  fi

  local updated
  updated="$(echo "$existing" | jq '.["chat.mcp.autostart"] = true')"

  backup "$target"
  write_file "$target" "$updated"
}

# ── Adaptors ──────────────────────────────────────────────────────────────────
# Some servers require a different config in non-Claude targets (e.g. OAuth is
# not supported). Each adaptor_<name>_core() returns the replacement entry in
# Claude format (no "type" field). Callers wrap it for their target format.
#
# To add a new adaptor:
#   1. Add adaptor_<name>_core() returning Claude-format JSON (no "type" field)
#   2. Add a has("<name>") dispatch block in sync_copilot_cli_user (Claude schema)
#   3. Add a has("<name>") dispatch block in apply_vscode_adaptors (wraps with "type":"stdio")

# atlassian: Claude Code uses OAuth (remote MCP); Copilot CLI and VSCode Copilot
# do not support OAuth yet, so we proxy through mcp-remote instead.
adaptor_atlassian_core() {
  jq -n '{
    "command": "npx",
    "args": ["mcp-remote", "https://mcp.atlassian.com/v1/mcp"]
  }'
}

# Dispatcher for VSCode-format targets (servers schema, requires "type":"stdio").
# Wraps each core adaptor output with "type":"stdio" before applying.
apply_vscode_adaptors() {
  local servers_json="$1"
  local result="$servers_json"

  if echo "$result" | jq -e 'has("atlassian")' >/dev/null 2>&1; then
    local override
    override="$(adaptor_atlassian_core | jq '{"type": "stdio"} + .')"
    result="$(echo "$result" | jq --argjson v "$override" '.atlassian = $v')"
  fi

  # Add further adaptors here:
  # if echo "$result" | jq -e 'has("<name>")' >/dev/null 2>&1; then
  #   override="$(adaptor_<name>_core | jq '{"type": "stdio"} + .')"
  #   result="$(echo "$result" | jq --argjson v "$override" '.<name> = $v')"
  # fi

  echo "$result"
}

# ── Target: Copilot CLI user-level (~/.copilot/mcp-config.json) ───────────────
# Same mcpServers schema as Claude Code, so no structural conversion is needed.
# However, some servers require adaptors (e.g. OAuth not supported by Copilot CLI).
# For project-level Copilot CLI config, use --vscode-project instead — Copilot CLI
# reads .vscode/mcp.json at the project level, same as VSCode Copilot.

sync_copilot_cli_user() {
  local target="$COPILOT_CLI_CONFIG"
  info "==> Copilot CLI user-level: $target"

  local existing="{}"
  [[ -f "$target" ]] && existing="$(cat "$target")"

  local src_servers
  src_servers="$(jq '.mcpServers // {}' "$SOURCE")"

  # Apply adaptors for Copilot CLI incompatibilities (mcpServers format, no "type" field)
  if echo "$src_servers" | jq -e 'has("atlassian")' >/dev/null 2>&1; then
    src_servers="$(echo "$src_servers" | jq --argjson v "$(adaptor_atlassian_core)" '.atlassian = $v')"
  fi
  # Add further adaptors here:
  # if echo "$src_servers" | jq -e 'has("<name>")' >/dev/null 2>&1; then
  #   src_servers="$(echo "$src_servers" | jq --argjson v "$(adaptor_<name>_core)" '.<name> = $v')"
  # fi

  local existing_servers
  existing_servers="$(echo "$existing" | jq '.mcpServers // {}')"

  local to_add
  to_add="$(added_keys "$src_servers" "$existing_servers")"
  info "  servers to add: $to_add"

  # Merge: existing entries take priority
  local merged
  merged="$(echo "$existing" | jq --argjson src "$src_servers" '
    .mcpServers = ($src + (.mcpServers // {}))
  ')"

  backup "$target"
  write_file "$target" "$merged"
}

# ── Target: VSCode Copilot + Copilot CLI project-level ([PROJ]/.vscode/) ──────
# Writes [PROJECT_DIR]/.vscode/mcp.json with VSCode schema (servers + type:stdio).
# Copilot CLI also reads .vscode/mcp.json at project level, so this covers both.
# Also writes "chat.mcp.autostart": true to [PROJECT_DIR]/.vscode/settings.json.
#
# Schema conversion from Claude format:
#   mcpServers → servers
#   adds "type": "stdio" per entry
#   applies per-server adaptors for known incompatibilities

sync_vscode_project() {
  local target="${PROJECT_DIR}/.vscode/mcp.json"
  info "==> VSCode Copilot + Copilot CLI project-level: $target"

  local existing_servers="{}"
  [[ -f "$target" ]] && existing_servers="$(jq '.servers // {}' "$target")"

  # Step 1: default Claude→VSCode conversion (rename key, add type:stdio)
  local src_servers_vscode
  src_servers_vscode="$(jq '.mcpServers // {} | with_entries(.value |= ({"type": "stdio"} + .))' "$SOURCE")"

  # Step 2: apply per-server adaptors
  src_servers_vscode="$(apply_vscode_adaptors "$src_servers_vscode")"

  local to_add
  to_add="$(added_keys "$src_servers_vscode" "$existing_servers")"
  info "  servers to add: $to_add"

  # Merge: existing entries take priority
  local merged_servers
  merged_servers="$(jq -n \
    --argjson src "$src_servers_vscode" \
    --argjson existing "$existing_servers" \
    '$src + $existing')"

  # Reconstruct full file (preserve any other top-level keys in existing file)
  local final
  if [[ -f "$target" ]]; then
    final="$(jq --argjson servers "$merged_servers" '.servers = $servers' "$target")"
  else
    final="$(jq -n --argjson servers "$merged_servers" '{"servers": $servers}')"
  fi

  backup "$target"
  write_file "$target" "$final"

  # Set chat.mcp.autostart in project .vscode/settings.json so servers start
  # automatically without a manual "Start" click in VSCode UI.
  local proj_settings="${PROJECT_DIR}/.vscode/settings.json"
  info "  chat.mcp.autostart → $proj_settings"
  local existing_settings="{}"
  [[ -f "$proj_settings" ]] && existing_settings="$(cat "$proj_settings")"
  if echo "$existing_settings" | jq -e '.["chat.mcp.autostart"] == true' >/dev/null 2>&1; then
    info "  chat.mcp.autostart already enabled, nothing to do"
  else
    local updated_settings
    updated_settings="$(echo "$existing_settings" | jq '.["chat.mcp.autostart"] = true')"
    backup "$proj_settings"
    write_file "$proj_settings" "$updated_settings"
  fi
}

# ── Run selected targets ───────────────────────────────────────────────────────

[[ "$SYNC_CLAUDE" == true ]]           && sync_claude_user
[[ "$SYNC_COPILOT_CLI_USER" == true ]] && sync_copilot_cli_user
[[ "$SYNC_VSCODE_USER" == true ]]      && sync_vscode_user
[[ "$SYNC_VSCODE_PROJECT" == true ]]   && sync_vscode_project

info ""
info "Done."
