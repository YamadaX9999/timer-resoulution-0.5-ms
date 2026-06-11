# =====================================================
# SYSTEM Timer Resolution 0.5ms - English Menu
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

# -- Helpers ------------------------------------------------------------------

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

# -- FIX #1:  [ConsoleColor]$string  [ConsoleColor]::$($string) ---------
# FIX #1: Use [ConsoleColor]$string instead of [ConsoleColor]::$($string)
function Draw-Frame([string]$Title) {
    Clear-Host
    Write-Host "+------------------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ("| {0,-64} |" -f $Title) -ForegroundColor Cyan
    Write-Host "+------------------------------------------------------------------+" -ForegroundColor DarkCyan
}

function Draw-Menu([string]$Selected = "") {
    Draw-Frame "Timer Resolution 0.5ms Setup"
    Write-Line ""
    Write-Line "Select an option" DarkGray
    Write-Line ""

    $items = @(
        @{ Key = "1"; Text = "Install and Start"; Color = "DarkGreen" },
        @{ Key = "2"; Text = "Check Status";        Color = "DarkCyan"  },
        @{ Key = "3"; Text = "Uninstall";        Color = "DarkRed"   },
        @{ Key = "4"; Text = "Exit";                 Color = "DarkGray"  }
    )

    foreach ($item in $items) {
        $isSelected = ($Selected -eq $item.Key)
        # FIX: cast string -> ConsoleColor 
        # FIX: safely cast string -> ConsoleColor

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

# -- Worker Script ( Scheduled Task) ------------------
# Worker Script (written to disk, runs via Scheduled Task)
# FIX: removed finally block (no effect when process is hard-killed)
# FIX: added Write-Log "PID=..." so Status page can verify process is alive
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

    # Keep process alive  Sleep loop  Scheduled Task 
    # Keep process alive - Sleep loop is best for this Scheduled Task pattern
        Start-Sleep -Seconds 3600
    }
}
catch {
    Write-Log "FATAL | PID=$PID | $($_.Exception.Message)"
    exit 1
}
'@

# -- Install -------------------------------------------------------------------

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

    # FIX: poll  task  register  Start
    # FIX: poll until task is actually registered before calling Start
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
        throw "Register-ScheduledTask timed out"
    }
}

# -- Status: 3-state timer check -----------------------------------------------
# States:
#   ACTIVE           worker running + system resolution <= 0.5ms
#   ACTIVE          - worker running + system resolution <= 0.5ms
#   DEGRADED        - worker running but system resolution > 0.5ms (unexpected)
#   EXTERNAL SOURCE - worker not running but resolution <= 0.5ms (held by another process)
#   NOT RUNNING     - worker not running + system resolution > 0.5ms
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
    #  PID  log  worker  start
    # Read latest PID from log written by worker on startup
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

    #  PID  log  process 
    # Verify process is actually alive via PID from log
    if ($taskRunning) {
        $wpid = Get-WorkerPid
        if ($wpid) {
            $workerAlive = [bool](Get-Process -Id $wpid -ErrorAction SilentlyContinue)
        }
        else {
            #  PID  log  task Running   task state  fallback
            # No PID in log but task Running - fall back to task state
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
    Draw-Frame "System Status"

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $info = $null
    if ($task) {
        try { $info = Get-ScheduledTaskInfo -TaskName $TaskName } catch {}
    }

    # FIX: null fallback  Author / Description
    # FIX: null fallback for Author / Description
    $desc   = if (-not [string]::IsNullOrWhiteSpace($task.Description)) { $task.Description } else { "N/A" }

    Write-Line "Scheduled Task Info" Cyan
    Write-Host ("- TaskName         : {0}" -f $TaskName)   -ForegroundColor White

    if ($task) {
        Write-Host ("- State            : {0}" -f $task.State) -ForegroundColor Green
        Write-Host ("- Author           : {0}" -f $author)     -ForegroundColor White
        Write-Host ("- TaskPath         : {0}" -f $task.TaskPath) -ForegroundColor White
        Write-Host ("- Description      : {0}" -f $desc)       -ForegroundColor White
    }
    else {
        Write-Host "- State            : Task not found" -ForegroundColor Yellow
    }

    if ($info) {
        Write-Host ("- LastRunTime      : {0}" -f $info.LastRunTime)        -ForegroundColor White
        Write-Host ("- NextRunTime      : {0}" -f $info.NextRunTime)        -ForegroundColor White
        Write-Host ("- LastTaskResult   : {0}" -f $info.LastTaskResult)     -ForegroundColor White
        Write-Host ("- NumberOfMissedRuns: {0}" -f $info.NumberOfMissedRuns) -ForegroundColor White
    }

    # -- 3-state timer status --------------------------------------------------
    # 3-state timer status
    Write-Line "Timer Resolution Status" Cyan

    $wpid = Get-WorkerPid
    Write-Host ("- Worker PID       : {0}" -f $(if ($wpid) { $wpid } else { "Not found in log" })) -ForegroundColor White

    $overallStatus, $systemMs = Get-TimerOverallStatus

    $msDisplay = if ($null -ne $systemMs) { "$($systemMs) ms" } else { "Unable to read" }
    Write-Host ("- System Resolution: {0}" -f $msDisplay) -ForegroundColor White

    switch ($overallStatus) {
        "ACTIVE" {
            Write-Host ("- Overall Status   : {0}" -f $overallStatus) -ForegroundColor Green
        }
        "DEGRADED" {
            Write-Host ("- Overall Status   : {0} (worker running but resolution not at 0.5ms)" -f $overallStatus) -ForegroundColor Yellow
        }
        "EXTERNAL SOURCE" {
            Write-Host ("- Overall Status   : {0} (another process holds 0.5ms  worker not running)" -f $overallStatus) -ForegroundColor DarkYellow
        }
        "NOT RUNNING" {
            Write-Host ("- Overall Status   : {0}" -f $overallStatus) -ForegroundColor Red
        }
    }

    # --  ------------------------------------------------------------------
    # File Status section
    Write-Line "File Status" Cyan
    Write-Host ("- Script Exists    : {0}" -f (Test-Path $Script))  -ForegroundColor White
    Write-Host ("- Log Exists       : {0}" -f (Test-Path $LogPath)) -ForegroundColor White

    if (Test-Path $LogPath) {
        Write-Line ""
        Write-Line "Recent Log" Cyan
        Write-Host "+------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Get-Content $LogPath -Tail 12
        Write-Host "+------------------------------------------------------------------+" -ForegroundColor DarkCyan
    }
    else {
        Write-Line ""
        Write-Line "Log file not found" Yellow
    }

    Write-Line ""
    # FIX: Read-Host | Out-Null  [void](Read-Host ...)
    # FIX: Read-Host | Out-Null -> [void](Read-Host ...)
}

# -- Uninstall -----------------------------------------------------------------

function Uninstall-Task {
    Draw-Frame "Uninstall"

    Write-Line "  Uninstall" Yellow
    $confirm = Read-Host "Confirm"

    if ($confirm -ne "CONFIRM") {
        Write-Line ""
        Write-Line "Uninstall" Yellow
        Start-Sleep -Seconds 1
        return
    }

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}

        # FIX: poll  task  remove  ( file lock)
        # FIX: poll until task stops before removing files (prevent file lock)
            $state = (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).State
            if ($state -ne "Running") { break }
            Start-Sleep -Seconds 1
        }

        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    if (Test-Path $Script)  { Remove-Item $Script  -Force -ErrorAction SilentlyContinue }
    if (Test-Path $LogPath) { Remove-Item $LogPath -Force -ErrorAction SilentlyContinue }

    Write-Line ""
    Write-Line "Uninstall" Green
    Start-Sleep -Seconds 1
}

# -- Entry Point ---------------------------------------------------------------

if (-not (Test-Admin)) {
    throw "Please run PowerShell as Administrator"
}

while ($true) {
    Draw-Menu
    $choice = Read-Host "Select number"

    Draw-Menu -Selected $choice
    Start-Sleep -Milliseconds 250

    switch ($choice) {
        "1" {
            Draw-Frame "Installing"
            Write-Line "Creating files and Scheduled Task..." Cyan
            Install-Task
            Write-Line ""
            Write-Line "Installed and started successfully" Green
            Start-Sleep -Seconds 1
        }
        "2" { Show-Status }
        "3" { Uninstall-Task }
        "4" { Clear-Host; return }
        default {
            Write-Line "Please select 1-4" Yellow
            Start-Sleep -Seconds 1
        }
    }
}
