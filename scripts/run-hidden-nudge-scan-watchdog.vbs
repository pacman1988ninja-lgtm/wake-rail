Set s = CreateObject("WScript.Shell")
s.Run "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\kimi-work\wake-rail\scripts\watchdog-nudge-scan-task.ps1""", 0, False
Set s = Nothing
