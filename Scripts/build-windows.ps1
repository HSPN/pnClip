param(
    [ValidateSet('Release', 'Debug')][string]$Configuration = 'Release',
    [switch]$CaptureTests,
    [switch]$Run
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (!(Test-Path -LiteralPath $vswhere)) { throw 'Install Visual Studio with Desktop development with C++ and a Windows SDK.' }
$vsPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$vsPath) { throw 'Visual Studio C++ build tools were not found.' }
$vsVersion = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationVersion
$vsMajor = [int]($vsVersion.Split('.')[0])
$generator = if ($vsMajor -ge 18) { 'Visual Studio 18 2026' } else { 'Visual Studio 17 2022' }
$cmake = Join-Path $vsPath 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
if (!(Test-Path -LiteralPath $cmake)) { $cmake = (Get-Command cmake -ErrorAction Stop).Source }
$ctest = Join-Path (Split-Path $cmake) 'ctest.exe'
$buildDir = Join-Path $projectRoot 'build/windows'
& $cmake -S $projectRoot -B $buildDir -G $generator -A x64
if ($LASTEXITCODE) { throw 'CMake configuration failed.' }
& $cmake --build $buildDir --config $Configuration --parallel
if ($LASTEXITCODE) { throw 'Build failed.' }
& $ctest --test-dir $buildDir -C $Configuration --output-on-failure
if ($LASTEXITCODE) { throw 'Tests failed.' }
if ($CaptureTests) {
    Push-Location $buildDir
    try {
        & (Join-Path $buildDir "$Configuration/PNClipWindowsTests.exe") --capture
        if ($LASTEXITCODE) { throw 'Capture integration tests failed.' }
        & (Join-Path $buildDir "$Configuration/PNClipUITests.exe")
        if ($LASTEXITCODE) { throw 'UI smoke tests failed.' }
    } finally { Pop-Location }
}
$packageDir = Join-Path $projectRoot 'build/PNClip-Windows-x64'
New-Item -ItemType Directory -Force -Path $packageDir | Out-Null
Copy-Item -LiteralPath (Join-Path $buildDir "$Configuration/PNClip.exe") -Destination $packageDir
Copy-Item -LiteralPath (Join-Path $projectRoot 'ThirdParty/libwebp/COPYING') -Destination (Join-Path $packageDir 'LICENSE-libwebp.txt')
Copy-Item -LiteralPath (Join-Path $projectRoot 'ThirdParty/libwebp/PATENTS') -Destination (Join-Path $packageDir 'PATENTS-libwebp.txt')
Copy-Item -LiteralPath (Join-Path $projectRoot 'WINDOWS.md') -Destination (Join-Path $packageDir 'README.md')
Write-Output "Ready: $packageDir/PNClip.exe"
if ($Run) { Start-Process -FilePath (Join-Path $packageDir 'PNClip.exe') }
