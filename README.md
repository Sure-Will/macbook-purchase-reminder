# Mac Purchase Countdown Reminder (Win11)

Win11 PowerShell reminder for MacBook Air M5 purchase windows.

## What it does

- Sends Win11 Toast reminders in four Beijing-time windows:
  - `00:00-00:10`
  - `09:50-10:20`
  - `14:00-15:00`
  - `20:00-22:30`
- Shows countdown around launch date `2026-03-11`.
- Includes two JD SKU buttons in every toast:
  - `32+512 银色`
  - `24+512 天蓝色`
- Launches a mini draggable dashboard by default:
  - movable small window (not fullscreen)
  - countdown to next purchase slot
  - topmost toggle
  - close button (dashboard only)
- Writes reminder and click logs to `logs/reminder-log.csv`.

## Run

From project root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-reminder.ps1
```

This starts both:
- reminder loop (toast)
- mini dashboard window

## Send one test toast

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-reminder.ps1 -TestToast
```

## Optional modes

```powershell
# Reminder only (no mini dashboard)
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-reminder.ps1 -NoDashboard

# Dashboard only (no reminder loop)
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-reminder.ps1 -DashboardOnly
```

## Files

- `config.json`: launch date, slots, SKU links, interval.
- `start-reminder.ps1`: main scheduler and toast sender.
- `launch-dashboard.ps1`: mini dashboard window.
- `open-sku.ps1`: called by toast buttons, opens URL and logs click.
- `dashboard-state.json`: persisted mini dashboard position and topmost flag.
- `tools/open_*.cmd`: generated launcher scripts for each SKU button.
- `logs/reminder-log.csv`: reminder/click audit log.

## Notes

- Keep the PowerShell window running after start.
- If toast does not appear, check Windows notification settings:
  - `Settings -> System -> Notifications`.
