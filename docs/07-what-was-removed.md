# 07. What was removed, and why

This kit is extracted from a larger, daily-used harness. The real one has more than is shown here, and unlisted items were excluded on purpose. Categories only; no names of employers, clients or projects appear in this repository, and no counts.

| Category | What it covers | Treatment |
|---|---|---|
| Employer process | tracker workspace, space, list and task IDs; team member tables and user IDs; the status lifecycle as a company process; deploy-platform app IDs and permission rules | kept only as parameterized TEMPLATE files with placeholders (`agents/tracker.md`, `templates/skills/task-gate-workflow`, `templates/platform-example/`), or dropped |
| Client and project material | commands, knowledge bases and catalogues tied to specific products or customers | dropped |
| Employer branding | branded document and presentation tooling with fonts, logos and sample assets | dropped |
| Personal items | personal rituals, machine clean-up, hobby and personal-assistant material, personal diagnostics scripts | dropped |
| Third-party authored skills and commands | design-pattern packs, community prompt tools, vendor-synced document skills, plugin bundles, anything with an origin tag, an external license or a publisher metadata block | not copied. Where provenance was unclear, the item was excluded and listed here by category |
| Credential-handling code | the usage-limits block of the status line, which read an OAuth token to call a usage endpoint | removed, not gated behind a flag |
| Local settings | the real settings file (plugins, marketplaces, model, environment, permission rules), local overrides, task state files | replaced by a hand-written `settings.example.json` |
| Private design history | a personal taste file, a design log, research notes | dropped; the design agent and protocol accept an optional user-supplied taste file instead |
| Brain content | session notes, insight notes, rebuilt summaries, digests, logs, raw captures, human-only notes, checkpoints, sync-conflict copies, scheduled-task definitions | dropped; only scripts, empty templates and two synthetic examples ship |
| Registry-writing hook | a notification hook that writes a registry key to register a toast identity | omitted; Windows-only and not needed for the agentic patterns |
| Backups and caches | backup copies, caches, compiled files, logs | dropped |

**Scrubbing applied to what did ship.**
- Absolute user paths replaced by `~`, `$HOME` or an environment variable.
- Dated incident comments, run counts and ports from real incidents rewritten as the generic lesson.
- Dashes (U+2013, U+2014), emoji and byte-order marks removed; LF line endings.
- Public open-source tools (node, prettier, eslint, tsc, Drizzle, pytest, Basic Memory, the Chrome DevTools Protocol) and the hosting CLI used in the labeled example are named; everything else that was a proper noun was treated as suspect.

**How this is checked.** `tools/hygiene/` holds a leak scanner and a dash and encoding scanner, with tests that plant leaks at runtime and prove the scanners catch them. `tools/hygiene/check_all.sh` runs them with the self-tests. The scanner's private denylist is kept outside the repository folder, so copying or zipping the folder cannot ship it.

**What this does not guarantee.** Scanners find patterns. The first line of defense was reading every copied file by hand and defaulting to exclusion when unsure.
