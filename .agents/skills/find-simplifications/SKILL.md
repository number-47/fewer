---
name: find-simplifications
description: Use when asked to find simplification candidates in the Fewer repository — dead, duplicated, speculative, over-built, added-then-removed, or hand-rolled-where-a-system-framework-exists code — and produce evidence-backed proposals or targeted TODO/FIXME notes.
---

# 寻找 Fewer 简化点

把「找可以简化什么」变成有证据、可执行的清理提案。优先用 codebase-memory-mcp 的 `search_graph` / `trace_path` 做代码发现，必要时回退 `rg`。

## 先读仓库上下文

- 根 `AGENTS.md`（尤其「简洁优先」与「精准修改」）。
- `project.yml` 确认模块边界（FewerApp / FewerCore / FewerFinderExtension / FewerShortcutHelper）。
- 判断前先看调用点，不凭「看起来复杂」下结论。

## 什么算强候选

移除、折叠或降级了真实面，且有证据说明当前设计成本大于收益：

- 公开方法、类型、事件、配置项、helper、注册通知没有生产消费者。
- 只有测试或文档消费，且其固定的行为不再承重。
- 两个表示镜像同一事实（例如持久化与瞬态各存一份）。
- 一个接缝所有实现都必须支持但无消费者使用。
- 单独 target 只服务测试/demo/支持代码并增加维护成本。
- 投机性通用设计：多会话/可重载/后台任务花名册/实时失效等没有产品归属。
- 某个 invariant、回滚路径、特殊用例只保护一个未使用 API。
- 手写代码复刻了 Swift 标准库、Foundation、AppKit/SwiftUI 已提供的功能，替换可删除实现及专属测试。

薄候选通常不够：删一个错字、说一句「这很复杂」却没有调用点证据。

## 用证据证明或否决

对每个符号/行为先分类消费者：

- 生产语料：`FewerApp/`、`FewerCore/`、`FewerFinderExtension/`、`FewerShortcutHelper/` 的实现与运行时路径。
- 非生产语料：`FewerCoreTests/`、`FewerUITests/`、README/docs、注释与快照。

先用 `search_graph`（符号、类型、方法名）和 `trace_path`（谁调用它），再用 `rg` 搜精确符号、配置键、wire 字符串，然后读调用点。

出现以下情况就否决或降级：

- 存在生产调用者，简化会变成功能决策而非清理。
- API 被 `AGENTS.md` 或既有设计明确背书，且新证据不足以推翻。
- 删除会引发无关改动，却未真正减少公开 API 或必需行为。
- 想法正确但很小 → 写定向 `TODO/FIXME`，用稳定标签命名并说明何时可安全重访。

## 手写代码 vs 系统 API

替换成系统能力是合法简化，但要证明净收益：读手写实现，指出系统 API 精确覆盖的面；评估不覆盖的残留语义；权衡「实现 + 专属测试 + 文档」减去剩余胶水。包装一层却没减少复杂度不是收益。

## 输出

- 小范围本地清理：写 `TODO/FIXME`，短、可执行、说明为什么安全。
- 大范围或需要设计决策的简化：给出证据化提案（文件、符号、消费者、移除/折叠内容、风险、验收标准），等用户确认后再动。不要臆造仓库里不存在的 notes/归档体系。
- 不直接改动未授权的代码。
