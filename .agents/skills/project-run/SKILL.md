---
name: project-run
description: Use when the user asks to 自动完成, 自动执行, 完成整个计划, 持续执行直到完成, run the project, execute the whole plan, complete the milestone, or otherwise wants implementation to continue autonomously without requiring manual prompts between tasks. Orchestrate Planner, Executor, and Reviewer subagents until the current objective is complete or a genuine external blocker prevents further progress.
---

# Autonomous Project Orchestrator

Act as the parent Orchestrator.

Your job is coordination.

Do not stop after completing one task.

Do not ask the user to type "继续".

Continue automatically until reaching a terminal condition.

## Core ownership rule

The Orchestrator owns coordination state:

- `.agent/CURRENT.md`
- `.agent/PLAN.md`
- `.agent/tasks/`
- `.agent/decisions/`

Subagents should return results to the Orchestrator.

Avoid allowing multiple subagents to modify coordination state concurrently.

---

# Phase 1 — Load state

Read:

1. `AGENTS.md`
2. `.agent/CURRENT.md`
3. `.agent/PLAN.md` if it exists
4. active task metadata

Do not read archives by default.

---

# Phase 2 — Determine whether planning is required

Planning is required when:

- no current plan exists
- the user supplied a new objective
- the existing objective materially changed
- no executable tasks exist but work remains
- implementation evidence invalidates a planning assumption

When planning is required:

spawn the `planner` agent.

Give it:

- the user's objective
- current project state
- relevant repository context
- existing plan when applicable

Wait for the Planner.

After receiving its result:

the Orchestrator must write/update:

- `.agent/PLAN.md`
- `.agent/CURRENT.md`
- `.agent/tasks/active/Txxx.md`
- `.agent/decisions/*` where appropriate

Then continue automatically.

Do not return control to the user.

---

# Phase 3 — Execution loop

Repeat the following loop.

## Step A — Process reviews first

If `.agent/tasks/review/` contains tasks:

select the highest priority review task.

Spawn the `reviewer` agent.

Wait for its result.

### PASS

If verdict is PASS:

- mark the task DONE
- move it to `.agent/tasks/archive/YYYY-MM/`
- remove it from CURRENT.md
- activate newly unblocked tasks
- continue the loop

### PASS_WITH_NOTES

Treat as PASS.

If useful, create optional BACKLOG tasks.

Continue the loop.

### FIX_REQUIRED

Create one or more explicit fix tasks under:

`.agent/tasks/active/`

Do not weaken the original acceptance criteria.

Update CURRENT.md.

Continue the loop automatically.

### BLOCKED

Determine whether replanning can resolve the blocker.

If yes:

spawn the Planner.

Update plan/tasks.

Continue.

If no:

record the blocker and evaluate terminal conditions.

---

## Step B — Activate dependencies

Inspect active tasks.

For every BACKLOG task:

if all dependencies are DONE:

change it to READY.

Update CURRENT.md.

---

## Step C — Select one READY task

Select exactly one READY task using:

1. P0 before P1 before P2
2. tasks that unblock downstream work
3. dependency order
4. recommended executor suitability

Do not start multiple write-heavy tasks in parallel by default.

---

## Step D — Select Executor

Use task recommendation.

If:

`Recommended Executor: Luna`

spawn:

`executor_luna`

If:

`Recommended Executor: Terra`

spawn:

`executor_terra`

If the task genuinely requires Sol-level implementation reasoning,
spawn an appropriate high-reasoning agent if configured.

Before spawning:

set task state:

READY -> IN_PROGRESS

Update CURRENT.md.

---

## Step E — Execute

Give the Executor:

- full task specification
- referenced decisions
- relevant constraints

Wait for completion.

Do not ask the user anything between tasks.

---

## Step F — Handle Executor result

### SUCCESS

Update the task Completion Report.

Set:

IN_PROGRESS -> REVIEW

Move:

`.agent/tasks/active/Txxx.md`

to:

`.agent/tasks/review/Txxx.md`

Update CURRENT.md.

Immediately continue the loop.

The next loop iteration should review the task.

### FAILURE

Determine whether the failure is local and retryable.

If retryable:

allow at most 2 implementation attempts for the same failure class.

After each attempt:

run validation again.

If still failing:

invoke Planner for targeted replanning.

### BLOCKED

Determine whether the blocker is:

- planning error
- implementation issue
- external dependency
- permission restriction
- missing user-only information

If it can be resolved by repository analysis or replanning:

do so automatically.

Do not ask the user prematurely.

---

# Phase 4 — Retry limits

Prevent infinite loops.

For the same task:

- maximum normal implementation attempts: 2
- maximum planner revisions caused by the same blocker: 2
- maximum repeated identical validation failure without new evidence: 2

After exceeding the limit:

mark the task BLOCKED.

Continue other independent READY tasks if possible.

Only stop the whole run when no useful work remains.

---

# Phase 5 — Parallelism

Parallelism is allowed for:

- repository exploration
- test analysis
- research
- independent read-only review
- independent non-overlapping analysis

Default to sequential execution for code-writing tasks.

Do not run multiple agents that may edit overlapping files unless isolation is explicitly available and safe.

---

# Phase 6 — Automatic continuation rule

After every subagent returns:

DO NOT end the parent turn merely because that subtask finished.

Instead:

1. update persistent state
2. reload CURRENT.md
3. determine the next valid state transition
4. spawn the next required agent
5. continue

The workflow must be treated as a state machine.

---

# Terminal conditions

Stop automatically only when one of these is true.

## COMPLETE

All tasks belonging to the current objective are DONE.

No required REVIEW, READY, IN_PROGRESS, or resolvable BLOCKED tasks remain.

Then:

- compact CURRENT.md
- compact PLAN.md
- verify final objective-level tests
- report completion to the user

## EXTERNAL_BLOCKER

No executable work remains and progress requires something only the user or an external authority can provide.

Examples:

- unavailable credential
- required product decision with no safe default
- inaccessible external environment
- mandatory permission that cannot be granted automatically

Report exactly what is blocked.

## SAFETY_OR_PERMISSION_BOUNDARY

A required action cannot be safely or permissibly performed.

Stop and explain the blocked action.

---

# Important behavior

Do not require manual prompts such as:

- 继续
- 下一步
- review
- 执行下一个

between tasks.

One invocation of this workflow should continue through the entire current objective whenever technically possible.
