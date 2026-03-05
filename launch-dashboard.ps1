param(
    [string]$ConfigPath = "",
    [string]$StatePath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptRoot "config.json"
}
if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Join-Path $scriptRoot "dashboard-state.json"
}

if (-not (Test-Path $ConfigPath)) {
    throw "config.json not found: $ConfigPath"
}

$config = Get-Content -Path $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
if ($null -eq $config.skus -or $config.skus.Count -lt 1) {
    throw "No SKU found in config.json"
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

function Parse-TimeToMinutes {
    param([string]$HHmm)
    $parts = $HHmm.Split(":")
    if ($parts.Count -ne 2) {
        throw "Invalid time format: $HHmm. Expected HH:mm"
    }
    ([int]$parts[0] * 60) + [int]$parts[1]
}

function Get-SlotDisplayName {
    param([string]$SlotName)

    if ([string]::IsNullOrWhiteSpace($SlotName)) {
        return "未命名"
    }
    if ($SlotName -like "*凌晨*") {
        return "凌晨"
    }
    if ($SlotName -like "*上午*") {
        return "上午"
    }
    if ($SlotName -like "*下午*") {
        return "下午"
    }
    if ($SlotName -like "*晚间*" -or $SlotName -like "*晚上*") {
        return "晚上"
    }
    return $SlotName
}

function Format-SkuTagForDisplay {
    param(
        [string]$SkuId,
        [string]$SkuTag
    )

    if ($SkuId -eq "M5-32-512-SILVER") {
        return "32 + 512 银色"
    }
    if ($SkuId -eq "M5-24-512-SKYBLUE") {
        return "24 + 512 天蓝色"
    }
    if ([string]::IsNullOrWhiteSpace($SkuTag)) {
        return "暂无"
    }
    return ($SkuTag -replace "\s*\+\s*", " + ")
}

function Format-Countdown {
    param([TimeSpan]$Span)
    if ($Span.TotalSeconds -lt 0) {
        $Span = [TimeSpan]::Zero
    }
    "{0:D2}:{1:D2}:{2:D2}" -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds
}

function Get-CurrentOrNextSlot {
    param(
        [datetime]$NowLocal,
        [array]$Slots
    )

    $today = $NowLocal.Date
    $upcoming = @()

    foreach ($slot in $Slots) {
        $startMinutes = Parse-TimeToMinutes -HHmm $slot.start
        $endMinutes = Parse-TimeToMinutes -HHmm $slot.end

        if ($startMinutes -le $endMinutes) {
            $startToday = $today.AddMinutes($startMinutes)
            $endToday = $today.AddMinutes($endMinutes)

            if ($NowLocal -ge $startToday -and $NowLocal -le $endToday) {
                return [pscustomobject]@{
                    IsActive  = $true
                    Slot      = $slot
                    StartTime = $startToday
                    EndTime   = $endToday
                }
            }

            $nextStart = $startToday
            if ($nextStart -le $NowLocal) {
                $nextStart = $nextStart.AddDays(1)
            }
            $nextEnd = $nextStart.Date.AddMinutes($endMinutes)
            $upcoming += [pscustomobject]@{
                Slot      = $slot
                StartTime = $nextStart
                EndTime   = $nextEnd
            }
        }
        else {
            $startToday = $today.AddMinutes($startMinutes)
            $endTomorrow = $today.AddDays(1).AddMinutes($endMinutes)
            $startYesterday = $today.AddDays(-1).AddMinutes($startMinutes)
            $endToday = $today.AddMinutes($endMinutes)

            if (($NowLocal -ge $startToday -and $NowLocal -le $endTomorrow) -or ($NowLocal -ge $startYesterday -and $NowLocal -le $endToday)) {
                $activeStart = $startToday
                $activeEnd = $endTomorrow
                if ($NowLocal -le $endToday) {
                    $activeStart = $startYesterday
                    $activeEnd = $endToday
                }

                return [pscustomobject]@{
                    IsActive  = $true
                    Slot      = $slot
                    StartTime = $activeStart
                    EndTime   = $activeEnd
                }
            }

            $nextStart = $startToday
            if ($nextStart -le $NowLocal) {
                $nextStart = $nextStart.AddDays(1)
            }
            $nextEnd = $nextStart.Date.AddDays(1).AddMinutes($endMinutes)
            $upcoming += [pscustomobject]@{
                Slot      = $slot
                StartTime = $nextStart
                EndTime   = $nextEnd
            }
        }
    }

    if ($upcoming.Count -lt 1) {
        throw "No valid time slots in config."
    }

    $nextSlot = $upcoming | Sort-Object StartTime | Select-Object -First 1
    return [pscustomobject]@{
        IsActive  = $false
        Slot      = $nextSlot.Slot
        StartTime = $nextSlot.StartTime
        EndTime   = $nextSlot.EndTime
    }
}

function Get-DefaultLocation {
    param(
        [int]$Width,
        [int]$Height
    )
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = [Math]::Max($area.Left, $area.Right - $Width - 20)
    $y = [Math]::Max($area.Top, $area.Bottom - $Height - 40)
    [System.Drawing.Point]::new($x, $y)
}

function Is-LocationVisible {
    param(
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height
    )
    $rect = [System.Drawing.Rectangle]::new($X, $Y, $Width, $Height)
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        if ($screen.WorkingArea.IntersectsWith($rect)) {
            return $true
        }
    }
    return $false
}

function Read-DashboardState {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return $null
    }
    try {
        return Get-Content -Path $Path -Raw -Encoding utf8 | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Save-DashboardState {
    param(
        [string]$Path,
        [int]$X,
        [int]$Y,
        [bool]$TopMost
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [pscustomobject]@{
        x       = $X
        y       = $Y
        topMost = $TopMost
    } | ConvertTo-Json | Set-Content -Path $Path -Encoding utf8
}

function Open-Url {
    param([string]$Url)
    try {
        Start-Process -FilePath $Url | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to open link: $Url",
            "Open Link Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

$tzInfo = Resolve-TimeZoneInfo -ConfiguredTimeZone $config.timezone

$formWidth = 420
$formHeight = 300

$form = New-Object System.Windows.Forms.Form
$form.Text = "Mac 抢购迷你面板"
$form.Size = New-Object System.Drawing.Size($formWidth, $formHeight)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual

$savedState = Read-DashboardState -Path $StatePath
$initialPoint = Get-DefaultLocation -Width $formWidth -Height $formHeight
$initialTopMost = $false

if ($null -ne $savedState) {
    if ($savedState.PSObject.Properties.Name -contains "topMost") {
        $initialTopMost = [bool]$savedState.topMost
    }
    if (($savedState.PSObject.Properties.Name -contains "x") -and ($savedState.PSObject.Properties.Name -contains "y")) {
        $candidateX = [int]$savedState.x
        $candidateY = [int]$savedState.y
        if (Is-LocationVisible -X $candidateX -Y $candidateY -Width $formWidth -Height $formHeight) {
            $initialPoint = [System.Drawing.Point]::new($candidateX, $candidateY)
        }
    }
}

$form.Location = $initialPoint
$form.TopMost = $initialTopMost

$labelNow = New-Object System.Windows.Forms.Label
$labelNow.Location = New-Object System.Drawing.Point(12, 12)
$labelNow.Size = New-Object System.Drawing.Size(390, 24)
$labelNow.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)

$labelStatus = New-Object System.Windows.Forms.Label
$labelStatus.Location = New-Object System.Drawing.Point(12, 42)
$labelStatus.Size = New-Object System.Drawing.Size(390, 22)
$labelStatus.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)

$labelWindow = New-Object System.Windows.Forms.Label
$labelWindow.Location = New-Object System.Drawing.Point(12, 66)
$labelWindow.Size = New-Object System.Drawing.Size(390, 22)
$labelWindow.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)

$labelCountdownTitle = New-Object System.Windows.Forms.Label
$labelCountdownTitle.Location = New-Object System.Drawing.Point(12, 96)
$labelCountdownTitle.Size = New-Object System.Drawing.Size(390, 22)
$labelCountdownTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)

$labelCountdown = New-Object System.Windows.Forms.Label
$labelCountdown.Location = New-Object System.Drawing.Point(12, 120)
$labelCountdown.Size = New-Object System.Drawing.Size(390, 46)
$labelCountdown.Font = New-Object System.Drawing.Font("Consolas", 22, [System.Drawing.FontStyle]::Bold)

$skuOne = $config.skus[0]
$skuTwo = $null
if ($config.skus.Count -ge 2) {
    $skuTwo = $config.skus[1]
}

$buttonSkuOne = New-Object System.Windows.Forms.Button
$buttonSkuOne.Location = New-Object System.Drawing.Point(12, 176)
$buttonSkuOne.Size = New-Object System.Drawing.Size(190, 36)
$buttonSkuOne.Text = Format-SkuTagForDisplay -SkuId ([string]$skuOne.id) -SkuTag ([string]$skuOne.tag)
$buttonSkuOne.Add_Click({
    Open-Url -Url ([string]$skuOne.url)
})

$buttonSkuTwo = New-Object System.Windows.Forms.Button
$buttonSkuTwo.Location = New-Object System.Drawing.Point(212, 176)
$buttonSkuTwo.Size = New-Object System.Drawing.Size(190, 36)
$buttonSkuTwo.Text = if ($null -ne $skuTwo) { Format-SkuTagForDisplay -SkuId ([string]$skuTwo.id) -SkuTag ([string]$skuTwo.tag) } else { "暂无" }
$buttonSkuTwo.Enabled = ($null -ne $skuTwo)
$buttonSkuTwo.Add_Click({
    if ($null -ne $skuTwo) {
        Open-Url -Url ([string]$skuTwo.url)
    }
})

$checkTopMost = New-Object System.Windows.Forms.CheckBox
$checkTopMost.Location = New-Object System.Drawing.Point(12, 227)
$checkTopMost.Size = New-Object System.Drawing.Size(130, 24)
$checkTopMost.Text = "置顶该窗口"
$checkTopMost.Checked = $initialTopMost
$checkTopMost.Add_CheckedChanged({
    $form.TopMost = $checkTopMost.Checked
})

$buttonClose = New-Object System.Windows.Forms.Button
$buttonClose.Location = New-Object System.Drawing.Point(307, 223)
$buttonClose.Size = New-Object System.Drawing.Size(95, 30)
$buttonClose.Text = "关闭"
$buttonClose.Add_Click({
    $form.Close()
})

$form.Controls.Add($labelNow)
$form.Controls.Add($labelStatus)
$form.Controls.Add($labelWindow)
$form.Controls.Add($labelCountdownTitle)
$form.Controls.Add($labelCountdown)
$form.Controls.Add($buttonSkuOne)
$form.Controls.Add($buttonSkuTwo)
$form.Controls.Add($checkTopMost)
$form.Controls.Add($buttonClose)

$updateDisplay = {
    $nowLocal = Get-NowInZone -TimeZone $tzInfo
    $slotInfo = Get-CurrentOrNextSlot -NowLocal $nowLocal -Slots $config.timeSlots
    $slotName = Get-SlotDisplayName -SlotName ([string]$slotInfo.Slot.name)

    $labelNow.Text = "北京时间：" + $nowLocal.ToString("yyyy-MM-dd HH:mm:ss")
    $labelWindow.Text = "抢购时间段：{0} {1}-{2}" -f $slotName, $slotInfo.Slot.start, $slotInfo.Slot.end

    if ($slotInfo.IsActive) {
        $labelStatus.Text = "当前状态：当前处于抢购时间段"
        $labelCountdownTitle.Text = "当前时间段剩余："
        $labelCountdown.Text = Format-Countdown -Span ($slotInfo.EndTime - $nowLocal)
    }
    else {
        $labelStatus.Text = "当前状态：等待下一个抢购时间段"
        $labelCountdownTitle.Text = "距离下个时间段："
        $labelCountdown.Text = Format-Countdown -Span ($slotInfo.StartTime - $nowLocal)
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick($updateDisplay)
$timer.Start()

$form.Add_FormClosing({
    Save-DashboardState -Path $StatePath -X $form.Location.X -Y $form.Location.Y -TopMost ([bool]$form.TopMost)
})

& $updateDisplay
[void]$form.ShowDialog()

