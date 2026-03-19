#!/usr/bin/env bash
# review-common.sh -- Shared functions for PRISM, CRUCIBLE, MiroPRISM
# Sourced by orchestrator scripts. Do not execute directly.

# Ensure claude CLI is in PATH
export PATH="$HOME/.local/bin:$PATH"

# Resolve claude binary once (no env override -- T2-1 fix)
CLAUDE_BIN="$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")"

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
ANALYSIS_DIR="$WORKSPACE/analysis/prism"
ARCHIVE_DIR="$ANALYSIS_DIR/archive"
RUNS_DIR="$ANALYSIS_DIR/runs"

# CRUCIBLE paths
CRUCIBLE_ANALYSIS_DIR="$WORKSPACE/analysis/crucible"
CRUCIBLE_ARCHIVE_DIR="$CRUCIBLE_ANALYSIS_DIR/archive"
CRUCIBLE_RUNS_DIR="$CRUCIBLE_ANALYSIS_DIR/runs"
VIPER_ARCHIVE_DIR="$WORKSPACE/analysis/red-viper"

# Load Telegram credentials from .env
load_env() {
    if [ -f "$HOME/.openclaw/.env" ]; then
        TG_TOKEN=$(grep -m1 'TELEGRAM_BOT_TOKEN' "$HOME/.openclaw/.env" | cut -d= -f2)
        TG_CHAT=$(grep -m1 'TELEGRAM_CHAT_ID' "$HOME/.openclaw/.env" | cut -d= -f2)
    fi
    TG_TOKEN="${TG_TOKEN:-}"
    TG_CHAT="${TG_CHAT:-}"
}

# Log to run log + stderr
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "${RUN_LOG:-/dev/stderr}"
    echo "$msg" >&2
}

# Send Telegram notification
notify() {
    [[ -z "$TG_TOKEN" || -z "$TG_CHAT" ]] && return
    local msg="$1"
    curl -s -o /dev/null -w "" -X POST \
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d chat_id="$TG_CHAT" \
        -d parse_mode="Markdown" \
        --data-urlencode "text=$msg" 2>/dev/null || true
}

# Generate kebab-case slug from text
# Usage: generate_slug "API authentication redesign"
# Output: api-authentication-redesign
generate_slug() {
    local input="$1"
    echo "$input" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9 -]//g' \
        | sed 's/  */ /g' \
        | sed 's/ /-/g' \
        | cut -c1-60
}

# Create run directory with lock
# Sets RUN_DIR and RUN_LOG globals
# Usage: setup_run_dir <slug>
setup_run_dir() {
    local slug="$1"
    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    RUN_DIR="$RUNS_DIR/${slug}-${timestamp}"

    # T2-E fix: detect same-second collision
    if [ -d "$RUN_DIR" ]; then
        RUN_DIR="${RUN_DIR}-$$"
        log "Same-second collision detected, appending PID: $RUN_DIR"
    fi

    RUN_LOG="$RUN_DIR/run.log"
    START_TIME=$(date +%s)
    mkdir -p "$RUN_DIR/reviews"
    echo $$ > "$RUN_DIR/.lock"
    log "Run directory: $RUN_DIR"
}

# Remove lock file on exit
cleanup_lock() {
    if [ -n "${RUN_DIR:-}" ] && [ -f "$RUN_DIR/.lock" ]; then
        rm -f "$RUN_DIR/.lock"
        log "Lock removed"
    fi
}

# Find prior reviews for a topic slug
# Writes paths to prior-review-paths.txt in run dir
# Returns 0 if found, 1 if none
find_prior_reviews() {
    local slug="$1"
    local out="$RUN_DIR/prior-review-paths.txt"
    local found=0

    # Direct directory match
    if [ -d "$ARCHIVE_DIR/$slug" ]; then
        find "$ARCHIVE_DIR/$slug" -name "*review*.md" -not -name "*artifact*" -print 2>/dev/null | sort -r | head -3 > "$out"
        found=$(wc -l < "$out" | tr -d ' ')
    fi

    # Grep fallback if no directory match
    if [ "$found" -eq 0 ]; then
        grep -rli -- "$slug" "$ARCHIVE_DIR/" 2>/dev/null | head -10 > "$out"
        found=$(wc -l < "$out" | tr -d ' ')
    fi

    if [ "$found" -gt 0 ]; then
        log "Found $found prior review(s) for '$slug'"
        return 0
    else
        log "No prior reviews found for '$slug'"
        rm -f "$out"
        return 1
    fi
}

# Select model based on flags
# Usage: select_model [--opus] [--haiku]
# Default: sonnet
select_model() {
    local model="sonnet"
    for arg in "$@"; do
        case "$arg" in
            --opus) model="opus" ;;
            --haiku) model="haiku" ;;
        esac
    done
    echo "$model"
}

# Spawn a claude -p agent in the background
# Usage: spawn_agent <label> <prompt_file> <output_file> <budget> <model> <permission_mode> [<add_dir>]
# Sets global SPAWNED_PID (do NOT capture via $() -- grandchild PIDs break wait)
spawn_agent() {
    local label="$1"
    local prompt_file="$2"
    local output_file="$3"
    local budget="$4"
    local model="$5"
    local perm="${6:-plan}"
    local add_dir="${7:-$WORKSPACE}"

    log "Spawning: $label (model=$model, budget=\$$budget, perm=$perm, dir=$add_dir)"

    # Read prompt content before backgrounding
    local prompt_content
    prompt_content="$(cat "$prompt_file")"

    "$CLAUDE_BIN" -p "$prompt_content" \
        --add-dir "$add_dir" \
        --permission-mode "$perm" \
        --max-budget-usd "$budget" \
        --model "$model" \
        --output-format text \
        > "$output_file" 2>> "$RUN_LOG" &

    SPAWNED_PID=$!
    log "  PID $SPAWNED_PID -> $(basename "$output_file")"
}

# Wait for a PID with timeout (macOS compatible, no timeout command)
# Usage: wait_with_timeout <pid> <seconds> <label>
# Returns: 0 on success, 1 on timeout/failure
wait_with_timeout() {
    local pid=$1
    local secs=$2
    local label=$3

    # Write a sentinel so watchdog can verify PID ownership before killing
    local sentinel="/tmp/prism-watchdog-${pid}.sentinel"
    echo "$pid" > "$sentinel"

    # Background watchdog: kill process group after $secs seconds
    (
        sleep "$secs"
        # T2-A fix: verify PID still belongs to this run before killing
        if [ -f "$sentinel" ] && [ "$(cat "$sentinel" 2>/dev/null)" = "$pid" ]; then
            # T2-D fix: kill process group to catch subprocesses
            kill -- -"$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" 2>/dev/null || kill "$pid" 2>/dev/null
        fi
    ) &
    local watchdog=$!

    wait "$pid" 2>/dev/null
    local exit_code=$?

    # Clean up sentinel and watchdog
    rm -f "$sentinel"
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null

    if [ $exit_code -ne 0 ]; then
        log "TIMEOUT or FAIL: $label (exit=$exit_code after ${secs}s limit)"
        return 1
    fi

    log "Complete: $label"
    return 0
}

# Build a reviewer prompt from template
# Replaces {{ARTIFACT_PATH}}, {{EVIDENCE_RULES}}, {{PRIOR_BRIEF}}
# Usage: build_reviewer_prompt <template_file> <artifact_path> <evidence_rules_file> [<brief_file>]
# Writes to stdout (redirect to temp file)
build_reviewer_prompt() {
    local template="$1"
    local artifact_path="$2"
    local evidence_file="$3"
    local brief_file="${4:-}"

    local evidence_rules
    evidence_rules=$(cat "$evidence_file")

    local prior_brief=""
    if [ -n "$brief_file" ] && [ -f "$brief_file" ]; then
        # Sanitize: strip template markers + enforce 3000 char ceiling
        prior_brief=$(cat "$brief_file" | sed 's/{{//g; s/}}//g' | head -c 3000)
    fi

    local content
    content=$(cat "$template")
    content="${content//\{\{ARTIFACT_PATH\}\}/$artifact_path}"
    content="${content//\{\{EVIDENCE_RULES\}\}/$evidence_rules}"
    content="${content//\{\{PRIOR_BRIEF\}\}/$prior_brief}"

    echo "$content"
}

# Archive a review result
# Usage: archive_result <slug> <source_file> [<artifact_file>]
archive_result() {
    local slug="$1"
    local source="$2"
    local artifact="${3:-}"
    local dest_dir="$ARCHIVE_DIR/$slug"
    local dest="$dest_dir/$(date '+%Y-%m-%d')-review.md"

    mkdir -p "$dest_dir"

    # Avoid overwriting: append suffix if exists
    if [ -f "$dest" ]; then
        local n=2
        while [ -f "${dest%.md}-r${n}.md" ]; do
            n=$((n + 1))
        done
        dest="${dest%.md}-r${n}.md"
    fi

    cp "$source" "$dest"
    log "Archived: $dest"

    # T3-B fix: archive artifact alongside synthesis for future traceability
    if [ -n "$artifact" ] && [ -f "$artifact" ]; then
        local artifact_dest="${dest%.md}-artifact.md"
        cp "$artifact" "$artifact_dest"
        log "Archived artifact: $artifact_dest"
    fi

    echo "$dest"
}
