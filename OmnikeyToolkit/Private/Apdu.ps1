# HID AViatoR TLV escape APDUs - source: github.com/hidglobal/HID-OMNIKEY-Sample-Codes
# (ReaderCapabilities.cs, ContactlessSlotConfiguration.cs, ContactSlotConfiguration.cs,
#  ReaderConfigurationControl.cs). See CLAUDE.md "Rdzen techniczny".

# contactless slot (A4/A5 container); tech tags: A2=14443A A3=14443B A4=15693 A5=FeliCa A6=iCLASS A0=common
function Format-GetApdu([string]$tech, [string]$sub) { "FF70076B0AA208A006A404" + $tech + "02" + $sub + "0000" }
function Format-SetApdu([string]$tech, [string]$sub, [string]$val) { "FF70076B0BA209A107A405" + $tech + "03" + $sub + "01" + $val + "00" }
function Format-PollSetApdu([byte[]]$order5) { "FF70076B0FA20DA10BA409A0078905" + (($order5 | ForEach-Object { $_.ToString("X2") }) -join '') + "00" }
# contact slot (A3 container); sub: 82 voltage sequence, 83 operating mode, 85 slot enable
function Format-ContactGetApdu([string]$sub) { "FF70076B0AA208A006A304A002" + $sub + "0000" }
function Format-ContactSetApdu([string]$sub, [string]$val) { "FF70076B0BA209A107A305A003" + $sub + "01" + $val + "00" }

$script:APDU_APPLY    = "FF70076B08A206A104A902800000"
$script:APDU_REBOOT   = "FF70076B08A206A104A902830000"
$script:APDU_FACTORY_DEFAULTS = "FF70076B08A206A104A902810000"   # ReaderConfigurationControl.RestoreFactoryDefaults
$script:APDU_POLL_GET = "FF70076B0AA208A006A404A002890000"
# reader capabilities (A0)
$script:APDU_PRODUCT       = "FF70076B08A206A004A002820000"
$script:APDU_FW            = "FF70076B08A206A004A002850000"
$script:APDU_CONTACT_SLOTS = "FF70076B08A206A004A0028B0000"
$script:APDU_CL_SLOTS      = "FF70076B08A206A004A0028C0000"
$script:APDU_SERIAL        = "FF70076B08A206A004A002920000"

# ---------- response parsers ----------
function ConvertFrom-BoolResponse([string]$resp, [string]$sub) {
    if ($resp -match ('^BD03' + $sub + '01(00|01)9000$')) { return ($Matches[1] -eq "01") }
    return $null
}
function ConvertFrom-ByteResponse([string]$resp, [string]$sub) {
    if ($resp -match ('^BD03' + $sub + '01([0-9A-F]{2})9000$')) { return [Convert]::ToByte($Matches[1], 16) }
    return $null
}
# identity TLV: BD <len> <tag> <asciiLen> <ascii...> 90 00; empty value => $null
function ConvertFrom-AsciiResponse([string]$resp) {
    if ($resp -notmatch '^BD' -or $resp -notmatch '9000$') { return $null }
    $b = ConvertFrom-HexString $resp
    if ($b.Length -lt 5) { return $null }
    $len = [int]$b[3]
    if ($len -eq 0 -or $b.Length -lt (4 + $len)) { return $null }
    $text = ((-join ($b[4..(3 + $len)] | ForEach-Object { [char]$_ })) -replace "`0", "").Trim()
    if ($text) { $text } else { $null }
}
function ConvertFrom-FirmwareResponse([string]$resp) {
    if ($resp -match '^BD058503([0-9A-F]{2})([0-9A-F]{2})([0-9A-F]{2})9000$') {
        return "{0}.{1}.{2}" -f [Convert]::ToByte($Matches[1], 16), [Convert]::ToByte($Matches[2], 16), [Convert]::ToByte($Matches[3], 16)
    }
    "?"
}

# ---------- baud rates: bit 212=1 424=2 848=4; byte = rxNibble<<4 | txNibble; 106 always on ----------
function ConvertTo-BaudByte($rxList, $txList) {
    $map = @{212 = 1; 424 = 2; 848 = 4 }; $rx = 0; $tx = 0
    foreach ($v in @($rxList)) { if ($map.ContainsKey([int]$v)) { $rx = $rx -bor $map[[int]$v] } }
    foreach ($v in @($txList)) { if ($map.ContainsKey([int]$v)) { $tx = $tx -bor $map[[int]$v] } }
    [byte](($rx -shl 4) -bor $tx)
}
function ConvertFrom-BaudByte([byte]$b) {
    $rx = @(106); $tx = @(106)
    if ($b -band 0x10) { $rx += 212 }; if ($b -band 0x20) { $rx += 424 }; if ($b -band 0x40) { $rx += 848 }
    if ($b -band 0x01) { $tx += 212 }; if ($b -band 0x02) { $tx += 424 }; if ($b -band 0x04) { $tx += 848 }
    @{ rx = $rx; tx = $tx }
}
function Format-BaudDisplay($b) { "rx:" + (($b.rx -join "/")) + " tx:" + (($b.tx -join "/")) }

$script:FreqNames = @("41Hz", "20Hz", "10Hz", "5Hz", "2.5Hz", "1.3Hz", "0.7Hz", "0.3Hz", "0.15Hz", "0.08Hz")
$script:PollNames = @{0 = "none"; 1 = "iso15693"; 2 = "iso14443a"; 3 = "iso14443b"; 4 = "iclass"; 6 = "felica" }
$script:PollCodes = @{"none" = 0; "iso15693" = 1; "iso14443a" = 2; "iso14443b" = 3; "iclass" = 4; "felica" = 6 }

# ---------- contact slot values (OperatingModeFlags.cs, VoltageSequenceFlags.cs) ----------
$script:OperatingModeNames = @{0 = "iso7816"; 1 = "emvco" }
$script:OperatingModeCodes = @{"iso7816" = 0; "emvco" = 1 }
$script:VoltageNames = @{3 = "5V"; 2 = "3V"; 1 = "1.8V" }
$script:VoltageCodes = @{"5V" = 3; "3V" = 2; "1.8V" = 1 }

# voltage sequence byte = first + second<<2 + third<<4 (0 = "auto": the driver decides)
function ConvertTo-VoltageByte([string[]]$names) {
    $b = 0
    for ($i = 0; $i -lt $names.Count; $i++) { $b = $b -bor ($script:VoltageCodes[$names[$i]] -shl (2 * $i)) }
    [byte]$b
}
function Format-VoltageDisplay($b) {
    if ($null -eq $b) { return "?" }
    if ($b -eq 0) { return "auto" }
    $names = foreach ($i in 0..2) {
        $code = ([int]$b -shr (2 * $i)) -band 3
        if ($code) { $script:VoltageNames[$code] }
    }
    @($names) -join ","
}
