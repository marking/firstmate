#!/usr/bin/env bash
# Kiro stop-hook adapter for the firstmate PRIMARY turn-end guard.
#
# Kiro stop hooks are passive: exit code does not block the turn from ending.
# This adapter uses the shared primary-scoped predicate in fm-turnend-guard.sh.
# When that predicate says the primary would end blind (exit 2), the adapter
# forces one same-session follow-up by running `kiro-cli chat --resume-id`
# with a guard instruction. FM_KIRO_TURNEND_GUARD_ACTIVE is the loop guard:
# the nested turn's own stop hook exits without spawning another nested turn.
#
# The stop hook receives JSON on stdin with:
#   { "hook_event_name": "stop", "cwd": "...", "assistant_response": "..." }
# KIRO_SESSION_ID is available in the environment.
#
# This script is intended for use in a workspace-local .kiro/agents/ config
# as the primary firstmate session's stop hook. It is NOT used by crewmate
# spawns (those use the simpler `touch .turn-ended` hook in fm-crew.json).
set -u

# Loop guard: if we're already inside a guard-forced continuation, allow stop.
[ -z "${FM_KIRO_TURNEND_GUARD_ACTIVE:-}" ] || exit 0

# Consume stdin (the hook payload).
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# Resolve firstmate root from this script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR%/bin}"
[ -x "$ROOT/bin/fm-turnend-guard.sh" ] || exit 0

# Need jq to build the predicate's expected input.
command -v jq >/dev/null 2>&1 || exit 0

# Need a session ID to resume.
SESSION_ID="${KIRO_SESSION_ID:-}"
[ -n "$SESSION_ID" ] || exit 0

# Build the payload that fm-turnend-guard.sh expects (it reads stop_hook_active
# for the loop guard). We pass stop_hook_active=false since this is our first
# check this turn.
GUARD_INPUT=$(jq -n '{stop_hook_active: false}')

# Run the shared predicate.
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-kiro.XXXXXX") || exit 0
trap 'rm -f "$ERR"' EXIT

printf '%s' "$GUARD_INPUT" | "$ROOT/bin/fm-turnend-guard.sh" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] || exit 0

# Turn would end blind. Force one follow-up.
REASON=$(cat "$ERR" 2>/dev/null || true)
[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'

FM_KIRO_TURNEND_GUARD_ACTIVE=1 \
  kiro-cli chat --resume-id "$SESSION_ID" \
    --trust-all-tools \
    "TURN WOULD END BLIND - supervision is off. Repair missing watcher supervision according to the session-start operating block before ending the turn.

$REASON" >/dev/null 2>&1 || true
