<#
.SYNOPSIS
    Basalt 0.5.x Benchmark & Cold-Prefill Verification Suite for Qwen3.8-FN and DeepSeek-V4.1-Flash.
    Supports single-build validation (-BuildARoot omitted defaults to this folder) or ABBA comparison
    (-BuildARoot vs -BuildBRoot), e.g., upstream v0.5.5 vs v0.5.5 + PR #328.
    Records 1s Windows FreePhysicalMemory + basalt RSS alongside basalt-bench JSON and engine.log.
#>

param(
    [string]$BuildARoot = "",
    [string]$LabelA = "",

    [string]$BuildBRoot = "",
    [string]$LabelB = "",

    [string]$QwenModel = "",
    [string]$DeepSeekModel = "",
    [string]$ModelsDir = "",

    [string]$Gpu = "0",
    [int]$DecodeReps = 2,
    [int]$Seed = 42,
    [string]$DecodeTests = "conv,struct,prose",
    [string]$PrefillDepths = "16384,65536,131072",
    [string]$PowerLabel = "",

    # Engine flags appended after "--"
    [string]$QwenFlags = "--kv int8 --prefill auto --resident-experts --expert-cache auto --ram-reserve-mib 2048",
    [string]$DeepSeekFlags = "--kv fp8 --expert-cache auto --ram-reserve-mib 2048 --vram-reserve-mib 384 --spec 3",

    # Optional HTTP server cold-compaction reproducer (#261): 0 = disabled, 2+ = send N unique ~130k prompts via basalt serve
    [int]$ServeColdRounds = 0,
    [int]$ServePromptRepeat = 3600,
    [int]$ServeMaxContext = 163840,
    [int]$ServePort = 8099,
    [string]$PythonExe = "",

    [int]$CooldownSeconds = 5,
    [string]$OutDir = ""
)

$ErrorActionPreference = "Continue"

function Resolve-BasaltBuild {
    param([string]$InputPath, [string]$FallbackLabel)
    $full = (Resolve-Path -LiteralPath $InputPath).Path
    $binDir = $null
    $rootDir = $null

    if (Test-Path (Join-Path $full "bin\basalt-bench.exe")) {
        $rootDir = $full
        $binDir = Join-Path $full "bin"
    } elseif (Test-Path (Join-Path $full "basalt-bench.exe")) {
        $binDir = $full
        $rootDir = Split-Path $full -Parent
    } else {
        throw "Could not find basalt-bench.exe under '$full' or '$full\bin'."
    }

    $benchExe  = Join-Path $binDir "basalt-bench.exe"
    $engineExe = Join-Path $binDir "basalt.exe"
    if (-not (Test-Path $engineExe)) {
        throw "Could not find basalt.exe in '$binDir'."
    }

    $label = if ($FallbackLabel) { $FallbackLabel } else { Split-Path $rootDir -Leaf }
    return [PSCustomObject]@{
        Label     = $label
        RootDir   = $rootDir
        BinDir    = $binDir
        BenchExe  = $benchExe
        EngineExe = $engineExe
    }
}

function Format-ArgString {
    param([string[]]$ArgList)
    $quoted = foreach ($a in $ArgList) {
        if ($null -eq $a) { continue }
        if ($a -match '[\s"]') {
            '"' + ($a -replace '"', '\"') + '"'
        } else {
            $a
        }
    }
    return ($quoted -join ' ')
}

function Split-FlagString {
    param([string]$Flags)
    if ([string]::IsNullOrWhiteSpace($Flags)) { return @() }
    return @($Flags -split '\s+' | Where-Object { $_ -ne '' })
}

function Stop-StrayBasalt {
    Get-Process -Name "basalt" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Start-ProcessWithRamMonitor {
    param(
        [string]$FilePath,
        [string[]]$ArgList,
        [string]$WorkingDirectory,
        [string]$StdoutPath,
        [string]$StderrPath,
        [string]$RamCsvPath
    )

    $argStr = Format-ArgString -ArgList $ArgList
    $psiArgs = @{
        FilePath               = $FilePath
        ArgumentList           = $argStr
        WorkingDirectory       = $WorkingDirectory
        RedirectStandardOutput = $StdoutPath
        RedirectStandardError  = $StderrPath
        PassThru               = $true
        NoNewWindow            = $true
    }
    $proc = Start-Process @psiArgs

    $samples = New-Object System.Collections.Generic.List[string]
    $samples.Add("timestamp,free_phys_mib,total_phys_mib,basalt_rss_mib,basalt_private_mib")
    $minFreeMiB = [double]::MaxValue
    $maxRssMiB = 0.0
    $lastPrint = Get-Date

    while (-not $proc.HasExited) {
        $now = Get-Date
        $freeMiB = -1.0
        $totMiB  = -1.0
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $freeMiB = [math]::Round($os.FreePhysicalMemory / 1024.0, 1)
            $totMiB  = [math]::Round($os.TotalVisibleMemorySize / 1024.0, 1)
            if ($freeMiB -lt $minFreeMiB) { $minFreeMiB = $freeMiB }
        } catch {}

        $rssMiB = 0.0
        $privMiB = 0.0
        try {
            $bps = @(Get-Process -Name "basalt" -ErrorAction SilentlyContinue)
            if ($bps.Count -gt 0) {
                $rssMiB  = [math]::Round((($bps | Measure-Object WorkingSet64 -Sum).Sum) / 1MB, 1)
                $privMiB = [math]::Round((($bps | Measure-Object PrivateMemorySize64 -Sum).Sum) / 1MB, 1)
                if ($rssMiB -gt $maxRssMiB) { $maxRssMiB = $rssMiB }
            }
        } catch {}

        $samples.Add(("{0},{1},{2},{3},{4}" -f $now.ToString("yyyy-MM-dd HH:mm:ss"), $freeMiB, $totMiB, $rssMiB, $privMiB))

        if (($now - $lastPrint).TotalSeconds -ge 15) {
            $lastPrint = $now
            Write-Host ("    [monitor] FreeRAM={0} MiB | basalt RSS={1} MiB" -f $freeMiB, $rssMiB) -ForegroundColor DarkGray
        }
        Start-Sleep -Milliseconds 1000
        $proc.Refresh()
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($RamCsvPath, $samples, $utf8)

    if ($minFreeMiB -eq [double]::MaxValue) { $minFreeMiB = -1.0 }
    return [PSCustomObject]@{
        ExitCode   = $proc.ExitCode
        MinFreeMiB = $minFreeMiB
        MaxRssMiB  = $maxRssMiB
    }
}

function Inspect-StallInLogs {
    param([string]$RunLogDir)
    $stalls = @()
    if (-not (Test-Path $RunLogDir)) { return $stalls }
    $logFiles = Get-ChildItem -Path $RunLogDir -Filter "*.log" -Recurse -ErrorAction SilentlyContinue
    foreach ($lf in $logFiles) {
        $hit = Select-String -Path $lf.FullName -Pattern "stall report|CPU expert pool stalled|no progress for" -SimpleMatch:$false -ErrorAction SilentlyContinue
        if ($hit) {
            $stalls += [PSCustomObject]@{ File = $lf.FullName; Matches = @($hit | ForEach-Object { $_.Line }) }
        }
    }
    return $stalls
}

function Invoke-BenchPhase {
    param(
        [PSCustomObject]$Build,
        [string]$ModelKind,
        [string]$ModelPath,
        [string]$EngineFlags,
        [string]$ArmLabel,
        [string]$PhaseName,
        [string]$OutRoot
    )

    $runDir = Join-Path $OutRoot ("{0}_{1}_{2}" -f $ModelKind, ($ArmLabel -replace '[^a-zA-Z0-9._-]', '_'), $PhaseName)
    $logsDir = Join-Path $runDir "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

    $jsonOut = Join-Path $runDir "bench.json"
    $errOut  = Join-Path $runDir "bench-stderr.log"
    $ramCsv  = Join-Path $runDir "ram-samples.csv"

    $benchArgs = New-Object System.Collections.Generic.List[string]
    $benchArgs.Add("--engine"); $benchArgs.Add($Build.EngineExe)
    $benchArgs.Add("--model");  $benchArgs.Add($ModelPath)
    $benchArgs.Add("--gpu");    $benchArgs.Add($Gpu)
    $benchArgs.Add("-o");       $benchArgs.Add("json")
    $benchArgs.Add("--logs");   $benchArgs.Add($logsDir)
    if ($PowerLabel) { $benchArgs.Add("--power-label"); $benchArgs.Add($PowerLabel) }

    if ($PhaseName -eq "decode") {
        $benchArgs.Add("-t");     $benchArgs.Add($DecodeTests)
        $benchArgs.Add("-r");     $benchArgs.Add("$DecodeReps")
        $benchArgs.Add("--seed"); $benchArgs.Add("$Seed")
    } else {
        $benchArgs.Add("-p");     $benchArgs.Add($PrefillDepths)
        $benchArgs.Add("-r");     $benchArgs.Add("1")
    }

    $extra = Split-FlagString -Flags $EngineFlags
    if ($extra.Count -gt 0) {
        $benchArgs.Add("--")
        foreach ($x in $extra) { $benchArgs.Add($x) }
    }

    Write-Host ("  -> [{0}] {1} ({2})..." -f $ArmLabel, $ModelKind, $PhaseName) -ForegroundColor Yellow
    Write-Host ("     cmd: {0} {1}" -f $Build.BenchExe, (Format-ArgString $benchArgs)) -ForegroundColor DarkGray

    Stop-StrayBasalt
    $mon = Start-ProcessWithRamMonitor `
        -FilePath $Build.BenchExe `
        -ArgList $benchArgs.ToArray() `
        -WorkingDirectory $Build.RootDir `
        -StdoutPath $jsonOut `
        -StderrPath $errOut `
        -RamCsvPath $ramCsv

    $stalls = Inspect-StallInLogs -RunLogDir $runDir
    $parsed = $null
    if (Test-Path $jsonOut) {
        $rawJson = (Get-Content -LiteralPath $jsonOut -Raw -ErrorAction SilentlyContinue)
        if ($rawJson -and $rawJson.Trim().StartsWith("{")) {
            try { $parsed = $rawJson | ConvertFrom-Json } catch {}
        }
    }

    if ($mon.ExitCode -ne 0 -or $stalls.Count -gt 0 -or -not $parsed) {
        Write-Host ("     [WARN/FAIL] exit={0}, stalls={1}, minFreeRAM={2} MiB, maxRSS={3} MiB" -f $mon.ExitCode, $stalls.Count, $mon.MinFreeMiB, $mon.MaxRssMiB) -ForegroundColor Red
        if (Test-Path $errOut) {
            Get-Content $errOut -Tail 15 | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkYellow }
        }
    } else {
        Write-Host ("     [OK] minFreeRAM={0} MiB, maxRSS={1} MiB" -f $mon.MinFreeMiB, $mon.MaxRssMiB) -ForegroundColor Green
        foreach ($row in $parsed.summary) {
            Write-Host ("       {0,-12} : {1,7:N1} +/- {2,5:N1} tok/s (acc {3:N1}%, dlen {4:N2})" -f `
                $row.test, $row.tok_s_mean, $row.tok_s_stddev, $row.accept_pct_mean, $row.draft_len_mean) -ForegroundColor Gray
        }
    }

    Start-Sleep -Seconds $CooldownSeconds
    return [PSCustomObject]@{
        Arm        = $ArmLabel
        BuildLabel = $Build.Label
        ModelKind  = $ModelKind
        Phase      = $PhaseName
        ExitCode   = $mon.ExitCode
        MinFreeMiB = $mon.MinFreeMiB
        MaxRssMiB  = $mon.MaxRssMiB
        StallCount = $stalls.Count
        Json       = $parsed
        RunDir     = $runDir
    }
}

function Find-PythonForServe {
    param([string]$RootDir)
    if ($PythonExe -and (Test-Path $PythonExe)) { return $PythonExe }
    $candidates = @(
        (Join-Path $RootDir ".venv\Scripts\python.exe"),
        (Join-Path (Split-Path $RootDir -Parent) ".venv\Scripts\python.exe")
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return ""
}

function Invoke-ServeColdStress {
    param(
        [PSCustomObject]$Build,
        [string]$ModelKind,
        [string]$ModelPath,
        [string]$EngineFlags,
        [string]$ArmLabel,
        [string]$OutRoot
    )

    $runDir = Join-Path $OutRoot ("{0}_{1}_serve_cold" -f $ModelKind, ($ArmLabel -replace '[^a-zA-Z0-9._-]', '_'))
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $engineCfg = [ordered]@{ "max-context" = $ServeMaxContext }
    $toks = Split-FlagString -Flags $EngineFlags
    for ($i = 0; $i -lt $toks.Count; $i++) {
        if ($toks[$i] -match '^--(.+)$') {
            $k = $Matches[1]
            if ($i + 1 -lt $toks.Count -and $toks[$i + 1] -notmatch '^--') {
                $i++
                $v = $toks[$i]
                if ($v -match '^-?\d+$') { $engineCfg[$k] = [long]$v }
                elseif ($v -match '^-?\d+\.\d+$') { $engineCfg[$k] = [double]$v }
                else { $engineCfg[$k] = $v }
            } else {
                $engineCfg[$k] = $true
            }
        }
    }

    $cfgObj = @{
        version = 2
        server  = @{ host = "127.0.0.1"; port = $ServePort }
        engine  = $engineCfg
        models  = @(
            @{ alias = "stress-model"; model = $ModelPath; gpu = $Gpu; vision = "off" }
        )
    }
    $cfgPath = Join-Path $runDir "serve_stress.json"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($cfgPath, ($cfgObj | ConvertTo-Json -Depth 10), $utf8)

    $py = Find-PythonForServe -RootDir $Build.RootDir
    $srvArgs = New-Object System.Collections.Generic.List[string]
    $srvArgs.Add("serve"); $srvArgs.Add("--config"); $srvArgs.Add($cfgPath)
    if ($py) { $srvArgs.Add("--python"); $srvArgs.Add($py) }

    $srvStdOut = Join-Path $runDir "serve-stdout.log"
    $srvStdErr = Join-Path $runDir "serve-stderr.log"
    $ramCsv    = Join-Path $runDir "serve-ram-samples.csv"

    Write-Host ("  -> [{0}] {1} serve cold-compaction stress ({2} rounds)..." -f $ArmLabel, $ModelKind, $ServeColdRounds) -ForegroundColor Yellow
    Stop-StrayBasalt
    $srvProc = Start-Process -FilePath $Build.EngineExe -ArgumentList (Format-ArgString $srvArgs.ToArray()) `
        -WorkingDirectory $Build.RootDir -RedirectStandardOutput $srvStdOut -RedirectStandardError $srvStdErr -PassThru -NoNewWindow

    $ready = $false
    $swLoad = [System.Diagnostics.Stopwatch]::StartNew()
    while ($swLoad.Elapsed.TotalSeconds -lt 450 -and -not $srvProc.HasExited) {
        Start-Sleep -Seconds 1
        try {
            $h = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/health" -f $ServePort) -TimeoutSec 2 -ErrorAction Stop
            if ($h.loaded -eq $true) { $ready = $true; break }
        } catch {}
        $srvProc.Refresh()
    }

    $ramSamples = New-Object System.Collections.Generic.List[string]
    $ramSamples.Add("timestamp,round,free_phys_mib,basalt_rss_mib,basalt_private_mib")
    $minFreeMiB = [double]::MaxValue

    if (-not $ready) {
        Write-Host "     [ERROR] basalt serve did not become ready within 450s." -ForegroundColor Red
    } else {
        Write-Host ("     [OK] Server ready in {0:N1}s. Sending unique cold prompts..." -f $swLoad.Elapsed.TotalSeconds) -ForegroundColor Green
        $unit = "struct Node { uint64_t id; double w; uint32_t next; float acc; }; // block padding sample `n"
        $bodyText = ($unit * $ServePromptRepeat)

        for ($r = 1; $r -le $ServeColdRounds; $r++) {
            $nonce = [Guid]::NewGuid().ToString("N")
            $prompt = "RUN_ID=$nonce`n$bodyText`nSummarize the struct fields in one short sentence."
            $reqJson = @{
                model = "stress-model"
                messages = @(@{ role = "user"; content = $prompt })
                max_tokens = 24
                temperature = 0.0
                reasoning_effort = "none"
            } | ConvertTo-Json -Depth 6

            $reqFile = Join-Path $runDir ("req_{0}.json" -f $r)
            [System.IO.File]::WriteAllText($reqFile, $reqJson, $utf8)

            $uri = ("http://127.0.0.1:{0}/v1/chat/completions" -f $ServePort)
            $job = Start-Job -ScriptBlock {
                param($u, $f)
                $b = [System.IO.File]::ReadAllText($f)
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $resp = Invoke-RestMethod -Uri $u -Method Post -Body $b -ContentType "application/json" -TimeoutSec 420
                    $sw.Stop()
                    return [PSCustomObject]@{ Ok = $true; Ms = $sw.ElapsedMilliseconds; PromptTokens = $resp.usage.prompt_tokens; Err = "" }
                } catch {
                    $sw.Stop()
                    return [PSCustomObject]@{ Ok = $false; Ms = $sw.ElapsedMilliseconds; PromptTokens = 0; Err = $_.Exception.Message }
                }
            } -ArgumentList $uri, $reqFile

            while ($job.State -eq "Running") {
                $freeMiB = -1.0; $rssMiB = 0.0; $privMiB = 0.0
                try {
                    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
                    $freeMiB = [math]::Round($os.FreePhysicalMemory / 1024.0, 1)
                    if ($freeMiB -lt $minFreeMiB) { $minFreeMiB = $freeMiB }
                } catch {}
                try {
                    $bps = @(Get-Process -Name "basalt" -ErrorAction SilentlyContinue)
                    if ($bps.Count -gt 0) {
                        $rssMiB  = [math]::Round((($bps | Measure-Object WorkingSet64 -Sum).Sum) / 1MB, 1)
                        $privMiB = [math]::Round((($bps | Measure-Object PrivateMemorySize64 -Sum).Sum) / 1MB, 1)
                    }
                } catch {}
                $ramSamples.Add(("{0},{1},{2},{3},{4}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $r, $freeMiB, $rssMiB, $privMiB))
                Start-Sleep -Seconds 1
            }

            $res = Receive-Job -Job $job
            Remove-Job -Job $job -Force
            Remove-Item $reqFile -Force -ErrorAction SilentlyContinue
            if ($res.Ok) {
                Write-Host ("       Round {0}: OK ({1} prompt tokens in {2:N1}s)" -f $r, $res.PromptTokens, ($res.Ms / 1000.0)) -ForegroundColor Gray
            } else {
                Write-Host ("       Round {0}: FAILED after {1:N1}s - {2}" -f $r, ($res.Ms / 1000.0), $res.Err) -ForegroundColor Red
            }
        }
    }

    if ($srvProc -and -not $srvProc.HasExited) {
        cmd /c "taskkill /F /T /PID $($srvProc.Id)" 2>$null | Out-Null
    }
    Stop-StrayBasalt
    [System.IO.File]::WriteAllLines($ramCsv, $ramSamples, $utf8)
    Start-Sleep -Seconds $CooldownSeconds
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------
if (-not $BuildARoot) {
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    if ((Test-Path (Join-Path $here "bin\basalt-bench.exe")) -or (Test-Path (Join-Path $here "basalt-bench.exe"))) {
        $BuildARoot = $here
    } else {
        throw "Pass -BuildARoot pointing to an unpacked Basalt release folder (with bin\basalt-bench.exe)."
    }
}

$buildA = Resolve-BasaltBuild -InputPath $BuildARoot -FallbackLabel $LabelA
$buildB = if ($BuildBRoot) { Resolve-BasaltBuild -InputPath $BuildBRoot -FallbackLabel $LabelB } else { $null }

$searchDirs = @()
if ($ModelsDir) { $searchDirs += $ModelsDir }
if (-not $QwenModel -and -not $DeepSeekModel) {
    $searchDirs += @(
        (Join-Path $buildA.RootDir "models"),
        (Join-Path (Split-Path $buildA.RootDir -Parent) "models"),
        (Join-Path (Get-Location).Path "models")
    )
}

foreach ($d in ($searchDirs | Select-Object -Unique)) {
    if (-not $d -or -not (Test-Path $d)) { continue }
    if (-not $QwenModel) {
        $q = Get-ChildItem -Path $d -Filter "*.basalt" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)qwen' } | Select-Object -First 1
        if ($q) { $QwenModel = $q.FullName }
    }
    if (-not $DeepSeekModel) {
        $dsk = Get-ChildItem -Path $d -Filter "*.basalt" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)deepseek' } | Select-Object -First 1
        if ($dsk) { $DeepSeekModel = $dsk.FullName }
    }
}

$modelsToRun = @()
if ($QwenModel) {
    if (-not (Test-Path $QwenModel)) { throw "Qwen model not found: $QwenModel" }
    $modelsToRun += [PSCustomObject]@{ Kind = "Qwen3.8-FN"; Path = (Resolve-Path $QwenModel).Path; Flags = $QwenFlags }
}
if ($DeepSeekModel) {
    if (-not (Test-Path $DeepSeekModel)) { throw "DeepSeek model not found: $DeepSeekModel" }
    $modelsToRun += [PSCustomObject]@{ Kind = "DeepSeek-V4.1"; Path = (Resolve-Path $DeepSeekModel).Path; Flags = $DeepSeekFlags }
}
if ($modelsToRun.Count -eq 0) {
    throw "No models specified or found. Pass -QwenModel and/or -DeepSeekModel (or -ModelsDir)."
}

if (-not $OutDir) {
    $OutDir = Join-Path (Get-Location).Path ("basalt-test-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$sequence = if ($buildB) {
    @(
        @{ Arm = "A1_$($buildA.Label)"; Build = $buildA },
        @{ Arm = "B1_$($buildB.Label)"; Build = $buildB },
        @{ Arm = "B2_$($buildB.Label)"; Build = $buildB },
        @{ Arm = "A2_$($buildA.Label)"; Build = $buildA }
    )
} else {
    @(
        @{ Arm = "Single_$($buildA.Label)"; Build = $buildA }
    )
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " Basalt 0.5.x Verification Suite" -ForegroundColor Cyan
Write-Host " Build A : $($buildA.Label) ($($buildA.RootDir))" -ForegroundColor Cyan
if ($buildB) { Write-Host " Build B : $($buildB.Label) ($($buildB.RootDir)) [ABBA]" -ForegroundColor Cyan }
Write-Host " Output  : $OutDir" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

$allResults = @()

foreach ($m in $modelsToRun) {
    Write-Host "`n### Model: $($m.Kind) ($($m.Path))" -ForegroundColor White
    foreach ($step in $sequence) {
        if ($DecodeTests) {
            $allResults += Invoke-BenchPhase -Build $step.Build -ModelKind $m.Kind -ModelPath $m.Path -EngineFlags $m.Flags -ArmLabel $step.Arm -PhaseName "decode" -OutRoot $OutDir
        }
        if ($PrefillDepths) {
            $allResults += Invoke-BenchPhase -Build $step.Build -ModelKind $m.Kind -ModelPath $m.Path -EngineFlags $m.Flags -ArmLabel $step.Arm -PhaseName "prefill" -OutRoot $OutDir
        }
        if ($ServeColdRounds -gt 0) {
            Invoke-ServeColdStress -Build $step.Build -ModelKind $m.Kind -ModelPath $m.Path -EngineFlags $m.Flags -ArmLabel $step.Arm -OutRoot $OutDir
        }
    }
}

$reportPath = Join-Path $OutDir "summary.md"
$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Basalt Verification Report ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))")
$md.Add("")
$md.Add("- **Build A**: ``$($buildA.Label)`` (``$($buildA.RootDir)``)")
if ($buildB) { $md.Add("- **Build B**: ``$($buildB.Label)`` (``$($buildB.RootDir)``)") }
$md.Add("- **GPU**: ``$Gpu`` | **Decode reps**: $DecodeReps | **Seed**: $Seed | **Prefill depths**: ``$PrefillDepths``")
$md.Add("")
$md.Add("| Model | Arm | Phase | Test | tok/s | Accept % | Min Free RAM (MiB) | Max RSS (MiB) | Stalls | Exit |")
$md.Add("| :--- | :--- | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |")

foreach ($r in $allResults) {
    if ($r.Json -and $r.Json.summary) {
        foreach ($row in $r.Json.summary) {
            $acc = if ($null -ne $row.accept_pct_mean -and $row.accept_pct_mean -gt 0) { "{0:N1}" -f $row.accept_pct_mean } else { "-" }
            $md.Add("| $($r.ModelKind) | $($r.Arm) | $($r.Phase) | $($row.test) | $("{0:N1}" -f $row.tok_s_mean) | $acc | $($r.MinFreeMiB) | $($r.MaxRssMiB) | $($r.StallCount) | $($r.ExitCode) |")
        }
    } else {
        $md.Add("| $($r.ModelKind) | $($r.Arm) | $($r.Phase) | FAILED | - | - | $($r.MinFreeMiB) | $($r.MaxRssMiB) | $($r.StallCount) | $($r.ExitCode) |")
    }
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($reportPath, $md, $utf8)
Write-Host "`nDone! Report written to: $reportPath" -ForegroundColor Green
