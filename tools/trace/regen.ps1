# Rebuilds trace_gen.exe against F:\Dev\ReSkate (read only) and regenerates tools\trace\out\*.lua.
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File F:\Dev\DynCam-Plugin\tools\trace\regen.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:PATH = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer;$env:PATH"
$vs = & vswhere.exe -latest -products * -property installationPath
$obj = Join-Path $here "obj"
New-Item -ItemType Directory -Force $obj | Out-Null
$src = Join-Path $here "trace_gen.cpp"
$objfile = Join-Path $obj "trace_gen.obj"
$exe = Join-Path $here "trace_gen.exe"
$vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"
cmd /c "`"$vcvars`" >nul && cl /nologo /O2 /std:c++20 /EHsc /I F:\Dev\ReSkate `"$src`" /Fo`"$objfile`" /Fe:`"$exe`""
if ($LASTEXITCODE -ne 0) { throw "build failed" }
$out = Join-Path $here "out"
New-Item -ItemType Directory -Force $out | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $out "*")
& $exe $out
