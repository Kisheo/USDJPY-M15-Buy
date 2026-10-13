param([string]$RuntimePath = (Join-Path $env:LOCALAPPDATA 'CodexMT5Bridge'))
$ErrorActionPreference = 'Stop'
$runtime = $RuntimePath
$config = Get-Content -LiteralPath (Join-Path $runtime 'config.json') -Raw | ConvertFrom-Json
$source = Join-Path $PSScriptRoot 'server.py'
$target = Join-Path $runtime 'server.py'
$backup = Join-Path $runtime ('server.before-usdjpy-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.py.bak')
Copy-Item -LiteralPath $target -Destination $backup
Copy-Item -LiteralPath $source -Destination $target -Force
$experts = Join-Path $config.mt5_data 'MQL5\Experts\CodexBridge'
New-Item -ItemType Directory -Path $experts -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\mt5\USDJPYSignalEA.mq5'),(Join-Path $PSScriptRoot '..\mt5\USDJPYSignalEA.ex5') -Destination $experts -Force
# Restart only the receiver identified by its exact script path, preserving the tunnel.
$receivers = Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^python(w)?\.exe$' -and $_.CommandLine -and $_.CommandLine.Contains($target) }
foreach ($receiver in $receivers) { Stop-Process -Id $receiver.ProcessId -Force }
Write-Output 'Receiver upgraded and separate EA installed. Existing supervisor will restart the receiver. Tunnel and secrets preserved.'

