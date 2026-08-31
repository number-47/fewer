---
name: project-workflow
description: Use for Fewer project planning, replanning, autonomous runs, continue/next requests, execution or review of a Txxx task, and project-state compaction. Route all of these modes through the single .agent task state.
---

# Project Workflow

Read `AGENTS.md`, `.agent/README.md`, `.agent/PROJECT.md`, relevant accepted decisions, and affected task files before acting. Task files are the state source; do not recreate separate status tables.

Use these modes, including their matching natural-language requests:

- `plan <objective>`: clarify and inspect first, then create only `PENDING` tasks and update `PROJECT.md`; do not implement product code.
- `replan [Txxx] <reason>`: preserve prior evidence, revise invalid tasks or dependencies, and update `PROJECT.md`; do not implement product code.
- `next`: select exactly one dependency-satisfied `PENDING` task, preferring P0 then downstream impact; complete its implementation, main-conversation acceptance, and state transition, then stop.
- `task Txxx`: refuse execution when the task is not `PENDING`/`IN_PROGRESS` or has unfinished dependencies; otherwise execute, accept, and transition only that task.
- `review Txxx`: inspect an `IN_PROGRESS` task's diff, acceptance criteria, and validation evidence. On pass, record evidence, set `DONE`, and archive it immediately. On a required fix, keep `IN_PROGRESS` and state the concrete correction. On an external or safety blocker, set `BLOCKED` with evidence and a clear `解除条件`.
- `run [objective]`: plan first only when the objective is new or tasks are insufficient. Re-read task files after every transition; continue independent executable work after a blocked task. Stop only when the objective is complete, all remaining work needs an external condition, or a safety/permission boundary requires user action.
- `compact`: keep `PROJECT.md` concise and ensure terminal tasks are under `tasks/archive/YYYY-MM/`; never delete historical evidence.

Before implementation, verify dependencies, read the task, inspect relevant code and tests, and set it `IN_PROGRESS`. Main conversation owns planning, `.agent` state writes, and acceptance. Delegate ordinary scoped development to `implementer`; use `batch_worker` only for fixed, mechanical, easily reversible work. Give every delegated task its goal, scope, prohibited changes, acceptance criteria, and validation commands. Do not allow overlapping writable scopes.

After implementation, run the task's minimum sufficient validation and check every acceptance criterion. A pass becomes archived `DONE`; a fix remains `IN_PROGRESS`; a direct blocker becomes `BLOCKED` with evidence and a clear `解除条件`; a cancelled task records its reason and becomes archived `CANCELLED`. Retry the same failure class at most twice without new evidence, then block it. `PENDING` dependency status is derived from archived `DONE` tasks and is never manually promoted.
