#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$InstallDir = "C:\LowLatency"
$TaskName    = "SYSTEM_Timer_Resolution_0.5ms"
$WorkerPath  = Join-Path $InstallDir "TimerResolutionWorker.ps1"
$LogPath     = Join-Path $InstallDir "timer.log"

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-InstallDir {
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir | Out-Null
    }
}

function Write-Title([string]$Text) {
    Clear-Host
    Write-Host "+------------------------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ("| {0,-70} |" -f $Text) -ForegroundColor Cyan
    Write-Host "+------------------------------------------------------------------------+" -ForegroundColor DarkCyan
}

function Write-Section([string]$Text) {
    Write-Host ""
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("-" * 72) -ForegroundColor DarkCyan
}

function Write-Info([string]$Text)  { Write-Host $Text -ForegroundColor White }
function Write-Ok([string]$Text)    { Write-Host $Text -ForegroundColor Green }
function Write-Warn([string]$Text)  { Write-Host $Text -ForegroundColor Yellow }
function Write-Bad([string]$Text)   { Write-Host $Text -ForegroundColor Red }

function Pause-Menu {
    [void](Read-Host "กด Enter เพื่อกลับเมนู")
}

function Format-Ms([uint32]$Ticks) {
    [math]::Round($Ticks / 10000.0, 4)
}

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class TimerQueryNative
{
    [DllImport("ntdll.dll")]
    public static extern int NtQueryTimerResolution(
        out uint MinimumResolution,
        out uint MaximumResolution,
        out uint CurrentResolution
    );
}
"@

$WorkerScript = @'
#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class TimerWorkerNative
{
    [DllImport("ntdll.dll")]
    public static extern int NtSetTimerResolution(
        uint DesiredResolution,
        bool SetResolution,
        out uint CurrentResolution
    );

    [DllImport("ntdll.dll")]
    public static extern int NtQueryTimerResolution(
        out uint MinimumResolution,
        out uint MaximumResolution,
        out uint CurrentResolution
    );
}
"@

$BaseDir = "C:\LowLatency"
$LogPath = Join-Path $BaseDir "timer.log"

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$stamp] $Message"
    Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Convert-ToMs([uint32]$Ticks) {
    [math]::Round($Ticks / 10000.0, 4)
}

try {
    if (-not (Test-Path $BaseDir)) {
        New-Item -ItemType Directory -Path $BaseDir | Out-Null
    }

    Write-Log "START | PID=$PID | Worker launching"

    [uint32]$current = 0
    $status = [TimerWorkerNative]::NtSetTimerResolution(5000, $true, [ref]$current)

    if ($status -ne 0) {
        throw "NtSetTimerResolution failed: NTSTATUS=0x$($status.ToString('X8'))"
    }

    [uint32]$min = 0
    [uint32]$max = 0
    [uint32]$now = 0
    $q = [TimerWorkerNative]::NtQueryTimerResolution([ref]$min, [ref]$max, [ref]$now)

    if ($q -eq 0) {
        Write-Log "OK | PID=$PID | Current=$(Convert-ToMs $now)ms | Min=$(Convert-ToMs $min)ms | Max=$(Convert-ToMs $max)ms"
    }
    else {
        Write-Log "OK | PID=$PID | NtSetTimerResolution succeeded | NtQueryTimerResolution failed: 0x$($q.ToString('X8'))"
    }

    while ($true) {
        Start-Sleep -Seconds 3600
    }
}
catch {
    Write-Log "FATAL | PID=$PID | $($_.Exception.Message)"
    exit 1
}
'@

function Get-SystemTimerMs {
    try {
        [uint32]$min = 0
        [uint32]$max = 0
        [uint32]$now = 0
        $status = [TimerQueryNative]::NtQueryTimerResolution([ref]$min, [ref]$max, [ref]$now)
        if ($status -eq 0) {
            return [math]::Round($now / 10000.0, 4)
        }
    }
    catch {
    }
    return $null
}

function Get-WorkerPidFromLog {
    if (-not (Test-Path $LogPath)) {
        return $null
    }

    $match = Get-Content -Path $LogPath -Tail 100 -ErrorAction SilentlyContinue |
        Select-String -Pattern 'PID=(\d+)' |
        Select-Object -Last 1

    if ($null -ne $match -and $match.Matches.Count -gt 0) {
        $pidText = $match.Matches[0].Groups[1].Value
        if (-not [string]::IsNullOrWhiteSpace($pidText)) {
            return [int]$pidText
        }
    }

    return $null
}

function Get-WorkerAlive {
    $pid = Get-WorkerPidFromLog
    if ($null -eq $pid) {
        return $false
    }

    return [bool](Get-Process -Id $pid -ErrorAction SilentlyContinue)
}

function Get-OverallStatus {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $taskRunning = $false
    if ($task) {
        $taskRunning = ($task.State -eq "Running")
    }

    $workerAlive = $false
    if ($taskRunning) {
        $workerAlive = Get-WorkerAlive
    }

    $systemMs = Get-SystemTimerMs
    $isLow = ($null -ne $systemMs -and $systemMs -le 0.5)

    if ($workerAlive -and $isLow) {
        return [pscustomobject]@{ Status = "ACTIVE"; SystemMs = $systemMs; WorkerAlive = $true; TaskRunning = $true }
    }

    if ($workerAlive -and -not $isLow) {
        return [pscustomobject]@{ Status = "DEGRADED"; SystemMs = $systemMs; WorkerAlive = $true; TaskRunning = $true }
    }

    if (-not $workerAlive -and $isLow) {
        return [pscustomobject]@{ Status = "EXTERNAL SOURCE"; SystemMs = $systemMs; WorkerAlive = $false; TaskRunning = $taskRunning }
    }

    return [pscustomobject]@{ Status = "NOT RUNNING"; SystemMs = $systemMs; WorkerAlive = $false; TaskRunning = $taskRunning }
}

function Install-Task {
    Ensure-InstallDir

    Set-Content -Path $WorkerPath -Value $WorkerScript -Encoding UTF8

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        try {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        }
        catch {
        }

        for ($i = 0; $i -lt 10; $i++) {
            $state = (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).State
            if ($state -ne "Running") {
                break
            }
            Start-Sleep -Milliseconds 500
        }

        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WorkerPath`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null

    $ready = $false
    for ($i = 0; $i -lt 10; $i++) {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 500
    }

    if (-not $ready) {
        throw "Register-ScheduledTask timed out"
    }

    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 2
}

function Show-Status {
    Write-Title "หน้าสถานะระบบ"

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $info = $null
    if ($task) {
        try {
            $info = Get-ScheduledTaskInfo -TaskName $TaskName
        }
        catch {
            $info = $null
        }
    }

    $author = "N/A"
    $desc = "N/A"
    if ($task) {
        if (-not [string]::IsNullOrWhiteSpace($task.Author)) {
            $author = $task.Author
        }
        if (-not [string]::IsNullOrWhiteSpace($task.Description)) {
            $desc = $task.Description
        }
    }

    Write-Section "ข้อมูล Scheduled Task"
    Write-Info ("- TaskName          : {0}" -f $TaskName)
    if ($task) {
        Write-Info ("- State             : {0}" -f $task.State)
        Write-Info ("- Author            : {0}" -f $author)
        Write-Info ("- TaskPath          : {0}" -f $task.TaskPath)
        Write-Info ("- Description       : {0}" -f $desc)
    }
    else {
        Write-Warn "- State             : ไม่พบงาน"
    }

    if ($info) {
        Write-Info ("- LastRunTime       : {0}" -f $info.LastRunTime)
        Write-Info ("- NextRunTime       : {0}" -f $info.NextRunTime)
        Write-Info ("- LastTaskResult    : {0}" -f $info.LastTaskResult)
        Write-Info ("- MissedRuns        : {0}" -f $info.NumberOfMissedRuns)
    }

    Write-Section "สถานะ Timer"
    $workerPid = Get-WorkerPidFromLog
    $overall = Get-OverallStatus

    Write-Info ("- Worker PID        : {0}" -f $(if ($null -ne $workerPid) { $workerPid } else { "ไม่พบใน log" }))
    Write-Info ("- Worker Alive      : {0}" -f $overall.WorkerAlive)
    Write-Info ("- Task Running      : {0}" -f $overall.TaskRunning)
    Write-Info ("- System Resolution  : {0} ms" -f $(if ($null -ne $overall.SystemMs) { $overall.SystemMs } else { "อ่านไม่ได้" }))

    switch ($overall.Status) {
        "ACTIVE" {
            Write-Ok ("- Overall Status    : {0}" -f $overall.Status)
        }
        "DEGRADED" {
            Write-Warn ("- Overall Status    : {0} (worker ยังรัน แต่ system resolution ไม่ถึง 0.5ms)" -f $overall.Status)
        }
        "EXTERNAL SOURCE" {
            Write-Warn ("- Overall Status    : {0} (มี process อื่นถือ 0.5ms อยู่)" -f $overall.Status)
        }
        default {
            Write-Bad ("- Overall Status    : {0}" -f $overall.Status)
        }
    }

    Write-Section "สถานะไฟล์"
    Write-Info ("- Script Exists     : {0}" -f (Test-Path $WorkerPath))
    Write-Info ("- Log Exists        : {0}" -f (Test-Path $LogPath))

    if (Test-Path $LogPath) {
        Write-Section "บันทึกล่าสุด"
        Get-Content -Path $LogPath -Tail 12 -ErrorAction SilentlyContinue
    }

    Pause-Menu
}

function Stop-TaskAndWait {
    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        return
    }

    try {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    catch {
    }

    for ($i = 0; $i -lt 10; $i++) {
        $state = (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).State
        if ($state -ne "Running") {
            break
        }
        Start-Sleep -Seconds 1
    }
}

function Uninstall-Task {
    Write-Title "ถอนการติดตั้ง"

    $confirm = Read-Host "พิมพ์คำว่า ถอน เพื่อยืนยัน"
    if ($confirm -ne "ถอน") {
        Write-Warn "ยกเลิกการถอนการติดตั้ง"
        Start-Sleep -Seconds 1
        return
    }

    Stop-TaskAndWait

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    if (Test-Path $WorkerPath) {
        Remove-Item -Path $WorkerPath -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $LogPath) {
        Remove-Item -Path $LogPath -Force -ErrorAction SilentlyContinue
    }

    Write-Ok "ถอนการติดตั้งและล้างไฟล์เรียบร้อย"
    Start-Sleep -Seconds 1
}

function Start-TaskNow {
    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        throw "ยังไม่ได้ติดตั้งงานนี้"
    }

    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 2
}

function Show-Menu {
    Write-Title "ระบบตั้งค่า Timer Resolution 0.5ms"

    Write-Host "  [1] ติดตั้งและเริ่มใช้งาน" -ForegroundColor Green
    Write-Host "  [2] ตรวจสอบสถานะ" -ForegroundColor Cyan
    Write-Host "  [3] ถอนการติดตั้ง" -ForegroundColor Red
    Write-Host "  [4] ออก" -ForegroundColor DarkGray
    Write-Host ""
}

if (-not (Test-Admin)) {
    throw "กรุณาเปิด PowerShell ด้วยสิทธิ์ผู้ดูแลระบบ"
}

while ($true) {
    Show-Menu
    $choice = Read-Host "เลือกหมายเลข"

    switch ($choice) {
        "1" {
            Write-Title "กำลังติดตั้ง"
            Write-Info "กำลังสร้าง worker script และ Scheduled Task..."
            Install-Task
            Write-Ok "ติดตั้งและเริ่มทำงานแล้ว"
            Start-Sleep -Seconds 1
        }
        "2" { Show-Status }
        "3" { Uninstall-Task }
        "4" { break }
        default {
            Write-Warn "กรุณาเลือก 1-4"
            Start-Sleep -Seconds 1
        }
    }
}
