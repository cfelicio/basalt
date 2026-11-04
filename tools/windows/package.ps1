<#
    tools/windows/package.ps1 - assembles the Windows release folder and its zip from a built tree.

    Layout it produces (the folder name is the zip's root, so unpacking gives one folder):

        basalt-<version>-windows-x64-cuda13/
            bin/            basalt.exe, basalt-bench.exe, basalt-probe.exe, basalt-vision.exe
                            and the CUDA and MSVC runtime DLLs they load, so a graphics driver is enough
            serve/          the Python server (its tests folder is not shipped)
            tools/          the modules the server imports and the command-line helpers
            data/           the expert profiles (data/profiles) and the bench fixtures (data/bench)
            docs/           the engine's own documentation
            START-HERE.bat  the first run: checks the machine, sets up Python, the model and the config, serves
            VERSION         the commit, the toolkit and the CUDA architecture the binaries were built for
            requirements.txt, LICENSE, THIRD_PARTY_LICENSES, README.md, basalt_config.example.json

    The engine finds serve/ and data/ by walking up from its own folder (platform::tree_root), so the whole folder
    runs wherever it is unpacked. The build must be a Release build for compute capability 12.0.

    Usage:
        pwsh -File tools/windows/package.ps1 -SourceDir . -OutDir dist -Version 0.2.1-win1
        pwsh -File tools/windows/package.ps1 -SourceDir . -OutDir dist -Version test -BuildDir build -NoZip
#>
[CmdletBinding()]
param(
    [string] $SourceDir = (Get-Location).Path,
    [string] $BuildDir = '',
    [string] $OutDir = 'dist',
    [string] $Version = 'dev',
    [string] $Architecture = 'cuda13',
    [switch] $NoZip
)

$ErrorActionPreference = 'Stop'
$SourceDir = (Resolve-Path $SourceDir).Path
if (-not $BuildDir) { $BuildDir = Join-Path $SourceDir 'build' }
if (-not (Test-Path -LiteralPath $BuildDir)) { throw "no build folder at $BuildDir" }

$name = "basalt-$Version-windows-x64-$Architecture"
$outFull = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutDir))
New-Item -ItemType Directory -Path $outFull -Force | Out-Null
$stage = Join-Path $outFull 'stage-tmp'
$root = Join-Path $stage $name
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $root 'bin') -Force | Out-Null

function Copy-Tree([string] $from, [string] $to, [string[]] $excludeParts = @()) {
    if (-not (Test-Path -LiteralPath $from)) { throw "missing $from" }
    Get-ChildItem -LiteralPath $from -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($from.Length).TrimStart('\', '/')
        foreach ($x in $excludeParts) {
            if ($rel -like "$x\*" -or $rel -like "*\$x\*") { return }
        }
        $dst = Join-Path $to $rel
        $dir = Split-Path $dst -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
    }
}

# ---- the binaries: the four programs the build produces, from build/bin (Ninja single-config)
$binFrom = Join-Path $BuildDir 'bin'
if (-not (Test-Path -LiteralPath $binFrom)) { $binFrom = $BuildDir }
$exes = Get-ChildItem -LiteralPath $binFrom -Filter '*.exe' -File -ErrorAction SilentlyContinue
if (-not $exes) { throw "no .exe files under ${binFrom}: build first (cmake --build build)" }
$exes | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $root 'bin') -Force }

# ---- the CUDA runtime: cudart and cuBLAS, the libraries the engine links. The toolkit keeps these
# DLLs under bin, and its dev components put some of them under bin\x64 or x64.
$cudaRoot = $env:CUDA_PATH
if (-not $cudaRoot -or -not (Test-Path -LiteralPath $cudaRoot)) {
    $cudaRoot = Get-ChildItem 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA' -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $cudaRoot -or -not (Test-Path -LiteralPath $cudaRoot)) { throw 'no CUDA toolkit found for the runtime DLLs' }
$cudaDirs = @('bin', 'bin\x64', 'x64') | ForEach-Object { Join-Path $cudaRoot $_ } |
    Where-Object { Test-Path -LiteralPath $_ }
$cudaDlls = @('cudart64_*.dll', 'cublas64_*.dll', 'cublasLt64_*.dll') | ForEach-Object {
    $pattern = $_
    $cudaDirs | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter $pattern -File -ErrorAction SilentlyContinue }
} | Sort-Object Name -Unique
foreach ($need in 'cudart64_*.dll', 'cublas64_*.dll') {
    if (-not ($cudaDlls | Where-Object { $_.Name -like $need })) {
        $seen = ($cudaDirs | ForEach-Object {
            (Get-ChildItem -LiteralPath $_ -Filter '*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ' '
        }) -join '; '
        throw "no $need under the CUDA toolkit. searched: $($cudaDirs -join ', '). dlls there: $seen"
    }
}
$cudaDlls | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $root 'bin') -Force }

# ---- the MSVC runtime, so a machine with no Visual C++ redist installed still starts the engine
$crt = @()
if ($env:VCToolsRedistDir -and (Test-Path -LiteralPath $env:VCToolsRedistDir)) {
    $crt = Get-ChildItem -LiteralPath $env:VCToolsRedistDir -Recurse -File -Filter '*.dll' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\Microsoft\.VC14\d\.CRT\\' }
}
foreach ($n in 'vcruntime140.dll', 'vcruntime140_1.dll', 'vcruntime140_2.dll', 'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll') {
    $found = $crt | Where-Object Name -eq $n | Select-Object -First 1
    if ($found) { Copy-Item -LiteralPath $found.FullName -Destination (Join-Path $root 'bin') -Force }
}

# ---- the tree the engine and the server read beside the binaries
Copy-Tree (Join-Path $SourceDir 'data') (Join-Path $root 'data')
Copy-Tree (Join-Path $SourceDir 'serve') (Join-Path $root 'serve') @('tests', '__pycache__')
Copy-Tree (Join-Path $SourceDir 'tools') (Join-Path $root 'tools') @('convert', 'migrations', '__pycache__')
Copy-Tree (Join-Path $SourceDir 'docs')  (Join-Path $root 'docs')
foreach ($f in 'START-HERE.bat', 'requirements.txt', 'LICENSE', 'THIRD_PARTY_LICENSES') {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir $f))) { throw "the release needs $f and it is not in $SourceDir" }
    Copy-Item -LiteralPath (Join-Path $SourceDir $f) -Destination $root -Force
}
if (Test-Path -LiteralPath (Join-Path $SourceDir 'README.md')) {
    Copy-Item -LiteralPath (Join-Path $SourceDir 'README.md') -Destination $root -Force
}

# ---- what the build was, for a bug report
$commit = 'unknown'
$git = Join-Path $SourceDir '.git'
if (Test-Path -LiteralPath $git) {
    $c = & git -C $SourceDir rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { $commit = $c.Trim() }
}
$suffix = if ($Architecture -eq 'cuda13') { '120' } else { $Architecture }
$cudaVer = 'unknown'
$nvcc = Get-Command nvcc -ErrorAction SilentlyContinue
if ($nvcc) {
    $line = (nvcc --version 2>$null | Select-String 'release' | Select-Object -First 1)
    if ($line) { $cudaVer = ($line.ToString() -split 'release')[-1].Trim() }
}
@"
version:    $Version
commit:     $commit
platform:   windows-x64
architecture: sm_$suffix
cuda:       $cudaVer
built:      $(Get-Date -Format 'yyyy-MM-dd HH:mm') UTC
"@ | Set-Content -LiteralPath (Join-Path $root 'VERSION') -Encoding ascii

@'
{
  "server": { "model": "models/Qwen3.8-FN-GSQ-RCO-Q2_0.basalt", "gpu": "0", "port": 8080 },
  "engine": { "expert-cache": "auto", "prefill": "auto", "kv": "int8", "resident-experts": true }
}
'@ | Set-Content -LiteralPath (Join-Path $root 'basalt_config.example.json') -Encoding ascii

@'
# Basalt on Windows (this fork)

The engine needs an NVIDIA Blackwell card (RTX 50 series, RTX PRO Blackwell: compute capability 12.0) and a recent
NVIDIA driver. Nothing else has to be installed: the CUDA and MSVC runtime libraries are in bin.

Double-click **START-HERE.bat**. It checks the card, sets up Python in .venv, helps you choose a model, writes
basalt_config.json and starts the server. Ask it what it would do first with:

    START-HERE.bat --plan

Run it yourself, once it is set up:

    bin\basalt.exe serve --config basalt_config.json

The server answers on http://127.0.0.1:8080 (OpenAI- and Anthropic-compatible API, and a web page). To stop it,
press Ctrl+C in its window.

Models are tens of gigabytes. START-HERE.bat lists the packs with their sizes and only downloads the one you pick;
put a .basalt file you already have in models\ and choose that.

More: docs/platforms.md (requirements, the Windows limitations), docs/probe.md (measuring this machine),
docs/configuration/index.md (every setting). This build came from <version>; see VERSION.
'@ -replace '<version>', $Version | Set-Content -LiteralPath (Join-Path $root 'README-WINDOWS.md') -Encoding ascii

# ---- what is in it, and the zip
$total = Get-ChildItem -LiteralPath $root -Recurse -File | Measure-Object -Sum Length
"package: $($total.Count) files, $([math]::Round($total.Sum / 1MB, 1)) MiB in $name"
foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $root 'bin') -File)) {
    '  bin\{0}  {1,8:N1} MiB' -f $f.Name, ($f.Length / 1MB)
}

if ($NoZip) { Write-Output "package: staged at $root (no zip)"; exit 0 }

$zip = [System.IO.Path]::GetFullPath((Join-Path $outFull "$name.zip"))
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -LiteralPath $root -DestinationPath $zip -CompressionLevel Optimal
Remove-Item -LiteralPath $stage -Recurse -Force

$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
"$hash  $name.zip" | Set-Content -LiteralPath "$zip.SHA256SUMS" -Encoding ascii -NoNewline
$mi = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1)
"package: $zip ($mi MiB)"
"package: sha256 $hash"
