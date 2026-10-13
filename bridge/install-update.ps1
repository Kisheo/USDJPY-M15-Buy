param([string]$RuntimePath = (Join-Path $env:LOCALAPPDATA 'CodexMT5Bridge'))
$ErrorActionPreference = 'Stop'
$runtime = $RuntimePath
$config = Get-Content -LiteralPath (Join-Path $runtime 'config.json') -Raw | ConvertFrom-Json
# Preflight both compiled EAs before changing runtime files.
foreach ($name in @('USDJPYSignalEA','XAUUSDSignalEA')) {
    if (!(Test-Path -LiteralPath (Join-Path $PSScriptRoot "..\mt5\$name.ex5"))) { throw "Compile $name before installing" }
}
$source = Join-Path $PSScriptRoot 'server.py'
$target = Join-Path $runtime 'server.py'
$backup = Join-Path $runtime ('server.before-usdjpy-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.py.bak')
Copy-Item -LiteralPath $target -Destination $backup
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'news_calendar.py') -Destination (Join-Path $runtime 'news_calendar.py') -Force
Copy-Item -LiteralPath $source -Destination $target -Force
$experts = Join-Path $config.mt5_data 'MQL5\Experts\CodexBridge'
New-Item -ItemType Directory -Path $experts -Force | Out-Null
$eaBackup = Join-Path $experts ('before-news-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $eaBackup -Force | Out-Null
foreach ($name in @('USDJPYSignalEA','XAUUSDSignalEA')) {
    foreach ($ext in @('mq5','ex5')) {
        $installed = Join-Path $experts "$name.$ext"
        if (Test-Path -LiteralPath $installed) { Copy-Item -LiteralPath $installed -Destination $eaBackup }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\mt5\$name.$ext") -Destination $experts -Force
    }
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\mt5\NewsProtection.mqh') -Destination $experts -Force
# Restart only the receiver identified by its exact script path, preserving the tunnel.
$receivers = Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^python(w)?\.exe$' -and $_.CommandLine -and $_.CommandLine.Contains($target) }
foreach ($receiver in $receivers) { Stop-Process -Id $receiver.ProcessId -Force }
Write-Output 'Receiver upgraded and both news-protected EAs installed; reload them in MT5. Existing supervisor will restart the receiver. Tunnel and secrets preserved.'
