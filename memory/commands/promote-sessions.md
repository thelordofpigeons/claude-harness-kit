---
description: Recover orphaned session checkpoints (from crashes or hard closes) into <BRAIN_DIR>/sessions/ and <BRAIN_DIR>/insights/. Reads <BRAIN_DIR>/session-checkpoints/, parses each transcript, writes session and insight notes, archives processed checkpoints.
---

# /promote-sessions

Recover sessions that ended abruptly (crash, shutdown, force close) before the end-of-session ritual could run. The Stop hook (`checkpoint-session.sh`) writes a cheap checkpoint after every turn; this command turns old checkpoints into proper session notes.

`<BRAIN_DIR>` means the memory folder: the `BRAIN_DIR` environment variable, default `~/brain`.

## Steps

1. **List orphaned checkpoints**
   ```bash
   node -e "
     const fs=require('fs'),path=require('path'),os=require('os');
     const root=process.env.BRAIN_DIR||path.join(os.homedir(),'brain');
     const dir=path.join(root,'session-checkpoints');
     if(!fs.existsSync(dir)){console.log('[]');process.exit(0)}
     const cutoff=Date.now()-2*3600*1000;
     const out=[];
     for(const f of fs.readdirSync(dir)){
       if(!f.endsWith('.json'))continue;
       const fp=path.join(dir,f);
       try{
         if(!fs.statSync(fp).isFile())continue;
         const j=JSON.parse(fs.readFileSync(fp,'utf8'));
         const t=Date.parse(j.last_active);
         if(t&&t<cutoff)out.push({...j,checkpoint_file:fp});
       }catch(e){}
     }
     console.log(JSON.stringify(out,null,2));
   "
   ```

2. **For each orphan, in sequence:**
   a. Confirm the transcript file at `transcript_path` exists and is readable.
   b. **Dispatch a `general-purpose` subagent with `model: haiku`** to read the transcript JSONL and produce the session body. Brief the subagent:
      > Read the JSONL transcript at `<transcript_path>`. Extract:
      > - What we built (concrete bullets: file names, function names, named outputs)
      > - Decisions made with rationale (format: "Decision, because reason")
      > - Files changed (exact paths)
      > - Next session entry point (file:line and what to do, or "No active work")
      > - Open threads (unresolved questions, blockers, deferred decisions)
      >
      > Output ONLY the session body (no frontmatter, I will add it).
      > Be concise. If the transcript is short or trivial, say so.
   c. Compute the session file path: `<BRAIN_DIR>/sessions/YYYY-MM-DD-HH.md` from the checkpoint's `last_active` timestamp (date and hour).
   d. If a session file already exists at that path (rare collision), append `-<session_id_short>` to the filename.
   e. Write the session file with this frontmatter:
      ```
      ---
      type: session
      date: YYYY-MM-DD
      task_id: <task_id from the checkpoint, or "none">
      recovered: true
      source: orphan-checkpoint
      ---
      <body from the subagent>
      ```
   f. Ask the same subagent a follow-up: "Did a non-obvious pattern, decision, or architectural insight emerge? If yes, output a single insight in this format: `topic: <kebab-slug>` / `confidence: high|medium|low` / `## Pattern / Decision` / `## Why it matters` / `## Applies to`. If no, reply 'no insight'."
   g. If an insight was returned, write `<BRAIN_DIR>/insights/YYYY-MM-DD-<slug>.md` with proper frontmatter (`type: insight`, `topic`, `project`, `confidence`).
   h. Archive the checkpoint: move the JSON to `<BRAIN_DIR>/session-checkpoints/processed/`.

3. **Report**
   - "Promoted N sessions."
   - "Extracted M insights."
   - "Skipped K (transcript missing)." Move those checkpoints to `processed/orphaned-no-transcript/`.

## Cost guidance

- Each promotion is one Haiku subagent call over one transcript. Recovering a handful of orphans is cheap compared with losing the session knowledge.
- If a transcript is very large, let the subagent summarize in chunks. Do not escalate to a larger model unless the Haiku output is clearly broken.
- The nightly job (`brain-nightly.py`) calls this command headless in at most 5 rounds and stops on the first round that makes no progress.

## Skip rules

- Checkpoints with `last_active` less than 2h ago: leave alone (the session may still be active).
- Checkpoints whose `transcript_path` does not exist: move to `processed/orphaned-no-transcript/`, log a warning, do not call a subagent.
- If the subagent fails twice on the same transcript: write a minimal session note saying "extraction failed; transcript at <path> for manual review" and archive the checkpoint.

## After promotion

If any promoted orphan had an active `task_id`, surface it: "Recovered task <ID> was in progress, check your tracker to confirm its current state."
