---
name: project-execute
description: Use when the user explicitly asks to implement or execute a specific project Task ID such as T001, T017, or T103. Execute exactly the specified task according to .agent/tasks and do not implement unrelated tasks.
---

# Project Task Executor

Act as an Executor.

Extract the Task ID from the user's request.

Example:

`执行 T017`

means:

Task ID = `T017`

## Read

Read:

1. `AGENTS.md`
2. `.agent/CURRENT.md`
3. `.agent/tasks/active/<TASK_ID>.md`
4. `.agent/decisions/INDEX.md`
5. relevant source code
6. relevant tests

## Preflight

Verify:

- task exists
- task is READY or IN_PROGRESS
- dependencies are DONE
- no unresolved blocker exists

If dependencies are incomplete, do not execute.

## Scope

Implement exactly the assigned task.

Do not:

- implement another task
- perform unrelated refactoring
- redesign architecture
- weaken acceptance criteria
- remove tests to make validation pass

## Validation

Run all validation defined by the task.

Evaluate every acceptance criterion.

## Successful completion

When implementation and validation succeed:

- update Completion Report
- change status to REVIEW
- move the task file from `.agent/tasks/active/` to `.agent/tasks/review/`
- update `.agent/CURRENT.md`

Do NOT mark DONE.

Reviewer owns DONE.

## Failure

If unable to complete safely:

- mark BLOCKED
- record exact reason
- stop
