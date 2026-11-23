# Builds WiFiTalk.exe with the C# compiler that ships with Windows (.NET Framework 4). No SDK to install.
# Run:  pwsh -File windows\build.ps1
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$refs = '/r:System.dll', '/r:System.Core.dll', '/r:System.Drawing.dll', '/r:System.Windows.Forms.dll', '/r:System.Web.Extensions.dll'
$src = Join-Path $here 'WiFiTalk.cs'
$exe = Join-Path $here 'WiFiTalk.exe'
$ico = Join-Path $here 'WiFiTalk.ico'
$manifest = "/win32manifest:$(Join-Path $here 'WiFiTalk.manifest')"

# First pass draws the icon, second pass embeds it.
& $csc /nologo /target:winexe /optimize+ /platform:anycpu $refs $manifest "/out:$exe" $src
if ($LASTEXITCODE) { exit 1 }
& $exe --make-icon $ico | Out-Null
& $csc /nologo /target:winexe /optimize+ /platform:anycpu $refs $manifest "/win32icon:$ico" "/out:$exe" $src
if ($LASTEXITCODE) { exit 1 }
'built: ' + $exe
