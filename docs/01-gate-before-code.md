# 01. The gate before code

**Problem.** A rule in a router file ("always open a tracked task before coding") is prose. Under a long context it gets skipped, and nothing notices.

**Mechanism.** Three layers, each cheaper than the one behind it:

1. `hooks/workflow-gate.sh` (UserPromptSubmit). A regex classifies the prompt: an imperative verb (build, fix, refactor, ...) within a few words of a code noun (endpoint, component, test, ...), and not a question. If it matches, the hook prints an instruction to load the workflow skill. If a task is already active, it prints a resume notice instead. The skill name comes from the `WORKFLOW_SKILL` variable.
2. `hooks/task-gate-reminder.sh` (PreToolUse on Edit and Write). If no task is registered when the agent is about to edit, it reminds once per directory per day. A lock file keeps it from nagging. It is the second enforcement point behind the prompt gate.
3. `templates/skills/task-gate-workflow/SKILL.md`. The protocol itself, loaded only when the gate fires: classify the request, announce the workflow, create or claim a tracker task, then follow the steps for that workflow type (new feature, bug fix, new repository, refactor).

**Task state.** `scripts/task-state.sh` writes small files (`current-task`, `-name`, `-status`, `-step`) that the hooks and `statusline/statusline.mjs` read. The tracker itself is reached only through `agents/tracker.md`, a small-model agent that returns one-line summaries.

**Design choices.**
- The regex skips questions on purpose ("how do you think we could enhance this"). An earlier version fired on opinion requests, which taught the user to ignore it.
- The hook only advises. Blocking would break legitimate edits (configuration, notes). The cost of a skipped nudge is low because layer 2 repeats it.
- There is an explicit escape hatch ("skip workflow").

**What is parameterized.** Skill name (`WORKFLOW_SKILL`), tracker agent (`TRACKER_AGENT`), status lifecycle. The lifecycle in the skill is an example from a team process, kept as a template.

**Limits.** The regex is English-only and heuristic. It can miss a request phrased without a code noun, and it can fire on a prose request that contains both words. Neither case is silent for long: the reminder at edit time catches the first.

See also: [05 hooks as enforcement](05-hooks-as-enforcement.md), `templates/CLAUDE.router.example.md`.
