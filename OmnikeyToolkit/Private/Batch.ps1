# Batch provisioning station building blocks. All scriptblocks handed to Invoke-WithReader are
# defined here, inside the module (lesson 1). Units are matched by SERIAL NUMBER after reboot
# (USB indices shuffle).

$script:CsvHeader = "timestamp;serial;product_name;firmware;inventory_number;result;detail"

function Read-InventoryMap([string]$path) {
    $inv = @{}
    if ($path -and (Test-Path $path)) {
        Import-Csv $path -Delimiter ';' | ForEach-Object { if ($_.serial) { $inv[$_.serial] = $_.inventory_number } }
    }
    $inv
}
function Read-ResumeState([string]$logCsv) {
    $done = @{}
    if (Test-Path $logCsv) { Import-Csv $logCsv -Delimiter ';' | Where-Object { $_.result -eq "PASS" } | ForEach-Object { $done[$_.serial] = $true } }
    $done
}
function Write-ProvisioningLog([string]$logCsv, [hashtable]$inv, [hashtable]$id, [string]$result, [string]$detail) {
    if (-not (Test-Path $logCsv)) { $script:CsvHeader | Out-File $logCsv -Encoding utf8 }
    $invNo = if ($id.Serial -and $inv.ContainsKey($id.Serial)) { $inv[$id.Serial] } else { "" }
    "{0};{1};{2};{3};{4};{5};{6}" -f (Get-Date -Format s), $id.Serial, $id.Product, $id.Fw, $invNo, $result, $detail |
        Out-File $logCsv -Append -Encoding utf8
}

# wait until the number of matching readers is non-zero and stable for $stableSec
function Wait-BatchStable([string]$readerMatch, [int]$pollMs, [int]$stableSec) {
    $count = 0; $stableFor = 0
    while ($true) {
        Start-Sleep -Milliseconds $pollMs
        $now = (Get-ReaderList $readerMatch).Count
        if ($now -gt 0 -and $now -eq $count) { $stableFor += $pollMs; if ($stableFor -ge ($stableSec * 1000)) { break } } else { $stableFor = 0 }
        $count = $now
    }
    $count
}

# read identity + check the profile; returns $null on a read error (see $script:lastErr)
# or @{ Id; Model; Supported; Compliant; Bad }
function Get-BatchUnitState([string]$reader, $ops) {
    Invoke-WithReader $reader {
        param($card, $o)
        $id = Read-Identity $card
        if (-not $id.Serial) { if ($id.Product) { $script:lastErr = "no-serial:$($id.Product)" }; return $null }
        $model = Resolve-ReaderModel $id
        $unsupported = @($o | Where-Object { @($model.profileKeys) -notcontains $_.name })
        if (-not $model.known -or $unsupported.Count -gt 0) {
            return @{ Id = $id; Model = $model; Supported = $false; Compliant = $false; Bad = @() }
        }
        $chk = Invoke-OpCheckAll $card $o
        @{ Id = $id; Model = $model; Supported = $true; Compliant = $chk.ok; Bad = $chk.bad }
    } $ops
}

# decide / apply for one unit; returns the batch entry @{ id; status; detail; verified }
function Invoke-BatchUnitApply([string]$reader, $ops, $state) {
    $id = $state.Id
    if (-not $state.Supported) { return @{ id = $id; status = "FAIL"; detail = ("unsupported model: {0}" -f $state.Model.product); verified = $true } }
    if ($state.Compliant) { return @{ id = $id; status = "PASS"; detail = (T already); verified = $true } }
    $res = Invoke-WithReader $reader { param($card, $o) Invoke-OpApplyAll $card $o } $ops
    if ($null -eq $res) { return @{ id = $id; status = "FAIL"; detail = "apply: connection lost ($script:lastErr)"; verified = $true } }
    if ($res.errors.Count -gt 0) { return @{ id = $id; status = "FAIL"; detail = ("apply: " + ($res.errors -join ",")); verified = $true } }
    @{ id = $id; status = "PENDING"; detail = ""; verified = $false }
}

# post-reboot verification matched by serial; updates $batch in place
function Invoke-BatchVerify([hashtable]$batch, $ops, [string]$readerMatch, [int]$rebootWait, [int]$verifyRetry, [int]$pollMs) {
    $pending = @($batch.Keys | Where-Object { -not $batch[$_].verified })
    if ($pending.Count -eq 0) { return }
    Write-Host (T pend $pending.Count $rebootWait)
    Start-Sleep -Seconds $rebootWait
    $trace = @{ scans = 0; maxR = 0; seen = @{}; errs = @{} }; $kick = $false
    for ($i = 0; $i -lt $verifyRetry -and $pending.Count -gt 0; $i++) {
        $trace.scans++
        $cur = Get-ReaderList $readerMatch
        $trace.maxR = [Math]::Max($trace.maxR, $cur.Count)
        foreach ($r in $cur) {
            $data = Invoke-WithReader $r {
                param($card, $o)
                $id = Read-Identity $card
                if (-not $id.Serial) { return $null }
                $chk = Invoke-OpCheckAll $card $o
                @{ Id = $id; Ok = $chk.ok; Bad = $chk.bad }
            } $ops
            if (-not $data) { if ($script:lastErr) { $trace.errs[$script:lastErr] = $true }; continue }
            $sn = $data.Id.Serial; $trace.seen[$sn] = $true
            if ($sn -in $pending) {
                if ($data.Ok) { $batch[$sn] = @{ id = $data.Id; status = "PASS"; detail = (T cfg); verified = $true } }
                else          { $batch[$sn] = @{ id = $data.Id; status = "FAIL"; detail = ("mismatch: " + ($data.Bad -join ",")); verified = $true } }
                $pending = @($pending | Where-Object { $_ -ne $sn })
            }
        }
        if (-not $kick -and $pending.Count -gt 0 -and $i -ge [int]($verifyRetry / 2)) { Reset-Context; $kick = $true }
        if ($pending.Count -gt 0) { Start-Sleep -Milliseconds $pollMs }
    }
    foreach ($sn in $pending) {
        $diag = ("scans:{0} maxReaders:{1} serialsSeen:[{2}] errors:[{3}] ctxResets:{4}" -f `
                 $trace.scans, $trace.maxR, (($trace.seen.Keys | Sort-Object) -join ","), (($trace.errs.Keys | Select-Object -First 5) -join " | "), $script:ctxResets)
        $batch[$sn] = @{ id = $batch[$sn].id; status = "FAIL"; detail = "verify failed: $diag"; verified = $true }
    }
}
