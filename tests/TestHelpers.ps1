[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'dot-sourced into test files')]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'pure test-data builders')]
param()

# Shared test paths, APDU oracle and reader simulators. Unit tests dot-source the module's
# component files (same list and order as OmnikeyToolkit.psm1) so private functions and plain
# Pester mocks work; Module.Tests.ps1 covers the real Import-Module wiring.

$RepoRoot         = Split-Path -Parent $PSScriptRoot
$ModuleRoot       = Join-Path $RepoRoot 'OmnikeyToolkit'
$ModuleManifest   = Join-Path $ModuleRoot 'OmnikeyToolkit.psd1'
$CheckProfilePath = Join-Path $RepoRoot 'CheckProfile5022.ps1'
$BatchPath        = Join-Path $RepoRoot 'Batch-Omnikey5022-Provision.ps1'
$OmnikeyPath      = Join-Path $RepoRoot 'Omnikey.ps1'
$ExampleProfile   = Join-Path $RepoRoot 'profiles/example-profile.json'
$FixturesRoot     = Join-Path $PSScriptRoot 'fixtures'

$psm1Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $ModuleRoot 'OmnikeyToolkit.psm1'), [ref]$null, [ref]$null)
$ComponentFiles = @($psm1Ast.Find({
    param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$ComponentFiles'
}, $true).Right.Expression.SafeGetValue() | ForEach-Object { Join-Path $ModuleRoot $_ })

# APDUs straight from CLAUDE.md / HID samples (independent oracle, not from the module)
$ApduGetPrefix  = 'FF70076B0AA208A006A404'
$ApduSetPrefix  = 'FF70076B0BA209A107A405'
$ApduPollSet    = 'FF70076B0FA20DA10BA409A0078905'
$ApduPollGet    = 'FF70076B0AA208A006A404A002890000'
$ApduApply      = 'FF70076B08A206A104A902800000'
$ApduReboot     = 'FF70076B08A206A104A902830000'
$ApduSerial     = 'FF70076B08A206A004A002920000'
$ApduProduct    = 'FF70076B08A206A004A002820000'
$ApduFirmware   = 'FF70076B08A206A004A002850000'
$ApduContactSlots     = 'FF70076B08A206A004A0028B0000'
$ApduContactlessSlots = 'FF70076B08A206A004A0028C0000'
$ApduContactGetPrefix = 'FF70076B0AA208A006A304A002'      # + sub + 0000
$ApduContactSetPrefix = 'FF70076B0BA209A107A305A003'      # + sub + 01 + val + 00

# profiles/example-profile.json -> SET APDUs, in operation order (hand-built from CLAUDE.md)
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

# GET responses of the hardware used for this project (serial replaced by a synthetic one)
function New-Reader5022Sim {
    @{
        $ApduSerial = (New-AsciiResponse '92' 'EXAMPLE0001')
        $ApduProduct = 'BD0F820D4F4D4E494B45592035303232009000'      # "OMNIKEY 5022\0"
        $ApduFirmware = 'BD0585030200009000'                          # 2.0.0
        $ApduContactSlots = 'BD038B01009000'; $ApduContactlessSlots = 'BD038C01019000'
        "${ApduGetPrefix}A202800000" = 'BD038001019000'
        "${ApduGetPrefix}A202840000" = 'BD038401019000'
        "${ApduGetPrefix}A202830000" = 'BD038301009000'
        "${ApduGetPrefix}A202810000" = 'BD038101339000'
        "${ApduGetPrefix}A302800000" = 'BD038001019000'
        "${ApduGetPrefix}A302810000" = 'BD038101339000'
        "${ApduGetPrefix}A402800000" = 'BD038001019000'
        "${ApduGetPrefix}A502800000" = 'BD038001019000'
        "${ApduGetPrefix}A502810000" = 'BD038101119000'
        "${ApduGetPrefix}A602830000" = 'BD038301019000'
        "${ApduGetPrefix}A002870000" = 'BD038701019000'
        "${ApduGetPrefix}A0028E0000" = 'BD038E01019000'
        "${ApduGetPrefix}A0028D0000" = 'BD038D01069000'
        $ApduPollGet = 'BD07890502030406019000'
    }
}
function New-Reader3121Sim {
    @{
        $ApduSerial = 'BD0292009000'                                  # empty serial (as the real 3121)
        $ApduProduct = 'BD0F820D4F4D4E494B45592033313231009000'      # "OMNIKEY 3121\0"
        $ApduFirmware = 'BD0585030106009000'                          # 1.6.0
        $ApduContactSlots = 'BD038B01019000'; $ApduContactlessSlots = 'BD038C01009000'
        "${ApduContactGetPrefix}850000" = 'BD038501019000'            # slot enabled
        "${ApduContactGetPrefix}830000" = 'BD038301009000'            # ISO 7816
        "${ApduContactGetPrefix}820000" = 'BD0382011B9000'            # 5V,3V,1.8V
        "${ApduGetPrefix}A202800000" = '9E0202049000'            # contactless GET: TLV error
    }
}
function Test-IsWriteApdu([string]$apdu) {
    $apdu.StartsWith($ApduSetPrefix) -or $apdu.StartsWith($ApduPollSet) -or $apdu.StartsWith($ApduContactSetPrefix) -or
        $apdu -eq $ApduApply -or $apdu -eq $ApduReboot
}

# console text written with Write-Host (information stream), honouring -NoNewline
function Get-HostText([object[]]$records) {
    $sb = [System.Text.StringBuilder]::new()
    foreach ($r in $records) {
        if ($r -isnot [System.Management.Automation.InformationRecord]) { continue }
        $m = $r.MessageData
        if ($m -is [System.Management.Automation.HostInformationMessage]) {
            [void]$sb.Append($m.Message); if (-not $m.NoNewLine) { [void]$sb.Append("`n") }
        } else { [void]$sb.Append([string]$m).Append("`n") }
    }
    ($sb.ToString() -replace "`r", '').TrimEnd()
}
function Get-FixtureText([string]$name) { ((Get-Content (Join-Path $FixturesRoot $name) -Raw) -replace "`r", '').TrimEnd() }

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
