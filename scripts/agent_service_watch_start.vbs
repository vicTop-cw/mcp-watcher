' agent_service_watch_start.vbs -- hidden (no-window) start for the
' mcp-watcher daemon that notifies laya when fist-agent services come up.
' Trigger: scheduled task Mbt-AgentServiceWatch (ONLOGON).
' ASCII only + CRLF discipline (TnrPolishCron 255 rule).
Set sh = CreateObject("WScript.Shell")
sh.Run "cmd /c cd /d E:\IDEProjects\AI\mcp-watcher && node E:\IDEProjects\AI\_build\js\debug\build\cmd\main\main.js run --rules rule\agent-service-up.json >> E:\IDEProjects\AI\mcp-watcher\temp\agent-service-watch.log 2>&1", 0, False
