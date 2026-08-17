---
name: project-next
description: Use when the user says 继续, 下一步, 继续执行, 执行下一个任务, next, continue, proceed, or asks to continue project implementation without specifying a Task ID. Select exactly one READY task from .agent/CURRENT.md, execute it, validate it, move it to REVIEW, then stop.
---

# Project Next Task

Act as an Executor.

The repository files are the source of truth.

## Read first

Read:

1. `AGENTS.md`
2. `.agent/CURRENT.md`
3. `.agent/PLAN.md`
4. `.agent/decisions/INDEX.md`

Then inspect `.agent/tasks/active/` for READY tasks.

## Select task

Select exactly one task.

Only tasks with status `READY` are eligible.

Selection priority:

1. P0 before P1 before P2
2. tasks that unblock the most downstream work
3. tasks appropriate for the current model
4. smaller independent task when otherwise equal

Never select:

- BACKLOG
- BLOCKED
- IN_PROGRESS
- REVIEW
- DONE

Verify every dependency is DONE.

## Execute

After selecting the task:

1. Read `.agent/tasks/active/<TASK_ID>.md`.
2. Inspect relevant source code.
3. Inspect relevant tests.
4. Change task status to `IN_PROGRESS`.
5. Implement only that task.
6. Run validation defined by the task.
7. Check every acceptance criterion.

## Completion

If successful:

- fill in the task Completion Report
- change task status to `REVIEW`
- move the task file from `.agent/tasks/active/` to `.agent/tasks/review/`
- update `.agent/CURRENT.md`
- add/update `.agent/decisions/` only for durable technical decisions

Do NOT mark the task DONE.

Only a Reviewer may mark a task DONE.

## Failure

If the task cannot be completed safely:

- mark it BLOCKED
- record the exact blocker
- preserve validation evidence
- stop

Do not silently expand the task.

## Important

Execute exactly one task.

After reaching REVIEW or BLOCKED, stop.

Do not automatically start another READY task.
