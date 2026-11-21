# install.ps1 - Build and install the full minilang toolchain (self-hosted
# compiler + boot VM + standard library + documentation) onto a per-user prefix
# (default %LOCALAPPDATA%\Programs\minilang).
#
# Steps: fetch boot / compiler / syslib / document (or reuse local checkouts)
# -> compile the boot VM on site (CMake/Release) -> lay down bin\, lib\minilang
# and share\doc\minilang -> add the prefix bin to the user PATH -> run the full
# test suite against the installed layout.
#
# Layout under $Prefix:
#   bin\minilang.cmd                  wrapper: boot.exe run lib\minilang\main.mil
#   lib\minilang\bin\minilang.exe     real boot binary
#   lib\minilang\runtime.c            C runtime for the native backend
#   lib\minilang\minilang.h           shared C headers
#   lib\minilang\minilang_runtime.h
#   lib\minilang\main.mil compiler.mil vm.mil milc_io.mil   self-hosted sources
#   lib\minilang\syslib\*.mil         bundled standard library
#   share\doc\minilang\docs\*.md      user documentation
#
# Parameters:
#   -Prefix       install prefix
#   -CompilerSource reuse a compiler source tree
#   -BootSource   reuse a boot source tree
#   -DocSource    reuse a document source tree
#   -SysSource    reuse a syslib source tree
#   -Branch       branch/tag to fetch (default main; empty = remote HEAD via git)
#   MINILANG_NO_GIT=1  skip git and download the source archive (zip) instead
#   -SkipTests    do not run the full test suite after install
#   -KeepWork     keep the temporary build tree for inspection

[CmdletBinding()]
param(
    [string]$Prefix = $(if ($env:MINILANG_PREFIX) { $env:MINILANG_PREFIX } else { Join-Path $env:LOCALAPPDATA 'Programs\minilang' }),
    [string]$CompilerSource = $(if ($env:COMPILER_SOURCE) { $env:COMPILER_SOURCE } else { '' }),
    [string]$BootSource = $(if ($env:BOOT_SOURCE) { $env:BOOT_SOURCE } else { '' }),
    [string]$DocSource = $(if ($env:DOC_SOURCE) { $env:DOC_SOURCE } else { '' }),
    [string]$SysSource = $(if ($env:SYS_SOURCE) { $env:SYS_SOURCE } else { '' }),
    [string]$Branch = $(if ($env:MINILANG_BRANCH) { $env:MINILANG_BRANCH } else { 'main' }),
    [string]$CompilerRepo = $(if ($env:MINILANG_REPO) { $env:MINILANG_REPO } else { 'https://github.com/HFunction2013/minilang-compiler.git' }),
    [string]$BootRepo = $(if ($env:MINILANG_BOOT_REPO) { $env:MINILANG_BOOT_REPO } else { 'https://github.com/HFunction2013/minilang-boot.git' }),
    [string]$DocRepo = $(if ($env:MINILANG_DOC_REPO) { $env:MINILANG_DOC_REPO } else { 'https://github.com/HFunction2013/minilang-document.git' }),
    [string]$SysRepo = $(if ($env:MINILANG_SYS_REPO) { $env:MINILANG_SYS_REPO } else { 'https://github.com/HFunction2013/minilang-syslib.git' }),
    [switch]$SkipTests,
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..')).Path

function Log($m) { Write-Host "[install] $m" }
function Die($m) { Write-Host "[install] $m" -ForegroundColor Red; exit 1 }

# ---- 1. Resolve sources: local siblings first, otherwise clone ----
$Work = $null
if (-not $CompilerSource -and (Test-Path (Join-Path $RepoRoot 'main.mil'))) {
    $CompilerSource = $RepoRoot
    Log "Using local compiler checkout: $CompilerSource"
}
$bootSibling = Join-Path $RepoRoot '..\minilang-boot'
if (-not $BootSource -and (Test-Path (Join-Path $bootSibling 'main.c'))) {
    $BootSource = (Resolve-Path $bootSibling).Path
    Log "Using local boot checkout: $BootSource"
}
$docSibling = Join-Path $RepoRoot '..\minilang-document'
if (-not $DocSource -and (Test-Path (Join-Path $docSibling 'docs'))) {
    $DocSource = (Resolve-Path $docSibling).Path
    Log "Using local document checkout: $DocSource"
}
function Get-Slug($Url) {
    $u = $Url -replace '^https?://', ''
    $u = $u -replace '^git@', ''
    $u = $u -replace '^github.com[:/]', ''
    $u = $u -replace '\.git$', ''
    return $u.TrimEnd('/')
}

function Fetch-Repo($RepoUrl, $Name) {
    if (-not $Work) {
        $script:Work = Join-Path $env:TEMP ("minilang-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
        New-Item -ItemType Directory -Force -Path $Work | Out-Null
    }
    $dir = Join-Path $Work $Name
    if (Test-Path $dir) { return $dir }
    $useGit = $true
    if ($env:MINILANG_NO_GIT -eq '1') { $useGit = $false }
    if ($useGit -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $cloneArgs = @('clone', '--depth', '1')
        if ($Branch) { $cloneArgs += @('--branch', $Branch); Log "Cloning $RepoUrl ($Branch)" }
        else { Log "Cloning $RepoUrl (remote HEAD)" }
        $cloneArgs += @($RepoUrl, $dir)
        git @cloneArgs | Out-Host
    } else {
        if (-not $Branch) { Die 'git unavailable: set -Branch / MINILANG_BRANCH to download an archive' }
        $slug = Get-Slug $RepoUrl
        $zip = Join-Path $Work "$Name.zip"
        Log "Downloading archive $slug @ $Branch (no git)"
        Invoke-WebRequest -Uri "https://codeload.github.com/$slug/zip/refs/heads/$Branch" -OutFile $zip
        $extract = Join-Path $Work "$Name-extract"
        Expand-Archive -Path $zip -DestinationPath $extract -Force
        $nested = Get-ChildItem $extract -Directory | Select-Object -First 1
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Move-Item (Join-Path $nested.FullName '*') $dir -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
    return $dir
}

if (-not $CompilerSource) { $CompilerSource = Fetch-Repo $CompilerRepo 'compiler' }
if (-not $BootSource)    { $BootSource    = Fetch-Repo $BootRepo    'minilang-boot' }
if (-not $DocSource)      { $DocSource     = Fetch-Repo $DocRepo     'document' }

# Local syslib sibling: the compiler tree's own syslib submodule, else the
# sibling minilang-syslib checkout. Resolved after the compiler source exists.
if (-not $SysSource) {
    $sysSibling = Join-Path $CompilerSource 'syslib'
    if (Test-Path (Join-Path $sysSibling 'builtin.mil')) {
        $SysSource = $sysSibling
    } else {
        $sysRepoSibling = Join-Path $CompilerSource '..\minilang-syslib'
        if (Test-Path (Join-Path $sysRepoSibling 'builtin.mil')) {
            $SysSource = (Resolve-Path $sysRepoSibling).Path
            Log "Using local syslib checkout: $SysSource"
        }
    }
}
if (-not $SysSource)      { $SysSource     = Fetch-Repo $SysRepo     'syslib' }

if (-not (Test-Path (Join-Path $BootSource 'main.c')))      { Die "boot source not found ($BootSource)" }
if (-not (Test-Path (Join-Path $CompilerSource 'main.mil'))){ Die "compiler source not found ($CompilerSource)" }

# Stage the fetched syslib into the compiler source tree: the test suite
# resolves syslib from MINILANG_DIR/syslib, and a plain clone/archive omits the
# submodule.
$sysTarget = Join-Path $CompilerSource 'syslib'
if ((Test-Path (Join-Path $SysSource 'builtin.mil')) -and -not (Test-Path (Join-Path $sysTarget 'builtin.mil'))) {
    New-Item -ItemType Directory -Force -Path $sysTarget | Out-Null
    Get-ChildItem -Path $SysSource -Filter '*.mil' -File | Copy-Item -Destination $sysTarget -Force
}

# ---- 2. Compile the boot VM on site (CMake/Release) ----
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) { Die 'cmake not found on PATH' }
Log "Building boot compiler in $BootSource"
Push-Location $BootSource
try {
    cmake -B build | Out-Host
    if ($LASTEXITCODE -ne 0) { Die 'cmake configure failed' }
    cmake --build build --config Release | Out-Host
    if ($LASTEXITCODE -ne 0) { Die 'cmake build failed' }
} finally { Pop-Location }

$BootExe = Join-Path $BootSource 'build\Release\minilang.exe'
if (-not (Test-Path $BootExe)) { $BootExe = Join-Path $BootSource 'build\minilang.exe' }
if (-not (Test-Path $BootExe)) { Die 'build failed: minilang.exe not produced' }

# ---- 3. Lay down the install tree ----
$Lib     = Join-Path $Prefix 'lib\minilang'
$BinDir  = Join-Path $Lib 'bin'
$DocDir  = Join-Path $Prefix 'share\doc\minilang'
Log "Installing to $Prefix"
New-Item -ItemType Directory -Force -Path $BinDir, (Join-Path $Lib 'syslib'), (Join-Path $Prefix 'bin'), (Join-Path $DocDir 'docs') | Out-Null

Copy-Item $BootExe (Join-Path $BinDir 'minilang.exe') -Force

# Import library produced by the build (MSVC minilang.lib, MinGW
# libminilang.dll.a) lives next to the exe so prebuilt extension DLLs link it.
foreach ($imp in 'minilang.lib','libminilang.dll.a') {
    $candidates = @(
        (Join-Path $BootSource $imp),
        (Join-Path $BootSource "build\Release\$imp"),
        (Join-Path $BootSource "build\$imp")
    )
    foreach ($c in $candidates) { if (Test-Path $c) { Copy-Item $c $BinDir -Force } }
}

foreach ($f in 'runtime.c','minilang.h','minilang_runtime.h') {
    $src = Join-Path $BootSource $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $Lib $f) -Force }
}
foreach ($f in 'main.mil','compiler.mil','vm.mil','milc_io.mil') {
    $src = Join-Path $CompilerSource $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $Lib $f) -Force }
}
if (Test-Path $SysSource) {
    Get-ChildItem -Path $SysSource -Filter '*.mil' -File | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $Lib 'syslib') -Force
    }
}
if (Test-Path (Join-Path $DocSource 'docs')) {
    Get-ChildItem -Path (Join-Path $DocSource 'docs') -Filter '*.md' -File | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $DocDir 'docs') -Force
    }
}

# ---- 4. Wrapper on PATH: self-hosted entry through the boot VM ----
$wrapper = Join-Path $Prefix 'bin\minilang.cmd'
$cmd = @"
@echo off
rem Generated by minilang-compiler/scripts/install.ps1.
if not defined MINILANG_DIR set "MINILANG_DIR=%~dp0..\lib\minilang"
"%~dp0..\lib\minilang\bin\minilang.exe" run "%MINILANG_DIR%\main.mil" %*
"@
Set-Content -Path $wrapper -Value $cmd -Encoding ASCII

# ---- 5. Add $Prefix\bin to the user PATH (idempotent) ----
$userPath = [Environment]::GetEnvironmentVariable('Path','User')
$binPath  = Join-Path $Prefix 'bin'
if (-not ($userPath -split ';') -contains $binPath) {
    Log "Adding $binPath to user PATH"
    $newPath = (($userPath.TrimEnd(';')) + ';' + $binPath)
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    $env:Path = "$env:Path;$binPath"
}

# ---- 6. Full test suite against the installed layout ----
if (-not $SkipTests) {
    Log "Running full test suite (MINILANG_BOOT=$BinDir\minilang.exe)"
    $env:MINILANG_BOOT = Join-Path $BinDir 'minilang.exe'
    $env:MINILANG_DIR  = $CompilerSource
    if (-not $env:CC) { $env:CC = 'clang' }
    Push-Location $CompilerSource
    try { bash full_test.sh } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { Die 'full test suite failed' }
} else {
    Log 'Skipping full test suite (-SkipTests)'
}

if ($Work -and -not $KeepWork) { Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue }
Log "Done. Documentation at $DocDir\docs. Run 'minilang' from a fresh terminal (or '$wrapper')."
