[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'dot-sourced into test files')]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'pure test-data builders')]
param()

# Shared test paths and helpers. Tests dot-source the scripts themselves (the
# scripts return right after their function definitions when dot-sourced);
# after the module refactor (backlog 3) this is the single place to switch to
# Import-Module.

$RepoRoot         = Split-Path -Parent $PSScriptRoot
$CheckProfilePath = Join-Path $RepoRoot 'CheckProfile5022.ps1'
$BatchPath        = Join-Path $RepoRoot 'Batch-Omnikey5022-Provision.ps1'
$ExampleProfile   = Join-Path $RepoRoot 'profiles/example-profile.json'

# APDU prefixes straight from CLAUDE.md (independent oracle, not from the scripts)
$ApduGetPrefix  = 'FF70076B0AA208A006A404'
$ApduSetPrefix  = 'FF70076B0BA209A107A405'
$ApduPollSet    = 'FF70076B0FA20DA10BA409A0078905'
$ApduPollGet    = 'FF70076B0AA208A006A404A002890000'
$ApduApply      = 'FF70076B08A206A104A902800000'
$ApduReboot     = 'FF70076B08A206A104A902830000'
$ApduSerial     = 'FF70076B08A206A004A002920000'
$ApduProduct    = 'FF70076B08A206A004A002820000'
$ApduFirmware   = 'FF70076B08A206A004A002850000'

# profiles/example-profile.json -> SET APDUs, in Build-Ops order (hand-built from CLAUDE.md)
$ExampleProfileOpNames = @(
    'iso14443a.enabled', 'iso14443a.mifarePreferred', 'iso14443a.mifareKeyCache', 'iso14443a.baud',
    'iso14443b.enabled', 'iso14443b.baud', 'iso15693.enabled', 'felica.enabled', 'felica.baud',
    'iclass.enabled', 'emdSuppression', 'sleepModeCardDetection', 'sleepModePollingFrequency',
    'pollingSearchOrder'
)
$ExampleProfileSetApdus = @(
    "${ApduSetPrefix}A20380010100"    # 14443A enable = 1
    "${ApduSetPrefix}A20384010100"    # mifarePreferred = 1
    "${ApduSetPrefix}A20383010000"    # mifareKeyCache = 0
    "${ApduSetPrefix}A20381013300"    # 14443A baud rx 212/424, tx 212/424 = 0x33
    "${ApduSetPrefix}A30380010100"    # 14443B enable = 1
    "${ApduSetPrefix}A30381013300"    # 14443B baud = 0x33
    "${ApduSetPrefix}A40380010100"    # 15693 enable = 1
    "${ApduSetPrefix}A50380010100"    # FeliCa enable = 1
    "${ApduSetPrefix}A50381011100"    # FeliCa baud rx 212, tx 212 = 0x11
    "${ApduSetPrefix}A60383010100"    # iCLASS enable (sub 83!) = 1
    "${ApduSetPrefix}A00387010100"    # EMD suppression = 1
    "${ApduSetPrefix}A0038E010100"    # sleep card detection = 1
    "${ApduSetPrefix}A0038D010600"    # sleep polling 0.7Hz = index 6
    "${ApduPollSet}020304060100"      # 14443A,14443B,iCLASS,FeliCa,15693
)

function ConvertTo-TestProfile([string]$json) { $json | ConvertFrom-Json }

# single-value GET response: BD 03 <sub> 01 <val> 90 00
function New-GetResponse([string]$sub, [string]$val) { "BD03{0}01{1}9000" -f $sub, $val }

# identity TLV response: BD <len> <tag> <asciiLen> <ascii...> 90 00
function New-AsciiResponse([string]$tag, [string]$text) {
    $hex = -join ($text.ToCharArray() | ForEach-Object { ([byte][char]$_).ToString('X2') })
    "BD{0:X2}{1}{2:X2}{3}9000" -f ($text.Length + 2), $tag, $text.Length, $hex
}

# PC/SC part 3 storage-card pseudo-ATR with the given 2-byte name code
function New-StorageAtr([string]$code) { "3B8F8001804F0CA00000030603{0}000000006A" -f $code }

# true if any value in the op (recursively) is a ScriptBlock - lesson 1
function Test-ContainsScriptBlock($value) {
    if ($value -is [scriptblock]) { return $true }
    if ($value -is [System.Collections.IDictionary]) {
        foreach ($v in $value.Values) { if (Test-ContainsScriptBlock $v) { return $true } }
        return $false
    }
    if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
        foreach ($v in $value) { if (Test-ContainsScriptBlock $v) { return $true } }
    }
    $false
}
