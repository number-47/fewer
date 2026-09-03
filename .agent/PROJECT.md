# Project

## Objective

在不触碰现有发布安全边界和 T041 工作区改动的前提下，交付以 macOS 26 为最低版本的 OCR 截图翻译：独立快捷键、区域选取、端侧 Vision OCR、可配置且充分展开的浮窗原文/译文、可靠的 Apple Translation 目标语言选择与回归验证。

## Constraints

- 特权命令只允许已认证 XPC；不得以 DistributedNotificationCenter 降级替代。
- Finder 根路径例外只能在签名实机文件操作矩阵通过后移除。
- 保留历史任务中的验证与未验证证据；不把构建结果表述为实机验收。
- 遵循已接受的 D002、D003、D004。
- OCR 文本与译文只保留在当前会话；不得写入日志、UserDefaults、App Group、文件或网络服务。
- 最低版本为 macOS 26；Apple Translation 继续使用系统 API，不引入外部翻译服务。
- 正在进行的 T041 及其既有脏文件不属于 OCR 截图翻译范围。

## Blockers

- T028：公开 `NSXPCConnection` 无法提供 audit token。证据与解除条件见任务文件；需要选择低层 XPC listener 或调整安全验收。
- T029：启用的 Finder Extension 来自旧安装，覆盖安装前不能执行最新构建的实机矩阵。
- T033：当前 XCTest UI host 没有辅助功能授权，不能将该 smoke 纳入阻断 CI。
- 代码知识图索引在 2026-09-02 连续两次崩溃；OCR 开发期间以定向源码检索补充架构核对，待索引服务修复后重新索引。
- T047：OCR 截图翻译仍需物理全局按键、屏幕录制、Apple Translation 语言资源与多显示器证据；代码层验证不能替代这些实机证据。
- T050：结果窗位置、内容展开和目标语言修复已完成代码与静态验收，但当前 WSL 环境没有 Xcode/Swift 工具链；需在 macOS 26 完成 XCTest、Debug 构建和签名 UI 交互后归档。

## Next Action

在 macOS 26/Xcode 环境验证 T050 的 FewerCore XCTest、Debug 构建及设置页/结果窗/目标语言交互；通过后归档 T050，并继续 T047 的完整实机矩阵。

## Last Reconciled

2026-09-03
