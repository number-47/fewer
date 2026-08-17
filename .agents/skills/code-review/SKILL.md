---
name: code-review
description: Use when reviewing a Fewer pull request — orient the reviewer to this repository's standards (AGENTS.md conventions, project.yml module boundaries, Swift 6 strict concurrency, testing and security rules) and the review-specific checks code alone cannot show.
---

# 审查 Fewer PR

这是审查定位而非完整清单。先确认 PR 的 live base 与 head，再看 diff 和足够上下文做语义审查。优先正确性、生命周期、安全与被破坏的必需行为，而非风格；一个带实证的 blocker 胜过一串 nit。

## 事实来源

- 根 `AGENTS.md`：模块职责、构建/测试命令、命名、并发、测试、提交与安全约定。
- `project.yml`：target、scheme、entitlements、依赖与构建配置的权威来源；`Fewer.xcodeproj` 是生成产物。
- `Config/Base.xcconfig`：版本与签名相关配置。
- `.agents/skills/ship-code/SKILL.md`：实现与交付门禁约定。
- `DEV_STATE.md`：当前开发状态与已知边界。

## 阻断项

1. **核心逻辑被用例覆盖。** 新增核心逻辑覆盖成功、边界、失败路径；修 bug 有回归测试。测试断言要失败在所针对的回归，而不是复述实现。
2. **文档与注释匹配代码。** 配置、默认值、错误、公开行为在同一 diff 里同步；注释只写代码无法表达的非显然契约，删除实现叙述、测试走查、审查历史与重复解释。
3. **并发与生命周期正确。** `SWIFT_STRICT_CONCURRENCY = complete`：明确 `Sendable`、`@MainActor` 与安全异步边界。检查竞态、await 期间取消、回调所有权、重入前归属、彻底清理。
4. **注册与清理成对。** 新增通知、回调、权限、资源注册需有对应清理，且走真实入口路径。
5. **业务逻辑在 FewerCore。** AppKit/SwiftUI 层保持轻量；不要为单一调用点扩张公共服务 API。
6. **最小范围。** 挑战无关功能与投机通用性；能用手头系统 API 解决的不手写新抽象。
7. **权限与安全。** 不提交证书、钥匙串或 `Config/Signing.local.xcconfig`；新增权限同步审查 entitlements、用途说明与最小权限范围。

## 手动检查

- **接口契约**：追踪每个被改接口两侧；实现匹配 PR 意图，包括错误、取消、归属与清理。
- **能力与消费者契合**：追踪现有消费者，标记泄漏到接口的特定消费者行为，也标记「只有一个内部调用点」的不必要公开 API。
- **真实入口路径**：测试通过真正的 App/扩展/辅助进程路径，而不是手工拼装的假象。
- **测试强度**：断言验证外部状态、日志、事件或清理，而非复述实现或信任 agent 报告。
- **UI/Finder/截图/权限变更**：要求真实交互证据（截图或录屏），并注明权限、签名或迁移影响；仅有构建成功不算验证。

## 报告

陈述缺陷、位置、影响与证据。局部缺陷放在最紧的 diff 行内；跨切面的架构/范围问题用 PR 级评论。把 blocker 与建议分开，省略已被绿色门禁覆盖的问题。收到审查时逐条核实并在技术层面修复或反驳，不做表演式认同。
