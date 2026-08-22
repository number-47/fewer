# Current Project State

> 此文件只表达“现在是什么状态”，不记录历史。
> 任务完成后移出本文件，历史进入 `tasks/archive/`。

## Objective

完成五模块 Stats 风格菜单栏监控，并修复网络统计、按键展示位置、日历入口和鼠标手势右键回放。

## Current Milestone

菜单栏监控与输入交互修复。

## Active Tasks

| Task | Title | Status | Priority | Depends On |
|------|-------|--------|----------|------------|
| T012 | 集成与发布验收 | IN_PROGRESS | P0 | T004-T011 |

## Review Queue

| Task | Title | Status | Priority |
|------|-------|--------|----------|
| T001 | 修复输入增强“平滑滚动 + 反转方向”后鼠标滚轮失效 | REVIEW | P1 |
| T002 | 五模块模型、偏好与 schema 4 迁移 | REVIEW | P0 |
| T003 | 共享菜单栏组件与状态项引擎 | REVIEW | P0 |
| T004 | CPU 模块 | REVIEW | P1 |
| T005 | GPU 模块 | REVIEW | P1 |
| T006 | 内存模块 | REVIEW | P1 |
| T007 | 磁盘模块 | REVIEW | P1 |
| T008 | 网络模块与默认路由统计 | REVIEW | P0 |
| T009 | 按键展示位置 | REVIEW | P1 |
| T010 | 独立菜单栏日历 | REVIEW | P1 |
| T011 | 鼠标手势右键分界 | REVIEW | P1 |

## Blocked

无。

## Recommended Next Task

执行 T002；T001 保持 REVIEW，待真实鼠标滚轮实机确认。

## Current Risks

- T001 的“其他应用中真实滚轮滚动”仍需用户实机确认（需真实滚轮输入）。
- IOReport、SMC、SMART 与 Wi-Fi 定位权限需要在签名实机上验证。

## Last Updated

2026-08-22
