---
name: stop-time
description: Stop the running time tracker.
argument-hint: "description"
disable-model-invocation: true
allowed-tools: Bash(/d/projects/timer/timer/t:*)
---

Run `/d/projects/timer/timer/t stop "<description>"`, where the description is the arguments given (`$ARGUMENTS`), or omit it if none were given. The script stops whichever timer is running, so no project is needed.

Reply with the script's output only.
