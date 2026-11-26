# mcp-watcher daemon self-heal launcher (pure ASCII; scheduled every 5 min)
# Rule: if the node daemon (pid in temp/wt-daemon.pid) is alive, do nothing.
# Else start it hidden: mcp-watcher js daemon, debounce 0 (js clock gap workaround).
# Paths are derived from the script location (project root = script\..\..), no hardcode.
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root      = [System.IO.Path]::GetFullPath((Join-Path $scriptDir "..\.."))
# Build output lives at the workspace root _build (moon workspace root),
# not under mcp-watcher; keep a fallback to the repo-local path just in case.
$main = Join-Path $root "..\_build\js\debug\build\cmd\main\main.js"
if (-not (Test-Path $main)) {
    $main = Join-Path $root "_build\js\debug\build\cmd\main\main.js"
}
$main = [System.IO.Path]::GetFullPath($main)
if (-not (Test-Path $main)) {
    # No build output: exit silently instead of spawning a doomed node process.
    exit 1
}
$rules = Join-Path $root ".mcp-watch.json"
if (-not (Test-Path $rules)) {
    # No rules file in this repo: nothing to watch; exit silently (no doomed spawn).
    exit 0
}
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
    "--rules", $rules,
    "--watch-dir", $root,
    "--debounce-ms", "0"
)
$p = Start-Process -FilePath "node" -ArgumentList $argList -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err" -PassThru
Set-Content -Path $pidFile -Value $p.Id
