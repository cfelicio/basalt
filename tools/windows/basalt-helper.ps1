# basalt-helper.ps1 - the tuning menu for a Basalt Windows release: basalt-probe with its
# suggestions merged into the config, A/B benches over the standard fixtures, a config
# interview and a server launcher. The release root's TUNE-HERE.bat runs this file; -Root
# points it at another installation.
param([string]$Root = $PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Get-Location).Path }
$ErrorActionPreference = 'Continue'

function C($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function AskDef($q, $def) {
    $a = Read-Host "$q [$def]"
    if ([string]::IsNullOrWhiteSpace($a)) { $def } else { $a.Trim() }
}
function AskY($q, $def = 'y') { (AskDef "$q (y/n)" $def) -match '^[yY]' }
function Resolve-P($p) { if ([System.IO.Path]::IsPathRooted($p)) { $p } else { (Join-Path $Root $p) } }

# ---------------------------------------------------------------- detect the release folder
$enginePath = Join-Path $Root 'bin\basalt.exe'
$probePath  = Join-Path $Root 'bin\basalt-probe.exe'
$benchPath  = Join-Path $Root 'bin\basalt-bench.exe'
foreach ($p in @($enginePath, $probePath, $benchPath)) {
    if (-not (Test-Path $p)) {
        C "`nnot found: $p" Red
        C 'Run TUNE-HERE.bat from the release root (the folder with bin\ and models\),' Yellow
        C 'or pass -Root: powershell -File basalt-helper.ps1 -Root <release folder>' Yellow
        Read-Host 'Press Enter to exit' | Out-Null
        exit 1
    }
}
$logsDir = Join-Path $Root 'helper-logs'

# ---------------------------------------------------------------- model
$modelCandidates = @()
foreach ($d in @((Join-Path $Root 'models'), $Root)) {
    if (Test-Path $d) {
        $modelCandidates += Get-ChildItem -Path $d -Filter '*.basalt' -File -ErrorAction SilentlyContinue |
                            ForEach-Object { $_.FullName }
    }
}
$modelPath = $null
if ($modelCandidates.Count -eq 1) { $modelPath = $modelCandidates[0] }
elseif ($modelCandidates.Count -gt 1) {
    C "`nModel files found:" Cyan
    for ($i = 0; $i -lt $modelCandidates.Count; $i++) {
        $sz = [math]::Round((Get-Item $modelCandidates[$i]).Length / 1GB, 1)
        C ("  [{0}] {1}  ({2} GB)" -f ($i + 1), $modelCandidates[$i], $sz)
    }
    $sel = AskDef 'pick the model to benchmark' '1'
    if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $modelCandidates.Count) {
        $modelPath = $modelCandidates[[int]$sel - 1]
    }
}
if (-not $modelPath) { $modelPath = Resolve-P (AskDef 'path to the .basalt model file' 'models\Qwen3.8-FN-NVFP4-DQ6_K.basalt') }
while (-not (Test-Path $modelPath)) {
    C "no model file at: $modelPath" Red
    $modelPath = Resolve-P (AskDef 'path to the .basalt model file (Enter to quit)' '')
    if (-not $modelPath) { exit 1 }
}
$modelRel = $modelPath
if ($modelPath.StartsWith($Root, 'OrdinalIgnoreCase')) { $modelRel = $modelPath.Substring($Root.Length).TrimStart('\') }
# DeepSeek-V4.1-Flash is fp16-KV-only and has no residency or relaxed-drafting flags (docs/models/index.md)
$script:isDeepSeek = $modelPath -match '(?i)deepseek'

# ---------------------------------------------------------------- fixtures (probe/bench prompt ids)
$script:fxNeed = @('conv.ids', 'struct.ids', 'prose.ids')
function FxOk($d) {
    if (-not $d -or -not (Test-Path $d)) { return $false }
    $missing = $script:fxNeed | Where-Object { -not (Test-Path (Join-Path $d $_)) }
    return @($missing).Count -eq 0
}
$script:fx = $null
foreach ($c in @((Join-Path $Root 'data\bench'), (Join-Path (Split-Path $Root -Parent) 'data\bench'))) {
    if (FxOk $c) { $script:fx = $c; break }
}
while (-not $script:fx) {
    C "`nbasalt-probe and basalt-bench need pre-tokenized prompt fixtures (conv.ids, struct.ids, prose.ids)." Yellow
    $cand = AskDef 'folder containing the .ids files (Enter to quit)' ''
    if (-not $cand) { exit 1 }
    if (FxOk $cand) { $script:fx = $cand } else { C "missing one or more of: $($script:fxNeed -join ', ') in $cand" Red }
}

# ---------------------------------------------------------------- gpu, config, base engine flags
$script:gpu = AskDef 'GPU numbers (as nvidia-smi lists them)' '0'

function Find-Config {
    foreach ($c in @((Join-Path $Root 'basalt_config.json'))) { if (Test-Path $c) { return $c } }
    $any = Get-ChildItem $Root -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -notmatch 'benchmarks|example'
    } | Select-Object -First 1
    if ($any) { return $any.FullName }
    return $null
}
$script:configPath = Find-Config

function ConfigToFlags($path) {
    try { $j = Get-Content $path -Raw | ConvertFrom-Json } catch { return '' }
    if (-not $j.engine) { return '' }
    $parts = @()
    foreach ($p in $j.engine.PSObject.Properties) {
        if ($p.Value -eq $true) { $parts += "--$($p.Name)" }
        elseif ($p.Value -is [System.Array]) {
            $parts += "--$($p.Name)"
            foreach ($v in $p.Value) { $parts += "$v" }
        }
        elseif ($null -ne $p.Value -and $p.Value -ne $false) { $parts += "--$($p.Name)"; $parts += "$($p.Value)" }
    }
    $parts -join ' '
}

$flagFile = Join-Path $Root 'helper-engine-flags.txt'
$script:base = ''
if (Test-Path $flagFile) {
    $script:base = (Get-Content $flagFile -Raw).Trim()
} elseif ($script:configPath -and (AskY 'start the base engine flags (used by probe/bench) from the config file' 'y')) {
    $script:base = ConfigToFlags $script:configPath
}
if ([string]::IsNullOrWhiteSpace($script:base)) {
    $script:base = if ($script:isDeepSeek) { '--max-context 262144' } else { '--kv int8 --max-context 262144' }
}
if ($script:isDeepSeek -and $script:base -match '(^|\s)--kv(\s|$)') {
    C '--kv: DeepSeek-V4.1-Flash runs fp16 KV only; dropped --kv from the base flags.' Yellow
    $script:base = ($script:base -replace '(^|\s)--kv(\s+\S+)?', ' ').Trim()
}
$script:base = $script:base -replace '\s+', ' '

C "`n--- basalt helper ---" Green
C "  folder   $Root"
C "  engine   $enginePath"
C "  model    $modelPath"
C "  fixtures $script:fx"
C "  config   $(if ($script:configPath) { $script:configPath } else { '(none yet - use menu 7)' })"
C "  gpu      $script:gpu"
C "  flags    $script:base"

# ---------------------------------------------------------------- shared plumbing
function Split-Flags($flags) { @($flags -split '\s+' | Where-Object { $_ -ne '' }) }

# Replace (or add) --name val in a flag string.
function Override-Flag($flags, $name, $val) {
    $toks = Split-Flags $flags
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $toks.Count; $i++) {
        if ($toks[$i] -eq "--$name") {
            while ($i + 1 -lt $toks.Count -and $toks[$i + 1] -notmatch '^--') { $i++ }
            continue
        }
        $out.Add($toks[$i])
    }
    $out.Add("--$name")
    if ($null -ne $val) { $out.Add("$val") }
    $out -join ' '
}

# Turn "--kv int8 --spec 7" into --set "kv int8" --set "spec 7" (basalt-bench syntax).
function Flags-ToSets($flags) {
    $toks = Split-Flags $flags
    $flat = @()
    for ($i = 0; $i -lt $toks.Count; $i++) {
        if ($toks[$i] -match '^--(.+)$') {
            $name = $Matches[1]
            $vals = @()
            while ($i + 1 -lt $toks.Count -and $toks[$i + 1] -notmatch '^--') { $i++; $vals += $toks[$i] }
            $flat += @('--set', (('{0} {1}' -f $name, ($vals -join ' ')).Trim()))
        }
    }
    return $flat
}

# Turn a flag string into an ordered name->value map (bool/number/string) for the JSON engine block.
function Flags-ToEngine($flags) {
    $toks = Split-Flags $flags
    $o = [ordered]@{}
    for ($i = 0; $i -lt $toks.Count; $i++) {
        if ($toks[$i] -match '^--(.+)$') {
            $name = $Matches[1]
            $vals = @()
            while ($i + 1 -lt $toks.Count -and $toks[$i + 1] -notmatch '^--') { $i++; $vals += $toks[$i] }
            if ($vals.Count -eq 0) { $o[$name] = $true }
            elseif ($vals.Count -eq 1) {
                $v = $vals[0]
                if     ($v -match '^-?[0-9]+$')          { $o[$name] = [long]$v }
                elseif ($v -match '^-?[0-9]*\.?[0-9]+$') { $o[$name] = [double]$v }
                else                                     { $o[$name] = $v }
            } else { $o[$name] = $vals }
        }
    }
    return $o
}

function Write-Json($obj, $path) {
    $json = $obj | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Pause-Menu { Read-Host "`nPress Enter for the menu" | Out-Null }

# ---------------------------------------------------------------- menu 1: hardware
function Run-Hardware {
    C "`nnvidia-smi:" Cyan
    try { & nvidia-smi --query-gpu=name,memory.total,power.limit,driver_version --format=csv } catch { C 'nvidia-smi not found' Red }
    C "`nlink and memory rates (no model loaded):" Cyan
    & $benchPath --engine $enginePath --hardware
}

# ---------------------------------------------------------------- menu 2: probe
function Offer-Apply($lines) {
    $set = New-Object System.Collections.Specialized.OrderedDictionary
    $drop = @()
    foreach ($l in $lines) {
        if ($l -match 'no\s+--expert-profile-save') { $drop += 'expert-profile-save'; continue }
        foreach ($m in [regex]::Matches($l, '--([a-z0-9][a-z0-9-]*)\s+(\S+)')) {
            $n = $m.Groups[1].Value; $v = $m.Groups[2].Value
            if     ($v -match '^-?[0-9]+$')          { $set[$n] = [long]$v }
            elseif ($v -match '^-?[0-9]*\.[0-9]+$')  { $set[$n] = [double]$v }
            else                                     { $set[$n] = $v }
        }
    }
    if ($set.Count -eq 0 -and $drop.Count -eq 0) { return }
    C "`nThe probe measured these as faster than the defaults on YOUR machine:" Green
    foreach ($k in $set.Keys) { C "  $($k) = $($set[$k])" Green }
    foreach ($k in $drop)     { C "  remove $k" Green }
    if (-not (AskY 'merge them into the config file engine block' 'y')) { return }

    if (-not $script:configPath -or -not (Test-Path $script:configPath)) {
        if (-not (AskY "no config found: create $(Join-Path $Root 'basalt_config.json')" 'y')) { return }
        $script:configPath = Join-Path $Root 'basalt_config.json'
        $cfg = [pscustomobject]@{
            server = [pscustomobject]@{ model = $modelRel; gpu = "$script:gpu"; host = '127.0.0.1'; port = 8083; vision = 'dynamic' }
            engine = [pscustomobject](Flags-ToEngine $script:base)
        }
    } else {
        $cfg = Get-Content $script:configPath -Raw | ConvertFrom-Json
    }
    if (-not $cfg.engine) { $cfg | Add-Member -NotePropertyName engine -NotePropertyValue ([pscustomobject]@{}) -Force }
    foreach ($k in $set.Keys) {
        if ($cfg.engine.PSObject.Properties[$k]) { $cfg.engine.$k = $set[$k] }
        else { $cfg.engine | Add-Member -NotePropertyName $k -NotePropertyValue $set[$k] }
    }
    foreach ($k in $drop) {
        if ($cfg.engine.PSObject.Properties[$k]) { $cfg.engine.PSObject.Properties.Remove($k) }
    }
    $bak = "$script:configPath.bak"
    Copy-Item $script:configPath $bak -Force -ErrorAction SilentlyContinue
    Write-Json $cfg $script:configPath
    C "merged into $script:configPath (previous copy: $bak)" Green
    C 'restart the server to apply it.' Yellow
}

function Run-Probe {
    C "`nbasalt-probe: loads the model, runs 5 short sequences + the adaptive tests." Cyan
    C "Expect a few minutes. Close any running Basalt server first (the GPU must be free)." Yellow
    if (-not (AskY 'start the probe' 'y')) { return }
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    $pa = @('--engine', $enginePath, '--model', $modelPath, '--fixtures', $script:fx, '--gpu', $script:gpu, '--logs', $logsDir, '--') + (Split-Flags $script:base)
    # Windows PowerShell 5.1 has no Tee-Object -Variable (6+ only), so stream each line to the
    # host and keep a copy for the suggested: parsing; the log goes out whole at the end.
    $all = New-Object System.Collections.Generic.List[string]
    & $probePath @pa 2>&1 | ForEach-Object { $all.Add("$_"); Write-Host "$_" }
    $all | Set-Content -LiteralPath (Join-Path $logsDir 'probe-report.txt') -Encoding ASCII
    $sugg = @($all | ForEach-Object { "$_" } | Where-Object { $_ -match 'suggested:' })
    if ($sugg.Count -gt 0) { Offer-Apply $sugg }
    else { C "`nNo suggested: lines - the built-in defaults were already best on this machine." Green }
}

# ---------------------------------------------------------------- bench runners
function Run-BenchLabelled($label, $flags, $reps, $withPrefill) {
    C "`n--- $label ---" Cyan
    C "    engine flags: $flags" DarkGray
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    $ba = @('--engine', $enginePath, '--model', $modelPath, '--fixtures', $script:fx, '--gpu', $script:gpu,
            '-r', "$reps", '-t', 'conv,struct,prose', '--logs', $logsDir)
    if ($withPrefill -and (Test-Path (Join-Path $script:fx 'prefill.ids'))) { $ba += @('-p', '16384') }
    $ba += (Flags-ToSets $flags)
    & $benchPath @ba
    C "(exit code $LASTEXITCODE)" DarkGray
}

function Run-KvCompare {
    if ($script:isDeepSeek) {
        C "`nDeepSeek-V4.1-Flash has no KV choice (fp16 only, docs/models/index.md): this A/B does not apply." Yellow
        return
    }
    C "`nSame workload, different KV formats. int8 is the usual pick; k8v4/q4_0 free VRAM for experts." Cyan
    $reps = AskDef 'repetitions per row (-r)' '2'
    $list = AskDef 'KV formats to compare' 'int8 k8v4 q4_0'
    foreach ($kv in ($list -split '\s+' | Where-Object { $_ })) {
        Run-BenchLabelled "kv = $kv" (Override-Flag $script:base 'kv' $kv) $reps $true
    }
    C "`nq4_0 and k8v4 trade a little precision for VRAM (see docs/precision/index.md)." Yellow
}

function Run-DraftCompare {
    C "`nWhat speculation costs/gains. relaxed-drafting is FASTER but changes the sampling distribution." Cyan
    $reps = AskDef 'repetitions per row (-r)' '2'
    Run-BenchLabelled 'baseline (current flags)' $script:base $reps $false
    if ($script:isDeepSeek) {
        # DeepSeek has no relaxed-drafting flag; its knob is the DSpark window (--spec, default 3).
        Run-BenchLabelled 'spec 3 (DSpark default window)' (Override-Flag $script:base 'spec' '3') $reps $false
    } else {
        Run-BenchLabelled 'relaxed-drafting true'  (Override-Flag $script:base 'relaxed-drafting' 'true') $reps $false
    }
    Run-BenchLabelled 'spec 0 (no speculation)' (Override-Flag $script:base 'spec' '0') $reps $false
}

function Run-Custom {
    $extra = AskDef 'extra engine flags to add on top of the base (Enter = base only)' ''
    $reps = AskDef 'repetitions (-r)' '2'
    $flags = $script:base
    if ($extra) { $flags = ("$script:base $extra" -replace '\s+', ' ').Trim() }
    Run-BenchLabelled 'custom run' $flags $reps $true
}

# ---------------------------------------------------------------- menu 6: quality
function Run-Quality {
    C "`nQuality gate: PPL/KLD/top-1 against the BF16 reference through the decode path." Cyan
    if ($script:isDeepSeek) {
        C 'DeepSeek-V4.1-Flash has no lossy flags to measure (docs/models/index.md): this gate scores the pack itself.' Yellow
    } else {
        C 'This pack''s OFFICIAL numbers are already published:' Yellow
        C '  https://huggingface.co/jesdga/Qwen3.8-Flash-Next-Basalt#quality' Yellow
        C 'You only need to run this yourself to measure LOSSY flags (relaxed-drafting, q4_0, k8v4...)' Yellow
    }
    C 'against the reference. It needs the BF16 .kld base file (llama-perplexity --kl-divergence-base' Yellow
    C 'on the BF16 GGUF; see docs/precision/quality.md).' Yellow
    $kld = AskDef 'path to the .kld base file (Enter to go back)' ''
    if (-not $kld) { return }
    if (-not (Test-Path $kld)) { C "not found: $kld" Red; return }
    $chunks = AskDef 'chunks to score' '100'
    $lossy = AskDef 'extra lossy flags to score, e.g. "--relaxed-drafting true" (Enter = none)' ''
    $flags = $script:base
    if ($lossy) { $flags = "$script:base $lossy" }
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    $qa = @('--engine', $enginePath, '--model', $modelPath, '--fixtures', $script:fx, '--gpu', $script:gpu,
            '--quality', "$chunks", '--kld-base', $kld, '--logs', $logsDir) + (Flags-ToSets $flags)
    & $benchPath @qa
    Pause-Menu
}

# ---------------------------------------------------------------- menu 7: config interview
function New-Config {
    $path = Resolve-P (AskDef 'config file to create/replace' 'basalt_config.json')
    if (Test-Path $path -and -not (AskY "overwrite existing $path" 'n')) { return }
    $hostSel = AskDef 'bind address: 1 = 127.0.0.1 (this machine only), 2 = 0.0.0.0 (whole LAN)' '1'
    $hostAddr = if ($hostSel -eq '2') { '0.0.0.0' } else { '127.0.0.1' }
    $port = [int](AskDef 'port' '8083')
    $vision = AskDef 'vision (dynamic / off)' 'dynamic'
    $ctx = [long](AskDef 'max-context tokens' '262144')
    $engine = [ordered]@{ 'max-context' = $ctx; 'expert-cache' = 'auto' }
    if ($script:isDeepSeek) {
        C 'DeepSeek-V4.1-Flash: fp16 KV only; no prefill/residency/relaxed-drafting flags; DSpark drafts by default.' DarkGray
    } else {
        $engine['prefill'] = 'auto'
        $engine['kv'] = (AskDef 'kv format (int8 / k8v4 / q4_0 / fp16)' 'int8')
        $engine['resident-experts'] = $true
        if (AskY 'relaxed-drafting (faster, changes the sampling distribution)' 'y') { $engine['relaxed-drafting'] = $true }
    }
    if (AskY 'expert-profile-save (restarts reuse the learned expert placement)' 'y') { $engine['expert-profile-save'] = 'basalt-learned.prof' }

    $cfg = [pscustomobject]@{
        server = [pscustomobject]@{ model = $modelRel; gpu = "$script:gpu"; host = $hostAddr; port = $port; vision = $vision }
        engine = [pscustomobject]$engine
    }
    Write-Json $cfg $path
    $script:configPath = $path
    $script:base = ConfigToFlags $path
    Set-Content -Path $flagFile -Value $script:base -Encoding ASCII
    C "wrote $path" Green
    C "bench/probe base flags now: $script:base" DarkGray

    $bat = Join-Path $Root 'run-server.bat'
    @"
@echo off
rem Starts the Basalt server from this folder's config.
rem api-key CANNOT live in the config file: set BASALT_API_KEY and it is passed here.
cd /d "%~dp0"
if defined BASALT_API_KEY (
    bin\basalt.exe serve --config $(Split-Path $path -Leaf) --api-key %BASALT_API_KEY% %*
) else (
    bin\basalt.exe serve --config $(Split-Path $path -Leaf) %*
)
"@ | Set-Content -Path $bat -Encoding ASCII
    C "wrote $bat" Green
    if ($hostAddr -eq '0.0.0.0') {
        C "`nWARNING: bound to 0.0.0.0 - set BASALT_API_KEY before exposing this machine to the LAN." Red
    }
}

# ---------------------------------------------------------------- menu 8: server
function Run-Server {
    if (-not $script:configPath -or -not (Test-Path $script:configPath)) {
        C 'no config file yet - use menu 7 first, or start the server by hand.' Red; return
    }
    $sa = @('serve', '--config', $script:configPath)
    try { $hostAddr = (Get-Content $script:configPath -Raw | ConvertFrom-Json).server.host } catch { $hostAddr = '127.0.0.1' }
    if ("$hostAddr" -ne '127.0.0.1') {
        C "the config binds ${hostAddr} - without an api-key ANY machine on your network can use this server." Red
        $key = Read-Host 'api-key (Enter to start WITHOUT one, not recommended)'
        if ($key) { $sa += @('--api-key', $key) }
    }
    if (AskY 'add profiling flags (--decode-timing, --draft-log)' 'n') {
        New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
        $sa += @('--decode-timing', '--draft-log', (Join-Path $logsDir 'draft.log'))
    }
    C "`nrunning: $(Split-Path $enginePath -Leaf) $($sa -join ' ')" Cyan
    C '(Ctrl+C stops it; it keeps running until then, so probe/bench need it closed)' DarkGray
    & $enginePath @sa
}

# ---------------------------------------------------------------- menu 9/10: show & edit
function Show-Current {
    C "`nbase engine flags (probe/bench):  $script:base"
    C "saved flags file: $flagFile"
    C "fixtures: $script:fx"
    C "logs: $logsDir"
    if ($script:configPath -and (Test-Path $script:configPath)) {
        C "`nconfig ($script:configPath):"
        Get-Content $script:configPath | ForEach-Object { Write-Host "  $_" }
    } else { C "`nno config file yet (menu 7 creates one)." Yellow }
    C "`nNote: basalt-bench --community refuses --engine, so it needs a git source build;" Yellow
    C 'menu 3/4 run the same fixtures instead, comparable between your own runs.'
}

function Edit-Base {
    C "`ncurrent base engine flags:" Cyan
    C "  $script:base"
    C 'these are what probe and bench run; keep them equal to your server config.' DarkGray
    $a = AskDef 'new flags (Enter keeps)' ''
    if ($a) {
        $script:base = $a.Trim() -replace '\s+', ' '
        Set-Content -Path $flagFile -Value $script:base -Encoding ASCII
        C "saved to $flagFile" Green
    }
}

# ---------------------------------------------------------------- menu loop
while ($true) {
    C "`n=============== basalt helper ===============" Green
    C '  1   hardware snapshot (GPU, PCIe link, RAM read rate)'
    C '  2   basalt-probe: machine-tuned settings, merge into the config'
    C '  3   KV-format A/B bench (int8 vs k8v4 vs q4_0)'
    C '  4   drafting A/B bench (baseline vs relaxed-drafting vs no speculation)'
    C '  5   custom bench run (your own extra engine flags)'
    C '  6   quality gate (PPL/KLD, needs the BF16 .kld base file)'
    C '  7   create basalt_config.json + run-server.bat (interview)'
    C '  8   start the server (optional profiling flags)'
    C '  9   show current config, flags and paths'
    C '  10  edit the base engine flags used by 2-6'
    C '  0   exit'
    $choice = (AskDef 'choice' '2').Trim()
    try {
        switch ($choice) {
            '1' { Run-Hardware; Pause-Menu }
            '2' { Run-Probe; Pause-Menu }
            '3' { Run-KvCompare; Pause-Menu }
            '4' { Run-DraftCompare; Pause-Menu }
            '5' { Run-Custom; Pause-Menu }
            '6' { Run-Quality }
            '7' { New-Config; Pause-Menu }
            '8' { Run-Server }
            '9' { Show-Current; Pause-Menu }
            '10' { Edit-Base }
            '0' { C 'bye'; break }
            default { C "unknown choice: $choice" Red }
        }
    } catch {
        C "error: $($_.Exception.Message)" Red
        Pause-Menu
    }
    if ($choice -eq '0') { break }
}
