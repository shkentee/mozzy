# wearable-recorder UF2 自動書き込みスクリプト
# 使い方: .\flash.ps1 <UF2 file path>
# 動作:
#   1. COM8 (USB CDC ACM) に "boot" を送信 -> ボードが UF2 ブートローダに進入
#   2. XIAO-SENSE ドライブが現れるのを待つ
#   3. UF2 をコピー -> 自動再起動 -> 新ファーム起動
#
# 物理リセットダブルタップが必要なのは v12 以前だけ。v12 以降はこれ一発。

param(
    [Parameter(Mandatory=$true)]
    [string]$Uf2Path,

    [string]$ComPort
)

if (-not (Test-Path $Uf2Path)) {
    Write-Host "[ERR] UF2 not found: $Uf2Path" -ForegroundColor Red
    exit 1
}

function Find-BootDrive {
    try {
        $vol = Get-Volume -ErrorAction Stop | Where-Object {
            $_.DriveLetter -and ($_.FileSystemLabel -eq 'XIAO-SENSE' -or
            ($_.DriveType -eq 'Removable' -and $_.FileSystem -eq 'FAT' -and $_.Size -gt 1MB))
        } | Select-Object -First 1
        if ($vol) {
            return "$($vol.DriveLetter):\"
        }
    } catch {
        # Some Windows/PowerShell environments cannot load the Storage
        # module. Fall back to CIM, which is available in the Codex shell.
    }

    $disk = Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object {
        $_.DeviceID -and ($_.VolumeName -eq 'XIAO-SENSE' -or
        ($_.DriveType -eq 2 -and $_.Size -and $_.Size -gt 1MB -and $_.Size -lt 128MB))
    } | Select-Object -First 1
    if ($disk) {
        return "$($disk.DeviceID)\"
    }

    return $null
}

Write-Host "[INFO] UF2: $Uf2Path ($([math]::Round((Get-Item $Uf2Path).Length/1KB,1)) KB)"

$drive = Find-BootDrive
if ($drive) {
    Write-Host "[INFO] bootloader drive already present: $drive"
} else {
    if (-not $ComPort) {
        $ComPort = ([System.IO.Ports.SerialPort]::GetPortNames() | Where-Object {$_ -match '^COM\d+$'} | Sort-Object | Select-Object -First 1)
    }
    if (-not $ComPort) {
        Write-Host "[ERR] no COM port and no XIAO-SENSE drive. Is the board plugged in and running?" -ForegroundColor Red
        exit 1
    }

    Write-Host "[INFO] Sending 'boot' to $ComPort..."
    try {
        $port = [System.IO.Ports.SerialPort]::new($ComPort, 115200, 'None', 8, 'One')
        $port.Open()
        Start-Sleep -Milliseconds 200
        $port.WriteLine("boot")
        Start-Sleep -Milliseconds 100
        try { $port.Close() } catch {}
    } catch {
        Write-Host "[ERR] failed to write to $ComPort : $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    Write-Host "[INFO] Waiting for XIAO-SENSE drive to appear..."
    $start = Get-Date
    while ((Get-Date) - $start -lt [TimeSpan]::FromSeconds(15)) {
        $drive = Find-BootDrive
        if ($drive) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $drive) {
        Write-Host "[ERR] bootloader drive did not appear in 15 s" -ForegroundColor Red
        exit 1
    }
}
Write-Host "[OK] bootloader drive: $drive"

Write-Host "[INFO] Copying UF2..."
$copied = $false
for ($t = 1; $t -le 5; $t++) {
    try {
        Copy-Item -Path $Uf2Path -Destination $drive -Force -ErrorAction Stop
        $copied = $true
        break
    } catch {
        Start-Sleep -Milliseconds 200
    }
}
if (-not $copied) {
    Write-Host "[ERR] copy failed" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] flashed. Board will auto-reboot." -ForegroundColor Green
Write-Host "[INFO] Waiting 10 s for boot..."
Start-Sleep -Seconds 10
$newCom = ([System.IO.Ports.SerialPort]::GetPortNames() | Where-Object {$_ -match '^COM\d+$'} | Sort-Object | Select-Object -First 1)
if ($newCom) {
    Write-Host "[OK] back online at $newCom" -ForegroundColor Green
} else {
    Write-Host "[WRN] no COM port yet — board may take longer to enumerate" -ForegroundColor Yellow
}
