param(
    [Parameter(Mandatory = $true)]
    [string]$SkuId,
    [string]$SkuTag = "",
    [string]$Url = "",
    [string]$ConfigPath = "",
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptRoot "config.json"
}
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $logDir = Join-Path $scriptRoot "logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $LogPath = Join-Path $logDir "reminder-log.csv"
}

if ([string]::IsNullOrWhiteSpace($SkuTag) -or [string]::IsNullOrWhiteSpace($Url)) {
    if (-not (Test-Path $ConfigPath)) {
        throw "config.json not found: $ConfigPath"
    }

    $config = Get-Content -Path $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
    $matchedSku = $config.skus | Where-Object { $_.id -eq $SkuId } | Select-Object -First 1
    if ($null -eq $matchedSku) {
        throw "SKU id not found in config: $SkuId"
    }

    if ([string]::IsNullOrWhiteSpace($SkuTag)) {
        $SkuTag = [string]$matchedSku.tag
    }
    if ([string]::IsNullOrWhiteSpace($Url)) {
        $Url = [string]$matchedSku.url
    }
}

function Write-ClickLog {
    param(
        [string]$Status,
        [string]$ErrorMessage = ""
    )

    if (-not (Test-Path (Split-Path -Parent $LogPath))) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null
    }

    function Convert-ToCsvValue {
        param([string]$Value)
        if ($null -eq $Value) {
            $Value = ""
        }
        '"' + ($Value -replace '"', '""') + '"'
    }

    $values = @(
        (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"),
        "N/A",
        "CLICK",
        "N/A",
        ("{0}" -f $SkuTag),
        ("{0}" -f $SkuTag),
        $Status,
        $ErrorMessage
    )
    $line = ($values | ForEach-Object { Convert-ToCsvValue -Value $_ }) -join ","

    if (-not (Test-Path $LogPath)) {
        "timestamp,slot,phase,countdown,sku_tags,clicked_sku,status,error" | Out-File -FilePath $LogPath -Encoding utf8
    }

    Add-Content -Path $LogPath -Value $line -Encoding utf8
}

try {
    Start-Process -FilePath $Url | Out-Null
    Write-ClickLog -Status "clicked"
}
catch {
    Write-ClickLog -Status "click_failed" -ErrorMessage $_.Exception.Message
}
