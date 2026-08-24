# D002: 共享存储迁入 App Group，旧数据首版只复制不删除

- 日期：2026-08-24
- 状态：accepted
- 背景：当前 6 个 Store 通过 `sharedDataDirectory()` 写入 `~/Library/Application Support/Fewer/Shared`，没有使用三个 target 已声明的 `group.com.number47.fewer`。原计划同时切换路径、删除旧目录并移除 Finder `/` 临时例外，缺少回滚窗口，并把 Finder 用户文件访问和共享状态访问错误地视为同一个权限问题。
- 决策：共享状态写入 App Group Container 的 `Shared`；首个迁移版本在进程使用 Store 前以跨进程互斥方式复制缺失数据，目标已存在时绝不覆盖，旧目录至少保留一个发布周期。`containerURL == nil` 必须记录明确错误；兼容回退仅用于未正确签名的本地开发，不能作为发布验收成功。Finder `/` 例外在后续独立 PR 中，经签名实机文件操作矩阵通过后再删除。
- 影响：T014 只负责路径解析、幂等复制和三进程一致性；T016 负责 Finder 文件操作与 entitlement。迁移不得移入废纸篓，不使用“存在即完成”的无校验标记。Store 的长期跨进程写一致性另建任务。
