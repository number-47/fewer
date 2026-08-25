# fewer

> 少一点软件，多一点效率。

fewer 是一款面向 macOS 的原生菜单栏效率工具，将系统监控、日历、截图、Finder 增强和输入增强集中在一个轻量入口中。项目使用 Swift 6 开发，支持 macOS 14 及更高版本。

当前版本：`0.1.0`

## 功能概览

- **菜单栏仪表盘**：查看 CPU、GPU、内存、磁盘和网络状态，并按需调整模块的显示与顺序。
- **日历与提醒**：在菜单栏中浏览日期、系统日程和带日期的提醒事项。
- **智能截图**：支持智能、区域、窗口、全屏和滚动截图，并提供标注、复制、保存与贴图能力。
- **Finder 增强**：通过右键菜单新建文件或文件夹、使用模板创建文件、复制不同格式的路径、剪切粘贴、选择应用或终端打开，以及刷新 Finder。
- **输入增强**：提供平滑滚动、滚动方向调整、鼠标轨迹手势和按键展示。
- **系统快捷操作**：快速切换深色模式、静音和防休眠，关闭显示器或清空剪贴板。

各模块可以独立启用、隐藏和排序；不同功能依赖对应的系统权限。

## 环境要求

- macOS 14.0 或更高版本
- Xcode 16 或其他支持 Swift 6 的 Xcode 版本
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [xcbeautify](https://github.com/cpisciotta/xcbeautify)
- 用于本机运行的 Apple Development 签名证书和 Developer Team ID

可以使用 Homebrew 安装命令行依赖：

```bash
brew install xcodegen xcbeautify
```

## 从源码运行

1. 克隆仓库：

   ```bash
   git clone https://github.com/number-47/fewer.git
   cd fewer
   ```

2. 创建本地签名配置：

   ```bash
   cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
   ```

   编辑 `Config/Signing.local.xcconfig`，将 `YOUR_TEAM_ID` 替换为 Apple Developer Team ID。该文件已被 Git 忽略，不应提交。

3. 生成工程、构建、签名并启动应用：

   ```bash
   ./script/build_and_run.sh run
   ```

脚本会将 Debug 产物写入 `.build/DerivedData`，嵌入 Finder 扩展与快捷键辅助进程，并优先使用环境变量 `FEWER_SIGNING_IDENTITY` 指定的证书；未设置时会自动查找本机的 Apple Development 证书。

## 系统权限

部分能力需要在“系统设置 → 隐私与安全性”中授权：

| 权限 | 用途 |
| --- | --- |
| 屏幕录制 | 截取屏幕、窗口和滚动内容 |
| 辅助功能 | 执行输入增强和鼠标手势动作 |
| 输入监控 | 观察键盘、鼠标与滚轮事件 |
| 日历与提醒事项 | 在菜单栏日历中展示日程和提醒 |
| 定位服务 | 在展开 Wi-Fi 详情时读取网络名称、BSSID 和信号强度 |
| 自动化 | 在用户触发快捷操作时切换系统深色模式 |

Finder 右键菜单由随应用嵌入的 Finder Sync 扩展提供。若菜单未出现，请在系统设置的扩展管理中确认 Fewer Finder 扩展已经启用。

## 开发与验证

`project.yml` 是 Xcode 工程的唯一配置源。修改 target、scheme、构建设置或资源后，重新生成工程：

```bash
xcodegen generate
```

常用命令：

```bash
# 构建并运行 Debug 应用
./script/build_and_run.sh run

# 启动应用并查看主应用、Finder 扩展与 Helper 日志
./script/build_and_run.sh --logs

# 运行完整项目门禁
./script/verify.sh

# 校验内置 Office 模板与 Info.plist
./script/verify_templates.sh

# 生成本机测试 DMG
./script/package.sh --local
```

仅运行核心单元测试：

```bash
xcodebuild \
  -project Fewer.xcodeproj \
  -scheme FewerCore \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  SYMROOT="$PWD/.build/DerivedData/Build/Products" \
  OBJROOT="$PWD/.build/DerivedData/Build/Intermediates.noindex" \
  CODE_SIGNING_ALLOWED=NO \
  test | xcbeautify
```

正式发布包需要 Developer ID Application 证书；执行 Apple 公证时还需要预先配置 `notarytool` 钥匙串凭据：

```bash
FEWER_SIGNING_IDENTITY="Developer ID Application: ..." \
FEWER_NOTARY_PROFILE="your-notary-profile" \
./script/package.sh --signed --notarize
```

## 项目结构

```text
FewerApp/               菜单栏主应用、SwiftUI 视图和应用服务
FewerCore/              可复用模型、菜单逻辑、文件操作与共享设置
FewerFinderExtension/   Finder Sync 右键菜单扩展
FewerShortcutHelper/    全局快捷键与输入事件辅助进程
FewerCoreTests/         核心 XCTest 单元测试
FewerUITests/           macOS UI 测试
Resources/Templates/    内置文件模板
Config/                 版本、构建与本地签名配置
script/                 构建、验证和打包脚本
project.yml             XcodeGen 工程配置源
```

## 参与开发

提交改动前请先运行 `./script/verify.sh`。提交信息采用简洁的 [Conventional Commits](https://www.conventionalcommits.org/) 格式，例如 `feat: ...`、`fix: ...`、`docs: ...` 和 `test: ...`。

涉及界面、Finder 菜单、系统权限或签名行为的变更，请在 Pull Request 中说明真实运行环境和验证结果；构建成功不能替代对应的交互验证。
