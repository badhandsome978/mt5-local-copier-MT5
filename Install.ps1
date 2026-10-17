[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$TerminalDataPath
)
$ErrorActionPreference = 'Stop'
$taskRoot = (Resolve-Path -LiteralPath $TerminalDataPath).Path
if (-not (Test-Path -LiteralPath (Join-Path $taskRoot 'MQL5') -PathType Container)) {
    throw 'Selected path must be the MT5 DATA folder containing MQL5. Use MT5: File > Open Data Folder.'
}
$taskSource = Join-Path $PSScriptRoot 'Experts\LocalCopier'
$taskDestination = Join-Path $taskRoot 'MQL5\Experts\LocalCopier'
foreach ($taskRequired in @('CopierSource.ex5','CopierReceiver.ex5')) {
    if (-not (Test-Path -LiteralPath (Join-Path $taskSource $taskRequired))) { throw "Missing compiled EA: $taskRequired" }
}
if ([IO.Path]::GetFullPath($taskSource).TrimEnd('\') -eq [IO.Path]::GetFullPath($taskDestination).TrimEnd('\')) {
    throw 'Source and destination must be different.'
}
if (Test-Path -LiteralPath $taskDestination) {
    $taskBackup = $taskDestination + '.backup.' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    Copy-Item -LiteralPath $taskDestination -Destination $taskBackup -Recurse
    Write-Host "Existing files backed up to: $taskBackup"
}
New-Item -ItemType Directory -Path $taskDestination -Force | Out-Null
Get-ChildItem -LiteralPath $taskSource -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $taskDestination $_.Name) -Force
}
Write-Host "Installed: $taskDestination"
Write-Host 'Refresh MT5 Navigator > Expert Advisors. No EA has been attached and no trading setting has been changed.'
