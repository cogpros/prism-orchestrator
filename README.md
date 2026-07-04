# prism-orchestrator

Parallel adversarial review for a single artifact. One script spawns a panel of budget-capped `claude -p` specialist reviewers, waits for all of them, runs two post-collection challengers, then synthesizes everything into one verdict. A single reviewer gives you one perspective and one set of blind spots. A panel with assigned roles gives you structured disagreement.

Pollock 2026.

## What it does

- **Role-based reviewers, run in parallel.** Each reviewer is a headless `claude -p` agent with a fixed role prompt: security-auditor, performance-analyst, devils-advocate, simplicity-advocate, integration-engineer, code-reviewer, verification-auditor. Prompts live in `prompts/`.
- **Three modes.** `budget` runs 3 reviewers. `standard` runs 5. `extended` runs 7. Standard and extended add two post-collection passes: hurt-locker (blast radius on the collected findings) and wwz (premise challenge).
- **Per-agent budget caps.** Every agent runs under `--max-budget-usd`. Defaults: $0.80 per reviewer, $0.50 hurt-locker, $0.50 wwz, $0.30 brief compiler, $0.50 to $1.00 synthesis depending on mode. `--total-budget-usd` enforces a ceiling on the whole run before anything spawns.
- **Review memory.** Runs archive by slug. On a repeat review of the same slug, a brief compiler summarizes prior findings and feeds them to the reviewers, who must report each prior finding as fixed, still open, or worsened. The devils-advocate never sees the brief, so one seat stays cold.
- **Failure containment.** Timeouts per phase, undersized or budget-exhausted reviewer output replaced with an explicit failure stub, partial resume that skips reviewers with valid output from a prior attempt.
- **Synthesis.** A final agent merges all reviews into `synthesis.md` with a Final Verdict, then the result archives by slug and date.
- **Read-only reviewers.** Reviewers run in plan permission mode against the workspace. Only the brief compiler and synthesis agent get write access, scoped to the run directory.

## Requirements

- bash, `bc`
- The `claude` CLI on PATH. Agents spawn as `claude -p` with `--max-budget-usd`, `--permission-mode`, and `--add-dir`, so you need a version that supports those flags.
- Optional: `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` in `~/.openclaw/.env` for run notifications. Without them, notifications are silently skipped. <!-- commit-leak-scan: allow (path already public in scripts/lib/review-common.sh) -->

## Install

```bash
git clone https://github.com/cogpros/prism-orchestrator.git
```

The script resolves paths from `$WORKSPACE`, which defaults to `~/.openclaw/workspace`, and expects the role prompts at `$WORKSPACE/.claude/skills/prism/prompts`. Put them there (set `WORKSPACE` first if you are not using the default): <!-- commit-leak-scan: allow (path already public in scripts/lib/review-common.sh) -->

```bash
mkdir -p "$WORKSPACE/.claude/skills/prism"
cp -R prism-orchestrator/prompts "$WORKSPACE/.claude/skills/prism/prompts"
```

Run outputs land under `$WORKSPACE/analysis/prism/` (runs, archive).

## First run

Start with a dry run. It prints the reviewer roster and the full cost breakdown without spawning anything:

```bash
./scripts/prism.sh --artifact path/to/design.md --mode standard --dry-run
```

Then run it live:

```bash
./scripts/prism.sh --artifact path/to/design.md --mode standard
```

Read `synthesis.md` in the run directory. That is the deliverable.

## Usage

```bash
# Cheap pass: 3 reviewers, no hurt-locker or wwz
./scripts/prism.sh --artifact design.md --mode budget

# Full panel with a hard ceiling
./scripts/prism.sh --artifact design.md --mode extended --total-budget-usd 8.00

# Re-review under the same slug to activate review memory
./scripts/prism.sh --artifact design-v2.md --slug auth-redesign

# Read the artifact from stdin
cat design.md | ./scripts/prism.sh --artifact -

# Check on a running or finished run
./scripts/prism.sh --status "$WORKSPACE/analysis/prism/runs/<run-dir>"

# List archived reviews
./scripts/prism.sh --list
```

Flags: `--mode budget|standard|extended`, `--opus` or `--haiku` (default model is sonnet), `--max-per-agent-usd` (overrides every per-agent cap), `--total-budget-usd`, `--slug`, `--no-brief` (skip prior-findings brief), `--governance` (findings flagged 3+ times across reviews get marked STUCK in synthesis), `--dry-run`, `--status <dir>`, `--list`.

## How a standard run flows

1. Devils-advocate and the prior-findings brief compiler spawn in parallel.
2. The remaining reviewers spawn once the brief is ready, all in parallel, each with the artifact, the evidence rules, and the brief.
3. All reviewers complete or time out. Bad output gets stubbed so synthesis can't mistake it for a review.
4. Hurt-locker maps blast radius across the collected reviews. Wwz challenges the artifact's premises.
5. Synthesis merges everything into a verdict. The result archives by slug.

## Related

- [hugr-solve](https://github.com/cogpros/hugr-solve) is the decision-stage sibling. PRISM points many reviewer roles at an artifact you already have. Hugr-solve puts two agents in adversarial debate over a decision you have not made yet. Review the artifact here, debate the direction there.
