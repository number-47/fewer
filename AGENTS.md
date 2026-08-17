# 编码前思考
- 明确假设，不确定时询问而非猜测。
- 存在歧义时，列出多种解释，不默默选一种。
- 如果任务有明显更简单的做法，直接指出。
- 发现矛盾或不一致时停下来，要求澄清。

## 简洁优先
- 用最少的代码解决问题。
- 不为一次性需求创建抽象层。
- 不为"万一以后需要"加灵活性和可配置性。
- 如果 200 行可以写成 50 行，重写它。
- 检查标准：资深工程师会觉得这过于复杂吗？如果是，简化。

## 精准修改
- 只修改与当前任务直接相关的代码。
- 不顺手改进相邻代码、注释或格式。
- 不重构本来能正常工作的部分。
- 匹配现有代码风格，即使你更偏好另一种写法。
- 因你的修改而变成死代码的导入和变量，删除掉。
- 发现预先存在的死代码时，提出来但不要删。

## 目标驱动执行
- 定义清晰的成功标准再开始。
- "修复 bug" 转化为 "写一个重现 bug 的测试，然后让它通过"。
- "添加验证" 转化为 "为无效输入写测试，然后让它们通过"。
- "重构 X" 转化为 "确保重构前后所有测试都能通过"。
- 多步骤任务先给简短计划，每一步带验证方式。

## 输出与回复
使用中文

---

# Repository Guidelines

## 项目结构与模块组织

Fewer 是面向 macOS 14+ 的 Swift 6 应用。`FewerApp/` 包含菜单栏主应用、SwiftUI 视图、应用服务与资源；`FewerCore/` 存放可复用模型、菜单逻辑、文件操作及共享设置。`FewerFinderExtension/` 实现 Finder Sync 扩展，`FewerShortcutHelper/` 负责全局快捷键辅助进程，`FewerCoreTests/` 保存 XCTest 单元测试。模板资源位于 `Resources/Templates/`，签名与版本配置位于 `Config/`。`project.yml` 是 XcodeGen 的工程源文件；修改 target、scheme 或资源后应重新生成 `Fewer.xcodeproj`。

## 构建、测试与开发命令

DerivedData 路径约定：Debug 构建与单元测试一律复用 `.build/DerivedData`，Release 打包复用 `.build/PackageDerivedData`。自定义构建/测试命令不得另起新目录名，避免 `.build` 体积膨胀；清理构建产物直接删除这两个目录即可。注意：本机 Xcode 全局设置为自定义绝对构建位置（`IDECustomBuildProductsPath`），因此测试等 xcodebuild 命令必须像下方一样显式传入 `SYMROOT/OBJROOT`，产物才会进入项目 `.build` 而非全局目录。

- `xcodegen generate`：依据 `project.yml` 更新 Xcode 工程。
- `./script/build_and_run.sh run`：生成工程、构建 Debug 到 `.build/DerivedData`、签名并启动应用；需要 Apple Development 证书。
- `./script/build_and_run.sh --logs`：启动应用并流式查看三个进程的系统日志。
- `xcodebuild -project Fewer.xcodeproj -scheme FewerCore -configuration Debug -derivedDataPath .build/DerivedData SYMROOT="$PWD/.build/DerivedData/Build/Products" OBJROOT="$PWD/.build/DerivedData/Build/Intermediates.noindex" CODE_SIGNING_ALLOWED=NO test | xcbeautify`：运行核心单元测试（与构建共享同一 DerivedData，可复用增量产物）。
- `./script/verify_templates.sh`：校验内置 Office 模板及 `Info.plist`。
- `./script/package.sh --local`：生成本机测试 DMG；正式发布使用 `--signed --notarize`。

## 编码风格与命名约定

使用四空格缩进，遵循 Swift API Design Guidelines。类型采用 `UpperCamelCase`，方法、属性和测试方法采用 `lowerCamelCase`；文件通常与主要类型同名。保持 `SWIFT_STRICT_CONCURRENCY = complete`，明确使用 `Sendable`、`@MainActor` 与安全的异步边界。优先将业务逻辑放入 `FewerCore`，让 AppKit/SwiftUI 层保持轻量。仓库未配置自动格式化器，提交前请保持现有排版并消除编译警告。

## 测试指南

测试使用 XCTest，文件命名为 `<Subject>Tests.swift`，测试方法以 `test` 开头并描述行为，例如 `testStartDateRejectsInvalidMonth`。修复缺陷时添加回归测试；日期测试应显式设置 locale、时区和首周日。项目未规定覆盖率阈值，但新增核心逻辑必须覆盖成功、边界及失败路径。

## 提交与拉取请求

沿用简洁的 Conventional Commits：`feat: ...`、`fix: ...`、`docs: ...`、`test: ...`。每个提交聚焦一个可验证改动。PR 应说明动机、影响的 target、验证命令及结果；关联相关 issue。涉及设置页、菜单栏日历或 Finder 菜单的界面变化时附截图或录屏，并注明权限、签名或迁移影响。

## 安全与配置

不要提交证书、钥匙串信息或 `Config/Signing.local.xcconfig`。本地签名通过 `FEWER_SIGNING_IDENTITY` 配置，公证凭据通过 `FEWER_NOTARY_PROFILE` 提供；新增权限时同步审查 entitlements、用途说明与最小权限范围。

---

# Multi-Agent Workflow

本仓库使用文件驱动的多 Agent 协作系统。仓库文件是唯一事实源，聊天上下文不是。

## Project state

Persistent planning and execution state lives under:

`.agent/`

Important files:

- `.agent/CURRENT.md` — current state snapshot (objective, active/review tasks, blockers, next step)
- `.agent/PLAN.md` — overall implementation plan
- `.agent/tasks/active/` — executable task specifications (`Txxx.md`)
- `.agent/tasks/review/` — tasks awaiting review
- `.agent/tasks/archive/` — completed/cancelled task history
- `.agent/decisions/` — durable technical decisions (`Dxxx-<slug>.md` + `INDEX.md`)

## Workflow skills

Project workflows are implemented as repository skills under:

`.agents/skills/`

Automatic orchestration:

- `project-run` — Orchestrator loop: Planner → Executor → Reviewer until the objective is DONE or BLOCKED.

Manual fallback:

- `project-plan`
- `project-next`
- `project-execute`
- `project-review`
- `project-replan`

Maintenance:

- `project-compact` — archive completed work and keep hot files small.

Use the matching workflow whenever the user's intent clearly corresponds to one.

## Autonomous execution

This repository supports autonomous orchestration.

When the user's intent is:

- 自动完成
- 自动执行
- 完成整个计划
- 持续执行直到完成
- run the whole plan
- complete the current objective

use the `project-run` workflow.

During an autonomous run:

- the parent Orchestrator owns `.agent` coordination state
- Planner, Executor, and Reviewer operate as subagents
- completing one task is NOT a reason to stop
- completing one review is NOT a reason to stop
- after every subagent result, reload current state and continue
- do not require the user to type 继续

Continue until:

1. the objective is complete
2. a genuine external blocker prevents all remaining useful work
3. a safety or permission boundary requires user action

For normal autonomous runs, do not ask for confirmation between tasks.

## Manual fallback

The following workflows remain available for manual intervention:

- project-plan
- project-next
- project-execute
- project-review
- project-replan
- project-compact

Use these only when the user explicitly requests manual control, debugging, targeted execution, or recovery.

## Intent routing

Interpret these intents as follows.

### Automatic run (whole objective)

Examples:

- 自动完成这个需求
- 自动执行整个计划
- run the plan
- execute the whole milestone

Use the `project-run` workflow.

The orchestrator loops through Planner → Executor → Reviewer until the objective is DONE or BLOCKED, without requiring manual 继续 between steps.

### Planning

Examples:

- 规划
- 制定计划
- 分析并拆任务
- 设计实现方案
- plan this feature

Use the `project-plan` workflow.

Planner must not implement production code.

### Continue implementation

Examples:

- 继续
- 下一步
- 继续执行
- 执行下一个
- proceed
- continue

Use the `project-next` workflow.

Select exactly one READY task.

Do not execute multiple tasks in one turn.

### Execute specified task

Examples:

- 执行 T017
- implement T017
- work on T017

Use the `project-execute` workflow.

### Review

Examples:

- 验收 T017
- 审查 T017
- review T017
- verify T017

Use the `project-review` workflow.

### Replanning

Examples:

- 重新规划 T017
- 这个方案走不通，调整计划
- replan T017

Use the `project-replan` workflow.

## Role separation

### Orchestrator

In autonomous runs, owns `.agent` coordination state:

- `CURRENT.md`
- `PLAN.md`
- `tasks/`
- `decisions/`

The Orchestrator applies state transitions based on subagent results.

### Planner

Returns a structured plan (objective, scope, architecture, task decomposition, dependencies, acceptance criteria).

Planner does not implement production code or modify repository files directly.

### Executor

Implements exactly the assigned task and returns a completion report.

Executor must not mark a task DONE or modify `.agent` coordination state in autonomous runs.

### Reviewer

Returns an independent verdict: PASS, PASS_WITH_NOTES, FIX_REQUIRED, or BLOCKED.

Reviewer does not modify project files.

## Task state machine

Allowed states:

BACKLOG
READY
IN_PROGRESS
REVIEW
BLOCKED
DONE
CANCELLED

Normal flow:

BACKLOG -> READY -> IN_PROGRESS -> REVIEW -> DONE

## Manual execution discipline

Applies to manual fallback workflows (`project-next`, `project-execute`).

Before implementing a task:

1. Verify its dependencies.
2. Read its task specification.
3. Inspect relevant existing code.
4. Inspect relevant tests.

After implementation:

1. Run required validation.
2. Check every acceptance criterion.
3. Update task completion information.
4. Move task to REVIEW.
5. Stop.

Manual fallback executes exactly one task per invocation. Autonomous runs follow the `project-run` workflow and continue automatically.

## Source-of-truth priority

When information conflicts, follow this order:

1. Current explicit user instruction
2. `AGENTS.md`
3. Assigned task file
4. `.agent/decisions/`
5. `.agent/PLAN.md`
6. `.agent/CURRENT.md`
7. Previous chat context
