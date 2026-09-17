# Data-only op engine (lesson 1) and multi-value results as hashtables (lesson 2).

function Get-BoolParam([IntPtr]$card, [string]$tech, [string]$sub, [string]$slot = 'contactless') {
    $apdu = if ($slot -eq 'contact') { Format-ContactGetApdu $sub } else { Format-GetApdu $tech $sub }
    ConvertFrom-BoolResponse (Send-Escape $card $apdu) $sub
}
function Set-BoolParam([IntPtr]$card, [string]$tech, [string]$sub, [bool]$v, [string]$slot = 'contactless') {
    $val = if ($v) { "01" } else { "00" }
    $apdu = if ($slot -eq 'contact') { Format-ContactSetApdu $sub $val } else { Format-SetApdu $tech $sub $val }
    $r = Send-Escape $card $apdu
    if ($r -notmatch '9000$') { throw $r }
}
function Get-BaudParam([IntPtr]$card, [string]$tech) {
    $b = ConvertFrom-ByteResponse (Send-Escape $card (Format-GetApdu $tech "81")) "81"
    if ($null -ne $b) { ConvertFrom-BaudByte $b }
}
function Set-BaudParam([IntPtr]$card, [string]$tech, [byte]$v) {
    $r = Send-Escape $card (Format-SetApdu $tech "81" ($v.ToString("X2")))
    if ($r -notmatch '9000$') { throw $r }
}
function Get-ContactByte([IntPtr]$card, [string]$sub) { ConvertFrom-ByteResponse (Send-Escape $card (Format-ContactGetApdu $sub)) $sub }
function Get-FreqName([IntPtr]$card, [string]$missing) {
    $f = ConvertFrom-ByteResponse (Send-Escape $card (Format-GetApdu "A0" "8D")) "8D"
    if ($null -ne $f -and $f -lt $script:FreqNames.Count) { return $script:FreqNames[$f] }
    $missing -f $f
}
function Get-PollingOrder([IntPtr]$card) {
    $pr = Send-Escape $card $script:APDU_POLL_GET
    if ($pr -match '^BD078905([0-9A-F]{10})9000$') {
        $hex = $Matches[1]
        $codes = 0..4 | ForEach-Object { [Convert]::ToByte($hex.Substring($_ * 2, 2), 16) }
        $names = @($codes | Where-Object { $_ -ne 0 } | ForEach-Object { $script:PollNames[[int]$_] })
        return @{ hex = $hex; names = $names }
    }
    $null
}

function Invoke-OpApply([IntPtr]$card, $op) {
    switch ($op.kind) {
        "bool" { Set-BoolParam $card $op.tech $op.sub $op.want $op.slot }
        "baud" { Set-BaudParam $card $op.tech $op.want }
        "freq" { $r = Send-Escape $card (Format-SetApdu "A0" "8D" ($op.idx.ToString("X2"))); if ($r -notmatch '9000$') { throw $r } }
        "poll" { $r = Send-Escape $card (Format-PollSetApdu $op.codes); if ($r -notmatch '9000$') { throw $r } }
        { $_ -in "mode", "volt" } {
            $r = Send-Escape $card (Format-ContactSetApdu $op.sub ($op.want.ToString("X2"))); if ($r -notmatch '9000$') { throw $r } }
    }
}
function Invoke-OpCheck([IntPtr]$card, $op) {
    switch ($op.kind) {
        "bool" { $h = Get-BoolParam $card $op.tech $op.sub $op.slot; return @{ ok = ($h -eq $op.want); have = $h } }
        "baud" { $h = Get-BaudParam $card $op.tech; $hd = Format-BaudDisplay $h; return @{ ok = ($hd -eq $op.wantDisp); have = $hd } }
        "freq" { $hn = Get-FreqName $card "?"; return @{ ok = ($hn -eq $op.wantDisp); have = $hn } }
        "poll" { $po = Get-PollingOrder $card
                 if ($po) { return @{ ok = ($po.hex -eq $op.wantHex); have = ($po.names -join ",") } }
                 return @{ ok = $false; have = "?" } }
        "mode" { $h = Get-ContactByte $card $op.sub
                 $hn = if ($null -ne $h -and $script:OperatingModeNames.ContainsKey([int]$h)) { $script:OperatingModeNames[[int]$h] } else { "?" }
                 return @{ ok = ($null -ne $h -and $h -eq $op.want); have = $hn } }
        "volt" { $h = Get-ContactByte $card $op.sub
                 return @{ ok = ($null -ne $h -and $h -eq $op.want); have = (Format-VoltageDisplay $h) } }
    }
}

# check all ops; returns @{ok; bad=@(names); diff=@(@{name; want; have})}
function Invoke-OpCheckAll([IntPtr]$card, $ops) {
    $bad = @(); $diff = @()
    foreach ($op in $ops) {
        try {
            $r = Invoke-OpCheck $card $op
            if (-not $r.ok) { $bad += $op.name; $diff += @{ name = $op.name; want = $op.wantDisp; have = $r.have } }
        }
        catch { $bad += $op.name; $diff += @{ name = $op.name; want = $op.wantDisp; have = $null } }
    }
    @{ ok = ($bad.Count -eq 0); bad = $bad; diff = $diff }
}

# returns a hashtable (never an array!) - empty arrays unroll to $null across function
# boundaries, making success indistinguishable from a connection failure (lesson 2)
function Invoke-OpApplyAll([IntPtr]$card, $ops) {
    $bad = @()
    foreach ($op in $ops) {
        try { Invoke-OpApply $card $op }
        catch { $bad += ("{0}({1})" -f $op.name, (Format-TransportError $_.Exception.Message)) }
    }
    if ($bad.Count -eq 0) { [void](Send-Escape $card $script:APDU_APPLY); try { [void](Send-Escape $card $script:APDU_REBOOT) } catch { } }
    @{ errors = $bad }
}

# ---------- Get / Export ----------
function Get-ReaderConfiguration([IntPtr]$card, $model) {
    $o = [ordered]@{}
    if ($model.contactless) {
        $o["iso14443a.enabled"]         = Get-BoolParam $card "A2" "80"
        $o["iso14443a.mifarePreferred"] = Get-BoolParam $card "A2" "84"
        $o["iso14443a.mifareKeyCache"]  = Get-BoolParam $card "A2" "83"
        $o["iso14443a.baud"]            = Format-BaudDisplay (Get-BaudParam $card "A2")
        $o["iso14443b.enabled"]         = Get-BoolParam $card "A3" "80"
        $o["iso14443b.baud"]            = Format-BaudDisplay (Get-BaudParam $card "A3")
        $o["iso15693.enabled"]          = Get-BoolParam $card "A4" "80"
        $o["felica.enabled"]            = Get-BoolParam $card "A5" "80"
        $o["felica.baud"]               = Format-BaudDisplay (Get-BaudParam $card "A5")
        $o["iclass.enabled"]            = Get-BoolParam $card "A6" "83"
        $o["emdSuppression"]            = Get-BoolParam $card "A0" "87"
        $o["sleepModeCardDetection"]    = Get-BoolParam $card "A0" "8E"
        $o["sleepModePollingFrequency"] = Get-FreqName $card "?({0})"
        $po = Get-PollingOrder $card
        $o["pollingSearchOrder"]        = if ($po) { $po.names -join "," } else { "?" }
    }
    if ($model.contact) {
        $o["contactSlot.enabled"]         = Get-BoolParam $card "A0" "85" 'contact'
        $m = Get-ContactByte $card "83"
        $o["contactSlot.operatingMode"]   = if ($null -ne $m -and $script:OperatingModeNames.ContainsKey([int]$m)) { $script:OperatingModeNames[[int]$m] } else { "?($m)" }
        $o["contactSlot.voltageSequence"] = Format-VoltageDisplay (Get-ContactByte $card "82")
    }
    $o
}

function Get-BaudLists([IntPtr]$card, [string]$tech) {
    $full = Get-BaudParam $card $tech
    if ($null -eq $full) { return $null }
    @{ rx = @($full.rx | Where-Object { $_ -ne 106 }); tx = @($full.tx | Where-Object { $_ -ne 106 }) }
}

# Get/Export console line: key in the default colour, value green (yellow when it could not be read)
function Write-ConfigLine([string]$key, $value) {
    Write-Host ("  {0,-28} " -f $key) -NoNewline
    $unread = ($null -eq $value) -or ("$value" -eq "") -or ("$value" -match '^\?')
    Write-Host $value -ForegroundColor $(if ($unread) { "Yellow" } else { "Green" })
}

# reader configuration as a profile (same JSON schema Set/Verify/Batch consume)
function Export-ReaderProfile([IntPtr]$card, [string]$path, $model) {
    Get-ReaderProfile $card $model | ConvertTo-Json -Depth 4 | Out-File $path -Encoding utf8
}

# reader configuration as an ordered profile hashtable (values $null when unreadable)
function Get-ReaderProfile([IntPtr]$card, $model) {
    $prof = [ordered]@{}
    if ($model.contactless) {
        $a = Get-BaudLists $card "A2"; $bb = Get-BaudLists $card "A3"; $fb = Get-BaudLists $card "A5"
        $prof["iso14443a"] = [ordered]@{
            enabled         = Get-BoolParam $card "A2" "80"
            mifarePreferred = Get-BoolParam $card "A2" "84"
            mifareKeyCache  = Get-BoolParam $card "A2" "83"
            rx = $a.rx; tx = $a.tx
        }
        $prof["iso14443b"] = [ordered]@{ enabled = Get-BoolParam $card "A3" "80"; rx = $bb.rx; tx = $bb.tx }
        $prof["iso15693"]  = [ordered]@{ enabled = Get-BoolParam $card "A4" "80" }
        $prof["felica"]    = [ordered]@{ enabled = Get-BoolParam $card "A5" "80"; rx = $fb.rx; tx = $fb.tx }
        $prof["iclass"]    = [ordered]@{ enabled = Get-BoolParam $card "A6" "83" }
        $prof["emdSuppression"]         = Get-BoolParam $card "A0" "87"
        $prof["sleepModeCardDetection"] = Get-BoolParam $card "A0" "8E"
        $f = ConvertFrom-ByteResponse (Send-Escape $card (Format-GetApdu "A0" "8D")) "8D"
        if ($null -ne $f -and $f -lt $script:FreqNames.Count) { $prof["sleepModePollingFrequency"] = $script:FreqNames[$f] }
        $po = Get-PollingOrder $card
        if ($po) { $prof["pollingSearchOrder"] = @($po.names) }
    }
    if ($model.contact) {
        $section = [ordered]@{ enabled = Get-BoolParam $card "A0" "85" 'contact' }
        $m = Get-ContactByte $card "83"
        if ($null -ne $m -and $script:OperatingModeNames.ContainsKey([int]$m)) { $section["operatingMode"] = $script:OperatingModeNames[[int]$m] }
        $v = Get-ContactByte $card "82"
        if ($null -ne $v) { $section["voltageSequence"] = $(if ($v -eq 0) { "auto" } else { @((Format-VoltageDisplay $v) -split ',') }) }
        $prof["contactSlot"] = $section
    }
    $prof
}
