---
name: recall
description: Search the memory folder (sessions, insights, TELOS, raw notes) for a topic and return the relevant notes with dates and wikilinks. Use when the user asks "what do we know about X", "any insights on Y", "when did we decide Z", or types /recall <topic>. Uses the basic-memory MCP; falls back to ripgrep.
---

# /recall <topic>

The memory folder (`<BRAIN_DIR>`, default `~/brain`) is plain markdown, optionally indexed by Basic Memory (MCP server `basic-memory`). This skill is the read path. Nothing is written.

## Steps

1. **Search** with the `basic-memory` MCP: `search_notes` with the user's topic. If the topic is a person, project or file name, also try `build_context` on the best-matching note's `memory://` URL to pull its linked neighbours one hop out.
2. **Fallback** if the MCP is unavailable or returns nothing: run
   ```
   rg -il --glob '*.md' '<topic>' <BRAIN_DIR>/sessions <BRAIN_DIR>/insights <BRAIN_DIR>/telos <BRAIN_DIR>/raw
   ```
   then read the frontmatter plus the matching lines (with 2 lines of context) of the top 8 files by date, newest first. Never load whole session files unless the user asks.
3. **Never** read `<BRAIN_DIR>/telos/sensitive/*` unless the user's current message explicitly asks for that topic.
4. **Answer** in this shape:
   - one paragraph: what the notes say, newest fact first, with the date of each claim
   - bullets: the notes it came from as `[[YYYY-MM-DD-slug]]` wikilinks (the file stem), one line each
   - one line: what is NOT in the notes about this topic, if the question implied it
5. If the user asks a follow-up, stay on the same notes. Do not re-search unless the topic changes.

## Writing back

If the recall surfaces a durable fact that belongs in TELOS, or a pattern that recurs across 2 or more sessions, say so in one line and suggest saving it through your normal session-end step. Do not write to the memory folder from this skill.
