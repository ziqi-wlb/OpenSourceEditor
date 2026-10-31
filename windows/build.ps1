param([string]$Output = '.build', [switch]$Tests)
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        throw 'Open an x64 Native Tools Command Prompt for Visual Studio (Desktop development with C++), then run this script.'
    }
    New-Item -ItemType Directory -Force $Output | Out-Null
    $Name = if ($Tests) { 'SourceEditorTests' } else { 'SourceEditor' }
    $Options = if ($Tests) { @('/D', 'EDITOR_TESTS') } else { @() }
    & cl.exe @Options /nologo /std:c++17 /utf-8 /EHsc /O2 /MT main.cpp "/Fo$Output\$Name.obj" "/Fe$Output\$Name.exe" /link /SUBSYSTEM:WINDOWS user32.lib gdi32.lib comctl32.lib comdlg32.lib shell32.lib ole32.lib uuid.lib | Tee-Object -FilePath "$Output\$Name-build.log"
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
    Write-Output "Built: $Output\$Name.exe"
} finally { Pop-Location }
