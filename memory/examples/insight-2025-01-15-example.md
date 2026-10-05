---
type: insight
topic: bounded-retries
project: example-service
confidence: medium
permalink: brain/insights/2025-01-15-bounded-retries
---

# Bounded retries (synthetic example)

All content below is invented to show the note format.

## Pattern / Decision
Every retry loop gets a hard cap and a log line when the cap is hit.

## Why it matters
An unbounded loop turns one bad input into a permanent background cost, and nobody sees it because each attempt looks like normal activity.

## Applies to
Queue consumers, headless agent loops, scheduled jobs that call a paid API.
