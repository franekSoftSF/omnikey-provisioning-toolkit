# TestCard: PC/SC SHARED connection, ATR/UID and card classification.

# PC/SC part 3 storage card names (bytes after RID A0 00 00 03 06 + standard byte)
$script:StorageNames = @{
  "0001"=@("MIFARE Classic 1K",$true);   "0002"=@("MIFARE Classic 4K",$true)
  "0026"=@("MIFARE Mini",$true)
  "0036"=@("MIFARE Plus SL1 2K (Classic mode)",$true); "0037"=@("MIFARE Plus SL1 4K (Classic mode)",$true)
  "0038"=@("MIFARE Plus SL2 2K",$false); "0039"=@("MIFARE Plus SL2 4K",$false)
  "0003"=@("MIFARE Ultralight",$false);  "003A"=@("MIFARE Ultralight C",$false)
  "0030"=@("Topaz/Jewel",$false);        "000C"=@("FeliCa",$false)
}

# classify a contactless PC/SC ATR: storage cards carry RID A0 00 00 03 06 + standard byte + 2-byte name code
function Get-CardType([string]$atrHex) {
    if ($atrHex -match "A000000306..(....)") {
        $code = $Matches[1]
        if ($script:StorageNames.ContainsKey($code)) {
            $name, $classic = $script:StorageNames[$code]
            return @{kind="storage";code=$code;name=$name;classic=[bool]$classic}
        }
        return @{kind="storage";code=$code;name=$null;classic=$false}
    }
    @{kind="cpu";code=$null;name=$null;classic=$false}
}

function Format-ProtocolName([uint32]$proto) {
    switch ($proto) { $script:PROTO_T0 { "T=0" } $script:PROTO_T1 { "T=1" } default { "0x{0:X}" -f $proto } }
}

function Wait-CardRemoved([string]$reader) {
    Write-Host (T cardRemove) -ForegroundColor DarkGray
    while ($true) {
        $c = Invoke-NativeConnect $script:ctx $reader $script:SHARE_SHARED $script:PROTO_T0T1
        if ($c.rc -ne 0) { break }                    # connect fails -> card removed
        Disconnect-Card $c.card
        Start-Sleep -Milliseconds 400
    }
}

# returns 0 (Classic / contact card answered), 1 (timeout), 2 (not presented as Classic)
function Invoke-CardTest([string]$reader, [int]$timeout, [bool]$prefEnabled, [bool]$contactless = $true) {
    if ($contactless) { Write-Host ((T prefState $(if ($prefEnabled) { "ENABLED" } else { "DISABLED" }))) }
    Write-Host (T cardWait $timeout)
    $c = $null
    $deadline = (Get-Date).AddSeconds($timeout)
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-NativeConnect $script:ctx $reader $script:SHARE_SHARED $script:PROTO_T0T1
        if ($r.rc -eq 0) { $c = $r; break }
        Start-Sleep -Milliseconds 400
    }
    if ($null -eq $c) { Write-Host (T cardTimeout) -ForegroundColor Red; return 1 }
    try {
        $atrHex = Get-CardAtr $c.card
        Write-Host ("{0}: {1}" -f (T cardAtr), $atrHex)
        if (-not $contactless) {
            Write-Host (T cardIs (T cardContact (Format-ProtocolName $c.proto))) -ForegroundColor Cyan
            Write-Host ""
            Write-Host (T verdictContact) -ForegroundColor Green
            return 0
        }
        try { $u = Send-Apdu $c.card $c.proto "FFCA000000"
              if ($u -match '^(.+)9000$') { Write-Host ("{0}: {1}" -f (T cardUid), $Matches[1]) } } catch { }

        $ct = Get-CardType $atrHex
        $isClassic = $ct.classic
        if ($ct.kind -eq "storage") {
            if ($ct.name) { Write-Host (T cardIs $ct.name) -ForegroundColor Cyan }
            else          { Write-Host (T cardRaw $ct.code) -ForegroundColor Yellow }
        } else {
            Write-Host (T cardIs (T cardCpu)) -ForegroundColor Cyan
        }
        Write-Host ""
        if ($isClassic) { Write-Host (T verdictYes) -ForegroundColor Green; return 0 }
        Write-Host (T verdictNo) -ForegroundColor Red
        if ($prefEnabled) { Write-Host (T hintPrefOn) -ForegroundColor Yellow } else { Write-Host (T hintPrefOff) -ForegroundColor Yellow }
        return 2
    }
    finally { Disconnect-Card $c.card }
}
