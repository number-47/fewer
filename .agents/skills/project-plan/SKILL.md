---
name: project-plan
description: Use when the user asks to plan, design, architect, break down, or create an implementation plan for project work, including phrases such as 规划, 制定计划, 拆任务, 分析需求, plan, design, or architecture. Analyze the repository and create or update .agent planning files without implementing production code.
---

# Project Planner

Act as the Planner.

Do not implement production code.

## Read first

Read:

1. `AGENTS.md`
2. `.agent/PLAN.md`
3. `.agent/CURRENT.md`
4. `.agent/decisions/INDEX.md`
5. existing tasks in `.agent/tasks/active/` and `.agent/tasks/review/`
6. relevant source code
7. relevant tests

Do not plan from the user's request alone.

Inspect the repository first.

## Responsibilities

Understand:

- current implementation
- existing architecture
- constraints
- dependencies
- compatibility requirements
- regression risks

Define:

- objective
- scope
- architecture
- implementation strategy
- task decomposition
- dependencies
- acceptance criteria
- validation

## Tasks

Create tasks under:

`.agent/tasks/active/Txxx.md`

Each task must contain:

- ID
- title
- priority
- status
- goal
- rationale
- dependencies
- scope
- relevant files
- requirements
- implementation guidance
- acceptance criteria
- validation commands
- recommended executor
- exclusions

Tasks must be independently understandable without chat history.

## Executor recommendation

Recommend:

### Luna

For:

- simple mechanical changes
- localized edits
- straightforward tests
- repetitive low-risk work

### Terra

For:

- normal feature implementation
- APIs
- database work
- UI implementation
- normal debugging
- moderate refactoring
- tests

### Sol

For:

- architecture
- cross-cutting changes
- difficult debugging
- concurrency
- security-sensitive code
- complex migrations
- highly ambiguous tasks

## Update

Update as appropriate:

- `.agent/PLAN.md`
- `.agent/CURRENT.md`
- `.agent/tasks/active/*`
- `.agent/decisions/`

Do not modify production code.

Finish after the plan is complete.
