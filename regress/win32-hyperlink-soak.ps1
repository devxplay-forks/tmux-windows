#requires -Version 5.1
<#
.SYNOPSIS
    DEV-111 soak test: does the tmux server survive sustained OSC-8 hyperlink
    rendering without crashing?

.DESCRIPTION
    DEV-111 is a 64-bit pointer truncation in tparm() that crashes the server in
    the '%s' branch of the Hls capability. That path is reached only when the
    server RENDERS a hyperlink to an attached client's tty
    (tty_hyperlink -> tty_putcode_ss(TTYC_HLS, ...) -> tparm("%s")).

    A detached session never exercises it: capture-pane reads the grid, it does
    not render to a tty. So this script attaches a real client, spawned as a
    tracked child (Start-Process -PassThru) so we own its PID and can kill it
    deterministically.

    DESIGN NOTES (learned the hard way)
      * Output is plain Write-Output only. No Write-Host / -ForegroundColor:
        those call GetConsoleScreenBufferInfo and throw
        "No process is on the other end of the pipe" when there is no console,
        which is exactly the case when launched detached with redirected output.
      * Run this DETACHED via Start-SoakTest.ps1 when driving it from another
        shell. Running it inline means a console failure wedges the caller.
      * Client PID is killed before the server. An attached client with no
        server spins retrying, which makes every later tmux command hang.
      * Socket label 'dev111soak' is private; your live sessions are untouched.
      * finally always cleans up, and sweeps any stray tmux.exe by PID.

.PARAMETER DurationSeconds
    Soak duration. DEV-111 criterion is >= 120 s; default 150.

.PARAMETER TmuxExe
    Path to tmux.exe under test. Defaults to whatever 'tmux' resolves to.

.PARAMETER EmitIntervalMs
    Delay between hyperlink emissions (default 50 ms, ~20/s).

.PARAMETER CleanupOnly
    Kill orphaned dev111soak processes and exit.

.EXAMPLE
    .\Start-SoakTest.ps1 -DurationSeconds 150     # preferred: detached

.EXAMPLE
    .\win32-hyperlink-soak.ps1 -DurationSeconds 150   # interactive foreground

.NOTES
    Exit codes: 0 = PASS, 1 = FAIL (crash/server death), 2 = FAIL (setup error).
#>

[CmdletBinding()]
param(
    [int]    $DurationSeconds = 150,
    [string] $TmuxExe         = '',
    [int]    $EmitIntervalMs  = 50,
    [switch] $CleanupOnly
)

$ErrorActionPreference = 'Stop'

$Label       = 'dev111soak'
$SessionName = 'soak'
$EmitterPath = Join-Path $env:TEMP 'dev111_hyperlink_emitter.ps1'

$script:ClientProc = $null
$script:TmuxExe    = $TmuxExe

# Console-independent logging. Write-Output goes to stdout, which the detached
# launcher redirects to a log file. No host/console APIs are touched.
function Log      { param([string]$m) Write-Output $m }
function LogOk    { param([string]$m) Write-Output "  [PASS] $m" }
function LogBad   { param([string]$m) Write-Output "  [FAIL] $m" }
function LogInfo  { param([string]$m) Write-Output "  $m" }
function LogWarn  { param([string]$m) Write-Output "  [WARN] $m" }

# ---------------------------------------------------------------------------
# Process helpers
# ---------------------------------------------------------------------------

function Get-SoakProcs {
    return @(Get-CimInstance Win32_Process -Filter "Name='tmux.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($Label) })
}

function Stop-SoakProcs {
    $killed = 0
    foreach ($p in (Get-SoakProcs)) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $killed++ } catch { }
    }
    return $killed
}

# ---------------------------------------------------------------------------
# Crash detection
# ---------------------------------------------------------------------------

$DumpDir = Join-Path $env:LOCALAPPDATA 'CrashDumps'

function Get-TmuxDumps {
    if (-not (Test-Path $DumpDir)) { return @() }
    return @(Get-ChildItem -Path $DumpDir -Filter 'tmux.exe.*.dmp' -File -ErrorAction SilentlyContinue)
}

function Get-TmuxCrashEvents {
    try {
        return @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000 } `
                              -MaxEvents 200 -ErrorAction Stop |
                 Where-Object { $_.Message -match 'tmux' })
    } catch { return @() }
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

function Invoke-Cleanup {
    # Client FIRST: an attached client with no server spins and wedges tmux.
    if ($script:ClientProc -and -not $script:ClientProc.HasExited) {
        try { Stop-Process -Id $script:ClientProc.Id -Force -ErrorAction SilentlyContinue } catch { }
        try { $script:ClientProc.WaitForExit(3000) | Out-Null } catch { }
    }
    if ($script:TmuxExe -and (Test-Path $script:TmuxExe)) {
        try { & $script:TmuxExe -L $Label kill-server 2>$null | Out-Null } catch { }
    }
    Start-Sleep -Milliseconds 500
    $swept = Stop-SoakProcs
    if ($swept -gt 0) { LogInfo "swept $swept leftover process(es)" }
    if (Test-Path $EmitterPath) { Remove-Item $EmitterPath -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# Resolve binary
# ---------------------------------------------------------------------------

if (-not $TmuxExe) {
    $cmd = Get-Command tmux -ErrorAction SilentlyContinue
    if (-not $cmd) { LogBad 'tmux not found on PATH. Pass -TmuxExe.'; exit 2 }
    $TmuxExe = $cmd.Source
}
if (-not (Test-Path $TmuxExe)) { LogBad "tmux.exe not found: $TmuxExe"; exit 2 }
$script:TmuxExe = $TmuxExe

# ---------------------------------------------------------------------------
# CleanupOnly
# ---------------------------------------------------------------------------

if ($CleanupOnly) {
    Log "=== Cleaning up '$Label' orphans ==="
    try { & $TmuxExe -L $Label kill-server 2>$null | Out-Null } catch { }
    Start-Sleep -Milliseconds 500
    $n = Stop-SoakProcs
    LogInfo "killed $n process(es)"
    if (@(Get-SoakProcs).Count -eq 0) { LogOk 'no soak processes remain' }
    else { LogBad 'some soak processes still running' }
    exit 0
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

$stale = @(Get-SoakProcs)
if ($stale.Count -gt 0) {
    LogWarn "found $($stale.Count) leftover soak process(es); clearing"
    try { & $TmuxExe -L $Label kill-server 2>$null | Out-Null } catch { }
    Start-Sleep -Milliseconds 500
    Stop-SoakProcs | Out-Null
    Start-Sleep -Milliseconds 500
}

Log '=== DEV-111 OSC-8 hyperlink soak ==='
$version = ((& $TmuxExe -V 2>&1) -join ' ').Trim()
LogInfo "binary  : $TmuxExe"
LogInfo "version : $version"
LogInfo "duration: ${DurationSeconds}s"
LogInfo "emit    : every ${EmitIntervalMs}ms"
LogInfo "label   : $Label (isolated from your sessions)"

if ($version -notmatch 'patched') {
    LogWarn 'this build does not report "patched"'
    Log '  A stock 3.6a-win32 build is EXPECTED to crash here (useful negative'
    Log '  control), but it is not the build to ship.'
}

$emitterBody = @'
$esc = [char]27
$i = 0
while ($true) {
    $i++
    $url = "https://example.com/dev111/soak/$i"
    [Console]::Out.Write("$esc]8;;$url$esc\$i-clickable-link$esc]8;;$esc`r`n")
    [Console]::Out.Flush()
    Start-Sleep -Milliseconds __INTERVAL__
}
'@
$emitterBody = $emitterBody -replace '__INTERVAL__', $EmitIntervalMs
Set-Content -Path $EmitterPath -Value $emitterBody -Encoding UTF8

$exitCode = 2

try {
    $startTime  = Get-Date
    $baseDumps  = @(Get-TmuxDumps | Select-Object -ExpandProperty Name)
    $baseEvents = @(Get-TmuxCrashEvents)
    LogInfo "baseline: $($baseDumps.Count) tmux dump(s), $($baseEvents.Count) tmux crash event(s)"

    # --- server under test ------------------------------------------------
    & $TmuxExe -L $Label new -d -s $SessionName -x 120 -y 30 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & $TmuxExe -L $Label has-session -t $SessionName 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { LogBad 'inner session failed to start'; exit 2 }

    # --- emitter in the pane ----------------------------------------------
    $emitCmd = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$EmitterPath`""
    & $TmuxExe -L $Label send-keys -t $SessionName $emitCmd Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    # --- attached client as a tracked child -------------------------------
    $script:ClientProc = Start-Process -FilePath $TmuxExe `
        -ArgumentList @('-L', $Label, 'attach', '-t', $SessionName) `
        -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 5

    $clients = (& $TmuxExe -L $Label list-clients 2>&1 | Out-String).Trim()
    if (-not $clients) {
        LogBad 'no client attached - the render path would NOT be exercised'
        exit 2
    }
    LogOk "attached client (pid $($script:ClientProc.Id)): $clients"

    # --- prove hyperlinks exist in the grid -------------------------------
    $innerCapture = (& $TmuxExe -L $Label capture-pane -t $SessionName -p -e 2>&1 | Out-String)
    $linkCount = ([regex]::Matches($innerCapture, '\]8;')).Count
    if ($linkCount -gt 0) {
        LogOk "Hls render path is live ($linkCount OSC-8 sequence(s) in the grid)"
    } else {
        LogBad 'no OSC-8 sequences in the pane grid - emitter did not run'
        LogInfo 'Aborting instead of reporting a vacuous PASS.'
        exit 2
    }

    # --- soak -------------------------------------------------------------
    Log ''
    Log "=== Soaking for ${DurationSeconds}s ==="

    $crashDetected = $false
    $crashReason   = ''
    $elapsed       = 0
    $pollSeconds   = 5

    while ($elapsed -lt $DurationSeconds) {
        Start-Sleep -Seconds $pollSeconds
        $elapsed += $pollSeconds

        & $TmuxExe -L $Label has-session -t $SessionName 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $crashDetected = $true; $crashReason = "server died after ~${elapsed}s"; break
        }

        $newDumps = @(Get-TmuxDumps | Where-Object { $baseDumps -notcontains $_.Name })
        if ($newDumps.Count -gt 0) {
            $crashDetected = $true; $crashReason = "new crash dump(s): $($newDumps.Name -join ', ')"; break
        }

        $newEvents = @(Get-TmuxCrashEvents | Where-Object { $_.TimeCreated -gt $startTime })
        if ($newEvents.Count -gt 0) {
            $crashDetected = $true; $crashReason = 'new Application Id=1000 event(s) for tmux'; break
        }

        $pct = [int](100 * $elapsed / $DurationSeconds)
        Log ("  [{0,3}%] {1,4}s / {2}s  alive, no crash" -f $pct, $elapsed, $DurationSeconds)
    }

    # --- verdict ----------------------------------------------------------
    Log ''
    Log '=== Verdict ==='

    $newDumpsFinal  = @(Get-TmuxDumps | Where-Object { $baseDumps -notcontains $_.Name })
    $newEventsFinal = @(Get-TmuxCrashEvents | Where-Object { $_.TimeCreated -gt $startTime })
    & $TmuxExe -L $Label has-session -t $SessionName 2>$null | Out-Null
    $aliveFinal = ($LASTEXITCODE -eq 0)

    $checks = @(
        [pscustomobject]@{ Check = 'server still alive at end';                              Pass = $aliveFinal },
        [pscustomobject]@{ Check = "no new tmux.exe crash dumps ($($newDumpsFinal.Count))";   Pass = ($newDumpsFinal.Count -eq 0) },
        [pscustomobject]@{ Check = "no new Application Id=1000 events ($($newEventsFinal.Count))"; Pass = ($newEventsFinal.Count -eq 0) }
    )
    foreach ($c in $checks) { if ($c.Pass) { LogOk $c.Check } else { LogBad $c.Check } }

    if ($crashDetected) { Log ''; LogBad "CRASH DETECTED: $crashReason" }

    $allPass = -not ($checks | Where-Object { -not $_.Pass })
    Log ''
    if ($allPass -and -not $crashDetected) {
        Log "RESULT: PASS - server survived ${DurationSeconds}s of continuous OSC-8 hyperlink rendering."
        Log 'DEV-111 soak acceptance criterion: MET'
        $exitCode = 0
    } else {
        Log 'RESULT: FAIL - see failures above.'
        Log 'DEV-111 soak acceptance criterion: NOT MET'
        $exitCode = 1
    }

} finally {
    Log ''
    Log 'cleaning up...'
    Invoke-Cleanup
    if (@(Get-SoakProcs).Count -eq 0) { LogOk 'no soak processes left behind' }
    else { LogBad 'soak processes still running - run with -CleanupOnly' }
}

exit $exitCode
