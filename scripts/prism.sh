#!/usr/bin/env bash
# prism.sh -- PRISM orchestrator. Sources review-common.sh.
# Spawns parallel reviewer agents, collects results, synthesizes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/review-common.sh"

PROMPTS_DIR="$WORKSPACE/.claude/skills/prism/prompts"

# Strip template-breaking chars from substitution values
sanitize_value() {
    echo "$1" | sed 's/{{//g; s/}}//g' | tr -d '\000'
}

# Spawn agent inline (avoids subshell PID ownership issue with spawn_agent)
# Sets LAST_PID global. Call wait_with_timeout on LAST_PID.
spawn_inline() {
    local label="$1"
    local prompt_file="$2"
    local output_file="$3"
    local budget="$4"
    local model="$5"
    local perm="${6:-plan}"

    # Scope by permission: acceptEdits agents get RUN_DIR only (can't write to workspace).
    # plan agents get WORKSPACE (read-only -- they need to read source files for evidence).
    local add_dir="$WORKSPACE"
    if [[ "$perm" == "acceptEdits" ]]; then
        add_dir="$RUN_DIR"
    fi

    log "Spawning: $label (model=$model, budget=\$$budget, perm=$perm, dir=$add_dir)"

    claude -p "$(cat "$prompt_file")" \
        --add-dir "$add_dir" \
        --permission-mode "$perm" \
        --max-budget-usd "$budget" \
        --model "$model" \
        --output-format text \
        > "$output_file" 2>> "$RUN_LOG" &

    LAST_PID=$!
    log "  PID $LAST_PID -> $(basename "$output_file")"
}

# --- Mode -> reviewer mapping ---
BUDGET_REVIEWERS="security-auditor performance-analyst devils-advocate"
STANDARD_REVIEWERS="security-auditor performance-analyst simplicity-advocate integration-engineer devils-advocate"
EXTENDED_REVIEWERS="$STANDARD_REVIEWERS code-reviewer verification-auditor"

# --- Budget table (per-agent USD) ---
BRIEF_BUDGET=0.30
REVIEWER_BUDGET=0.80
HURT_BUDGET=0.50
WWZ_BUDGET=0.50
SYNTH_BUDGET_BUDGET=0.50
SYNTH_BUDGET_STANDARD=0.80
SYNTH_BUDGET_EXTENDED=1.00

# --- Timeouts (seconds) ---
REVIEWER_TIMEOUT=600
HURT_TIMEOUT=300
WWZ_TIMEOUT=300
SYNTH_TIMEOUT=600
BRIEF_TIMEOUT=300

# --- Defaults ---
ARTIFACT=""
MODE="standard"
MODEL_FLAGS=""
GOVERNANCE=0
MAX_PER_AGENT=""
TOTAL_BUDGET=""
SLUG=""
DRY_RUN=0
NO_BRIEF=0
STATUS_DIR=""
LIST_MODE=0

# --- Argument parsing ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --artifact)
                ARTIFACT="$2"; shift 2 ;;
            --mode)
                MODE="$2"; shift 2 ;;
            --opus)
                MODEL_FLAGS="--opus"; shift ;;
            --haiku)
                MODEL_FLAGS="--haiku"; shift ;;
            --governance)
                GOVERNANCE=1; shift ;;
            --max-per-agent-usd)
                MAX_PER_AGENT="$2"; shift 2 ;;
            --total-budget-usd)
                TOTAL_BUDGET="$2"; shift 2 ;;
            --slug)
                SLUG=$(generate_slug "$2"); shift 2 ;;
            --dry-run)
                DRY_RUN=1; shift ;;
            --no-brief)
                NO_BRIEF=1; shift ;;
            --status)
                STATUS_DIR="$2"; shift 2 ;;
            --list)
                LIST_MODE=1; shift ;;
            --)
                shift; break ;;
            -*)
                echo "Unknown flag: $1" >&2; exit 1 ;;
            *)
                # Positional: treat as artifact if not set
                if [[ -z "$ARTIFACT" ]]; then
                    ARTIFACT="$1"
                fi
                shift ;;
        esac
    done
}

# --- List mode ---
do_list() {
    echo "=== Archived PRISM Reviews ==="
    if [[ -d "$ARCHIVE_DIR" ]]; then
        for d in "$ARCHIVE_DIR"/*/; do
            [[ -d "$d" ]] || continue
            local slug_name
            slug_name=$(basename "$d")
            local count
            count=$(find "$d" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
            local latest
            latest=$(ls -t "${d}"*.md 2>/dev/null | head -1 || true)
            local date_str="unknown"
            if [[ -n "$latest" ]]; then
                date_str=$(stat -f '%Sm' -t '%Y-%m-%d' "$latest" 2>/dev/null || echo "unknown")
            fi
            echo "  $slug_name  ($count reviews, latest: $date_str)"
        done
    else
        echo "  No archive directory found."
    fi
}

# --- Status mode ---
do_status() {
    local run_dir="$STATUS_DIR"
    if [[ ! -d "$run_dir" ]]; then
        echo "Run directory not found: $run_dir" >&2
        exit 1
    fi
    echo "=== PRISM Run Status ==="
    echo "Dir: $run_dir"
    if [[ -f "$run_dir/.lock" ]]; then
        local lock_pid
        lock_pid=$(cat "$run_dir/.lock")
        if ps -p "$lock_pid" > /dev/null 2>&1; then
            echo "Status: RUNNING (PID $lock_pid)"
        else
            echo "Status: STALE LOCK (PID $lock_pid not running)"
        fi
    else
        echo "Status: COMPLETE (no lock)"
    fi
    echo ""
    echo "Reviews completed:"
    if [[ -d "$run_dir/reviews" ]]; then
        for f in "$run_dir/reviews"/*.md; do
            [[ -f "$f" ]] || continue
            echo "  $(basename "$f")  ($(wc -c < "$f" | tr -d ' ') bytes)"
        done
    fi
    if [[ -f "$run_dir/synthesis.md" ]]; then
        echo ""
        echo "Synthesis: EXISTS ($(wc -c < "$run_dir/synthesis.md" | tr -d ' ') bytes)"
    else
        echo ""
        echo "Synthesis: NOT YET"
    fi
}

# --- Dry run ---
do_dry_run() {
    local reviewers="$1"
    local model="$2"
    local synth_budget="$3"
    local prior_count="$4"

    local reviewer_count
    reviewer_count=$(echo "$reviewers" | wc -w | tr -d ' ')
    local total_reviewer_cost
    total_reviewer_cost=$(echo "$reviewer_count * $REVIEWER_BUDGET" | bc)

    local hurt_cost=0
    local wwz_cost=0
    if [[ "$MODE" != "budget" ]]; then
        hurt_cost=$HURT_BUDGET
        wwz_cost=$WWZ_BUDGET
    fi

    local brief_cost_dr=0
    if [[ "$prior_count" -gt 0 && "$NO_BRIEF" -eq 0 ]]; then
        brief_cost_dr=$BRIEF_BUDGET
    fi

    local total
    total=$(echo "$brief_cost_dr + $total_reviewer_cost + $hurt_cost + $wwz_cost + $synth_budget" | bc)

    echo "=== PRISM Dry Run ==="
    echo "Artifact:    $ARTIFACT"
    echo "Slug:        $SLUG"
    echo "Mode:        $MODE"
    echo "Model:       $model"
    echo "Governance:  $([ $GOVERNANCE -eq 1 ] && echo 'yes' || echo 'no')"
    echo "Prior reviews: $prior_count"
    echo ""
    echo "Reviewers ($reviewer_count):"
    for r in $reviewers; do
        echo "  - $r  (\$$REVIEWER_BUDGET)"
    done
    if [[ "$MODE" != "budget" ]]; then
        echo "  - hurt-locker (post-collection)  (\$$HURT_BUDGET)"
        echo "  - wwz (premise challenge)  (\$$WWZ_BUDGET)"
    fi
    echo ""
    echo "Budget breakdown:"
    if [[ "$brief_cost_dr" != "0" ]]; then
        echo "  Brief compiler: \$$brief_cost_dr"
    fi
    echo "  Reviewers:      \$$total_reviewer_cost"
    if [[ "$MODE" != "budget" ]]; then
        echo "  Hurt Locker:    \$$hurt_cost"
        echo "  WWZ:            \$$wwz_cost"
    fi
    echo "  Synthesis:      \$$synth_budget"
    echo "  ---"
    echo "  Total estimate: \$$total (per-agent ceiling, typical spend is lower)"
    if [[ -n "$TOTAL_BUDGET" ]]; then
        local over
        over=$(echo "$total > $TOTAL_BUDGET" | bc)
        if [[ "$over" -eq 1 ]]; then
            echo ""
            echo "  WARNING: Exceeds --total-budget-usd \$$TOTAL_BUDGET"
        else
            echo "  (within --total-budget-usd \$$TOTAL_BUDGET)"
        fi
    fi
}

# --- Main ---
main() {
    parse_args "$@"
    load_env

    # Handle --list
    if [[ "$LIST_MODE" -eq 1 ]]; then
        do_list
        exit 0
    fi

    # Handle --status
    if [[ -n "$STATUS_DIR" ]]; then
        do_status
        exit 0
    fi

    # Validate artifact
    if [[ -z "$ARTIFACT" ]]; then
        echo "Error: --artifact <path> is required" >&2
        echo "Usage: prism.sh --artifact <path> [--mode budget|standard|extended] [--opus|--haiku]" >&2
        exit 1
    fi

    if [[ "$ARTIFACT" != "-" && ! -f "$ARTIFACT" ]]; then
        echo "Error: artifact not found: $ARTIFACT" >&2
        exit 1
    fi

    # Select model
    local model
    model=$(select_model $MODEL_FLAGS)

    # Generate slug
    if [[ -z "$SLUG" ]]; then
        local base
        base=$(basename "$ARTIFACT" .md)
        SLUG=$(generate_slug "$base")
    fi

    # Select reviewers and synth budget by mode
    local reviewers synth_budget
    case "$MODE" in
        budget)
            reviewers="$BUDGET_REVIEWERS"
            synth_budget="$SYNTH_BUDGET_BUDGET"
            ;;
        standard)
            reviewers="$STANDARD_REVIEWERS"
            synth_budget="$SYNTH_BUDGET_STANDARD"
            ;;
        extended)
            reviewers="$EXTENDED_REVIEWERS"
            synth_budget="$SYNTH_BUDGET_EXTENDED"
            ;;
        *)
            echo "Error: unknown mode '$MODE'. Use budget|standard|extended." >&2
            exit 1
            ;;
    esac

    # Override per-agent budgets if --max-per-agent-usd set
    if [[ -n "$MAX_PER_AGENT" ]]; then
        REVIEWER_BUDGET="$MAX_PER_AGENT"
        HURT_BUDGET="$MAX_PER_AGENT"
        WWZ_BUDGET="$MAX_PER_AGENT"
        BRIEF_BUDGET="$MAX_PER_AGENT"
        synth_budget="$MAX_PER_AGENT"
    fi

    # Setup run directory
    setup_run_dir "$SLUG"
    trap cleanup_lock EXIT

    # Copy artifact
    if [[ "$ARTIFACT" == "-" ]]; then
        cat > "$RUN_DIR/artifact.md"
        ARTIFACT="$RUN_DIR/artifact.md"
    else
        cp "$ARTIFACT" "$RUN_DIR/artifact.md"
    fi
    local artifact_path="$RUN_DIR/artifact.md"

    # Find prior reviews
    local prior_count=0
    if find_prior_reviews "$SLUG"; then
        prior_count=$(wc -l < "$RUN_DIR/prior-review-paths.txt" | tr -d ' ')
    fi

    # Pre-flight total cost estimate (after prior review search so brief cost is accurate)
    local reviewer_count
    reviewer_count=$(echo "$reviewers" | wc -w | tr -d ' ')
    local estimated_total
    local hurt_cost=0
    local wwz_cost=0
    local brief_cost=0
    [[ "$MODE" != "budget" ]] && hurt_cost=$HURT_BUDGET
    [[ "$MODE" != "budget" ]] && wwz_cost=$WWZ_BUDGET
    [[ "$prior_count" -gt 0 && "$NO_BRIEF" -eq 0 ]] && brief_cost=$BRIEF_BUDGET
    estimated_total=$(echo "$reviewer_count * $REVIEWER_BUDGET + $hurt_cost + $wwz_cost + $synth_budget + $brief_cost" | bc)
    log "Estimated total cost: \$$estimated_total ($reviewer_count reviewers x \$$REVIEWER_BUDGET + hurt \$$hurt_cost + wwz \$$wwz_cost + synth \$$synth_budget + brief \$$brief_cost)"

    # Handle --dry-run (show plan regardless of budget ceiling)
    if [[ "$DRY_RUN" -eq 1 ]]; then
        do_dry_run "$reviewers" "$model" "$synth_budget" "$prior_count"
        cleanup_lock
        trap - EXIT
        exit 0
    fi

    # Enforce --total-budget-usd ceiling (live runs only)
    if [[ -n "$TOTAL_BUDGET" ]]; then
        local over
        over=$(echo "$estimated_total > $TOTAL_BUDGET" | bc)
        if [[ "$over" -eq 1 ]]; then
            echo "Error: estimated cost \$$estimated_total exceeds --total-budget-usd \$$TOTAL_BUDGET" >&2
            echo "  Breakdown: $reviewer_count reviewers x \$$REVIEWER_BUDGET + hurt \$$hurt_cost + wwz \$$wwz_cost + synth \$$synth_budget + brief \$$brief_cost" >&2
            echo "  Use --max-per-agent-usd to lower per-agent caps, or increase --total-budget-usd" >&2
            cleanup_lock
            trap - EXIT
            exit 1
        fi
    fi

    log "PRISM run: mode=$MODE, model=$model, slug=$SLUG, governance=$GOVERNANCE"
    log "Reviewers: $reviewers"

    # --- Phase 1: Brief compiler + DA (parallel) ---
    local brief_file=""
    local brief_pid=""
    local da_pid=""

    # Helper: check if reviewer already has valid output (for partial resume)
    has_valid_output() {
        local outfile="$1"
        [[ -f "$outfile" ]] && [[ $(wc -c < "$outfile" | tr -d ' ') -gt 500 ]] && ! grep -qi 'REVIEWER FAILED' "$outfile" 2>/dev/null
    }

    # Spawn DA immediately (never gets brief)
    local da_prompt_file="$RUN_DIR/prompt-devils-advocate.md"
    if has_valid_output "$RUN_DIR/reviews/devils-advocate.md"; then
        log "Resuming: devils-advocate already has valid output, skipping"
    else
        build_reviewer_prompt \
            "$PROMPTS_DIR/devils-advocate.md" \
            "$artifact_path" \
            "$PROMPTS_DIR/evidence-rules.md" \
            > "$da_prompt_file"
        spawn_inline "devils-advocate" "$da_prompt_file" "$RUN_DIR/reviews/devils-advocate.md" "$REVIEWER_BUDGET" "$model" "plan"
        da_pid=$LAST_PID
    fi

    # Spawn brief compiler if needed
    if [[ "$prior_count" -gt 0 && "$NO_BRIEF" -eq 0 ]]; then
        local brief_prompt_file="$RUN_DIR/prompt-prior-brief.md"
        local prior_paths
        prior_paths=$(sanitize_value "$(cat "$RUN_DIR/prior-review-paths.txt")")

        local brief_template
        brief_template=$(cat "$PROMPTS_DIR/prior-brief-compiler.md")
        brief_template="${brief_template//\{\{PRIOR_REVIEW_PATHS\}\}/$prior_paths}"
        brief_template="${brief_template//\{\{RUN_DIR\}\}/$RUN_DIR}"
        echo "$brief_template" > "$brief_prompt_file"

        spawn_inline "prior-brief-compiler" "$brief_prompt_file" "$RUN_DIR/brief-compiler-output.md" "$BRIEF_BUDGET" "$model" "acceptEdits"
        brief_pid=$LAST_PID
        brief_file="$RUN_DIR/prior-findings-brief.md"
    fi

    # Wait for brief compiler if spawned
    if [[ -n "$brief_pid" ]]; then
        if ! wait_with_timeout "$brief_pid" "$BRIEF_TIMEOUT" "prior-brief-compiler"; then
            log "Brief compiler timed out or failed. Proceeding without brief."
            brief_file=""
        fi
        # Verify the brief file was actually written
        if [[ -n "$brief_file" && ! -f "$brief_file" ]]; then
            log "Brief file not found at $brief_file. Proceeding without brief."
            brief_file=""
        fi
    fi

    # --- Phase 2: Spawn remaining reviewers (all except DA) ---
    declare -a pids=()
    declare -a labels=()

    for reviewer in $reviewers; do
        # DA already spawned
        [[ "$reviewer" == "devils-advocate" ]] && continue

        local prompt_file="$RUN_DIR/prompt-${reviewer}.md"
        build_reviewer_prompt \
            "$PROMPTS_DIR/${reviewer}.md" \
            "$artifact_path" \
            "$PROMPTS_DIR/evidence-rules.md" \
            "$brief_file" \
            > "$prompt_file"

        if has_valid_output "$RUN_DIR/reviews/${reviewer}.md"; then
            log "Resuming: $reviewer already has valid output, skipping"
            continue
        fi

        spawn_inline "$reviewer" "$prompt_file" "$RUN_DIR/reviews/${reviewer}.md" "$REVIEWER_BUDGET" "$model" "plan"
        pids+=("$LAST_PID")
        labels+=("$reviewer")
    done

    # --- Phase 3: Wait for all reviewers ---
    # T2-B fix: check reviewer output for failures, replace bad output with explicit stub
    check_reviewer_output() {
        local label="$1"
        local outfile="$2"
        if [[ -f "$outfile" ]]; then
            local size
            size=$(wc -c < "$outfile" | tr -d ' ')
            if [[ "$size" -lt 100 ]]; then
                log "WARNING: $label output is only ${size} bytes -- replacing with failure stub"
                echo "REVIEWER FAILED: $label produced no usable output (${size} bytes). Do not treat as a valid review." > "$outfile"
            elif grep -qi 'exceeded.*budget\|budget.*exceeded\|Error:.*budget' "$outfile" 2>/dev/null; then
                log "WARNING: $label hit budget limit -- replacing with failure stub"
                echo "REVIEWER FAILED: $label exceeded budget before completing analysis. Do not treat as a valid review." > "$outfile"
            fi
        fi
    }

    # Wait for DA (only if spawned this run)
    if [[ -n "$da_pid" ]]; then
        if ! wait_with_timeout "$da_pid" "$REVIEWER_TIMEOUT" "devils-advocate"; then
            echo "FAILED: devils-advocate (exit non-zero within ${REVIEWER_TIMEOUT}s timeout)" > "$RUN_DIR/reviews/devils-advocate.md"
        fi
        check_reviewer_output "devils-advocate" "$RUN_DIR/reviews/devils-advocate.md"
    fi

    # Wait for remaining
    for i in "${!pids[@]}"; do
        if ! wait_with_timeout "${pids[$i]}" "$REVIEWER_TIMEOUT" "${labels[$i]}"; then
            echo "FAILED: ${labels[$i]} (exit non-zero within ${REVIEWER_TIMEOUT}s timeout)" > "$RUN_DIR/reviews/${labels[$i]}.md"
        fi
        check_reviewer_output "${labels[$i]}" "$RUN_DIR/reviews/${labels[$i]}.md"
    done

    log "All reviewers complete."

    # --- Phase 4: HURT LOCKER (standard/extended only) ---
    if [[ "$MODE" != "budget" ]]; then
        local review_files=""
        for f in "$RUN_DIR/reviews"/*.md; do
            [[ -f "$f" ]] || continue
            review_files="$review_files $f"
        done
        review_files=$(echo "$review_files" | sed 's/^ //')

        local hurt_prompt_file="$RUN_DIR/prompt-hurt-locker.md"
        local hurt_template
        hurt_template=$(cat "$PROMPTS_DIR/hurt-locker.md")
        review_files=$(sanitize_value "$review_files")
        hurt_template="${hurt_template//\{\{REVIEW_FILES\}\}/$review_files}"
        echo "$hurt_template" > "$hurt_prompt_file"

        spawn_inline "hurt-locker" "$hurt_prompt_file" "$RUN_DIR/reviews/hurt-locker.md" "$HURT_BUDGET" "$model" "plan"
        local hurt_pid=$LAST_PID

        if ! wait_with_timeout "$hurt_pid" "$HURT_TIMEOUT" "hurt-locker"; then
            echo "TIMEOUT: hurt-locker did not complete in ${HURT_TIMEOUT}s" > "$RUN_DIR/reviews/hurt-locker.md"
        fi
        log "HURT LOCKER complete."
    fi

    # --- Phase 5: WWZ -- Premise Challenge (standard/extended only) ---
    if [[ "$MODE" != "budget" ]]; then
        local wwz_prompt_file="$RUN_DIR/prompt-wwz.md"
        local wwz_template
        wwz_template=$(cat "$PROMPTS_DIR/wwz.md")
        local artifact_san
        artifact_san=$(sanitize_value "$artifact_path")
        local review_dir_san
        review_dir_san=$(sanitize_value "$RUN_DIR/reviews")
        wwz_template="${wwz_template//\{\{ARTIFACT_PATH\}\}/$artifact_san}"
        wwz_template="${wwz_template//\{\{REVIEW_DIR\}\}/$review_dir_san}"
        echo "$wwz_template" > "$wwz_prompt_file"

        spawn_inline "wwz" "$wwz_prompt_file" "$RUN_DIR/reviews/wwz.md" "$WWZ_BUDGET" "$model" "plan"
        local wwz_pid=$LAST_PID

        if ! wait_with_timeout "$wwz_pid" "$WWZ_TIMEOUT" "wwz"; then
            echo "TIMEOUT: wwz did not complete in ${WWZ_TIMEOUT}s" > "$RUN_DIR/reviews/wwz.md"
        fi
        log "WWZ complete."
    fi

    # --- Phase 6: Synthesis ---
    local governance_block=""
    if [[ "$GOVERNANCE" -eq 1 ]]; then
        governance_block="GOVERNANCE MODE: Any finding flagged 3+ times across reviews without resolution must be marked as STUCK in the Still Open section. STUCK findings require explicit owner assignment or architectural decision."
    fi

    local synth_prompt_file="$RUN_DIR/prompt-synthesis.md"
    local synth_template
    synth_template=$(cat "$PROMPTS_DIR/synthesis.md")
    synth_template="${synth_template//\{\{RUN_DIR\}\}/$RUN_DIR}"
    synth_template="${synth_template//\{\{SLUG\}\}/$SLUG}"
    synth_template="${synth_template//\{\{GOVERNANCE_BLOCK\}\}/$governance_block}"
    echo "$synth_template" > "$synth_prompt_file"

    spawn_inline "synthesis" "$synth_prompt_file" "$RUN_DIR/synthesis-raw.md" "$synth_budget" "$model" "acceptEdits"
    local synth_pid=$LAST_PID

    if ! wait_with_timeout "$synth_pid" "$SYNTH_TIMEOUT" "synthesis"; then
        log "Synthesis timed out. Check $RUN_DIR for partial results."
        notify "PRISM *$SLUG* -- synthesis timed out. Partial results in run dir."
        exit 1
    fi

    # Synthesis agent should write to RUN_DIR/synthesis.md via acceptEdits.
    # Fallback: if it wrote to stdout instead, use raw capture but validate content.
    if [[ ! -f "$RUN_DIR/synthesis.md" ]]; then
        if [[ -f "$RUN_DIR/synthesis-raw.md" ]] && grep -q 'Final Verdict' "$RUN_DIR/synthesis-raw.md" 2>/dev/null; then
            log "WARNING: Synthesis agent wrote to stdout, not to file. Using raw capture."
            cp "$RUN_DIR/synthesis-raw.md" "$RUN_DIR/synthesis.md"
        else
            log "ERROR: No valid synthesis output found (missing 'Final Verdict' marker). Run failed."
            notify "PRISM *$SLUG* -- synthesis produced no valid output."
            exit 1
        fi
    fi

    log "Synthesis complete."

    # --- Phase 7: Archive ---
    local archived
    archived=$(archive_result "$SLUG" "$RUN_DIR/synthesis.md" "$RUN_DIR/artifact.md")

    # F-2 fix: verify archive succeeded before any cleanup
    if [[ -z "$archived" || ! -f "$archived" ]]; then
        log "ERROR: Archive failed -- synthesis not saved. Run dir preserved."
        notify "PRISM *$SLUG* -- archive write failed. Review in run dir only."
    else
        log "Archived to: $archived"
        # Prune old run dirs (>30 days) only if archive is confirmed
        find "$RUNS_DIR" -maxdepth 1 -type d -mtime +30 -exec rm -rf {} \; 2>/dev/null || true
    fi

    # --- Sentry: verify synthesis addressed findings ---
    if [[ -f "$RUN_DIR/synthesis.md" && -f "$RUN_DIR/artifact.md" ]]; then
        bash "$HOME/.openclaw/scripts/sentry-check.sh" \
            --task "$RUN_DIR/artifact.md" \
            --output "$RUN_DIR/synthesis.md" \
            --source "orchestrator" 2>>"$HOME/.openclaw/logs/sentry-check.log" || \
            log "Sentry flagged synthesis (see sentry.jsonl)"
    fi

    # --- Phase 8: Notify ---
    local verdict
    verdict=$(grep -m1 'Final Verdict' "$RUN_DIR/synthesis.md" 2>/dev/null | head -1 || echo "unknown")
    notify "PRISM *$SLUG* complete ($MODE mode). $verdict. Archived: \`$archived\`"

    # Elapsed time
    local end_time elapsed_min
    end_time=$(date +%s)
    elapsed_min=$(( (end_time - START_TIME) / 60 ))
    local elapsed_sec=$(( (end_time - START_TIME) % 60 ))
    log "Elapsed: ${elapsed_min}m ${elapsed_sec}s"

    echo ""
    echo "=== PRISM Complete ==="
    echo "Slug:      $SLUG"
    echo "Mode:      $MODE"
    echo "Elapsed:   ${elapsed_min}m ${elapsed_sec}s"
    echo "Synthesis: $RUN_DIR/synthesis.md"
    echo "Archive:   $archived"
}

main "$@"
