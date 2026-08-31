# Agent 协作状态

`.agent/` 是项目协作的持久事实源。当前热状态只在 `PROJECT.md`；技术决策在 `decisions/`；任务在 `tasks/`。

## 目录

| 路径 | 用途 |
|---|---|
| `PROJECT.md` | 当前目标、约束、直接阻塞、下一动作和最近核对日期 |
| `tasks/active/` | 未终结任务：`PENDING`、`IN_PROGRESS`、`BLOCKED` |
| `tasks/archive/YYYY-MM/` | 终结任务：`DONE`、`CANCELLED`，保留历史证据 |
| `decisions/` | 可复用的技术决策 |

## 任务格式

活动任务使用以下最小结构。任务文件是状态、依赖、验收和证据的唯一来源。

```markdown
# Txxx: 标题

## Metadata
- Priority: P0 | P1 | P2
- Status: PENDING | IN_PROGRESS | BLOCKED
- Dependencies: 无 | Txxx, Tyyy

## Goal
可验证的单一结果。

## Scope
允许修改的范围和必要的排除项。

## Acceptance Criteria
- 可逐项判定的结果。

## Validation
- 最小充分的验证命令或人工验证矩阵。

## Evidence
仅在实施、阻塞或验收时追加。`BLOCKED` 必须说明证据和解除条件。
```

`PENDING` 不需要额外激活迁移：所有依赖均为归档 `DONE` 时即可选择执行。实施开始后置为 `IN_PROGRESS`；主对话验收通过后写入证据、置为 `DONE` 并立即移入当月归档。需修复时保持 `IN_PROGRESS`；取消任务记录原因后归档。`BLOCKED` 只表示任务自身的直接阻塞，不用于表达未完成依赖。

## 使用方式

唯一入口是 `$project-workflow`：

```text
$project-workflow plan <目标>
$project-workflow replan [Txxx] <原因>
$project-workflow run [目标]
$project-workflow next
$project-workflow task Txxx
$project-workflow review Txxx
$project-workflow compact
```

`next` 与 `task` 完成一个任务的实施、验收和状态迁移后停止；`run` 在每次归档后重新读取任务并继续。归档只收敛 `PROJECT.md` 和终态位置，不删除历史证据。
