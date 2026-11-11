<#
.SYNOPSIS
    Automated prompt test suite for Basalt server (DeepSeek-V4.1-Flash).
    Used to test PR #320 (Incremental Tail Prefill) and PR #322 / #5 (Memory & Context Scaling).

.USAGE
    # First start the server in a separate terminal:
    # .\bin\basalt.exe serve --config config.epyc7443.json

    # Then run this script:
    .\test-prompts.ps1 -Test Tail
    .\test-prompts.ps1 -Test MultiTurn
#>

param(
    [ValidateSet("Tail", "MultiTurn", "All")]
    [string]$Test = "Tail",
    [string]$Endpoint = "http://127.0.0.1:8080/v1/chat/completions",
    [string]$Model = "DeepSeek-V4.1-Flash"
)

function Send-ChatRequest {
    param([array]$Messages, [int]$MaxTokens = 64)
    $body = @{
        model = $Model
        messages = $Messages
        max_tokens = $MaxTokens
        temperature = 0.0
    } | ConvertTo-Json -Depth 10

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-RestMethod -Uri $Endpoint -Method Post -Body $body -ContentType "application/json" -TimeoutSec 120
        $sw.Stop()
        return @{
            Success = $true
            Content = $response.choices[0].message.content
            ElapsedMs = $sw.ElapsedMilliseconds
            Usage = $response.usage
        }
    } catch {
        $sw.Stop()
        return @{
            Success = $false
            Error = $_.Exception.Message
            ElapsedMs = $sw.ElapsedMilliseconds
        }
    }
}

# --- Harmless repetitive payload to build ~6,000 tokens of prefix ---
$block = @"
// System Architecture Reference Specification
// Section: In-Memory Data Pipeline and Batch Ingestion Worker
public class DataRecord {
    public long Id { get; set; }
    public string Payload { get; set; }
    public DateTime Timestamp { get; set; }
    public double[] MetricValues { get; set; }
    public bool IsProcessed { get; set; }

    public double ComputeScore(double weight) {
        if (MetricValues == null || MetricValues.Length == 0) return 0.0;
        double sum = 0.0;
        for (int i = 0; i < MetricValues.Length; i++) {
            sum += MetricValues[i] * weight * (i + 1);
        }
        return sum / MetricValues.Length;
    }
}
"@

$codePrefix = ($block + "`n`n") * 65 # ~6,500 tokens

if ($Test -eq "Tail" -or $Test -eq "All") {
    Write-Host "`n========================================================" -ForegroundColor Cyan
    Write-Host " TEST: Incremental Tail Prefill (PR #320)" -ForegroundColor Cyan
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "Sending Turn 1 (~6,500 token prefix)..." -ForegroundColor Yellow
    
    $messages = @(
        @{ role = "system"; content = "You are a concise software engineering assistant." },
        @{ role = "user"; content = $codePrefix + "`n`nQuestion 1: In one sentence, what does the ComputeScore function calculate?" }
    )
    
    $r1 = Send-ChatRequest -Messages $messages -MaxTokens 32
    if (-not $r1.Success) {
        Write-Host "Turn 1 Failed: $($r1.Error)" -ForegroundColor Red
        return
    }
    Write-Host "Turn 1 Done in $($r1.ElapsedMs) ms." -ForegroundColor Green
    Write-Host "Response: $($r1.Content.Trim())" -ForegroundColor Gray

    # Append assistant reply to simulate conversational state
    $messages += @{ role = "assistant"; content = $r1.Content }
    
    # Send Turn 2: Incremental tail of ~85 tokens (exceeds the 16-token threshold!)
    $turn2Prompt = "Question 2: Please write a short unit test function in C# that tests ComputeScore with an array of three elements: 1.0, 2.0, 3.0, and a weight of 2.0. Check that the returned score matches the expected value."
    $messages += @{ role = "user"; content = $turn2Prompt }
    
    Write-Host "`nSending Turn 2 (Incremental Tail: ~85 fresh tokens)..." -ForegroundColor Yellow
    $r2 = Send-ChatRequest -Messages $messages -MaxTokens 64
    if (-not $r2.Success) {
        Write-Host "Turn 2 Failed: $($r2.Error)" -ForegroundColor Red
        return
    }
    
    Write-Host "Turn 2 Total Elapsed: $($r2.ElapsedMs) ms" -ForegroundColor Green
    Write-Host "Check the server console output for Turn 2 prompt latency:" -ForegroundColor Magenta
    Write-Host "  -> Baseline takes ~2,000 ms (step decode loop for <256 tokens)" -ForegroundColor White
    Write-Host "  -> PR #320 takes ~850 ms (batch prefill chunk for >=16 tokens)" -ForegroundColor White
}

if ($Test -eq "MultiTurn" -or $Test -eq "All") {
    Write-Host "`n========================================================" -ForegroundColor Cyan
    Write-Host " TEST: Multi-Turn Context Scaling (PR #322 & PR #5)" -ForegroundColor Cyan
    Write-Host "========================================================" -ForegroundColor Cyan
    
    $messages = @(
        @{ role = "system"; content = "You are an expert algorithm designer. Reply concisely." }
    )
    
    $rounds = @(
        "Generate a 100-line Python implementation of a ThreadSafeRingBuffer with lock-free atomics.",
        "Now extend this RingBuffer to support batched dequeue with timeout handling.",
        "Add a benchmark driver comparing single-item enqueue vs batch enqueue under 16 concurrent threads.",
        "Refactor the memory layout to prevent false sharing by aligning head and tail pointers to 64-byte cache lines.",
        "Write 3 comprehensive pytest test cases validating empty queue, full queue, and concurrent wrap-around."
    )

    $turn = 1
    foreach ($prompt in $rounds) {
        Write-Host "`n--- Round $turn of $($rounds.Count) ---" -ForegroundColor Yellow
        $messages += @{ role = "user"; content = $prompt }
        $res = Send-ChatRequest -Messages $messages -MaxTokens 64
        if ($res.Success) {
            Write-Host "Round $turn completed in $($res.ElapsedMs) ms." -ForegroundColor Green
            $messages += @{ role = "assistant"; content = $res.Content }
        } else {
            Write-Host "Round $turn failed: $($res.Error)" -ForegroundColor Red
            break
        }
        $turn++
    }
    Write-Host "`nMulti-turn run finished. Check server console:" -ForegroundColor Magenta
    Write-Host "  -> Observe VRAM expert tier hit rate (should be 30%+ without paging freezes)" -ForegroundColor White
}
