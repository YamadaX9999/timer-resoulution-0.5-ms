# =====================================================
# SYSTEM Timer Resolution 0.5ms
# Version 3.0 - Menu Edition
# Menu: 1) Install  2) Status  3) Uninstall  4) Exit
# =====================================================

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ ERR ] Please run PowerShell as Administrator" -ForegroundColor Red
    exit 1
}

$BaseDir  = "C:\LowLatency"
$Script   = "$BaseDir\TimerResolution.ps1"
$TaskName = "SYSTEM_Timer_Resolution_0.5ms"
$LogPath  = "$BaseDir\timer.log"

# -- UI helpers --

function Write-Line {
    param([string]$Text = "", [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Write-Host $Text -ForegroundColor $Color
}

function Draw-Frame {
    param([string]$Title)
    Clear-Host
    Write-Host "+------------------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ("| {0,-64} |" -f $Title) -ForegroundColor Cyan
    Write-Host "+------------------------------------------------------------------+" -ForegroundColor DarkCyan
}

function Draw-Menu {
    param([string]$Selected = "")

    Draw-Frame "SYSTEM Timer Resolution 0.5ms"
    Write-Line ""
    Write-Line "  Select an option:" DarkGray
    Write-Line ""

    $items = @(
        @{ Key = "1"; Text = "Install and Start";  Color = [ConsoleColor]::DarkGreen },
        @{ Key = "2"; Text = "Check Status";        Color = [ConsoleColor]::DarkCyan  },
        @{ Key = "3"; Text = "Uninstall";           Color = [ConsoleColor]::DarkRed   },
        @{ Key = "4"; Text = "Exit";                Color = [ConsoleColor]::DarkGray  }
    )

    foreach ($item in $items) {
        if ($Selected -eq $item.Key) {
            Write-Host "  => " -NoNewline -ForegroundColor Yellow
            Write-Host "[ $($item.Key) ]" -NoNewline -ForegroundColor Black -BackgroundColor Yellow
            Write-Host "  $($item.Text)" -ForegroundColor Yellow
        } else {
            Write-Host "     [ " -NoNewline -ForegroundColor DarkGray
            Write-Host $item.Key -NoNewline -ForegroundColor Black -BackgroundColor $item.Color
            Write-Host " ]  " -NoNewline -ForegroundColor DarkGray
            Write-Host $item.Text -ForegroundColor $item.Color
        }
    }

    Write-Line ""
}

# -- Worker script content --

$WorkerScript = @'
Add-Type @"
using System;
using System.Runtime.InteropServices;

public class TimerResolution {
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
    param([string]$msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$ts] $msg" | Add-Content -Path $logPath -ErrorAction SilentlyContinue
}

function Get-ResolutionMs {
    param([uint32]$ticks)
    [math]::Round($ticks / 10000.0, 4)
}

Write-Log "=== Worker started | PID=$PID ==="

# Initial set with retry
$maxRetry = 5
$attempt  = 0
$success  = $false

while (-not $success -and $attempt -lt $maxRetry) {
    $attempt++
    [uint32]$current = 0
    $result = [TimerResolution]::NtSetTimerResolution(5000, $true, [ref]$current)

    if ($result -eq 0) {
        # Query actual system resolution to verify
        [uint32]$min = 0; [uint32]$max = 0; [uint32]$now = 0
        $qr = [TimerResolution]::NtQueryTimerResolution([ref]$min, [ref]$max, [ref]$now)

        if ($qr -eq 0) {
            Write-Log "OK | PID=$PID | Attempt=$attempt | Set=$(Get-ResolutionMs $current)ms | System=$(Get-ResolutionMs $now)ms | Min=$(Get-ResolutionMs $min)ms"
        } else {
            Write-Log "OK | PID=$PID | Attempt=$attempt | Set=$(Get-ResolutionMs $current)ms | NtQuery failed=0x$($qr.ToString('X8'))"
        }
        $success = $true
    } else {
        Write-Log "FAIL | Attempt=$attempt | NTSTATUS=0x$($result.ToString('X8')) | Retrying in 5s..."
        Start-Sleep -Seconds 5
    }
}

if (-not $success) {
    Write-Log "FATAL | PID=$PID | Failed after $maxRetry attempts. Exiting."
    exit 1
}

# Keep-alive loop: re-apply every 30s + heartbeat log every 60 loops (30min)
$loopCount = 0
while ($true) {
    Start-Sleep -Seconds 30
    $loopCount++

    [uint32]$current = 0
    $result = [TimerResolution]::NtSetTimerResolution(5000, $true, [ref]$current)

    if ($result -ne 0) {
        Write-Log "WARN | PID=$PID | Re-apply failed | NTSTATUS=0x$($result.ToString('X8'))"
    } elseif ($loopCount % 60 -eq 0) {
        # Heartbeat every 30 minutes
        [uint32]$min = 0; [uint32]$max = 0; [uint32]$now = 0
        [TimerResolution]::NtQueryTimerResolution([ref]$min, [ref]$max, [ref]$now) | Out-Null
        Write-Log "HEARTBEAT | PID=$PID | System=$(Get-ResolutionMs $now)ms | Uploop=$loopCount"
    }
}
'@

# -- NtQuery helper for Status page --

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class TimerQuery {
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
    } catch {}
    return $null
}

function Get-WorkerPid {
    if (-not (Test-Path $LogPath)) { return $null }
    $line = Get-Content $LogPath -Tail 100 |
            Select-String "PID=(\d+)" |
            Select-Object -Last 1
    if ($line -and $line.Matches.Groups[1].Value) {
        return [int]$line.Matches.Groups[1].Value
    }
    return $null
}

# -- Install --

function Install-Task {
    Draw-Frame "Installing..."
    Write-Line ""

    if (!(Test-Path $BaseDir)) {
        New-Item -ItemType Directory -Path $BaseDir | Out-Null
        Write-Line "  [+] Created directory: $BaseDir" Cyan
    }

    Set-Content -Path $Script -Value $WorkerScript -Encoding UTF8
    Write-Line "  [+] Worker script written" Cyan

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask $TaskName -Confirm:$false
        Write-Line "  [+] Removed old task" Cyan
    }

    $Action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`""

    $Trigger   = New-ScheduledTaskTrigger -AtStartup
    $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $Settings  = New-ScheduledTaskSettingsSet `
        -Hidden -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)

    Register-ScheduledTask `
        -TaskName $TaskName -Action $Action -Trigger $Trigger `
        -Principal $Principal -Settings $Settings | Out-Null

    Write-Line "  [+] Scheduled Task registered" Cyan

    # Poll until task exists before starting
    $ready = $false
    for ($i = 0; $i -lt 10; $i++) {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            $ready = $true; break
        }
        Start-Sleep -Milliseconds 500
    }

    if (-not $ready) {
        Write-Line "  [ERR] Task registration timed out" Red
        return
    }

    Start-ScheduledTask $TaskName
    Start-Sleep -Seconds 3

    $state = (Get-ScheduledTask -TaskName $TaskName).State
    Write-Line ""

    if ($state -eq "Running") {
        Write-Line "  [ OK ] Task is running under SYSTEM" Green
        Write-Line "  [ OK ] Timer resolution locked to 0.5ms" Green
        Write-Line "  [ OK ] Re-apply every 30s | Auto-restart on crash" Green
        Write-Line "  [ !! ] Reboot recommended for full effect" Yellow
    } else {
        Write-Line "  [WARN] Task state: $state" Yellow
        Write-Line "         Check log: $LogPath" Yellow
    }

    Write-Line ""
    [void](Read-Host "  Press Enter to return")
}

# -- Status --

function Show-Status {
    Draw-Frame "System Status"
    Write-Line ""

    # Task info
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $info = $null
    if ($task) {
        try { $info = Get-ScheduledTaskInfo -TaskName $TaskName } catch {}
    }

    Write-Line "  Scheduled Task" Cyan
    Write-Host ("  - Name        : {0}" -f $TaskName) -ForegroundColor White

    if ($task) {
        $stateColor = if ($task.State -eq "Running") { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
        Write-Host "  - State       : " -NoNewline -ForegroundColor White
        Write-Host $task.State -ForegroundColor $stateColor
    } else {
        Write-Host "  - State       : Not installed" -ForegroundColor Yellow
    }

    if ($info) {
        Write-Host ("  - Last Run    : {0}" -f $info.LastRunTime)    -ForegroundColor White
        Write-Host ("  - Last Result : {0}" -f $info.LastTaskResult) -ForegroundColor White
    }

    # Worker process check via PID from log
    Write-Line ""
    Write-Line "  Timer Resolution" Cyan

    $wpid     = Get-WorkerPid
    $procAlive = $false

    if ($wpid) {
        $procAlive = [bool](Get-Process -Id $wpid -ErrorAction SilentlyContinue)
        Write-Host ("  - Worker PID  : {0} ({1})" -f $wpid, $(if ($procAlive) { "alive" } else { "gone" })) -ForegroundColor $(if ($procAlive) { "Green" } else { "Yellow" })
    } else {
        Write-Host "  - Worker PID  : Not found in log" -ForegroundColor Yellow
    }

    $systemMs = Get-SystemTimerMs
    $msText   = if ($null -ne $systemMs) { "$systemMs ms" } else { "Unable to read" }
    Write-Host ("  - System Value: {0}" -f $msText) -ForegroundColor White

    # 3-state overall status
    $isLow       = ($null -ne $systemMs -and $systemMs -le 0.5)
    $workerAlive = $procAlive -or ($task -and $task.State -eq "Running" -and -not $wpid)

    Write-Line ""
    Write-Host "  - Overall     : " -NoNewline -ForegroundColor White

    if ($workerAlive -and $isLow) {
        Write-Host "ACTIVE" -ForegroundColor Green
    } elseif ($workerAlive -and -not $isLow) {
        Write-Host "DEGRADED  (worker running but resolution not at 0.5ms)" -ForegroundColor Yellow
    } elseif (-not $workerAlive -and $isLow) {
        Write-Host "EXTERNAL SOURCE  (0.5ms held by another process)" -ForegroundColor DarkYellow
    } else {
        Write-Host "NOT RUNNING" -ForegroundColor Red
    }

    # Recent log
    Write-Line ""
    Write-Line "  Recent Log" Cyan
    Write-Host "  +----------------------------------------------------------------+" -ForegroundColor DarkCyan
    if (Test-Path $LogPath) {
        Get-Content $LogPath -Tail 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    } else {
        Write-Host "  (log file not found)" -ForegroundColor DarkGray
    }
    Write-Host "  +----------------------------------------------------------------+" -ForegroundColor DarkCyan

    Write-Line ""
    [void](Read-Host "  Press Enter to return")
}

# -- Uninstall --

function Uninstall-Task {
    Draw-Frame "Uninstall"
    Write-Line ""
    Write-Line "  Type CONFIRM to uninstall everything, or press Enter to cancel:" Yellow
    $input = Read-Host "  >"

    if ($input -ne "CONFIRM") {
        Write-Line ""
        Write-Line "  Cancelled." DarkGray
        Start-Sleep -Seconds 1
        return
    }

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        try { Stop-ScheduledTask $TaskName -ErrorAction SilentlyContinue } catch {}

        # Poll until task stops before deleting files
        for ($i = 0; $i -lt 10; $i++) {
            $s = (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).State
            if ($s -ne "Running") { break }
            Start-Sleep -Seconds 1
        }

        Unregister-ScheduledTask $TaskName -Confirm:$false
        Write-Line "  [+] Task removed" Cyan
    } else {
        Write-Line "  [-] Task not found" DarkGray
    }

    if (Test-Path $Script)  { Remove-Item $Script  -Force -ErrorAction SilentlyContinue; Write-Line "  [+] Worker script deleted" Cyan }
    if (Test-Path $LogPath) { Remove-Item $LogPath -Force -ErrorAction SilentlyContinue; Write-Line "  [+] Log file deleted" Cyan }

    Write-Line ""
    Write-Line "  [ OK ] Uninstall complete." Green
    Start-Sleep -Seconds 2
}

# -- Main loop --

while ($true) {
    Draw-Menu
    $choice = Read-Host "  Select"

    Draw-Menu -Selected $choice
    Start-Sleep -Milliseconds 200

    switch ($choice) {
        "1" { Install-Task }
        "2" { Show-Status }
        "3" { Uninstall-Task }
        "4" { Clear-Host; exit 0 }
        default {
            Write-Line "  Please select 1-4" Yellow
            Start-Sleep -Seconds 1
        }
    }
}
