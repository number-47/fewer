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

项目协作由 `.agents/skills/project-workflow/` 的单一入口管理；`.agent/` 中的文件是唯一事实源。自然语言的规划、重新规划、自动执行、继续、执行指定任务、验收和归档均使用该技能的对应模式。

`.agent/PROJECT.md` 只保存当前目标、约束、直接阻塞和下一动作。任务文件保存任务详情与证据：`tasks/active/` 仅允许 `PENDING`、`IN_PROGRESS`、`BLOCKED`，`tasks/archive/YYYY-MM/` 仅允许 `DONE`、`CANCELLED`。`PENDING` 在其所有依赖都归档为 `DONE` 时可执行；通过验收后立即归档，不保留独立审查队列。技术决策位于 `.agent/decisions/`。

主对话负责澄清需求、架构决策、任务拆分、协调状态写入和最终验收。普通开发任务交给 `implementer`，任务说明必须给出目标、范围、禁止事项、验收标准和验证命令；只有范围固定、规则机械、容易验收和撤回的工作才交给 `batch_worker`。一两处低风险的明确修改可由主对话直接完成。子代理不得扩大范围、选择下一任务或修改未授权的协调状态；可写代理不得并发修改重叠文件。

自动运行在每个归档后重新读取任务；单一任务阻塞时继续处理独立的可执行任务。相同失败类别最多尝试两次，第二次没有新证据时标记 `BLOCKED`。仅在目标完成、没有可执行任务且其余任务均需外部条件，或触及安全/权限边界时停止。

事实源优先级：当前明确用户指令、`AGENTS.md`、指定任务文件、已接受的技术决策、`PROJECT.md`、聊天历史。
