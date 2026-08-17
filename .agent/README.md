# Agent 协作系统

本目录是多 Agent 协作系统的操作中心。仓库文件是唯一事实源。

## 文件说明

| 文件 | 用途 |
|------|------|
| `CURRENT.md` | 当前状态快照（目标、活动/审查任务、阻塞、下一步），保持很小 |
| `PLAN.md` | 当前实施计划，包含任务列表与依赖关系 |
| `tasks/active/` | 可执行任务（`Txxx.md`） |
| `tasks/review/` | 待审查任务 |
| `tasks/archive/` | 已完成/取消任务的归档 |
| `decisions/` | 单项技术决策（`Dxxx-<slug>.md` + `INDEX.md`） |

## 工作流

自动编排主入口：

```
project-run（Orchestrator）→ Planner → Executor → Reviewer → 循环 → Milestone DONE
```

人工 fallback：

```
project-plan / project-next / project-execute / project-review / project-replan
```

1. **Planner**（推荐 Sol XHigh）创建计划与任务，不写生产代码。
2. **Executor**（Terra 常规 / Luna 简单）执行单个任务，完成后置为 REVIEW。
3. **Reviewer**（Sol High）独立验收，只有 Reviewer 能置 DONE。
4. **project-compact** 归档已完成任务与历史，保持热数据小。

## 使用方式

在 Codex 中：

```
# 自动完成整个需求（Orchestrator 循环，中间无需人工“继续”）
$project-run <需求描述>

# 制定计划
$project-plan <需求描述>

# 执行下一个 READY 任务
$project-next

# 执行指定任务
$project-execute T001

# 审查任务
$project-review T001

# 重新规划
$project-replan T003 blocked by API limit

# 归档与收敛
$project-compact
```

## 状态值

- `BACKLOG` — 任务已创建，尚未就绪
- `READY` — 依赖已满足，可以执行
- `IN_PROGRESS` — 正在执行
- `REVIEW` — 执行完成，等待审查
- `BLOCKED` — 被阻塞，需 Planner 介入
- `DONE` — 审查通过且验收标准全部满足
- `CANCELLED` — 已取消

## 任务文件模板

创建新任务时使用以下模板：

```markdown
# Txxx: <标题>

## Goal
<这个任务要达成什么>

## Context
<为什么需要这个任务>

## Files likely affected
- `path/to/file.swift`

## Dependencies
- Txxx (必须先完成)

## Implementation steps
1. ...
2. ...

## Acceptance criteria
- [ ] <可验证的条件 1>
- [ ] <可验证的条件 2>

## Recommended executor model
<推荐模型，如 Sol / Terra / Luna>
```
