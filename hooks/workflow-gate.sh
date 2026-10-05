#!/bin/bash
# workflow-gate.sh: UserPromptSubmit hook.
# TEMPLATE: parameters WORKFLOW_SKILL (skill to load, default "workflow"),
#           HARNESS_TASK_FILE (active task id file, default ~/.claude/current-task).
#
# Detects code-creating/modifying requests and tells the model to invoke the
# workflow skill, which loads the full protocol on demand. Why a hook: prose
# rules in a router file (CLAUDE.md) get skipped, so a mechanical nudge fires on
# every prompt instead. The hook only prints text; it never blocks.

SKILL="${WORKFLOW_SKILL:-workflow}"
TASK_FILE="${HARNESS_TASK_FILE:-$HOME/.claude/current-task}"

# node runtime (consolidated across all hooks, python is not a dependency)
PROMPT=$(cat | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{process.stdout.write(JSON.parse(d).prompt||'')}catch(e){}})" 2>/dev/null || echo "")

# Questions and opinion requests are not code requests: skip the gate when the
# prompt opens with an interrogative or asks what the model thinks. An earlier
# version fired on "how do you think we can enhance this setup" because the
# sentence contained an imperative-looking verb.
if echo "$PROMPT" | grep -qiE "^\s*(how|what|why|which|when|where|who|should|could|would|can|is|are|do|does|did|explain|tell me|check|audit|review|compare|assess|evaluate)\b|\b(what do you think|how do you think|your opinion|any thoughts|thoughts on)\b"; then
  exit 0
fi

# Detect code-related requests: an imperative verb followed by an object (not the bare verb alone)
if echo "$PROMPT" | grep -qiE "\b(build|create|implement|write|fix|refactor|add|develop|debug|resolve|repair|set ?up|scaffold|integrate|migrate|upgrade|optimize)\b.{0,40}\b(feature|repo|project|component|endpoint|route|api|service|page|screen|module|function|method|class|hook|command|script|tool|cli|app|system|pipeline|bug|error|test|tests|migration|schema|model|controller|query|view|form|table|job|worker|handler|middleware|package|library|dependency|typescript|python|code)\b|\bnew (feature|repo|project|component|endpoint|api|service|page|module|function|class|hook|command|script|tool|cli|app|system|pipeline)\b"; then

  if [ -f "$TASK_FILE" ] && [ -s "$TASK_FILE" ]; then
    TASK_ID=$(tr -d '[:space:]' < "$TASK_FILE")
    echo "WORKFLOW CONTEXT: Active tracked task: ${TASK_ID}. You are mid-workflow. Identify which step you are on (per the ${SKILL} skill) and continue from there. Do not restart."
  else
    echo "WORKFLOW GATE: Code-creation or modification request detected."
    echo "MANDATORY: Invoke the \`${SKILL}\` skill via the Skill tool BEFORE any code action."
    echo "The skill loads the four-workflow protocol (New Feature / Bug Fix / New Repository / Refactor) and the tracked-task gating rules."
    echo "Skip the skill ONLY if the user said 'skip workflow' / 'no workflow'."
  fi
fi
exit 0
