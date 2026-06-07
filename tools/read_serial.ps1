# Read N seconds of serial output from the board via COM8.
#
# Usage:
#   pwsh ./read_serial.ps1                 # 10 seconds, COM8
#   pwsh ./read_serial.ps1 -Seconds 20     # 20 seconds, COM8
#   pwsh ./read_serial.ps1 -Port COM7      # 10 seconds, COM7

param(
    [int]$Seconds = 10,
    [string]$Port = "COM8"
)

$sp = [System.IO.Ports.SerialPort]::new($Port, 115200,
    [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 500
# Assert DTR — firmware's wait_for_dtr() needs it to start logging promptly.
$sp.DtrEnable = $true
$sp.RtsEnable = $true

try {
    $sp.Open()
    $deadline = [System.Diagnostics.Stopwatch]::StartNew()
    while ($deadline.ElapsedMilliseconds -lt ($Seconds * 1000)) {
        try {
            $line = $sp.ReadLine()
            Write-Output $line
        } catch [System.TimeoutException] {
            # No new line within ReadTimeout — keep polling until total elapses.
        } catch {
            # Other read errors (port closed, etc.) — abort.
            break
        }
    }
} finally {
    if ($sp.IsOpen) { $sp.Close() }
}
