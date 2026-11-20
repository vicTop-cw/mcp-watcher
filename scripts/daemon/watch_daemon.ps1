# FIST self-tidy daemon self-heal launcher (pure ASCII; scheduled every 5 min)
# Rule: if the node daemon (pid in temp/wt-daemon.pid) is alive, do nothing.
# Else start it hidden: mcp-watcher js daemon, debounce 0 (js clock gap workaround).
$ErrorActionPreference = "Stop"
$root    = "E:\IDEProjects\AI\FIST-Mbt"
$main    = "E:\IDEProjects\AI\_build\js\debug\build\cmd\main\main.js"
$pidFile = Join-Path $root "temp\wt-daemon.pid"
$logFile = Join-Path $root "temp\wt-daemon.log"
New-Item -ItemType Directory -Force -Path (Join-Path $root "temp") | Out-Null
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
    "--rules", "E:\IDEProjects\AI\FIST-Mbt\.mcp-watch.json",
    "--watch-dir", "E:\IDEProjects\AI\FIST-Mbt",
    "--debounce-ms", "0"
)
$p = Start-Process -FilePath "node" -ArgumentList $argList -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err" -PassThru
Set-Content -Path $pidFile -Value $p.Id
