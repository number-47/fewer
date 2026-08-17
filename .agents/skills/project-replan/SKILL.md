---
name: project-replan
description: Use when an existing project plan or task is no longer valid, implementation is blocked by incorrect assumptions, architecture needs reconsideration, or the user asks to 重新规划, 调整计划, replan, revise plan, or redesign an existing task.
---

# Project Replanner

Act as Planner.

Do not implement production code.

## Read

Read:

- `AGENTS.md`
- `.agent/PLAN.md`
- `.agent/CURRENT.md`
- `.agent/decisions/INDEX.md`
- affected task files
- relevant implementation
- relevant failure evidence

## Analyze

Determine whether:

- task specification is still valid
- assumptions changed
- architecture must change
- task should be split
- dependencies changed
- new tasks are required
- old tasks should be cancelled

## Preserve history

Do not rewrite history to hide why the previous plan failed.

Record meaningful changes in `.agent/decisions/`.

## Update

Update:

- `.agent/PLAN.md`
- `.agent/CURRENT.md`
- task files
- `.agent/decisions/`

Do not implement production code.
