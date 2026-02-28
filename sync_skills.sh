#!/usr/bin/env bash
# sync_skills.sh — Sync Claude Code skills to user-level and project-level skill directories.
#
# OVERVIEW
#   This repo's .claude/skills/ is the source of truth for skill definitions.
#   Skills are subdirectories containing at least a SKILL.md file with YAML frontmatter.
#   No schema conversion is needed — the same format is read by all tools.
#
# SOURCE
#   <script-dir>/.claude/skills/<name>/SKILL.md
#
# TARGETS
#   --user       ~/.claude/skills/
#                User-level skills, shared across all projects.
#                Read by Claude Code, VSCode Copilot, and Copilot CLI.
#
#   --project    [PROJECT_DIR]/.claude/skills/
#                Project-level skills, scoped to one repository.
#                Read by Claude Code, VSCode Copilot, and Copilot CLI.
#
# BEHAVIOR
#   By default, existing skills in the target are never overwritten.
#   Use --force to overwrite (e.g. when updating a skill to a newer version).
#
# USAGE
#   sync_skills.sh (--user | --project | --all) [--skill <name>]
#                  [--project-dir <path>] [--force] [--dry-run] [--list]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_SOURCE="${SCRIPT_DIR}/.claude/skills"

USER_SKILLS_DIR="$HOME/.claude/skills"

DRY_RUN=false
FORCE=false
SYNC_USER=false
SYNC_PROJECT=false
FILTER_SKILL=""
PROJECT_DIR=""

# ── Helpers ────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") [TARGETS] [OPTIONS]

Sync skills from this repo's .claude/skills/ to user-level or project-level skill directories.
All three tools (Claude Code, VSCode Copilot, Copilot CLI) read from the same paths.
Existing skills are skipped by default — use --force to overwrite.

Source: <script-dir>/.claude/skills/

TARGETS:
  --user                 ~/.claude/skills/                   (user-level, all tools)
  --project              [PROJECT_DIR]/.claude/skills/        (project-level, all tools)
  --all                  Both targets (--project requires --project-dir)

OPTIONS:
  --skill <name>         Sync only the named skill (default: all skills)
  --project-dir <path>   Target project directory for --project (required with that flag)
  --force                Overwrite skills that already exist in the target
  --dry-run              Preview changes without copying any files
  --list                 List available skills in this repo and exit
  -h, --help             Show this help

EXAMPLES:
  $(basename "$0") --user
  $(basename "$0") --project --project-dir ~/proj/myapp
  $(basename "$0") --all --project-dir ~/proj/myapp
  $(basename "$0") --user --skill jira
  $(basename "$0") --user --force --dry-run
EOF
  exit 0
}

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "$*"; }

list_source_skills() {
  # List skill names (subdirectory names) that contain a SKILL.md
  for d in "$SKILLS_SOURCE"/*/; do
    [[ -f "${d}SKILL.md" ]] && basename "$d"
  done
}

# Copy a single skill directory to the target skills directory.
# Skips if the skill already exists and --force is not set.
sync_skill() {
  local name="$1"
  local target_skills_dir="$2"
  local src="${SKILLS_SOURCE}/${name}"
  local dest="${target_skills_dir}/${name}"

  if [[ ! -d "$src" ]]; then
    die "Skill not found in source: $name"
  fi

  if [[ -d "$dest" ]]; then
    if [[ "$FORCE" == false ]]; then
      info "  skipped (already exists): $name  — use --force to overwrite"
      return
    fi
    info "  overwriting: $name"
  else
    info "  copying: $name"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    info "  [dry-run] would copy → $dest"
  else
    mkdir -p "$target_skills_dir"
    cp -r "$src" "$dest"
    info "  copied → $dest"
  fi
}

# Sync all (or one filtered) skill to a given target directory.
sync_to() {
  local target_skills_dir="$1"
  local label="$2"
  info "==> $label: $target_skills_dir"

  local skills=()
  if [[ -n "$FILTER_SKILL" ]]; then
    skills=("$FILTER_SKILL")
  else
    while IFS= read -r name; do
      skills+=("$name")
    done < <(list_source_skills)
  fi

  if [[ ${#skills[@]} -eq 0 ]]; then
    die "No skills found in source: $SKILLS_SOURCE"
  fi

  for name in "${skills[@]}"; do
    sync_skill "$name" "$target_skills_dir"
  done
}

# ── Argument parsing ───────────────────────────────────────────────────────────

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)         SYNC_USER=true; SYNC_PROJECT=true ;;
    --user)        SYNC_USER=true ;;
    --project)     SYNC_PROJECT=true ;;
    --skill)       [[ -n "${2:-}" ]] || die "--skill requires a name"; FILTER_SKILL="$2"; shift ;;
    --project-dir) [[ -n "${2:-}" ]] || die "--project-dir requires a path"; PROJECT_DIR="$2"; shift ;;
    --force)       FORCE=true ;;
    --dry-run)     DRY_RUN=true ;;
    --list)
      echo "Available skills:"
      list_source_skills | sed 's/^/  /'
      exit 0
      ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1  (use --help for usage)" ;;
  esac
  shift
done

# ── Pre-flight checks ──────────────────────────────────────────────────────────

[[ -d "$SKILLS_SOURCE" ]] || die "Skills source directory not found: $SKILLS_SOURCE"
[[ "$SYNC_USER" == true || "$SYNC_PROJECT" == true ]] \
  || die "No target specified. Use --user, --project, or --all."
if [[ "$SYNC_PROJECT" == true && -z "$PROJECT_DIR" ]]; then
  die "--project-dir is required when using --project (or --all)"
fi
if [[ -n "$PROJECT_DIR" && ! -d "$PROJECT_DIR" ]]; then
  die "Project directory does not exist: $PROJECT_DIR"
fi
if [[ -n "$FILTER_SKILL" && ! -d "${SKILLS_SOURCE}/${FILTER_SKILL}" ]]; then
  die "Skill '$FILTER_SKILL' not found in source. Available: $(list_source_skills | tr '\n' ' ')"
fi

[[ "$DRY_RUN" == true ]] && info "[dry-run mode — no files will be copied]"
[[ "$FORCE" == true ]]   && info "[force mode — existing skills will be overwritten]"
info "Source: $SKILLS_SOURCE"
info ""

# ── Run selected targets ───────────────────────────────────────────────────────

[[ "$SYNC_USER" == true ]]    && sync_to "$USER_SKILLS_DIR"              "User-level (Claude Code, VSCode Copilot, Copilot CLI)"
[[ "$SYNC_PROJECT" == true ]] && sync_to "${PROJECT_DIR}/.claude/skills" "Project-level (Claude Code, VSCode Copilot, Copilot CLI)"

info ""
info "Done."
