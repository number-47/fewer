---
name: ship-code
description: Use for tasks that create, edit, delete, or rename Fewer repository code, tests, build scripts, project.yml, or tracked configuration. Run the complete implementation, verification, independent review, and reporting workflow. Do not use for read-only explanation, diagnosis, planning, review, or status checks.
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
- 实现完成后运行唯一完整门禁：

  ```bash
  ./script/verify.sh
  ```

- 只修复由本任务造成的失败；对预先存在或无法归因的失败保留证据并明确报告。

## 4. 独立审查

- 委派项目自定义 `reviewer` agent，提供用户需求、成功标准、任务文件清单和本任务 diff 范围。
- 若自定义 agent 尚未加载，改用一个明确只读的独立 subagent 执行同样审查，并报告该回退。
- 修复全部 P0、P1，以及确实影响本任务的 P2；忽略纯风格偏好和范围外建议。
- 审查后发生任何代码变化时，再次运行 `./script/verify.sh`。

## 5. 交付检查

- 检查任务文件的最终 diff，排除调试代码、秘密、生成垃圾、弱化断言和无关格式变化。
- UI、Finder、截图或权限行为必须执行真实交互验证；无法执行时明确标记为未验证，不能用构建成功替代。
- 用中文报告实现行为、验证命令和结果、review 结论、剩余风险及未验证项。
- 除非用户明确要求，否则不要 stage、commit、push、merge 或创建 PR。
