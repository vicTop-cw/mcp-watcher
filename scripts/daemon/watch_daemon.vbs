' FIST self-tidy daemon: hidden self-heal launcher (no console window)
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -File E:\IDEProjects\AI\mcp-watcher\scripts\daemon\watch_daemon.ps1", 0, False
