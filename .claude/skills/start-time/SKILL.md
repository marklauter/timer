---
name: start-time
description: Start the time tracker for the current project.
disable-model-invocation: true
allowed-tools: Bash(/d/projects/timer/timer/t:*), Bash(git remote get-url origin)
---

Start the timer with `/d/projects/timer/timer/t start <owner/repo> "<description>"`.

Arguments: $ARGUMENTS. If an `owner/repo` is among them, that's the project and the rest is the description. Otherwise all of it is the description (it may be empty) and the project comes from `git remote get-url origin` in the working directory. If there's no repo, no origin, or the location could mean several repos (such as a container folder), ask the user which project to use. Don't guess.

Reply with the script's output only.
