# D003: 发布架构收口由 5 个混合 PR 拆为 7 个单一职责 PR

- 日期：2026-08-24
- 状态：accepted
- 背景：原 PR4 同时改造 XPC 与 SystemMetrics，原 PR5 同时处理滚动截图、CI、构建脚本和五个大文件；这些改动没有共同回滚边界。代码核对还发现：Finder XPC 菜单回调不可靠序列化 `representedObject`；现有 Login Item 没有 Mach service 声明；返回单个 `CGImage` 的接口不能通过“分块合成”消除最终整图存储。
- 决策：先以独立 PR 建 CI 门禁，再分别处理 App Group、Finder 动作快照、事务文件操作、认证 XPC、SystemMetrics 后台采样和滚动截图内存预算，共 7 个 PR。XPC 先通过签名往返探针再替换生产通道；截图只承诺后台合成和显式预算，不承诺当前 API 无法实现的无整图内存。
- 影响：新增 T018、T019；T012 改为依赖 T013-T019。构建脚本沙盒化和机械大文件拆分延期，避免掩盖功能性 diff。
