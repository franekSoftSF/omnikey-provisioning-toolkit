# Profile JSON -> list of data-only operations (lesson 1: hashtables, never scriptblocks).
# Every key is optional; keys starting with "_" are metadata and ignored.

$script:ProfileSections = [ordered]@{
    iso14443a   = @('enabled', 'mifarePreferred', 'mifareKeyCache', 'rx', 'tx')
    iso14443b   = @('enabled', 'rx', 'tx')
    iso15693    = @('enabled')
    felica      = @('enabled', 'rx', 'tx')
    iclass      = @('enabled')
    contactSlot = @('enabled', 'operatingMode', 'voltageSequence')
}
$script:ProfileScalars = @('emdSuppression', 'sleepModeCardDetection', 'sleepModePollingFrequency', 'pollingSearchOrder')
$script:BaudRates = @{ iso14443a = @(212, 424, 848); iso14443b = @(212, 424, 848); felica = @(212, 424) }

function Get-ProfileKeyNames($o) {
    if ($o -is [System.Collections.IDictionary]) { return ,@($o.Keys) }
    ,@($o.PSObject.Properties | ForEach-Object { $_.Name })
}

function Assert-ProfileShape($p) {
    $top = @($script:ProfileSections.Keys) + $script:ProfileScalars
    foreach ($k in (Get-ProfileKeyNames $p)) {
        if ($k.StartsWith('_')) { continue }
        if ($top -notcontains $k) { throw (T profUnknownKey $k ($top -join ' ')) }
        if (@($script:ProfileSections.Keys) -contains $k) {
            $allowed = $script:ProfileSections[$k]
            $section = $p.$k
            if ($null -eq $section -or $section -is [string] -or $section -is [ValueType] -or $section -is [array]) {
                throw (T profSection $k ($allowed -join ' '))
            }
            foreach ($s in (Get-ProfileKeyNames $section)) {
                if ($s.StartsWith('_')) { continue }
                if ($allowed -notcontains $s) { throw (T profUnknownKey "$k.$s" ($allowed -join ' ')) }
            }
        }
    }
}

function ConvertTo-OperationList($p, $model = $null) {
    $ops = New-Object System.Collections.ArrayList
    if ($null -eq $p) { return ,$ops }
    Assert-ProfileShape $p

    function AddBool($name, $tech, $sub, $want, $slot = 'contactless') {
        if ($want -isnot [bool]) { throw (T profBool $name $want) }
        [void]$ops.Add(@{name = $name; kind = "bool"; slot = $slot; tech = $tech; sub = $sub; want = [bool]$want; wantDisp = $want })
    }
    function AddBaud($name, $tech, $section, $rx, $tx) {
        $allowed = $script:BaudRates[$section]
        foreach ($v in (@($rx) + @($tx))) {
            if ($null -eq $v) { continue }
            $ok = ($v -is [ValueType]) -and ($v -isnot [bool]) -and ([double]$v -eq [math]::Floor([double]$v)) -and
                  (([int]$v -eq 106) -or ($allowed -contains [int]$v))
            if (-not $ok) { throw (T profBaud $name $v ($allowed -join ' ')) }
        }
        $wb = ConvertTo-BaudByte $rx $tx
        [void]$ops.Add(@{name = $name; kind = "baud"; slot = 'contactless'; tech = $tech; want = $wb; wantDisp = (Format-BaudDisplay (ConvertFrom-BaudByte $wb)) })
    }

    if ($p.iso14443a) { $a = $p.iso14443a
        if ($null -ne $a.enabled)         { AddBool "iso14443a.enabled"         "A2" "80" $a.enabled }
        if ($null -ne $a.mifarePreferred) { AddBool "iso14443a.mifarePreferred" "A2" "84" $a.mifarePreferred }
        if ($null -ne $a.mifareKeyCache)  { AddBool "iso14443a.mifareKeyCache"  "A2" "83" $a.mifareKeyCache }
        if ($a.rx -or $a.tx)              { AddBaud "iso14443a.baud" "A2" "iso14443a" $a.rx $a.tx } }
    if ($p.iso14443b) { $b = $p.iso14443b
        if ($null -ne $b.enabled) { AddBool "iso14443b.enabled" "A3" "80" $b.enabled }
        if ($b.rx -or $b.tx)      { AddBaud "iso14443b.baud" "A3" "iso14443b" $b.rx $b.tx } }
    if ($p.iso15693 -and $null -ne $p.iso15693.enabled) { AddBool "iso15693.enabled" "A4" "80" $p.iso15693.enabled }
    if ($p.felica) {
        if ($null -ne $p.felica.enabled)   { AddBool "felica.enabled" "A5" "80" $p.felica.enabled }
        if ($p.felica.rx -or $p.felica.tx) { AddBaud "felica.baud" "A5" "felica" $p.felica.rx $p.felica.tx } }
    if ($p.iclass -and $null -ne $p.iclass.enabled) { AddBool "iclass.enabled" "A6" "83" $p.iclass.enabled }
    if ($null -ne $p.emdSuppression)         { AddBool "emdSuppression"         "A0" "87" $p.emdSuppression }
    if ($null -ne $p.sleepModeCardDetection) { AddBool "sleepModeCardDetection" "A0" "8E" $p.sleepModeCardDetection }
    if ($p.sleepModePollingFrequency) {
        $idx = [Array]::IndexOf($script:FreqNames, [string]$p.sleepModePollingFrequency)
        if ($idx -lt 0) { throw (T profFreq $p.sleepModePollingFrequency ($script:FreqNames -join ' ')) }
        [void]$ops.Add(@{name = "sleepModePollingFrequency"; kind = "freq"; slot = 'contactless'; idx = [byte]$idx; wantDisp = $script:FreqNames[$idx] }) }
    if ($p.pollingSearchOrder) {
        $names = @($p.pollingSearchOrder | ForEach-Object { ([string]$_).ToLower() })
        if ($names.Count -gt 5) { throw (T profPollMax $names.Count) }
        $codes = New-Object byte[] 5
        for ($i = 0; $i -lt 5; $i++) {
            if ($i -lt $names.Count) {
                if (-not $script:PollCodes.ContainsKey($names[$i])) { throw (T profPoll $names[$i] (($script:PollCodes.Keys | Sort-Object) -join ' ')) }
                $codes[$i] = [byte]$script:PollCodes[$names[$i]]
            } else { $codes[$i] = 0 }
        }
        [void]$ops.Add(@{name = "pollingSearchOrder"; kind = "poll"; slot = 'contactless'; codes = $codes
                         wantHex = (($codes | ForEach-Object { $_.ToString("X2") }) -join '')
                         wantDisp = (($names | Where-Object { $_ -ne "none" }) -join ",") }) }
    if ($p.contactSlot) { $c = $p.contactSlot
        if ($null -ne $c.enabled) { AddBool "contactSlot.enabled" "A0" "85" $c.enabled 'contact' }
        if ($null -ne $c.operatingMode) {
            $mode = ([string]$c.operatingMode).ToLower()
            if (-not $script:OperatingModeCodes.ContainsKey($mode)) {
                throw (T profChoice "contactSlot.operatingMode" $c.operatingMode (($script:OperatingModeCodes.Keys | Sort-Object) -join ' '))
            }
            [void]$ops.Add(@{name = "contactSlot.operatingMode"; kind = "mode"; slot = 'contact'; sub = "83"
                             want = [byte]$script:OperatingModeCodes[$mode]; wantDisp = $mode })
        }
        if ($null -ne $c.voltageSequence) {
            $v = $c.voltageSequence
            $valid = ($script:VoltageCodes.Keys | Sort-Object) -join ' '
            if ($v -is [string] -and $v.ToLower() -eq 'auto') { $vb = [byte]0 }
            else {
                $names = @($v | ForEach-Object {
                    $item = $_
                    $canon = @($script:VoltageCodes.Keys | Where-Object { $_ -eq [string]$item })
                    if ($item -isnot [string] -or $canon.Count -ne 1) { throw (T profVoltage (@($v) -join ',') $valid) }
                    $canon[0]
                })
                if ($names.Count -lt 1 -or $names.Count -gt 3 -or @($names | Select-Object -Unique).Count -ne $names.Count) {
                    throw (T profVoltage (@($v) -join ',') $valid)
                }
                $vb = ConvertTo-VoltageByte $names
            }
            [void]$ops.Add(@{name = "contactSlot.voltageSequence"; kind = "volt"; slot = 'contact'; sub = "82"
                             want = $vb; wantDisp = (Format-VoltageDisplay $vb) })
        }
    }

    if ($model) {
        foreach ($op in $ops) {
            if (@($model.profileKeys) -notcontains $op.name) { throw (T modelUnsupported $op.name $model.product) }
            if ($op.kind -eq "volt" -and $op.want -eq 0 -and -not $model.voltageAuto) { throw (T modelNoVoltageAuto $model.product) }
        }
    }
    ,$ops
}
