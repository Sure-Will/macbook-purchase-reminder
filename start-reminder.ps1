param(
    [switch]$TestToast,
    [switch]$RunOnce,
    [switch]$NoDashboard,
    [switch]$DashboardOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptRoot "config.json"
$dashboardScriptPath = Join-Path $scriptRoot "launch-dashboard.ps1"
$dashboardStatePath = Join-Path $scriptRoot "dashboard-state.json"
$logsDir = Join-Path $scriptRoot "logs"
$toolsDir = Join-Path $scriptRoot "tools"
$logPath = Join-Path $logsDir "reminder-log.csv"

if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
}
if (-not (Test-Path $toolsDir)) {
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
}

function Convert-ToCsvValue {
    param([string]$Value)
    if ($null -eq $Value) {
        $Value = ""
    }
    '"' + ($Value -replace '"', '""') + '"'
}

function Write-ReminderLog {
    param(
        [string]$Slot,
        [string]$Phase,
        [string]$Countdown,
        [string]$SkuTags,
        [string]$ClickedSku,
        [string]$Status,
        [string]$ErrorMessage = ""
    )

    if (-not (Test-Path $logPath)) {
        "timestamp,slot,phase,countdown,sku_tags,clicked_sku,status,error" | Out-File -FilePath $logPath -Encoding utf8
    }

    $values = @(
        (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"),
        $Slot,
        $Phase,
        $Countdown,
        $SkuTags,
        $ClickedSku,
        $Status,
        $ErrorMessage
    )

    $line = ($values | ForEach-Object { Convert-ToCsvValue -Value $_ }) -join ","
    Add-Content -Path $logPath -Value $line -Encoding utf8
}

function Resolve-TimeZoneInfo {
    param([string]$ConfiguredTimeZone)

    $ianaToWindows = @{
        "Asia/Shanghai" = "China Standard Time"
    }

    $candidates = @()
    if ($ConfiguredTimeZone) {
        $candidates += $ConfiguredTimeZone
    }
    if ($ianaToWindows.ContainsKey($ConfiguredTimeZone)) {
        $candidates += $ianaToWindows[$ConfiguredTimeZone]
    }
    $candidates += "China Standard Time"

    foreach ($candidate in $candidates | Select-Object -Unique) {
        try {
            return [System.TimeZoneInfo]::FindSystemTimeZoneById($candidate)
        }
        catch {
            continue
        }
    }

    throw "Cannot resolve timezone from config value '$ConfiguredTimeZone'."
}

function Get-NowInZone {
    param([System.TimeZoneInfo]$TimeZone)
    [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $TimeZone)
}

function Get-MinutesOfDay {
    param([datetime]$DateTimeValue)
    ($DateTimeValue.Hour * 60) + $DateTimeValue.Minute
}

function Parse-TimeToMinutes {
    param([string]$HHmm)

    $parts = $HHmm.Split(":")
    if ($parts.Count -ne 2) {
        throw "Invalid time format: $HHmm. Expected HH:mm"
    }
    ([int]$parts[0] * 60) + [int]$parts[1]
}

function Get-CurrentSlot {
    param(
        [datetime]$NowLocal,
        [array]$Slots
    )

    $nowMinutes = Get-MinutesOfDay -DateTimeValue $NowLocal
    foreach ($slot in $Slots) {
        $startMinutes = Parse-TimeToMinutes -HHmm $slot.start
        $endMinutes = Parse-TimeToMinutes -HHmm $slot.end

        if ($startMinutes -le $endMinutes) {
            if ($nowMinutes -ge $startMinutes -and $nowMinutes -le $endMinutes) {
                return $slot
            }
        }
        else {
            if ($nowMinutes -ge $startMinutes -or $nowMinutes -le $endMinutes) {
                return $slot
            }
        }
    }
    return $null
}

function Get-Phase {
    param(
        [datetime]$NowLocal,
        [datetime]$EventDate
    )

    if ($NowLocal.Date -lt $EventDate.Date) {
        return "PRESALE"
    }
    if ($NowLocal.Date -eq $EventDate.Date) {
        return "LAUNCH_DAY"
    }
    return "POST_LAUNCH"
}

function Get-CountdownText {
    param(
        [datetime]$NowLocal,
        [datetime]$EventDate
    )

    if ($NowLocal.Date -lt $EventDate.Date) {
        $span = $EventDate - $NowLocal
        if ($span.TotalMinutes -lt 0) {
            $span = [TimeSpan]::Zero
        }
        return "Countdown: {0}d {1}h {2}m" -f $span.Days, $span.Hours, $span.Minutes
    }
    if ($NowLocal.Date -eq $EventDate.Date) {
        return "Launch day: monitor stock closely"
    }

    $daysAfter = ($NowLocal.Date - $EventDate.Date).Days
    return "Post-launch day {0}: restock monitoring" -f $daysAfter
}

function Ensure-SkuLaunchers {
    param(
        [array]$Skus,
        [string]$ScriptRoot,
        [string]$ConfigFilePath,
        [string]$LogFilePath
    )

    $openSkuScript = Join-Path $ScriptRoot "open-sku.ps1"
    $buttonUriBySkuId = @{}

    foreach ($sku in $Skus) {
        $safeId = ($sku.id -replace "[^a-zA-Z0-9_-]", "_")
        $cmdPath = Join-Path $toolsDir ("open_{0}.cmd" -f $safeId)

        $cmdBody = @(
            "@echo off",
            "setlocal",
            "powershell -NoProfile -ExecutionPolicy Bypass -File `"$openSkuScript`" -SkuId `"$($sku.id)`" -ConfigPath `"$ConfigFilePath`" -LogPath `"$LogFilePath`""
        ) -join "`r`n"

        Set-Content -Path $cmdPath -Value $cmdBody -Encoding ascii
        $buttonUriBySkuId[$sku.id] = ([System.Uri]::new($cmdPath)).AbsoluteUri
    }

    return $buttonUriBySkuId
}

function Escape-Xml {
    param([string]$Text)
    [System.Security.SecurityElement]::Escape($Text)
}

function Send-ReminderToast {
    param(
        [string]$Title,
        [string]$Line1,
        [string]$Line2,
        [string]$Line3,
        [array]$Skus,
        [hashtable]$ButtonUriBySkuId
    )

    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

    $actionsXml = ""
    foreach ($sku in $Skus) {
        $uri = $ButtonUriBySkuId[$sku.id]
        $actionsXml += "<action content=""{0}"" arguments=""{1}"" activationType=""protocol"" />" -f (Escape-Xml ("Open " + $sku.tag)), (Escape-Xml $uri)
    }

    $toastXml = @"
<toast scenario="reminder">
  <visual>
    <binding template="ToastGeneric">
      <text>$(Escape-Xml $Title)</text>
      <text>$(Escape-Xml $Line1)</text>
      <text>$(Escape-Xml $Line2)</text>
      <text>$(Escape-Xml $Line3)</text>
    </binding>
  </visual>
  <actions>
    $actionsXml
  </actions>
</toast>
"@

    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml($toastXml)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("PowerShell")
    $notifier.Show($toast)
}

function Start-DashboardProcess {
    param(
        [string]$DashboardScriptPath,
        [string]$ConfigFilePath,
        [string]$StateFilePath
    )

    if (-not (Test-Path $DashboardScriptPath)) {
        Write-Warning "Dashboard script not found, skip launching mini panel."
        return
    }

    $pathPattern = [System.Text.RegularExpressions.Regex]::Escape($DashboardScriptPath)
    $existingPids = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine -match $pathPattern
    } | ForEach-Object { $_.ProcessId }

    $hasVisibleDashboard = $false
    foreach ($procId in $existingPids) {
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($null -ne $proc -and ($proc.MainWindowHandle -ne 0 -or $proc.MainWindowTitle -eq "Mac Purchase Mini Panel")) {
            $hasVisibleDashboard = $true
            break
        }
    }

    if ($hasVisibleDashboard) {
        Write-Host "Dashboard is already running."
        return
    }

    foreach ($procId in $existingPids) {
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $DashboardScriptPath,
        "-ConfigPath", $ConfigFilePath,
        "-StatePath", $StateFilePath
    )

    Start-Process -FilePath "powershell" -ArgumentList $args | Out-Null
    Write-Host "Dashboard launched."
}

if (-not (Test-Path $configPath)) {
    throw "config.json not found: $configPath"
}

if ($NoDashboard -and $DashboardOnly) {
    throw "Cannot use -NoDashboard and -DashboardOnly together."
}

$config = Get-Content -Path $configPath -Raw -Encoding utf8 | ConvertFrom-Json
$tzInfo = Resolve-TimeZoneInfo -ConfiguredTimeZone $config.timezone
$eventDate = [datetime]::ParseExact($config.eventDate, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
$buttonUriBySkuId = Ensure-SkuLaunchers -Skus $config.skus -ScriptRoot $scriptRoot -ConfigFilePath $configPath -LogFilePath $logPath
$skuTags = ($config.skus | ForEach-Object { $_.tag }) -join " / "

Write-Host "Mac Purchase Reminder started."
Write-Host ("Timezone: {0}" -f $tzInfo.Id)
Write-Host ("Event date: {0}" -f $eventDate.ToString("yyyy-MM-dd"))
Write-Host ("SKUs: {0}" -f $skuTags)

if ($DashboardOnly) {
    Start-DashboardProcess -DashboardScriptPath $dashboardScriptPath -ConfigFilePath $configPath -StateFilePath $dashboardStatePath
    Write-Host "Dashboard-only mode. Reminder loop not started."
    return
}

if ((-not $NoDashboard) -and (-not $TestToast)) {
    Start-DashboardProcess -DashboardScriptPath $dashboardScriptPath -ConfigFilePath $configPath -StateFilePath $dashboardStatePath
}

if ($TestToast) {
    $now = Get-NowInZone -TimeZone $tzInfo
    $phase = Get-Phase -NowLocal $now -EventDate $eventDate
    $countdown = Get-CountdownText -NowLocal $now -EventDate $eventDate
    $line3 = "SKUs: " + (($config.skus | ForEach-Object { $_.tag }) -join " / ")

    try {
        Send-ReminderToast `
            -Title "MacBook Air M5 JD Reminder" `
            -Line1 "Test reminder | open JD links directly" `
            -Line2 $countdown `
            -Line3 $line3 `
            -Skus $config.skus `
            -ButtonUriBySkuId $buttonUriBySkuId
        Write-ReminderLog -Slot "TEST_SLOT" -Phase $phase -Countdown $countdown -SkuTags $skuTags -ClickedSku "" -Status "test_sent"
        Write-Host "Test toast sent."
    }
    catch {
        Write-ReminderLog -Slot "TEST_SLOT" -Phase $phase -Countdown $countdown -SkuTags $skuTags -ClickedSku "" -Status "test_failed" -ErrorMessage $_.Exception.Message
        throw
    }
    return
}

$lastSentBySlot = @{}
$intervalMinutes = [int]$config.slotIntervalMinutes

while ($true) {
    $nowLocal = Get-NowInZone -TimeZone $tzInfo
    $slot = Get-CurrentSlot -NowLocal $nowLocal -Slots $config.timeSlots

    if ($null -ne $slot) {
        $slotKey = "{0}|{1}-{2}" -f $slot.name, $slot.start, $slot.end
        $shouldSend = $false

        if (-not $lastSentBySlot.ContainsKey($slotKey)) {
            $shouldSend = $true
        }
        else {
            $elapsed = $nowLocal - $lastSentBySlot[$slotKey]
            if ($elapsed.TotalMinutes -ge $intervalMinutes) {
                $shouldSend = $true
            }
        }

        if ($shouldSend) {
            $phase = Get-Phase -NowLocal $nowLocal -EventDate $eventDate
            $countdown = Get-CountdownText -NowLocal $nowLocal -EventDate $eventDate
            $line1 = "{0} {1}-{2}" -f $slot.name, $slot.start, $slot.end
            $line3 = "SKUs: " + (($config.skus | ForEach-Object { $_.tag }) -join " / ")

            try {
                Send-ReminderToast `
                    -Title "MacBook Air M5 JD Reminder" `
                    -Line1 $line1 `
                    -Line2 $countdown `
                    -Line3 $line3 `
                    -Skus $config.skus `
                    -ButtonUriBySkuId $buttonUriBySkuId

                $lastSentBySlot[$slotKey] = $nowLocal
                Write-ReminderLog -Slot $slotKey -Phase $phase -Countdown $countdown -SkuTags $skuTags -ClickedSku "" -Status "sent"
                Write-Host ("[{0}] Reminder sent: {1}" -f $nowLocal.ToString("yyyy-MM-dd HH:mm:ss"), $slotKey)
            }
            catch {
                Write-ReminderLog -Slot $slotKey -Phase $phase -Countdown $countdown -SkuTags $skuTags -ClickedSku "" -Status "send_failed" -ErrorMessage $_.Exception.Message
                Write-Warning ("[{0}] Reminder failed: {1}" -f $nowLocal.ToString("yyyy-MM-dd HH:mm:ss"), $_.Exception.Message)
            }
        }
    }

    if ($RunOnce) {
        break
    }

    $sec = 60 - (Get-Date).Second
    if ($sec -lt 1) {
        $sec = 1
    }
    Start-Sleep -Seconds $sec
}
