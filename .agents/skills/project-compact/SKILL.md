---
name: project-compact
description: Use when the user asks to compact, archive, or converge project planning state to keep .agent hot files small, e.g. 归档, 收敛, 压缩计划, compact, archive state. Moves completed tasks to archive and trims completed milestones and decisions from hot files without rewriting history.
---

# Project Compact

Act as the Orchestrator / Archivist.

Keep hot files small. Preserve history in `archive/`.

## Read first

Read:

1. `AGENTS.md`
2. `.agent/CURRENT.md`
3. `.agent/PLAN.md`
4. `.agent/decisions/INDEX.md`
5. `.agent/tasks/review/` and `.agent/tasks/active/`

## Compact

### Tasks

- Move `DONE` and `CANCELLED` tasks from `.agent/tasks/review/` to `.agent/tasks/archive/YYYY-MM/`.
- Do not move `READY`, `IN_PROGRESS`, `REVIEW`, or `BLOCKED` tasks.

### Plan

- Remove completed milestone details from `.agent/PLAN.md`, replacing them with a short summary and a pointer to `.agent/tasks/archive/`.
- Do not delete historical task files.

### Decisions

- Move `superseded` decisions from `.agent/decisions/` to `.agent/decisions/archive/`, then update `.agent/decisions/INDEX.md`.

### Current state

- Remove DONE tasks from `.agent/CURRENT.md`.
- Keep `CURRENT.md` to a few tens of lines.

## Do not

- Do not rewrite history to hide failures or cancelled work.
- Do not delete task or decision files; move them to `archive/`.
- Do not touch production code or unrelated dirty changes.
