#requires -Version 5.1
<#
.SYNOPSIS
    Launch the DEV-111 hyperlink soak as a DETACHED process, so a hang can never
    wedge the calling shell.

.DESCRIPTION
    The soak must attach a real tmux client, and a wedged attached client can
    make every later tmux command hang. Running it inline in the foreground is
    therefore unsafe: a console failure takes the caller down with it (observed:
    "No process is on the other end of the pipe" from GetConsoleScreenBufferInfo).

    This launcher starts win32-hyperlink-soak.ps1 in its own process with stdout
    and stderr redirected to log files, records the PID, and returns immediately.
    The caller can then poll the log and kill by PID if needed.

.PARAMETER DurationSeconds
    Soak duration passed through to the soak script (default 150).

.PARAMETER Status
    Print the current state of a previously launched soak (running/exited + log tail).

.PARAMETER Stop
    Kill the launched soak and any tmux processes carrying the soak label.

.PARAMETER TailLines
    Lines of log to show with -Status (default 25).

.EXAMPLE
    .\Start-SoakTest.ps1 -DurationSeconds 150

.EXAMPLE
    .\Start-SoakTest.ps1 -Status

.EXAMPLE
    .\Start-SoakTest.ps1 -Stop
#>

[CmdletBinding()]
param(
    [int]    $DurationSeconds = 150,
    [switch] $Status,
    [switch] $Stop,
    [int]    $TailLines = 25
)

$ErrorActionPreference = 'Stop'

$Label     = 'dev111soak'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$SoakPath  = Join-Path $ScriptDir 'win32-hyperlink-soak.ps1'
$RunDir    = Join-Path $env:TEMP 'dev111soak'
$PidFile   = Join-Path $RunDir 'soak.pid'
$LogFile   = Join-Path $RunDir 'soak.log'
$ErrFile   = Join-Path $RunDir 'soak.err.log'

function Get-SoakTmuxProcs {
    return @(Get-CimInstance Win32_Process -Filter "Name='tmux.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($Label) })
}

function Get-TrackedPid {
    if (-not (Test-Path $PidFile)) { return $null }
    $raw = (Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $raw) { return $null }
    $n = 0
    if ([int]::TryParse($raw.Trim(), [ref]$n)) { return $n }
    return $null
}

function Stop-Everything {
    $tracked = Get-TrackedPid
    if ($tracked) {
        $p = Get-Process -Id $tracked -ErrorAction SilentlyContinue
        if ($p) {
            Write-Output "Killing soak process $tracked ..."
            try { Stop-Process -Id $tracked -Force -ErrorAction Stop } catch { }
        }
    }
    $killed = 0
    foreach ($tp in (Get-SoakTmuxProcs)) {
        try { Stop-Process -Id $tp.ProcessId -Force -ErrorAction Stop; $killed++ } catch { }
    }
    if ($killed -gt 0) { Write-Output "Killed $killed soak tmux process(es)." }
    if (Test-Path $PidFile) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------

if ($Stop) {
    Stop-Everything
    $left = @(Get-SoakTmuxProcs).Count
    if ($left -eq 0) { Write-Output 'CLEAN: no soak tmux processes remain.' }
    else { Write-Output "WARN: $left soak tmux process(es) still running." }
    exit 0
}

if ($Status) {
    $tracked = Get-TrackedPid
    if (-not $tracked) {
        Write-Output 'No tracked soak run (no pid file).'
    } else {
        $p = Get-Process -Id $tracked -ErrorAction SilentlyContinue
        if ($p) { Write-Output "STATUS: RUNNING (pid $tracked)" }
        else { Write-Output "STATUS: EXITED (pid $tracked no longer running)" }
    }
    $tp = @(Get-SoakTmuxProcs)
    Write-Output ("soak tmux processes: " + $tp.Count)
    if (Test-Path $LogFile) {
        Write-Output ''
        Write-Output "--- last $TailLines log lines ($LogFile) ---"
        Get-Content $LogFile -Tail $TailLines -ErrorAction SilentlyContinue
    }
    if ((Test-Path $ErrFile) -and ((Get-Item $ErrFile).Length -gt 0)) {
        Write-Output ''
        Write-Output '--- stderr ---'
        Get-Content $ErrFile -Tail 15 -ErrorAction SilentlyContinue
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------

if (-not (Test-Path $SoakPath)) {
    Write-Output "ERROR: soak script not found at $SoakPath"
    exit 2
}

if (-not (Test-Path $RunDir)) { New-Item -ItemType Directory -Path $RunDir -Force | Out-Null }

# Clear any previous run so the log is unambiguous.
Stop-Everything | Out-Null
Remove-Item $LogFile, $ErrFile -Force -ErrorAction SilentlyContinue

$pwshExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
if (-not $pwshExe) { $pwshExe = 'powershell.exe' }

$argList = @(
    '-NoProfile'
    '-ExecutionPolicy', 'Bypass'
    '-File', $SoakPath
    '-DurationSeconds', $DurationSeconds
)

# Detached: own process, hidden window, redirected streams. -PassThru gives the
# PID we need in order to kill it if it wedges.
$proc = Start-Process -FilePath $pwshExe `
    -ArgumentList $argList `
    -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $LogFile `
    -RedirectStandardError $ErrFile

Set-Content -Path $PidFile -Value $proc.Id -Encoding ASCII

Write-Output "LAUNCHED pid=$($proc.Id) duration=${DurationSeconds}s"
Write-Output "LOG=$LogFile"
Write-Output "ERR=$ErrFile"
Write-Output ''
Write-Output 'This call returns immediately; the soak runs detached.'
Write-Output 'Poll with : .\Start-SoakTest.ps1 -Status'
Write-Output 'Abort with: .\Start-SoakTest.ps1 -Stop'
exit 0
