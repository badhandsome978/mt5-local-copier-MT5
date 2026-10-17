[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskCompiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $taskCompiler)) { throw '.NET Framework C# compiler not found.' }
$taskEA = Join-Path $taskRoot 'Experts\LocalCopier'
$taskArgs = @('/nologo','/target:winexe','/platform:x64','/optimize+', '/utf8output',
    '/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.Core.dll',
    ('/out:' + (Join-Path $taskRoot 'MT5Copier.exe')))
foreach ($taskFile in @('CopierSource.ex5','CopierReceiver.ex5','CopierSource.mq5','CopierReceiver.mq5','CopyCore.mqh','CopyProtocol.mqh','CopyDesktop.mqh')) {
    $taskPath = Join-Path $taskEA $taskFile
    if (-not (Test-Path -LiteralPath $taskPath)) { throw "Missing: $taskPath" }
    $taskArgs += '/resource:' + $taskPath + ',EA.' + $taskFile
}
$taskArgs += Join-Path $PSScriptRoot 'CopierWindow.cs'
$taskArgs += Join-Path $PSScriptRoot 'SelfTest.cs'
& $taskCompiler @taskArgs
if ($LASTEXITCODE -ne 0) { throw 'Desktop build failed.' }
Write-Host (Join-Path $taskRoot 'MT5Copier.exe')
