# =====================================================
# SYSTEM Timer Resolution 0.5ms - Thai Menu Pro
# Version 2.0 - Fixed & Enhanced
# Changes:
#   - Fixed [ConsoleColor] enum cast
#   - Poll-based Register->Start (race condition fix)
#   - Poll-based Stop->Remove in Uninstall
#   - Removed useless finally block in worker
#   - Worker logs PID on startup
#   - Status page: 3-state timer check (ACTIVE / DEGRADED / EXTERNAL SOURCE)
#   - Author/Description null fallback
#   - Read-Host cleanup
# =====================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$BaseDir  = "C:\LowLatency"
$Script   = Join-Path $BaseDir "TimerResolution.ps1"
$TaskName = "SYSTEM_Timer_Resolution_0.5ms"
$LogPath  = Join-Path $BaseDir "timer.log"

# ── Helpers ──────────────────────────────────────────────────────────────────

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-BaseDir {
    if (-not (Test-Path $BaseDir)) {
        New-Item -ItemType Directory -Path $BaseDir | Out-Null
    }
}

function Write-Line([string]$Text = "", [ConsoleColor]$Color = [ConsoleColor]::Gray) {
    Write-Host $Text -ForegroundColor $Color
}

# ── FIX #1: ใช้ [ConsoleColor]$string แทน [ConsoleColor]::$($string) ─────────

function Draw-Frame([string]$Title) {
    Clear-Host
    Write-Host "+------------------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ("| {0,-64} |" -f $Title) -ForegroundColor Cyan
    Write-Host "+------------------------------------------------------------------+" -ForegroundColor DarkCyan
}

function Draw-Menu([string]$Selected = "") {
    Draw-Frame "ระบบตั้งค่า Timer Resolution 0.5ms"
    Write-Line ""
    Write-Line "เลือกเมนูด้านล่าง" DarkGray
    Write-Line ""

    $items = @(
        @{ Key = "1"; Text = "ติดตั้งและเริ่มใช้งาน"; Color = "DarkGreen" },
        @{ Key = "2"; Text = "ตรวจสอบสถานะ";        Color = "DarkCyan"  },
        @{ Key = "3"; Text = "ถอนการติดตั้ง";        Color = "DarkRed"   },
        @{ Key = "4"; Text = "ออก";                 Color = "DarkGray"  }
    )

    foreach ($item in $items) {
        $isSelected = ($Selected -eq $item.Key)
        # FIX: cast string -> ConsoleColor อย่างปลอดภัย
        $itemColor  = [ConsoleColor]$item.Color

        if ($isSelected) {
            Write-Host "=> " -NoNewline -ForegroundColor Yellow
            Write-Host "[ $($item.Key) ]" -NoNewline -ForegroundColor Black -BackgroundColor Yellow
            Write-Host " " -NoNewline
            Write-Host $item.Text -ForegroundColor Yellow
        }
        else {
            Write-Host "   [ " -NoNewline -ForegroundColor DarkGray
            Write-Host $item.Key -NoNewline -ForegroundColor Black -BackgroundColor $itemColor
            Write-Host " ] " -NoNewline -ForegroundColor DarkGray
            Write-Host $item.Text -ForegroundColor $itemColor
        }
    }

    Write-Line ""
}

# ── Worker Script (เขียนลงดิสก์แล้วรันผ่าน Scheduled Task) ──────────────────
# FIX: ลบ finally block ออก (ไม่มีประโยชน์เพราะ process ถูก kill แบบ hard)
# FIX: เพิ่ม Write-Log "PID=..." เพื่อให้หน้า Status ตรวจ process จริงได้

$TimerWorker = @'
$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class TimerResolution {
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

$logPath = "C:\LowLatency\timer.log"

function Write-Log {
    param([string]$Msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logPath -Value "[$ts] $Msg" -ErrorAction SilentlyContinue
}

function ToMs([uint32]$ticks) {
    [math]::Round($ticks / 10000.0, 4)
}

Write-Log "=== Timer worker started | PID=$PID ==="

try {
    [uint32]$current = 0
    $status = [TimerResolution]::NtSetTimerResolution(5000, $true, [ref]$current)

    if ($status -ne 0) {
        throw "NtSetTimerResolution failed: NTSTATUS=0x$($status.ToString('X8'))"
    }

    [uint32]$min = 0
    [uint32]$max = 0
    [uint32]$now = 0
    $qStatus = [TimerResolution]::NtQueryTimerResolution([ref]$min, [ref]$max, [ref]$now)

    if ($qStatus -eq 0) {
        Write-Log "OK | PID=$PID | Current=$(ToMs $now)ms | Min=$(ToMs $min)ms | Max=$(ToMs $max)ms"
    }
    else {
        Write-Log "OK | PID=$PID | NtSetTimerResolution succeeded | NtQueryTimerResolution failed: 0x$($qStatus.ToString('X8'))"
    }

    # Keep process alive — Sleep loop ดีที่สุดสำหรับ Scheduled Task ลักษณะนี้
    while ($true) {
        Start-Sleep -Seconds 3600
    }
}
catch {
    Write-Log "FATAL | PID=$PID | $($_.Exception.Message)"
    exit 1
}
'@

# ── Install ───────────────────────────────────────────────────────────────────

function Install-Task {
    Ensure-BaseDir
    Set-Content -Path $Script -Value $TimerWorker -Encoding UTF8

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    $Action = New-ScheduledTaskAction `
        -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`""

    $Trigger = New-ScheduledTaskTrigger -AtStartup

    $Principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $Settings = New-ScheduledTaskSettingsSet `
        -Hidden `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -RestartCount 5 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $Action `
        -Trigger $Trigger `
        -Principal $Principal `
        -Settings $Settings | Out-Null

    # FIX: poll จนกว่า task จะ register จริงก่อน Start
    $ready = $false
    for ($i = 0; $i -lt 10; $i++) {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 500
    }

    if ($ready) {
        Start-ScheduledTask -TaskName $TaskName
        Start-Sleep -Seconds 2
    }
    else {
        throw "Register-ScheduledTask ไม่สำเร็จภายใน timeout"
    }
}

# ── Status: 3-state timer check ───────────────────────────────────────────────
# States:
#   ACTIVE          — worker running + system resolution <= 0.5ms
#   DEGRADED        — worker running แต่ system resolution > 0.5ms (น่าสงสัย)
#   EXTERNAL SOURCE — worker ไม่ running แต่ system resolution <= 0.5ms (process อื่นถือไว้)
#   NOT RUNNING     — worker ไม่ running + system resolution > 0.5ms

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class TimerQuery {
    [DllImport("ntdll.dll")]
    public static extern int NtQueryTimerResolution(
        out uint MinimumResolution,
        out uint MaximumResolution,
        out uint CurrentResolution
    );
}
"@ -ErrorAction SilentlyContinue

function Get-SystemTimerMs {
    try {
        [uint32]$min = 0; [uint32]$max = 0; [uint32]$now = 0
        $r = [TimerQuery]::NtQueryTimerResolution([ref]$min, [ref]$max, [ref]$now)
        if ($r -eq 0) { return [math]::Round($now / 10000.0, 4) }
    }
    catch {}
    return $null
}

function Get-WorkerPid {
    # อ่าน PID ล่าสุดจาก log ที่ worker เขียนไว้ตอน start
    if (-not (Test-Path $LogPath)) { return $null }
    $line = Get-Content $LogPath -Tail 50 |
            Select-String "PID=(\d+)" |
            Select-Object -Last 1
    if ($line -and $line.Matches.Groups[1].Value) {
        return [int]$line.Matches.Groups[1].Value
    }
    return $null
}

function Get-TimerOverallStatus {
    $task       = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $taskRunning = ($task -and $task.State -eq "Running")

    # ตรวจ PID จาก log ว่า process ยังอยู่จริง
    $workerAlive = $false
    if ($taskRunning) {
        $wpid = Get-WorkerPid
        if ($wpid) {
            $workerAlive = [bool](Get-Process -Id $wpid -ErrorAction SilentlyContinue)
        }
        else {
            # ไม่มี PID ใน log แต่ task Running → ใช้ task state เป็น fallback
            $workerAlive = $true
        }
    }

    $systemMs = Get-SystemTimerMs
    $isLow    = ($null -ne $systemMs -and $systemMs -le 0.5)

    if ($workerAlive -and $isLow)      { return "ACTIVE",          $systemMs }
    if ($workerAlive -and -not $isLow) { return "DEGRADED",        $systemMs }
    if (-not $workerAlive -and $isLow) { return "EXTERNAL SOURCE", $systemMs }
    return "NOT RUNNING", $systemMs
}

function Show-Status {
    Draw-Frame "หน้าสถานะระบบ"

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $info = $null
    if ($task) {
        try { $info = Get-ScheduledTaskInfo -TaskName $TaskName } catch {}
    }

    # FIX: null fallback สำหรับ Author / Description
    $author = if (-not [string]::IsNullOrWhiteSpace($task.Author))      { $task.Author }      else { "N/A" }
    $desc   = if (-not [string]::IsNullOrWhiteSpace($task.Description)) { $task.Description } else { "N/A" }

    Write-Line "ข้อมูล Scheduled Task" Cyan
    Write-Host ("- TaskName         : {0}" -f $TaskName)   -ForegroundColor White

    if ($task) {
        Write-Host ("- State            : {0}" -f $task.State) -ForegroundColor Green
        Write-Host ("- Author           : {0}" -f $author)     -ForegroundColor White
        Write-Host ("- TaskPath         : {0}" -f $task.TaskPath) -ForegroundColor White
        Write-Host ("- Description      : {0}" -f $desc)       -ForegroundColor White
    }
    else {
        Write-Host "- State            : ไม่พบงาน" -ForegroundColor Yellow
    }

    if ($info) {
        Write-Host ("- LastRunTime      : {0}" -f $info.LastRunTime)        -ForegroundColor White
        Write-Host ("- NextRunTime      : {0}" -f $info.NextRunTime)        -ForegroundColor White
        Write-Host ("- LastTaskResult   : {0}" -f $info.LastTaskResult)     -ForegroundColor White
        Write-Host ("- NumberOfMissedRuns: {0}" -f $info.NumberOfMissedRuns) -ForegroundColor White
    }

    # ── 3-state timer status ──────────────────────────────────────────────────
    Write-Line ""
    Write-Line "สถานะ Timer Resolution" Cyan

    $wpid = Get-WorkerPid
    Write-Host ("- Worker PID       : {0}" -f $(if ($wpid) { $wpid } else { "ไม่พบใน log" })) -ForegroundColor White

    $overallStatus, $systemMs = Get-TimerOverallStatus

    $msDisplay = if ($null -ne $systemMs) { "$($systemMs) ms" } else { "ไม่สามารถอ่านได้" }
    Write-Host ("- System Resolution: {0}" -f $msDisplay) -ForegroundColor White

    switch ($overallStatus) {
        "ACTIVE" {
            Write-Host ("- Overall Status   : {0}" -f $overallStatus) -ForegroundColor Green
        }
        "DEGRADED" {
            Write-Host ("- Overall Status   : {0} (worker running แต่ resolution ไม่ถึง 0.5ms)" -f $overallStatus) -ForegroundColor Yellow
        }
        "EXTERNAL SOURCE" {
            Write-Host ("- Overall Status   : {0} (process อื่นถือ 0.5ms ไว้ — worker ไม่ได้รัน)" -f $overallStatus) -ForegroundColor DarkYellow
        }
        "NOT RUNNING" {
            Write-Host ("- Overall Status   : {0}" -f $overallStatus) -ForegroundColor Red
        }
    }

    # ── ไฟล์ ──────────────────────────────────────────────────────────────────
    Write-Line ""
    Write-Line "สถานะไฟล์" Cyan
    Write-Host ("- Script Exists    : {0}" -f (Test-Path $Script))  -ForegroundColor White
    Write-Host ("- Log Exists       : {0}" -f (Test-Path $LogPath)) -ForegroundColor White

    if (Test-Path $LogPath) {
        Write-Line ""
        Write-Line "บันทึกล่าสุด" Cyan
        Write-Host "+------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Get-Content $LogPath -Tail 12
        Write-Host "+------------------------------------------------------------------+" -ForegroundColor DarkCyan
    }
    else {
        Write-Line ""
        Write-Line "ไม่พบบันทึก log" Yellow
    }

    Write-Line ""
    # FIX: Read-Host | Out-Null → [void](Read-Host ...)
    [void](Read-Host "กด Enter เพื่อกลับเมนู")
}

# ── Uninstall ─────────────────────────────────────────────────────────────────

function Uninstall-Task {
    Draw-Frame "ยืนยันการถอนการติดตั้ง"

    Write-Line "พิมพ์คำว่า ถอน เพื่อยืนยันการถอนการติดตั้งทั้งหมด" Yellow
    $confirm = Read-Host "ยืนยัน"

    if ($confirm -ne "ถอน") {
        Write-Line ""
        Write-Line "ยกเลิกการถอนการติดตั้ง" Yellow
        Start-Sleep -Seconds 1
        return
    }

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}

        # FIX: poll จนกว่า task จะหยุดก่อน remove ไฟล์ (ป้องกัน file lock)
        for ($i = 0; $i -lt 10; $i++) {
            $state = (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).State
            if ($state -ne "Running") { break }
            Start-Sleep -Seconds 1
        }

        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    if (Test-Path $Script)  { Remove-Item $Script  -Force -ErrorAction SilentlyContinue }
    if (Test-Path $LogPath) { Remove-Item $LogPath -Force -ErrorAction SilentlyContinue }

    Write-Line ""
    Write-Line "ถอนการติดตั้งและล้างไฟล์เรียบร้อย" Green
    Start-Sleep -Seconds 1
}

# ── Entry Point ───────────────────────────────────────────────────────────────

if (-not (Test-Admin)) {
    throw "กรุณาเปิด PowerShell ด้วยสิทธิ์ผู้ดูแลระบบ"
}

while ($true) {
    Draw-Menu
    $choice = Read-Host "เลือกหมายเลข"

    Draw-Menu -Selected $choice
    Start-Sleep -Milliseconds 250

    switch ($choice) {
        "1" {
            Draw-Frame "กำลังติดตั้ง"
            Write-Line "กำลังสร้างไฟล์และ Scheduled Task..." Cyan
            Install-Task
            Write-Line ""
            Write-Line "ติดตั้งและเริ่มทำงานแล้ว" Green
            Start-Sleep -Seconds 1
        }
        "2" { Show-Status }
        "3" { Uninstall-Task }
        "4" { Clear-Host; return }
        default {
            Write-Line "กรุณาเลือก 1-4" Yellow
            Start-Sleep -Seconds 1
        }
    }
}
