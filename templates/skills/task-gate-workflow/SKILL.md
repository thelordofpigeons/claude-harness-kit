---
name: task-gate-workflow
description: Use when starting any coding task: build, create, implement, add, fix, refactor, debug, migrate, scaffold or set up something code-related. Loads the four-workflow protocol (New Feature, Bug Fix, New Repository, Refactor) with a mandatory task-tracker gate. Invoke BEFORE any code action. Skip if the user says "skip workflow" or "no workflow", or if the work is configuration of the harness itself.
---

TEMPLATE: parameterized, originally written for one team's tracker.
Parameters: `<TRACKER_AGENT>` (the agent from `agents/tracker.md`, default name `tracker`), `<ASSIGNEE>`, the status lifecycle below (an example), and `WORKFLOW_SKILL` (set it to `task-gate-workflow` so `hooks/workflow-gate.sh` loads this skill, or rename the skill to `workflow`).
Roles such as architect, planner, test-first, reviewer and verification-loop are role names, not skills this kit ships. Back each one with a skill, an agent or a prompt of your own.

# Workflow Protocol

> Every coding request triggers a mandatory workflow. Follow the steps in order. Do not write code before passing the gate.

## Step 1: Classify

| Request type | Workflow |
|---|---|
| New feature, new capability, new component, new endpoint | Workflow 1 (New Feature) |
| Bug, error, crash, regression, test failure | Workflow 2 (Bug Fix) |
| New project, new repo, new service from scratch | Workflow 3 (New Repository) |
| Cleanup, dead code, performance, restructuring existing code | Workflow 4 (Refactor) |

## Step 2: Announce

Say: "This is a [type]. I'll follow Workflow [N]."

## Step 3: Create the tracker task (MANDATORY before any code)

1. Delegate to the `<TRACKER_AGENT>` agent: search for an existing task first.
2. Create or claim the task, assign it to `<ASSIGNEE>`, set DOING.
3. After the agent returns the task ID and name, register the active task so the status line shows the name and status, not just the ID:
   ```bash
   bash ~/.claude/scripts/task-state.sh init "TASK_ID" "TASK_NAME"
   ```
   Defaults: status `DOING`, step `task_created`, due `+7d`. Override with positional arguments 3 to 5. The helper keeps `${CLAUDE_HOME:-~/.claude}/current-task{-name,-status,-step,-start,-due}` in sync, the same files the status line reads.
4. Do not call Edit or Write for implementation until this step is done.

**Exception:** if the user explicitly says "skip workflow" or "no workflow", skip Step 3 only. Still follow every other step.

### Status lifecycle (example, configurable)

`TODO -> DOING -> REVIEW -> VERIFY -> DONE`

One status is the only Done status (here `DONE`). `BLOCKED` is a side status. Keep the step names passed to `task-state.sh` (`task_created`, `in_review`, `testing`) in sync with the map in `statusline/statusline.mjs`.

---

## Workflow 1: New Feature

```
0. [optional, complex or ambiguous features only] brainstorm
   -> clarify what is actually being built before investing in design

1. [role: architect] "what you're building"
   -> system design, tech choices, module breakdown

2. [role: planner] "one-line goal"
   -> step-by-step build plan

2a. search for existing solutions (package registries, MCP servers, repos)
    before writing custom code

2b. [conditional] parallel orchestration
    - 2 or 3 fully independent plan tasks: run them as parallel agents,
      one disjoint file set each, cap concurrency at 3 or 4
    - more than that: batch them in waves

3. WORKFLOW GATE: create the tracker task (Step 3 above)
   -> bash ~/.claude/scripts/task-state.sh init "TASK_ID" "TASK_NAME"

4. [role: test-first] write the failing tests from the plan, then implement
   - target is an LLM or agent loop: add a sandbox-mode test that avoids the
     live model round-trip

4a. [conditional, UI components] run the ui-protocol skill
    (templates/skills/ui-protocol)

5. Implement following the plan
   [conditional, 5 or more plan tasks] delegate each task to a fresh subagent
   with a two-stage review per task
   [conditional] language-specific reviewer for the languages touched

6. [simplify pass] parallel agents for reuse, quality and efficiency; fix
   what they find

7. [role: verification-loop] build -> types -> lint -> tests -> security scan
   -> diff review. The loop is run by a separate agent or command, not by the
   agent that wrote the code.
   [conditional, touching auth, user input, APIs or secrets] add a security reviewer

8. [conditional, user-facing UI] generate and run end-to-end tests for the
   critical flows

9. [role: reviewer] final review, PR description, merge-readiness checklist

10. Delegate to the tracker agent: status -> REVIEW, attach the PR link
    -> bash ~/.claude/scripts/task-state.sh status REVIEW in_review

11. [role: doc-update] update the README and the relevant documentation

12. Delegate to the tracker agent: status -> VERIFY
    -> bash ~/.claude/scripts/task-state.sh status VERIFY testing

13. Delegate to the tracker agent: status -> DONE, then:
    bash ~/.claude/scripts/task-state.sh shipped
```

---

## Workflow 2: Bug Fix

```
0. Read the insights file of the memory scaffold (memory/) if you keep one.
   Past incidents often recur. If a relevant insight applies, mention it
   before reproducing.

1. WORKFLOW GATE: delegate to the tracker agent to search for an existing bug
   ticket, then create or claim the task
   -> bash ~/.claude/scripts/task-state.sh init "TASK_ID" "TASK_NAME"

2. Debug systematically: reproduce -> isolate -> hypothesize -> implement the
   fix -> verify. Write a failing test for the bug first.

2a. [conditional, UI bug of the kind "each part is correct, the final state is
    wrong"] audit the click path end to end: map every state-store side effect
    triggered by the interaction, so functions that work alone but cancel each
    other out get caught.
    Symptoms that trigger this: "button does nothing", "fires twice", "wrong
    final state after clicking", "agent skips a tool some of the time".

3. If the build is broken, run the build-error resolver for the language.

4. [simplify pass]

5. [role: verification-loop] build -> types -> lint -> tests -> security scan
   -> diff review; confirm the bug is resolved and nothing regressed

6. [role: reviewer] final review and PR description

7. Tracker: status -> REVIEW, attach the PR link
   -> bash ~/.claude/scripts/task-state.sh status REVIEW in_review

8. Tracker: status -> VERIFY
   -> bash ~/.claude/scripts/task-state.sh status VERIFY testing

9. Tracker: status -> DONE, then:
   bash ~/.claude/scripts/task-state.sh shipped
```

---

## Workflow 3: New Repository

```
1. [role: architect] "what you're building"
   -> system design, tech choices, module breakdown

1a. Record the key technology choices as short decision records before
    committing to implementation.

1b. [conditional, repo will call an LLM API or run agent loops] design in
    caching, model routing and tool-space limits from day one.

2. [role: planner] "one-line goal"
   -> step-by-step build plan with the full file structure

2a. Search for existing libraries, templates and MCP servers before building
    from scratch.

2b. [conditional] if 2 or more plan tasks are fully independent, run them as
    parallel agents.

3. WORKFLOW GATE: create the tracker task
   -> bash ~/.claude/scripts/task-state.sh init "TASK_ID" "TASK_NAME"

4. Create the repository (private by default).

4a. [optional] CI/CD setup step. Platform-specific and not part of the
    generic protocol. templates/platform-example/ shows one hosting platform
    as a labeled example.

5. Implement following the plan.

6. [simplify pass]

7. [role: verification-loop]

8. [role: security-reviewer]: always run on the first push, so issues are
   caught before they enter git history.

9. [role: reviewer]

10. [role: doc-update]: README, CLAUDE.md, a short onboarding guide.

11. Commit and push.

12. Tracker: status -> DONE, then:
    bash ~/.claude/scripts/task-state.sh shipped
```

---

## Workflow 4: Refactor / Cleanup

```
0. Read the insights file of the memory scaffold if you keep one. Many
   refactors recreate problems documented in past insights.

1. WORKFLOW GATE: create the tracker task
   -> bash ~/.claude/scripts/task-state.sh init "TASK_ID" "TASK_NAME"

2. Dead-code analysis with the language's usual tools (unused exports,
   unused dependencies, duplicates).

2a. [conditional, target is an LLM or agent pipeline] check that caching
    behavior and the test harness survive the refactor. Refactoring agent
    loops without this is how caching regresses silently.

3. Review and apply the suggestions.

4. [simplify pass]

5. [role: reviewer] language-specific reviewer for the languages touched,
   otherwise a general code reviewer.

6. [role: verification-loop] build -> types -> lint -> tests -> diff review

7. [role: reviewer] final review and PR description.

8. Tracker: status -> DONE, then:
   bash ~/.claude/scripts/task-state.sh shipped
```
