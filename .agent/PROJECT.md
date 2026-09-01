# Project

## Objective

完成发布前收口：已认证 XPC、最小 Finder 权限、跨进程状态一致性、截图内存限制、UI smoke 与签名发布验收。

## Constraints

- 特权命令只允许已认证 XPC；不得以 DistributedNotificationCenter 降级替代。
- Finder 根路径例外只能在签名实机文件操作矩阵通过后移除。
- 保留历史任务中的验证与未验证证据；不把构建结果表述为实机验收。
- 遵循已接受的 D002、D003、D004。

## Blockers

- T028：公开 `NSXPCConnection` 无法提供 audit token。证据与解除条件见任务文件；需要选择低层 XPC listener 或调整安全验收。
- T029：启用的 Finder Extension 来自旧安装，覆盖安装前不能执行最新构建的实机矩阵。
- T033：当前 XCTest UI host 没有辅助功能授权，不能将该 smoke 纳入阻断 CI。

## Next Action

首先解决 T028 的低层 XPC 与安全验收选择；在此之前不修改生产特权命令通道。

## Last Reconciled

2026-09-01
