# D001: 平滑滚动的合成事件必须是格式正确的离散/触控板事件

- 日期：2026-08-17
- 状态：proposed
- 背景：`SmoothScrollEngine.post` 用 `CGEvent(scrollWheelEvent2Source:units:.pixel,…)` 生成合成事件，实测其 `scrollWheelEventIsContinuous` 默认为 1，而 `simulatesTrackpad == false` 时未重置该字段、也未设置 phase/momentum，导致产生“连续标记 + phase=none”的畸形事件。
- 决策：合成滚动事件的字段（`isContinuous`、`scrollPhase`、`momentumPhase`、各轴 delta）应显式、按 `simulatesTrackpad` 分支构造：非触控板模拟输出离散事件，触控板模拟输出完整 phase/momentum 序列；相关字段规格抽到 `FewerCore` 以便单测覆盖。
- 影响：修改范围集中在 `FewerShortcutHelper/SmoothScrollEngine.swift`（必要时 `FewerCore/Services/InputProcessing.swift`），并新增回归测试；不改设置 UI、衰减算法与符号翻转逻辑。
