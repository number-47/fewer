# Repository Guidelines

## 项目结构与模块组织

Fewer 是面向 macOS 14+ 的 Swift 6 应用。`FewerApp/` 包含菜单栏主应用、SwiftUI 视图、应用服务与资源；`FewerCore/` 存放可复用模型、菜单逻辑、文件操作及共享设置。`FewerFinderExtension/` 实现 Finder Sync 扩展，`FewerShortcutHelper/` 负责全局快捷键辅助进程，`FewerCoreTests/` 保存 XCTest 单元测试。模板资源位于 `Resources/Templates/`，签名与版本配置位于 `Config/`。`project.yml` 是 XcodeGen 的工程源文件；修改 target、scheme 或资源后应重新生成 `Fewer.xcodeproj`。

## 构建、测试与开发命令

DerivedData 路径约定：Debug 构建与单元测试一律复用 `.build/DerivedData`，Release 打包复用 `.build/PackageDerivedData`。自定义构建/测试命令不得另起新目录名，避免 `.build` 体积膨胀；清理构建产物直接删除这两个目录即可。注意：本机 Xcode 全局设置为自定义绝对构建位置（`IDECustomBuildProductsPath`），因此测试等 xcodebuild 命令必须像下方一样显式传入 `SYMROOT/OBJROOT`，产物才会进入项目 `.build` 而非全局目录。

- `xcodegen generate`：依据 `project.yml` 更新 Xcode 工程。
- `./script/build_and_run.sh run`：生成工程、构建 Debug 到 `.build/DerivedData`、签名并启动应用；需要 Apple Development 证书。
- `./script/build_and_run.sh --logs`：启动应用并流式查看三个进程的系统日志。
- `xcodebuild -project Fewer.xcodeproj -scheme FewerCore -configuration Debug -derivedDataPath .build/DerivedData SYMROOT="$PWD/.build/DerivedData/Build/Products" OBJROOT="$PWD/.build/DerivedData/Build/Intermediates.noindex" CODE_SIGNING_ALLOWED=NO test | xcbeautify`：运行核心单元测试（与构建共享同一 DerivedData，可复用增量产物）。
- `./script/verify_templates.sh`：校验内置 Office 模板及 `Info.plist`。
- `./script/package.sh --local`：生成本机测试 DMG；正式发布使用 `--signed --notarize`。

## 编码风格与命名约定

使用四空格缩进，遵循 Swift API Design Guidelines。类型采用 `UpperCamelCase`，方法、属性和测试方法采用 `lowerCamelCase`；文件通常与主要类型同名。保持 `SWIFT_STRICT_CONCURRENCY = complete`，明确使用 `Sendable`、`@MainActor` 与安全的异步边界。优先将业务逻辑放入 `FewerCore`，让 AppKit/SwiftUI 层保持轻量。仓库未配置自动格式化器，提交前请保持现有排版并消除编译警告。

## 测试指南

测试使用 XCTest，文件命名为 `<Subject>Tests.swift`，测试方法以 `test` 开头并描述行为，例如 `testStartDateRejectsInvalidMonth`。修复缺陷时添加回归测试；日期测试应显式设置 locale、时区和首周日。项目未规定覆盖率阈值，但新增核心逻辑必须覆盖成功、边界及失败路径。

## 提交与拉取请求

沿用简洁的 Conventional Commits：`feat: ...`、`fix: ...`、`docs: ...`、`test: ...`。每个提交聚焦一个可验证改动。PR 应说明动机、影响的 target、验证命令及结果；关联相关 issue。涉及设置页、菜单栏日历或 Finder 菜单的界面变化时附截图或录屏，并注明权限、签名或迁移影响。

## 安全与配置

不要提交证书、钥匙串信息或 `Config/Signing.local.xcconfig`。本地签名通过 `FEWER_SIGNING_IDENTITY` 配置，公证凭据通过 `FEWER_NOTARY_PROFILE` 提供；新增权限时同步审查 entitlements、用途说明与最小权限范围。
