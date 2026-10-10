---
name: adjust-time
description: Add a correction entry (± minutes with a reason) to the time ledger.
disable-model-invocation: true
allowed-tools: Bash(/d/projects/timer/timer/t:*), Bash(git remote get-url origin)
---

Run `/d/projects/timer/timer/t adjust <±minutes> "<reason>" <owner/repo>`.

Arguments: $ARGUMENTS. Get the minutes and reason from them, converting hours to minutes if needed (e.g. "-1.5h" is -90). Both are required; ask for whichever is missing. If an `owner/repo` is among the arguments, that's the project. Otherwise take it from `git remote get-url origin` in the working directory. If there's no repo, no origin, or the location could mean several repos (such as a container folder), ask the user which project to use. Don't guess.

Reply with the script's output only.
