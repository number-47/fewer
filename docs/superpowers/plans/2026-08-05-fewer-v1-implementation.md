# Fewer v1 实施计划

日期：2026-08-05
依据：[Fewer v1 产品与技术设计](../specs/2026-08-05-fewer-v1-design.md)

## 目标

在空仓库中交付一个可真实安装和运行的 `Fewer.app`。应用内嵌 Finder Sync Extension 与隐藏 Shortcut Helper，第一版完成新建文件、复制路径、右键剪切粘贴、Finder 全局 `Command-X` / `Command-V`、模板管理和设置界面。

## 已验证的本机基线

- Xcode 26.6（17F113）
- Swift 6.3.3
- XcodeGen 2.46.0
- xcbeautify 已安装
- 2 个有效代码签名身份
- 最低部署目标 macOS 14.0

## 实施原则

- 使用 XcodeGen 维护工程定义，提交 `project.yml` 与生成的 `Fewer.xcodeproj`，保证首次打开即可构建。
- 共享业务代码放在 `FewerCore` framework；SwiftUI、FinderSync 和事件监听只作为平台边界。
- 业务行为先写测试，再写最小实现。
- 小型设置使用 App Group `UserDefaults`；模板与剪切事务使用 App Group 容器中的版本化 JSON/文件。
- 测试通过依赖注入使用临时目录，不依赖真实 App Group 或用户 Finder。
- 自动测试之后必须构建完整应用，并在真实 Finder 中验收扩展与快捷键。
- 第一版不做截图、日历、账号、网络、自动更新或上架流程。

## 计划中的目录结构

```text
.
├── .codex/environments/environment.toml
├── Config/
│   ├── Base.xcconfig
│   └── Signing.local.xcconfig.example
├── FewerApp/
│   ├── App/
│   ├── Resources/
│   ├── Services/
│   └── Views/
├── FewerCore/
│   ├── Menu/
│   ├── Models/
│   ├── Services/
│   └── Support/
├── FewerCoreTests/
├── FewerFinderExtension/
├── FewerShortcutHelper/
├── Resources/Templates/
├── script/build_and_run.sh
├── project.yml
└── Fewer.xcodeproj
```

## Task 1：工程骨架、签名配置与运行入口

### 文件

- 新建：`project.yml`
- 新建：`Config/Base.xcconfig`
- 新建：`Config/Signing.local.xcconfig.example`
- 新建：`.gitignore`
- 新建：`FewerApp/App/FewerApp.swift`
- 新建：`FewerApp/Views/RootSettingsView.swift`
- 新建：各 Target 的 `Info.plist` 与 `.entitlements`
- 新建：`script/build_and_run.sh`
- 新建：`.codex/environments/environment.toml`
- 生成：`Fewer.xcodeproj`

### 步骤

1. 定义四个 Target：`FewerCore`、`Fewer`、`FewerFinderExtension`、`FewerShortcutHelper`，以及 `FewerCoreTests`。
2. 设置 bundle identifier、macOS 14.0、Swift 6、App Group 和 Finder Extension point。
3. 将 Finder 扩展嵌入 `Contents/PlugIns`，将快捷键助手嵌入 `Contents/Library/LoginItems`。
4. 用最小 SwiftUI 窗口证明主应用 Target 可启动；此时不添加假功能界面。
5. 构建脚本使用固定 DerivedData：`.build/DerivedData`，默认执行停止旧进程、XcodeGen、构建、启动。
6. 脚本实现 `--debug`、`--logs`、`--telemetry`、`--verify`；`--verify` 检查 Fewer 进程和嵌入组件是否存在。
7. Codex Run 操作只调用 `./script/build_and_run.sh`。

### 验证

```bash
xcodegen generate
xcodebuild -project Fewer.xcodeproj -scheme Fewer -configuration Debug -derivedDataPath .build/DerivedData build | xcbeautify
./script/build_and_run.sh --verify
```

预期：完整 `.app` 构建成功，主窗口出现，应用包内存在 `.appex` 与 Shortcut Helper。

## Task 2：共享模型与版本化配置存储

### 文件

- 新建：`FewerCore/Models/FeatureSettings.swift`
- 新建：`FewerCore/Models/ShortcutSettings.swift`
- 新建：`FewerCore/Models/TemplateDescriptor.swift`
- 新建：`FewerCore/Models/CutTransaction.swift`
- 新建：`FewerCore/Services/SharedSettingsStore.swift`
- 新建：`FewerCore/Support/AppGroupConstants.swift`
- 测试：`FewerCoreTests/SharedSettingsStoreTests.swift`

### 测试先行

1. 默认设置启用 New File、Copy Path、Cut、Paste，并保持确定顺序。
2. Codable 往返不丢字段。
3. 旧 schema 读取后补齐新字段。
4. 损坏 JSON 回退到默认值并保留可诊断错误。
5. 测试使用独立 `UserDefaults` suite，结束后清理。

### 实现

- 所有持久化模型带 `schemaVersion`。
- `SharedSettingsStore` 暴露小型同步读写接口，Finder 菜单构建不做文件扫描。
- App Group 不可用时返回明确错误；仅测试注入临时 suite，不在生产静默改用普通 defaults。

### 验证

```bash
xcodebuild test -project Fewer.xcodeproj -scheme FewerCore -derivedDataPath .build/DerivedData -only-testing:FewerCoreTests/SharedSettingsStoreTests | xcbeautify
```

## Task 3：路径格式与冲突命名

### 文件

- 新建：`FewerCore/Support/PathFormatter.swift`
- 新建：`FewerCore/Support/ConflictNameResolver.swift`
- 测试：`FewerCoreTests/PathFormatterTests.swift`
- 测试：`FewerCoreTests/ConflictNameResolverTests.swift`

### 测试先行

- 单选/多选 POSIX 路径。
- 空格、引号和反斜杠的带引号输出。
- `file://` URL 输出。
- `name.ext`、隐藏文件、无扩展名、多段扩展名的编号。
- 已存在 `name 2.ext` 时递增到下一个可用名称。

### 实现

- `PathFormatter` 只接收 `[URL]` 与格式枚举，返回字符串。
- `ConflictNameResolver` 通过可注入的存在性检查测试，不直接耦合全局 FileManager。

## Task 4：模板存储与合法内置模板

### 文件

- 新建：`FewerCore/Services/TemplateStore.swift`
- 新建：`FewerCore/Services/TemplateManifest.swift`
- 新建：`Resources/Templates/*`
- 测试：`FewerCoreTests/TemplateStoreTests.swift`
- 新建：`script/verify_templates.sh`

### 测试先行

1. 首次运行合并内置模板与空自定义清单。
2. 导入模板会复制源文件，源文件删除后仍可创建。
3. 自定义模板改名、排序、禁用、复制和删除。
4. 内置模板不能直接删除。
5. 损坏清单有明确错误且不删除模板文件。

### 实现

- 内置 TXT、Markdown、JSON、CSV 使用最小合法内容。
- DOCX、XLSX、PPTX 使用真实 Office Open XML 空白文件资源。
- 自定义模板使用 UUID 文件名与独立显示名称。
- 清单采用原子写入。

### 验证

```bash
./script/verify_templates.sh
xcodebuild test -project Fewer.xcodeproj -scheme FewerCore -derivedDataPath .build/DerivedData -only-testing:FewerCoreTests/TemplateStoreTests | xcbeautify
```

模板验证脚本必须检查 Office ZIP 包的关键 XML 条目，而不是只检查扩展名。

## Task 5：剪切事务与文件操作协调器

### 文件

- 新建：`FewerCore/Services/CutTransactionStore.swift`
- 新建：`FewerCore/Services/FileOperationCoordinator.swift`
- 新建：`FewerCore/Models/FileOperationResult.swift`
- 测试：`FewerCoreTests/CutTransactionStoreTests.swift`
- 测试：`FewerCoreTests/FileOperationCoordinatorTests.swift`

### 测试先行

- 创建、恢复、过期和剪贴板变更导致事务失效。
- 成功项目移除，失败项目保留。
- 单文件、多文件、目录和符号链接移动。
- 源等于目标、目录移入自身/后代目录被拒绝。
- 保留两者、跳过、替换三种冲突策略。
- 多项部分失败汇总结果正确。
- 重复请求通过事务 ID 去重。

### 实现

- 使用 actor 串行化事务与文件操作。
- 先完成校验，再逐项移动。
- 替换模式优先将旧目标移到废纸篓；无法安全恢复时返回失败，不静默删除。
- 操作结果包含用户可显示错误类别，不把原始路径写入常规日志。

## Task 6：与 UI 无关的 Finder 菜单模型

### 文件

- 新建：`FewerCore/Menu/FinderMenuContext.swift`
- 新建：`FewerCore/Menu/MenuCommand.swift`
- 新建：`FewerCore/Menu/MenuBuilder.swift`
- 测试：`FewerCoreTests/MenuBuilderTests.swift`

### 测试先行

- 目录背景显示 New File；有效剪切事务时显示 Paste Here。
- 文件选中显示 Copy Path 与 Cut。
- 单文件夹选中且有事务时显示 Paste Into Folder。
- 多选、空选择、只读位置和功能关闭时结果正确。
- 菜单顺序遵循设置。

### 实现

- `MenuBuilder` 返回平台无关命令树。
- Finder Extension 只负责将命令树转换为 `NSMenu` 和 selector。

## Task 7：Finder Sync Extension

### 文件

- 新建：`FewerFinderExtension/FinderSync.swift`
- 新建：`FewerFinderExtension/FinderMenuAdapter.swift`
- 新建：`FewerFinderExtension/FinderActionHandler.swift`
- 测试：`FewerCoreTests/FinderActionHandlerTests.swift`

### 步骤

1. 注册 Finder 可访问范围，不添加徽标或目录扫描。
2. 将 items/container/sidebar 场景映射为 `FinderMenuContext`。
3. 把 `MenuCommand` 映射为原生 `NSMenuItem` 和 New File 子菜单。
4. Copy Path 使用 `NSPasteboard` 写入字符串。
5. Cut 同时写入文件 URL pasteboard 与 `CutTransactionStore`。
6. Paste 调用 `FileOperationCoordinator`，完成后发送汇总通知。
7. 菜单构建同步且轻量；文件操作异步执行。

### 验证

```bash
xcodebuild -project Fewer.xcodeproj -scheme Fewer -configuration Debug -derivedDataPath .build/DerivedData build | xcbeautify
pluginkit -m -A -D -i com.number47.fewer.finder-extension
```

真实 Finder 菜单验证留到 Task 12，不以 `pluginkit` 注册信息代替可见菜单。

## Task 8：SwiftUI 设置应用骨架与状态页

### 文件

- 修改：`FewerApp/App/FewerApp.swift`
- 修改：`FewerApp/Views/RootSettingsView.swift`
- 新建：`FewerApp/Models/SettingsSection.swift`
- 新建：`FewerApp/Services/ExtensionStatusService.swift`
- 新建：`FewerApp/Services/PermissionService.swift`
- 新建：`FewerApp/Views/SidebarView.swift`
- 新建：`FewerApp/Views/OverviewView.swift`
- 测试：`FewerCoreTests/PermissionPresentationTests.swift`

### 实现

- `NavigationSplitView` 使用原生 sidebar list，不使用卡片式侧边栏。
- Overview 显示 Finder 扩展、Shortcut Helper、辅助功能权限三种真实状态。
- 提供 `FIFinderSyncController.showExtensionManagementInterface()` 与系统隐私设置入口。
- 权限文案区分“未请求、未授权、已授权、组件未运行”。

## Task 9：菜单、模板、快捷键与通用设置页面

### 文件

- 新建：`FewerApp/Views/ContextMenuSettingsView.swift`
- 新建：`FewerApp/Views/TemplateSettingsView.swift`
- 新建：`FewerApp/Views/ShortcutSettingsView.swift`
- 新建：`FewerApp/Views/GeneralSettingsView.swift`
- 新建：`FewerApp/Views/Components/StatusRow.swift`
- 新建：`FewerApp/Views/Components/ShortcutRecorder.swift`
- 新建：`FewerApp/Services/TemplateImportService.swift`

### 实现

- 菜单项目可启用、禁用和拖动排序。
- 模板页支持导入、复制、启用、重命名、排序、在关联应用打开和删除。
- Shortcut Recorder 拒绝无修饰键的普通字母，并检测 Fewer 内部冲突。
- General 显示冲突策略、通知、登录启动和诊断导出。
- 系统自适应颜色，支持 VoiceOver label、键盘焦点和缩放文本。

### 验证

- SwiftUI preview 仅作为辅助。
- 构建并真实导航全部设置页，验证修改后重启仍存在。

## Task 10：Shortcut Helper 与快捷键闭环

### 文件

- 新建：`FewerShortcutHelper/ShortcutHelperApp.swift`
- 新建：`FewerShortcutHelper/EventTapController.swift`
- 新建：`FewerShortcutHelper/FinderShortcutRouter.swift`
- 新建：`FewerShortcutHelper/PasteboardCutBridge.swift`
- 新建：`FewerCore/Services/HelperCommandStore.swift`
- 测试：`FewerCoreTests/PasteboardCutBridgeTests.swift`
- 测试：`FewerCoreTests/FinderShortcutRouterTests.swift`

### 测试先行

- 非 Finder 前台时所有键盘事件透传。
- Finder 无选中项时 `Command-X` 不创建事务。
- 有效剪切事务时 `Command-V` 映射为 Finder 原生移动粘贴。
- 普通复制或剪贴板 changeCount 改变后，`Command-V` 保持普通粘贴。
- 禁用设置或权限丢失时事件透传。

### 实现

- Event Tap 只筛选配置中的 keyCode 与 modifier。
- `Command-X` 通过 Finder 标准复制取得文件 URL，确认 pasteboard changeCount 后创建剪切事务。
- `Command-V` 仅在事务与当前 pasteboard 匹配时发送 `Option-Command-V`。
- 合成事件带内部标记，防止再次被自身拦截。
- 事件监听回调不执行文件 IO；状态处理转交 actor/串行队列。

## Task 11：Helper 生命周期、权限与通知

### 文件

- 新建：`FewerApp/Services/ShortcutHelperService.swift`
- 新建：`FewerCore/Support/NotificationNames.swift`
- 修改：`FewerApp/Views/OverviewView.swift`
- 修改：`FewerApp/Views/ShortcutSettingsView.swift`
- 修改：`FewerApp/Views/GeneralSettingsView.swift`

### 实现

- 使用 `SMAppService` 注册/取消隐藏登录项。
- 用户启用快捷键时请求辅助功能权限；失败时不把 UI 标记为成功。
- Helper 启动后写入心跳时间，主应用据此区分“已注册”和“正在运行”。
- 文件操作汇总通过 UserNotifications 展示，未授权通知时仍写入应用内最近结果。
- 导出的诊断日志移除完整路径和模板内容。

## Task 12：全量回归与真实 Finder 验收

### 自动验证

```bash
xcodegen generate
xcodebuild test -project Fewer.xcodeproj -scheme FewerCore -derivedDataPath .build/DerivedData | xcbeautify
./script/verify_templates.sh
./script/build_and_run.sh --verify
codesign --verify --deep --strict --verbose=2 .build/DerivedData/Build/Products/Debug/Fewer.app
```

### 真机清单

1. 启用 Finder Extension，并重启 Finder 使扩展加载。
2. 在目录背景确认 New File 与 Paste Here。
3. 在单选、多选文件确认 Copy Path 与 Cut。
4. 创建每种内置模板并用对应应用/格式检查器打开。
5. 导入自定义模板，删除原始文件后再次创建。
6. 验证右键 Cut → Paste Here、部分失败和重名策略。
7. 未授权辅助功能时确认右键正常、快捷键明确不可用。
8. 授权后验证 `Command-X` → `Command-V`。
9. 验证普通 `Command-C` → `Command-V` 没有被改成移动。
10. 重启 Fewer、Helper 和 Finder 后重新验证持久化。
11. 验证外置卷、只读位置、源文件消失和目录移入自身保护。
12. 验证深色/浅色、键盘导航和 VoiceOver 基本标签。

### 完成报告

报告必须分别列出：

- 自动测试结果。
- 完整 `.app` 构建和签名结果。
- Finder 原生菜单实际可见性。
- 快捷键真实执行结果。
- 未执行或受权限/签名阻塞的项目及准确原因。

## 推荐提交序列

1. `build: scaffold Fewer macOS targets`
2. `feat(core): add shared settings and models`
3. `feat(core): add paths templates and conflict handling`
4. `feat(core): add cut transactions and file operations`
5. `feat(finder): add Finder context menu extension`
6. `feat(app): add native settings interface`
7. `feat(shortcuts): add Finder cut and paste helper`
8. `test: verify Fewer v1 workflows`

每个提交前运行与该任务对应的最窄测试；最终提交前运行 Task 12 全量门禁。
