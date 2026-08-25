# Current Project State

> 此文件只表达“现在是什么状态”，不记录历史。
> 任务完成后移出本文件，历史进入 `tasks/archive/`。

## Objective

完成发布前收口：恢复 CI，完成已认证 XPC、最小 Finder 权限、跨进程状态一致性、截图内存限制、UI smoke 与签名发布验收。

## Current Milestone

发布前收口 v5。

## Active Tasks

| Task | Title | Status | Priority | Depends On |
|------|-------|--------|----------|------------|
| T020 | R0 — 真实运行基线与扩展问题扫描 | DONE(用户跳过实机) | P0 | 无 |
| T013 | PR1 — CI 基线与临时文件清理 | DONE | P0 | T020 |
| T021 | R1 — 右键事件完整性与鼠标手势状态机 | DONE | P0 | T013, T020 |
| T022 | R2 — 权限与扩展启用中心 | DONE | P0 | T013, T020 |
| T023 | R3 — Finder 菜单可见性与生命周期修复 | DONE | P0 | T013, T020, T021, T022 |
| T024 | R4 — 菜单栏日历滚动性能 | DONE | P1 | T013, T020 |
| T025 | R5 — 设置窗口响应与后台状态刷新 | DONE | P1 | T013, T020, T022 |
| T026 | R6 — 稳定性回归与第二轮问题收敛 | DONE | P0 | T021, T022, T023, T024, T025 |
| T014 | PR2 — App Group 共享存储与保守迁移 | DONE | P0 | T013 |
| T015 | PR3 — Finder 动作快照隔离与 MainActor 边界 | DONE | P0 | T013, T023 |
| T016 | PR4 — 可回滚 replace、文件协调与移除 `/` 例外 | DONE | P0 | T014, T015 |
| T017 | PR5 — 经签名验证的双向 XPC 命令通道 | BLOCKED | P0 | T013 |
| T018 | PR6 — SystemMetrics 后台采样与频率分层 | DONE | P1 | T013 |
| T019 | PR7 — 滚动截图后台合成与显式内存预算 | DONE | P1 | T013 |
| T012 | 集成与发布验收 | BACKLOG | P0 | T004-T010, T013-T026 |
| T027 | CI Swift 6 修复 | DONE | P0 | 无 |
| T028 | 签名 XPC 架构探针 | BLOCKED | P0 | T027 |
| T029 | Finder `/` 例外移除与实机矩阵 | BLOCKED | P0 | T027, T016 |
| T030 | App Group identifier 与跨进程 Store | DONE | P1 | T027 |
| T031 | ModulePreferences 损坏恢复 | DONE | P1 | T030 |
| T032 | 滚动截图 session 内存预算 | DONE | P1 | T027, T019 |
| T033 | 普通 CI UI smoke | BLOCKED | P1 | T027 |
| T034 | Popover 可访问性 | BACKLOG | P2 | T033 |
| T035 | Helper 构建嵌入收口 | BACKLOG | P2 | T017 |
| T036 | Input preference 主 App 单写迁移 | BACKLOG | P1 | T017, T030 |

## Review Queue

T013、T014、T021、T022、T024 已通过代码层验收：T013（CI 漂移检查、verify_templates.sh 通过、ci_verify.sh 语法 OK）；T014（FewerCore 267 tests/0 failures、Fewer build succeeded、8 项迁移单测全过、无 as any、未删旧数据/未改 Finder `/`）；T021（FewerCore 267 tests/0 failures、Fewer BUILD SUCCEEDED、无 as any、R1 回归测试全过、点击重放由 `activated` 状态判定）；T022（FewerCore 267 tests/0 failures、Fewer BUILD SUCCEEDED、无 as any、权限与扩展页已接入侧栏与 Overview/输入增强跳转、输入监控改用 `isInputMonitoringTrusted`、Event Tap 单独作为运行时诊断、状态刷新事件驱动且 pluginkit 在 `Task.detached` 后台执行、UI 测试 testPermissionsSettingsPageNavigation 已加）；T024（FewerCore 279 tests/0 failures、Fewer BUILD SUCCEEDED、无 as any、EventKit 查询与 reminder fetch 移至 EventKitWorker actor 后台边界、可见范围请求 150ms 合并、generation 守卫、有界 CalendarEventCache、网格像素偏移隔离到 GridOffsetStore 叶视图、行步进每事件限 ±1 并保留余数）；T023（FewerCore 289 tests/0 failures、Fewer BUILD SUCCEEDED、无 as any、`menu(for:)` 四分支原因码 moduleDisabled/contextUnavailable/servicesUnavailable/emptyEntries 已落地、FinderMenuDiagnostic 诊断心跳经共享 Store 持久化并在权限页 Finder 扩展行下方暴露、MenuBuilder 补齐 sidebar 的 copyPath/openInTerminal、directoryURLs 维持 /Users+/Volumes 未改）；T015（FewerCore 301 tests/0 failures、Fewer BUILD SUCCEEDED、无 as any、`FinderActionHandler.context`/`openWithBundleIDs`/标题反解/`representedObject` 全部移除、FinderMenuActionRegistry（Sendable+OSAllocatedUnfairLock）以唯一 token 绑定不可变快照、连续两菜单跨 context 隔离已测）；T016（FewerCore 309 tests/0 failures、Fewer BUILD SUCCEEDED、无 as any、`FileOperationCoordinator`/`TemplateFileCreator` 改为同名备份 rename 事务 + 注入式失败钩子覆盖 success/install-fail/rollback-fail/cleanup-fail/dir-replace、`NSFileCoordinator` 同时协调源与目标、Finder Extension `/` 例外按 T012 门禁暂不移除）；T025（FewerCore 309 tests、完整 Debug build、模板/产物/diff 门禁均通过，已修复快速重入与自身 DNC 回读两项持久化竞态，待签名实机性能和交互验收）。运行时实机验收（T001 其他应用滚轮、T005 Apple Silicon GPU 枚举、T009 多显示器、T021 Finder/Chrome/Safari 真实右键录制、T022 系统设置深链签名、T023 签名 Finder 菜单实机录屏、T024 Time Profiler 连续滚动录屏、T025 设置页性能与持久化、T017 签名 Mach service 探针、各模块真实采样与降级）由 T012 集成验收在签名实机完成。

## Blocked

T028：公开 `NSXPCConnection` 在当前 macOS SDK 不暴露 audit token；以 PID 反查签名不满足 audit-token 验收。需要用户决定是否允许改为低层 `xpc_connection_t` listener（保留 audit token）或调整安全验收，二者均不得静默降级。T029：启用的 extension 是 `/Applications/Fewer.app` 旧安装，覆盖用户安装前不能测试最新版本。T033：本机 XCTest UI host 缺少辅助功能授权。T017 在 T028 通过前保持 BLOCKED；不得以 DNC 回退。T016 的可回滚 replace 已完成，但 `/` entitlement 尚未移除，改由 T029 完成。T032 已完成 session resident-memory budget；其签名实机曲线留待 T012。

## Recommended Next Task

已完成：T027、T030、T031、T032。阻塞：T028（公开 `NSXPCConnection` 缺 audit token，需选择低层 XPC 或修改安全验收）、T029（最新 extension 未安装启用）、T033（XCTest UI host 缺 Accessibility）。T017、T034-T036、T012 受其依赖阻塞。

## Current Risks

- T001 的“其他应用中真实滚轮滚动”仍需用户实机确认（需真实滚轮输入）。
- IOReport、SMC、SMART 与 Wi-Fi 定位权限需要在签名实机上验证。
- Finder XPC 回调不可靠序列化 `representedObject`；T015 必须只依赖已确认可读的 `tag`，并用唯一 token 绑定动作快照。
- T016 删除 Finder `/` 临时例外前必须完成签名实机 create/cut/paste/replace/template 验证；失败时阻塞并重新设计权限边界。
- T017 必须先证明当前 `SMAppService.loginItem` 打包下的 Mach service 注册、连接生命周期和双方身份校验成立。
- T019 仍返回单个 `CGImage`，只能限制并移出整图分配，不能宣称分块后消除整图内存。
- T011 的 4pt/16pt 阈值组合已被实机反馈否定；T021 已重做完整 down/drag/up/cancel/timeout 状态机（由 `activated` 状态判定点击重放），该风险已收敛。遗留：MouseGestureClickTolerance 等旧类型因被测试引用而保留，存在轻微死代码，后续可在 find-simplifications 评估。
- T025 已将 Overview 的 `pluginkit` 和设置读写移出 MainActor；仍需签名实机的 Time Profiler、5 秒 Overview 进程采样和连续编辑持久化验证。
- T023 的 Finder 菜单可见性依赖扩展启用状态与 `directoryURLs` 注册范围，需签名实机录屏确认；reason code 与诊断心跳必须不记录用户文件名/完整路径（隐私红线）。

## Last Updated

2026-08-25（复验 `./script/verify.sh`：360 Core tests/0 failures、严格并发 Debug build、模板、三产物与 diff 检查通过；T028 发现 public `NSXPCConnection` 无 audit token，保持 BLOCKED。）
