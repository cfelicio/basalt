<#
    tools/windows/fetch_cuda_redist.ps1 - downloads the CUDA runtime DLLs the engine loads, from NVIDIA's
    own redistributable index, and lays them out in one bin folder for package.ps1.

    A toolkit install on a build machine is often dev-only (import libraries and headers, no DLLs), and the
    components it offers differ by toolkit version. NVIDIA's redist index names the runtime packages and
    carries the SHA-256 of every file, so the release carries the real runtime libraries and can say which
    version of each it ships.

    Writes  <OutDir>/bin/<dll>  and  <OutDir>/REDIST.txt  (package, version, file, sha256 of each download).

    Usage:
        pwsh -File tools/windows/fetch_cuda_redist.ps1 -Version 13.0.2 -OutDir cuda-redist
        powershell -File tools/windows/fetch_cuda_redist.ps1 -Packages cuda_cudart      # the small one
#>
[CmdletBinding()]
param(
    [string] $Version = '13.0.2',
    [string] $OutDir = 'cuda-redist',
    [string[]] $Packages = @('cuda_cudart', 'libcublas'),
    [string] $BaseUrl = 'https://developer.download.nvidia.com/compute/cuda/redist'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # PowerShell 5.1 draws a progress bar per buffer, which crawls
# -File hands arguments over as text, so a package list arrives as one comma-joined string
$Packages = @($Packages | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if (-not ('System.IO.Compression.ZipFileExtensions' -as [type])) { Add-Type -AssemblyName System.IO.Compression.FileSystem }

$outFull = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutDir))
$binOut = Join-Path $outFull 'bin'
New-Item -ItemType Directory -Path $binOut -Force | Out-Null

$index = Invoke-RestMethod -Uri "$BaseUrl/redistrib_$Version.json" -UseBasicParsing
"redist index ${Version}: $($Packages -join ', ')"
$rows = @()
foreach ($pkg in $Packages) {
    $entry = $index.$pkg.'windows-x86_64'
    if (-not $entry) { throw "the redist index has no windows-x86_64 entry for $pkg" }
    $pkgVersion = "$($index.$pkg.version)"
    $url = "$BaseUrl/$($entry.relative_path)"
    $zip = Join-Path $env:TEMP ("redist-" + [IO.Path]::GetFileName($entry.relative_path))
    "downloading $pkg $pkgVersion"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing

    $sha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha -ne $entry.sha256.ToLowerInvariant()) {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        throw "$pkg ${pkgVersion}: the file's sha256 is $sha, the index says $($entry.sha256)"
    }

    # the loadable DLLs are under a bin folder (the archive keeps them in bin/x64); the import libraries are
    # under lib, and the _debug builds of the same libraries are not what a release ships
    $z = [System.IO.Compression.ZipFile]::OpenRead($zip)
    $taken = @()
    try {
        foreach ($e in $z.Entries) {
            $name = $e.FullName -replace '\\', '/'
            $dll = ($name -split '/')[-1]
            if ($dll -notmatch '^(cudart64|cublas64|cublasLt64)[^/]*\.dll$') { continue }
            if ($dll -match '_debug') { continue }
            if ($name -notmatch '(^|/)bin(/|$)') { continue }
            $dst = Join-Path $binOut $dll
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dst, $true)
            $taken += $dll
        }
    } finally { $z.Dispose() }
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    if (-not $taken) { throw "$pkg ${pkgVersion}: its archive carries no cudart or cuBLAS DLL under a bin folder" }
    "$pkg ${pkgVersion}: $($taken -join ', ')"
    $rows += [pscustomobject]@{ package = $pkg; version = $pkgVersion; sha256 = $entry.sha256; dlls = ($taken -join ' ') }
}

$rows | ForEach-Object { "$($_.package) $($_.version)  sha256 $($_.sha256)  -> $($_.dlls)" } |
    Set-Content -LiteralPath (Join-Path $outFull 'REDIST.txt') -Encoding ascii
"redist: $((Get-ChildItem -LiteralPath $binOut -Filter '*.dll' -File).Count) DLLs in $binOut"
