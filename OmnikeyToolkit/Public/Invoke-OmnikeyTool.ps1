function Invoke-OmnikeyTool {
    <#
    .SYNOPSIS
      Single-reader tool (Get / Set / Verify / Export / TestCard). Returns the exit code
      (0 OK/PASS, 2 FAIL); execution errors throw (the calling script exits with 1).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [ValidateSet("Get", "Set", "Verify", "TestCard", "Export")] [string]$Mode = "Get",
        [string]$ProfilePath = "",
        [ValidateSet("en", "pl")] [string]$Lang = "en",
        [string]$ReaderMatch = "5022",
        [switch]$NoReboot,
        [int]$RebootWait = 10,
        [int]$CardTimeout = 30,
        [string]$OutProfile = ".\reader-profile.json",
        [switch]$Loop
    )
    Set-MessageLanguage $Lang

    Initialize-Context
    if (-not (Test-ContextReady)) { throw (T noService) }
    $all = Get-ReaderList
    $reader = $all | Where-Object { $_ -match $ReaderMatch } | Select-Object -First 1
    if (-not $reader) { throw (T noReader $ReaderMatch ($all -join "`n")) }

    $prof = $null
    if ($Mode -in "Set", "Verify") {
        if (-not $ProfilePath) { throw (T profileNeeded $Mode) }
        try { $prof = Get-Content $ProfilePath -Raw | ConvertFrom-Json } catch { throw (T profileBad $_.Exception.Message) }
    }

    $exit = 0
    $card = Connect-Direct $reader
    try {
        $id = Read-Identity $card
        $model = Resolve-ReaderModel $id
        Write-Host ("{0}: {1}" -f (T reader), $reader) -ForegroundColor Cyan
        Write-Host ("{0}: {1}`n" -f (T serial), $(if ($id.Serial) { $id.Serial } else { "?" })) -ForegroundColor Cyan
        Write-ModelNote $model

        switch ($Mode) {
            "Get" {
                Write-Host (T current) -ForegroundColor Cyan
                (Get-ReaderConfiguration $card $model).GetEnumerator() | ForEach-Object { Write-Host ("  {0,-28} {1}" -f $_.Key, $_.Value) }
            }
            "Set" {
                $ops = ConvertTo-OperationList $prof $model
                if (-not $model.known) { throw (T modelNoWrite $model.product) }
                Write-Host (T setting)
                $failed = $false
                foreach ($op in $ops) {
                    try { Invoke-OpApply $card $op; Write-Host (T setOk $op.name $op.wantDisp) -ForegroundColor Green }
                    catch { Write-Host (T setFail $op.name $_.Exception.Message) -ForegroundColor Red; $failed = $true }
                }
                if ($failed) { $exit = 1 }
                Write-Host (T applying)
                [void](Send-Escape $card $script:APDU_APPLY)
                if ($NoReboot) { Write-Host (T rebootSkip) -ForegroundColor Yellow }
                else {
                    try { [void](Send-Escape $card $script:APDU_REBOOT) } catch { }
                    Write-Host (T applied) -ForegroundColor Green
                }
            }
            "Export" {
                Export-ReaderProfile $card $OutProfile $model
                Write-Host (T current) -ForegroundColor Cyan
                (Get-ReaderConfiguration $card $model).GetEnumerator() | ForEach-Object { Write-Host ("  {0,-28} {1}" -f $_.Key, $_.Value) }
                $abs = (Resolve-Path $OutProfile).Path
                Write-Host ""
                Write-Host (T exported $abs) -ForegroundColor Green
                Write-Host (T exportHint $abs)
            }
            "TestCard" {
                $contactless = [bool]$model.contactless
                $pref = if ($contactless) { Get-BoolParam $card "A2" "84" } else { $false }
                Disconnect-Card $card   # release DIRECT before SHARED card session
                if (-not $Loop) {
                    $exit = Invoke-CardTest $reader $CardTimeout ([bool]$pref) $contactless
                } else {
                    Write-Host (T loopStart) -ForegroundColor Cyan
                    $nTotal = 0; $nClassic = 0; $nOther = 0
                    try {
                        while ($true) {
                            Write-Host ("--- #{0} ---" -f ($nTotal + 1)) -ForegroundColor DarkCyan
                            $r = Invoke-CardTest $reader $CardTimeout ([bool]$pref) $contactless
                            if ($r -eq 1) { continue }        # timeout - keep waiting for next card
                            $nTotal++
                            if ($r -eq 0) { $nClassic++; Invoke-BeepOk } else { $nOther++; Invoke-BeepFail 500 }
                            Wait-CardRemoved $reader
                            Write-Host ""
                        }
                    }
                    finally {
                        Write-Host ""
                        Write-Host (T loopSum $nTotal $nClassic $nOther) -ForegroundColor Cyan
                        $exit = 0
                    }
                }
            }
            "Verify" {
                $ops = ConvertTo-OperationList $prof $model
                Write-Host (T verifying)
                $bad = 0
                foreach ($op in $ops) {
                    try {
                        $r = Invoke-OpCheck $card $op
                        if ($r.ok) { Write-Host (T vOk $op.name $op.wantDisp) -ForegroundColor Green }
                        else       { Write-Host (T vBad $op.name $op.wantDisp) -NoNewline -ForegroundColor Red
                                     Write-Host (", reader: {0}" -f $r.have) -ForegroundColor Red; $bad++ }
                    }
                    catch { Write-Host (T vReadFail $op.name) -ForegroundColor Red; $bad++ }
                }
                Write-Host ""
                if ($bad -eq 0) { Write-Host (T resultPass $ops.Count) -ForegroundColor Green; $exit = 0 }
                else            { Write-Host (T resultFail $bad $ops.Count) -ForegroundColor Red;  $exit = 2 }
            }
        }
    }
    finally {
        Disconnect-Card $card
        if ($Mode -eq "Set" -and -not $NoReboot) { Start-Sleep -Seconds 2 }
        Close-Context
    }
    [int]$exit
}
