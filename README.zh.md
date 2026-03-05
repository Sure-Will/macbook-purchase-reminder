# MacBook抢购提醒（Win11）

> [!WARNING]
> 已弃用：目标机型已抢购成功。该项目转为归档状态，不再维护。

基于 Win11 PowerShell 的 MacBook Air M5 抢购时间段提醒脚本。

## 功能说明

- 在北京时间四个时间段发送 Win11 Toast 提醒：
  - `00:00-00:10`
  - `09:50-10:20`
  - `14:00-15:00`
  - `20:00-22:30`
- 围绕发售日 `2026-03-11` 显示倒计时信息。
- 每条提醒包含两个京东 SKU 快捷按钮：
  - `32 + 512 银色`
  - `24 + 512 天蓝色`
- 默认自动启动可拖拽迷你面板：
  - 可移动小窗（非全屏）
  - 显示下一次抢购时间段倒计时
  - 支持置顶开关
  - 支持单独关闭面板
- 提醒与点击日志写入 `logs/reminder-log.csv`。

## 运行方式

在项目根目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-reminder.ps1
```

该命令会同时启动：
- 提醒循环（Toast）
- 迷你面板窗口

## 发送一次测试提醒

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-reminder.ps1 -TestToast
```

## 可选模式

```powershell
# 仅提醒（不启动迷你面板）
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-reminder.ps1 -NoDashboard

# 仅面板（不启动提醒循环）
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-reminder.ps1 -DashboardOnly
```

## 主要文件

- `config.json`：发售日期、时间段、SKU 链接、提醒间隔配置。
- `start-reminder.ps1`：主调度与 Toast 发送入口。
- `launch-dashboard.ps1`：迷你面板窗口脚本。
- `open-sku.ps1`：Toast 按钮调用脚本，用于打开链接并记录点击日志。
- `dashboard-state.json`：面板位置与置顶状态持久化文件。
- `tools/open_*.cmd`：为每个 SKU 自动生成的启动脚本。
- `logs/reminder-log.csv`：提醒/点击审计日志。

## 注意事项

- 启动后请保持 PowerShell 窗口运行。
- 如果没有弹出提醒，请检查 Windows 通知设置：
  - `Settings -> System -> Notifications`
