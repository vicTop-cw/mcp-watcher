# mcp-watcher daemon self-heal launcher (pure ASCII; scheduled every 5 min)
# Rule: if the node daemon (pid in temp/wt-daemon.pid) is alive, do nothing.
# Else start it hidden: mcp-watcher js daemon, debounce 0 (js clock gap workaround).
# Paths are derived from the script location (project root = script\..\..), no hardcode.
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root      = [System.IO.Path]::GetFullPath((Join-Path $scriptDir "..\.."))
$main      = Join-Path $root "_build\js\debug\build\cmd\main\main.js"
$tempDir   = Join-Path $root "temp"
$pidFile   = Join-Path $tempDir "wt-daemon.pid"
$logFile   = Join-Path $tempDir "wt-daemon.log"
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
if (Test-Path $pidFile) {
    $old = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($old -match '^\d+$') {
        $p = Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue
        if ($p -ne $null -and $p.ProcessName -eq "node") { exit 0 }
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}
$argList = @(
    $main, "run",
    "--rules", (Join-Path $root ".mcp-watch.json"),
    "--watch-dir", $root,
    "--debounce-ms", "0"
)
$p = Start-Process -FilePath "node" -ArgumentList $argList -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err" -PassThru
Set-Content -Path $pidFile -Value $p.Id
