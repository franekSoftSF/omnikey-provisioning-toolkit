function Invoke-OmnikeyBatch {
    <#
    .SYNOPSIS
      Batch provisioning station: plug a batch -> check every unit -> apply only when needed ->
      reboot -> verify by serial -> CSV audit trail. Runs until Ctrl+C.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [string]$LogCsv = ".\omnikey-provisioning.csv",
        [string]$InventoryMap = "",
        [ValidateSet("en", "pl")][string]$Lang = "en",
        [string]$ReaderMatch = "5022",
        [int]$PollMs = 500, [int]$StableSec = 4, [int]$RebootWait = 10, [int]$VerifyRetry = 30
    )
    Set-MessageLanguage $Lang

    $inv  = Read-InventoryMap $InventoryMap
    $prof = Get-Content $ProfilePath -Raw | ConvertFrom-Json
    $ops  = ConvertTo-OperationList $prof
    $done = Read-ResumeState $LogCsv

    Initialize-Context
    if (-not (Test-ContextReady)) { throw "SCardSvr?" }
    Write-Host "=== OMNIKEY BATCH PROVISIONING ($ReaderMatch) | profile: $ProfilePath | params: $($ops.Count) ===" -ForegroundColor Cyan
    Write-Host ((T resume $done.Count) + " | CSV: $LogCsv`n")
    $sPass = 0; $sFail = 0; $batchNo = 0

    try {
        while ($true) {
            Write-Host (T wait) -ForegroundColor DarkGray
            [void](Wait-BatchStable $ReaderMatch $PollMs $StableSec)
            $batchNo++
            $readers = Get-ReaderList $ReaderMatch
            Write-Host ("`n" + (T batch $batchNo $readers.Count)) -ForegroundColor Cyan

            $batch = @{}   # serial -> @{id; status; detail; verified}
            foreach ($r in $readers) {
                $state = Get-BatchUnitState $r $ops
                if (-not $state) {
                    Write-Host ("  [$r] " + (T readErr) + " ($script:lastErr)") -ForegroundColor Red
                    Write-ProvisioningLog $LogCsv $inv @{Serial = "UNKNOWN"; Product = "?"; Fw = "?"} "FAIL" ((T readErr) + " ($r / $script:lastErr)"); $sFail++
                    continue
                }
                Write-Host (T state $state.Id.Serial $state.Id.Product $state.Id.Fw)
                $batch[$state.Id.Serial] = Invoke-BatchUnitApply $r $ops $state
            }

            Invoke-BatchVerify $batch $ops $ReaderMatch $RebootWait $VerifyRetry $PollMs

            $pass = 0; $fail = 0
            foreach ($sn in $batch.Keys) {
                $b = $batch[$sn]
                if ($b.status -eq "PASS") { $pass++; $done[$sn] = $true } else { $fail++ }
                Write-ProvisioningLog $LogCsv $inv $b.id $b.status $b.detail
                Write-Host ("  {0}: {1} - {2}" -f $sn, $b.status, $b.detail) -ForegroundColor $(if ($b.status -eq "PASS") { "Green" } else { "Red" })
            }
            $sPass += $pass; $sFail += $fail
            Write-Host (T sum $batchNo $pass $fail $sPass $sFail $done.Count) -ForegroundColor Cyan
            if ($fail -eq 0) { Invoke-BeepOk } else { Invoke-BeepFail 600 }

            Write-Host (T unplug) -ForegroundColor DarkGray
            while ((Get-ReaderList $ReaderMatch).Count -gt 0) { Start-Sleep -Milliseconds $PollMs }
            Write-Host ""
        }
    }
    finally {
        Close-Context
        Write-Host ("`n" + (T done $sPass $sFail $done.Count))
    }
    [int]0
}
