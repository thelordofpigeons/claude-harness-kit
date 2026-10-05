---
description: Print a summary of the current active task by reading the local state files.
---

Print a summary of the current active tracker task by reading the local state files written by `scripts/task-state.sh`.

## Instructions

Read the following state files and print a formatted summary:

```bash
H="${CLAUDE_HOME:-$HOME/.claude}"
TASK_ID=$(cat "$H/current-task" 2>/dev/null | tr -d '[:space:]')
TASK_NAME=$(cat "$H/current-task-name" 2>/dev/null | tr -d '\r')
TASK_STATUS=$(cat "$H/current-task-status" 2>/dev/null | tr -d '\r')
TASK_STEP=$(cat "$H/current-task-step" 2>/dev/null | tr -d '\r')
TASK_START=$(cat "$H/current-task-start" 2>/dev/null | tr -d '\r')
TASK_DUE=$(cat "$H/current-task-due" 2>/dev/null | tr -d '\r')
```

### If there is no active task (`current-task` file missing or empty)

Print:

```
No active task.
Use your start command (<cmd>) to claim or create a task.
```

Also check `$H/shipped-log` and show the last 3 shipped tasks if the file exists:

```bash
tail -3 "$H/shipped-log" 2>/dev/null
```

Each line has the format `TIMESTAMP|TASK_ID|TASK_NAME`. Print each as:

```
Recent shipped:
  [TASK_NAME] (TASK_ID), shipped at TIMESTAMP
```

### If an active task exists, print this block

```
----------------------------------------
  Active Task
----------------------------------------
  ID      : <TASK_ID>
  Name    : <TASK_NAME>
  Status  : <TASK_STATUS>
  Step    : <TASK_STEP>
  Started : <TASK_START>
  Due     : <TASK_DUE>
  URL     : <TRACKER_URL_BASE>/<TASK_ID>
----------------------------------------
```

Use the actual values from the files in place of the placeholders. `<TRACKER_URL_BASE>` is the base URL of your tracker's task pages; drop the line if you do not want it. If a file is missing or empty, show `-` for that field.

Do NOT call any tracker API or MCP tool. Read only from the local state files.
