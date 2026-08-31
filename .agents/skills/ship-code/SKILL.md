---
name: ship-code
description: Use for tasks that create, edit, delete, or rename Fewer repository code, tests, build scripts, project.yml, or tracked configuration. Run the implementation, minimum sufficient verification, main-conversation acceptance, and reporting workflow. Do not use for read-only explanation, diagnosis, planning, review, or status checks.
---

# Ship Code

把每次代码改动完成为可验证、可审查、范围清晰的交付。

## 1. 建立任务基线

- 阅读适用的 `AGENTS.md` 和相关实现、测试。
- 运行 `git status --short`，记录任务开始前已有的修改、删除和未跟踪文件。
- 若目标文件已经是 dirty，编辑前查看其 diff；后续只归属并审查本任务新增的变化。
- 对复杂任务先形成简短实施计划，并为每一步写明验证方式。

## 2. 最小实现

- 只修改满足需求所需的代码，不做相邻重构或格式整理。
- 修复缺陷时先重现问题，并在可行时添加回归测试。
- 优先复用现有依赖和抽象；新增生产依赖前请求用户确认。
- 修改 target、scheme 或资源后运行 `xcodegen generate`，并把生成的工程变化纳入本任务。

## 3. 逐步验证

- 在迭代过程中运行与改动直接相关的最小测试。
- 完成时运行任务明确要求的最小充分验证；只修复由本任务造成的失败，对预先存在或无法归因的失败保留证据。
- 仅在跨模块改动、`project.yml`/target/scheme、验证基础设施、发布任务、无法归因的改动，或用户明确要求时，运行完整门禁：

  ```bash
  ./script/verify.sh
  ```

`pre-push-checks` 是推送或标记可审查时的详细验证矩阵；不要在这里复制另一套门禁。审查后若有代码变化，只重新运行受影响的验证；完整门禁只在其适用范围发生变化时重跑。

## 4. 主对话验收

- 主对话检查任务 diff、验收标准、验证证据、范围控制与剩余风险。
- 修复全部 P0、P1，以及确实影响本任务的 P2；忽略纯风格偏好和范围外建议。

## 5. 交付检查

- 检查任务文件的最终 diff，排除调试代码、秘密、生成垃圾、弱化断言和无关格式变化。
- UI、Finder、截图或权限行为必须执行真实交互验证；无法执行时明确标记为未验证，不能用构建成功替代。
- 用中文报告实现行为、验证命令和结果、review 结论、剩余风险及未验证项。
- 除非用户明确要求，否则不要 stage、commit、push、merge 或创建 PR。
