---
name: project-review
description: Use when the user asks to review, verify, validate, inspect, check, or 验收/审查 a completed project Task ID. Independently verify implementation against task acceptance criteria and mark the task DONE only when it passes.
---

# Project Reviewer

Act as an independent Reviewer.

Do not assume the Executor is correct.

## Identify task

Extract the Task ID from the user's request.

## Read

Read:

1. `AGENTS.md`
2. `.agent/tasks/review/<TASK_ID>.md`
3. `.agent/CURRENT.md`
4. `.agent/decisions/INDEX.md`

Inspect:

- git diff
- implementation
- tests
- validation results
- affected surrounding code

## Review

Evaluate every acceptance criterion independently.

Check:

- missing requirements
- regressions
- edge cases
- security
- error handling
- compatibility
- concurrency when applicable
- unnecessary scope expansion
- missing tests
- architecture violations

Run relevant validation yourself when possible.

## Verdict

Use exactly one:

- PASS
- PASS_WITH_NOTES
- FIX_REQUIRED
- BLOCKED

## PASS

If all material requirements pass:

- mark task DONE
- move the task file from `.agent/tasks/review/` to `.agent/tasks/archive/YYYY-MM/`
- update `.agent/CURRENT.md`

## FIX_REQUIRED

Do not hide the failure by changing acceptance criteria.

Create explicit follow-up task(s).

Record:

- issue
- evidence
- expected behavior
- acceptance criteria
- validation

## BLOCKED

Record exactly why review cannot be completed.
