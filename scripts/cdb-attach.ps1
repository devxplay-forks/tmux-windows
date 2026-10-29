# Attach cdb to a spinning tmux-windows server and dump every thread's stack.
#
# Usage:  pwsh -File scripts/cdb-attach.ps1
#         pwsh -File scripts/cdb-attach.ps1 -ServerPid 1234
#
# Leaves the server running (.detach) so the hang can still be studied.

param(
    [int]$ServerPid = 0,
    [string]$SymbolPath = "C:\Users\payne\tools\tmux-symbols",
    [string]$LogPath = "$env:TEMP\tmux_spin.log"
)

$ErrorActionPreference = "Stop"

$cdbCandidates = @(
    "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe",
    "C:\Program Files\Windows Kits\10\Debuggers\x64\cdb.exe"
)
$cdb = $cdbCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $cdb) {
    Write-Error "cdb.exe not found. Install the Windows SDK Debugging Tools component."
}

if ($ServerPid -eq 0) {
    $servers = Get-CimInstance Win32_Process -Filter "Name='tmux.exe'" |
        Where-Object { $_.CommandLine -match '\s-D(\s|$)' }
    if (-not $servers) {
        Write-Error "No tmux server found (looked for a process with -D)."
    }
    if (@($servers).Count -gt 1) {
        Write-Output "Multiple servers found; pass -ServerPid explicitly:"
        $servers | ForEach-Object { Write-Output ("  PID=$($_.ProcessId)  $($_.CommandLine)") }
        exit 1
    }
    $ServerPid = [int]$servers.ProcessId
}

$proc = Get-Process -Id $ServerPid -ErrorAction SilentlyContinue
if (-not $proc) {
    Write-Error "No process with PID $ServerPid"
}

Write-Output "Attaching to tmux.exe PID $ServerPid"
Write-Output "Symbol path : $SymbolPath"
Write-Output "Log         : $LogPath"
Write-Output ""

# ~*k dumps every thread's stack; .detach leaves the process alive.
& $cdb -y $SymbolPath -p $ServerPid -c "~*k 200; .detach" -logo $LogPath

if (Test-Path $LogPath) {
    Write-Output ""
    Write-Output "=== hot-thread search (frames mentioning tmux!) ==="
    Select-String -Path $LogPath -Pattern 'tmux!' | Select-Object -First 20 |
        ForEach-Object { Write-Output $_.Line.Trim() }
}
