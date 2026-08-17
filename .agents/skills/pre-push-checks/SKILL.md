---
name: pre-push-checks
description: Use before pushing, force-pushing, marking ready for review, or claiming checks pass on a Fewer branch. Select the smallest relevant verification (xcodegen, targeted XCTest, verify.sh, verify_templates.sh, package.sh, build_and_run.sh) for the outgoing diff instead of reflexively running the full suite.
---

# Fewer Pre-Push Checks

push 前为即将推送的 diff 选择最小但足够的本地验证，而不是每次都跑完整仓库门禁。

## 1. 确认工作区与分支

```bash
git status --short --branch
git rev-parse --show-toplevel
```

记录 push 前已存在的无关修改，避免把验证结果错误归因。

## 2. 按改动范围选择验证

没有万能基线。按 diff 实际触及的模块选择最窄的可失败验证：

- **仅文档/注释/Markdown/模板**：`./script/verify_templates.sh`（涉及 `Resources/Templates` 或 `Info.plist` 时）+ `git diff --check`。不跑完整测试。
- **FewerCore 逻辑变更**：跑定向 XCTest。

  ```bash
  xcodebuild -project Fewer.xcodeproj -scheme FewerCore -configuration Debug \
    -derivedDataPath .build/DerivedData \
    SYMROOT="$PWD/.build/DerivedData/Build/Products" \
    OBJROOT="$PWD/.build/DerivedData/Build/Intermediates.noindex" \
    CODE_SIGNING_ALLOWED=NO test | xcbeautify
  ```

  新增核心逻辑必须覆盖成功、边界、失败路径；修复缺陷需有回归测试。
- **App/UI/权限/entitlements/扩展/Finder 菜单**：至少完整 Debug 构建；涉及真实交互（设置页、菜单栏日历、Finder 菜单、截图、快捷键）时用 `./script/build_and_run.sh --verify` 验证进程真实启动，并注明权限、签名或迁移影响。构建成功不能替代真实交互验证。
- **project.yml / target / scheme / 资源变化**：先 `xcodegen generate`，再 `./script/verify.sh`。
- **打包/签名/公证相关**：`./script/package.sh --local`；正式发布才用 `--signed --notarize`（需 `FEWER_SIGNING_IDENTITY` / `FEWER_NOTARY_PROFILE`）。
- **跨模块或无法归因**：直接跑唯一完整门禁 `./script/verify.sh`。

不要因为「要 push 了」就重复跑一遍已通过且不受本次改动影响的检查。

## 3. 完整门禁

`./script/verify.sh` 依次做：Codex 配置校验、内置模板校验、FewerCore 单测、完整 Debug 构建、产物与 diff 检查、验证 receipt 记录。跨模块改动、CI 失败排查、或用户明确要求时运行它。

## 4. 保护历史重写 push

rebase 允许，但禁止裸 `--force`。改写历史前先 fetch 当前远端分支并记录其 OID，用租约保护：

```bash
git push --force-with-lease=<branch>:<observed-oid>
```

改写后重新检查 review 状态与 CI；旧 commit 的哈希与行内评论不再作为证据。

## 5. push 后确认

```bash
git rev-parse HEAD origin/$(git branch --show-current)
```

有 PR 时再看远端 CI：

```bash
gh pr checks
```

待运行的检查报「待运行」；失败先排查再归因，不要默认是环境问题。

## 6. 失败处理

相关验证失败就先修或说明阻塞，不要 push 后指望 CI 兜底。疑似环境相关时记录确切命令、失败用例和平台差异，再确认非平台证据。
