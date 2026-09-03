# Project

## Objective

在不触碰现有发布安全边界和 T041 工作区改动的前提下，交付以 macOS 26 为最低版本的 OCR 截图翻译：独立快捷键、区域选取、端侧 Vision OCR、浮窗原文/译文、默认 Apple Translation，以及用户显式选择的 OpenAI-compatible 文本翻译与回归验证。

## Constraints

- 特权命令只允许已认证 XPC；不得以 DistributedNotificationCenter 降级替代。
- Finder 根路径例外只能在签名实机文件操作矩阵通过后移除。
- 保留历史任务中的验证与未验证证据；不把构建结果表述为实机验收。
- 遵循已接受的 D002、D003、D004。
- OCR 文本与译文只保留在当前会话；不得写入日志、UserDefaults、App Group 或文件。仅当用户在结果浮窗显式切换到 AI 时，才可将 OCR 文本和语言参数发送至其配置的服务；不得发送图片、坐标或密钥。
- 最低版本为 macOS 26；Apple Translation 继续为每次新截图的默认翻译源。AI 使用用户自配的 OpenAI-compatible Chat Completions 地址、模型和密钥，不引入第三方依赖或业务代理。
- 正在进行的 T041 及其既有脏文件不属于 OCR 截图翻译范围。

## Blockers

- T028：公开 `NSXPCConnection` 无法提供 audit token。证据与解除条件见任务文件；需要选择低层 XPC listener 或调整安全验收。
- T029：启用的 Finder Extension 来自旧安装，覆盖安装前不能执行最新构建的实机矩阵。
- T033：当前 XCTest UI host 没有辅助功能授权，不能将该 smoke 纳入阻断 CI。
- 代码知识图索引在 2026-09-02 连续两次崩溃；OCR 开发期间以定向源码检索补充架构核对，待索引服务修复后重新索引。
- T047：OCR 截图翻译仍需物理全局按键、屏幕录制、Apple Translation 语言资源与多显示器证据；代码层验证不能替代这些实机证据。
- T052：AI 翻译的签名 Debug 本地兼容服务端到端矩阵仍需在 T050/T051 完成后执行；真实外部供应商验证仅在用户提供配置时单独记录。

## Next Action

等待 T052 的用户授权签名 Debug 交互矩阵：物理快捷键、屏幕录制、OCR/系统→AI 切换、目标语言重译与多显示器；真实外部供应商验证仅在用户提供配置后执行。

## Last Reconciled

2026-09-03
