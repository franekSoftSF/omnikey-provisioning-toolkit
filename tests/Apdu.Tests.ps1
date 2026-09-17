#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# APDU builders, response parsers, baud / voltage encodings and ATR card classification.
# Pester scoping: variables set in BeforeAll/BeforeEach/BeforeDiscovery are used in other blocks
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    foreach ($f in $ComponentFiles) { . $f }
}

Describe 'APDU builders (literal strings from the HID samples)' {
    It 'contactless GET / SET' {
        Format-GetApdu 'A2' '84' | Should -Be 'FF70076B0AA208A006A404A202840000'
        Format-SetApdu 'A6' '83' '01' | Should -Be 'FF70076B0BA209A107A405A6038301 0100'.Replace(' ', '')
        Format-PollSetApdu ([byte[]](2, 3, 4, 6, 1)) | Should -Be 'FF70076B0FA20DA10BA409A0078905020304060100'
    }

    It 'contact slot GET / SET match ContactSlotConfiguration.cs' {
        Format-ContactGetApdu '82' | Should -Be 'FF70076B0AA208A006A304A002820000'
        Format-ContactGetApdu '83' | Should -Be 'FF70076B0AA208A006A304A002830000'
        Format-ContactGetApdu '85' | Should -Be 'FF70076B0AA208A006A304A002850000'
        Format-ContactSetApdu '82' '00' | Should -Be 'FF70076B0BA209A107A305A00382010000'   # SetAutomaticSequenceApdu()
        Format-ContactSetApdu '83' '01' | Should -Be 'FF70076B0BA209A107A305A00383010100'
        Format-ContactSetApdu '85' '01' | Should -Be 'FF70076B0BA209A107A305A00385010100'
    }

    It 'capability APDUs match ReaderCapabilities.cs' {
        $script:APDU_PRODUCT       | Should -Be $ApduProduct
        $script:APDU_FW            | Should -Be $ApduFirmware
        $script:APDU_SERIAL        | Should -Be $ApduSerial
        $script:APDU_CONTACT_SLOTS | Should -Be $ApduContactSlots
        $script:APDU_CL_SLOTS      | Should -Be $ApduContactlessSlots
        $script:APDU_APPLY         | Should -Be $ApduApply
        $script:APDU_REBOOT        | Should -Be $ApduReboot
    }
}

Describe 'Response parsers' {
    It 'ConvertFrom-BoolResponse reads 00/01 for the matching sub-tag' {
        ConvertFrom-BoolResponse (New-GetResponse '84' '01') '84' | Should -BeTrue
        ConvertFrom-BoolResponse (New-GetResponse '84' '00') '84' | Should -BeFalse
    }

    It 'ConvertFrom-BoolResponse returns $null for <case>' -ForEach @(
        @{ case = 'other sub-tag';   resp = 'BD038001019000' }
        @{ case = 'non-bool value';  resp = 'BD038401029000' }
        @{ case = 'error status';    resp = '6A80' }
        @{ case = 'TLV error';       resp = '9E0202049000' }
        @{ case = 'missing 9000';    resp = 'BD03840101' }
        @{ case = 'empty response';  resp = '' }
    ) {
        ConvertFrom-BoolResponse $resp '84' | Should -BeNullOrEmpty
    }

    It 'ConvertFrom-ByteResponse reads the value byte or returns $null' {
        ConvertFrom-ByteResponse (New-GetResponse '8D' '06') '8D' | Should -Be 6
        ConvertFrom-ByteResponse (New-GetResponse '81' 'FF') '81' | Should -Be 255
        ConvertFrom-ByteResponse (New-GetResponse '81' '33') '8D' | Should -BeNullOrEmpty
        ConvertFrom-ByteResponse '6A82' '81' | Should -BeNullOrEmpty
    }

    It 'ConvertFrom-AsciiResponse decodes TLV ASCII and trims NUL/space padding' {
        ConvertFrom-AsciiResponse (New-AsciiResponse '92' 'EXAMPLE0001') | Should -Be 'EXAMPLE0001'
        ConvertFrom-AsciiResponse 'BD0F820D4F4D4E494B45592035303232009000' | Should -Be 'OMNIKEY 5022'
        ConvertFrom-AsciiResponse (New-AsciiResponse '82' "OMNIKEY 3121`0 ") | Should -Be 'OMNIKEY 3121'
    }

    It 'ConvertFrom-AsciiResponse returns $null for <case>' -ForEach @(
        @{ case = 'error status';               resp = '6A80' }
        @{ case = 'missing 9000';               resp = 'BD0C920A4558414D504C45303031' }
        @{ case = 'response shorter than 5';    resp = 'BD9000' }
        @{ case = 'declared length too big';    resp = 'BD0592FF41429000' }
        @{ case = 'empty value (OMNIKEY 3121)'; resp = 'BD0292009000' }
    ) {
        ConvertFrom-AsciiResponse $resp | Should -BeNullOrEmpty
    }

    It 'ConvertFrom-FirmwareResponse formats major.minor.patch or "?"' {
        ConvertFrom-FirmwareResponse 'BD0585030200009000' | Should -Be '2.0.0'
        ConvertFrom-FirmwareResponse 'BD058503010A019000' | Should -Be '1.10.1'
        ConvertFrom-FirmwareResponse '6A80' | Should -Be '?'
    }

    It 'hex helpers round-trip and handle empty input' {
        ConvertTo-HexString (ConvertFrom-HexString 'ff 70 07 6b') 4 | Should -Be 'FF70076B'
        (ConvertFrom-HexString '').Length | Should -Be 0
        ConvertTo-HexString ([byte[]](1, 2)) 0 | Should -Be ''
    }
}

Describe 'Encodings' {
    It 'ConvertTo-BaudByte ignores 106 (always on) and unknown rates' {
        ConvertTo-BaudByte @(106, 212, 424, 848) @(106) | Should -Be 0x70
        ConvertTo-BaudByte @() @() | Should -Be 0
        ConvertTo-BaudByte $null @(424) | Should -Be 0x02
    }

    It 'ConvertFrom-BaudByte always includes 106 and round-trips' {
        foreach ($b in 0x00, 0x11, 0x33, 0x77, 0x40, 0x04) {
            $lists = ConvertFrom-BaudByte ([byte]$b)
            $lists.rx[0] | Should -Be 106
            $lists.tx[0] | Should -Be 106
            ConvertTo-BaudByte $lists.rx $lists.tx | Should -Be $b
        }
    }

    It 'voltage sequence: first voltage in the low bits (0x1B = 5V,3V,1.8V; 0x39 = 1.8V,3V,5V - both verified on a 3121)' {
        ConvertTo-VoltageByte @('5V', '3V', '1.8V') | Should -Be 0x1B
        ConvertTo-VoltageByte @('1.8V', '3V', '5V') | Should -Be 0x39
        Format-VoltageDisplay 0x1B | Should -Be '5V,3V,1.8V'
        Format-VoltageDisplay 0x39 | Should -Be '1.8V,3V,5V'
        Format-VoltageDisplay 0x03 | Should -Be '5V'
        Format-VoltageDisplay 0 | Should -Be 'auto'
        Format-VoltageDisplay $null | Should -Be '?'
    }
}

Describe 'Card classification (TestCard)' {
    It 'identifies storage code <code> as <name>, Classic verdict <classic>' -ForEach @(
        @{ code = '0001'; name = 'MIFARE Classic 1K';                  classic = $true }
        @{ code = '0002'; name = 'MIFARE Classic 4K';                  classic = $true }
        @{ code = '0026'; name = 'MIFARE Mini';                        classic = $true }
        @{ code = '0036'; name = 'MIFARE Plus SL1 2K (Classic mode)';  classic = $true }
        @{ code = '0037'; name = 'MIFARE Plus SL1 4K (Classic mode)';  classic = $true }
        @{ code = '0038'; name = 'MIFARE Plus SL2 2K';                 classic = $false }
        @{ code = '0039'; name = 'MIFARE Plus SL2 4K';                 classic = $false }
        @{ code = '0003'; name = 'MIFARE Ultralight';                  classic = $false }
        @{ code = '003A'; name = 'MIFARE Ultralight C';                classic = $false }
        @{ code = '0030'; name = 'Topaz/Jewel';                        classic = $false }
        @{ code = '000C'; name = 'FeliCa';                             classic = $false }
    ) {
        $t = Get-CardType (New-StorageAtr $code)
        $t.kind    | Should -Be 'storage'
        $t.code    | Should -Be $code
        $t.name    | Should -Be $name
        $t.classic | Should -Be $classic
    }

    It 'reports an unknown storage code without a name and without Classic verdict' {
        $t = Get-CardType (New-StorageAtr '0044')
        $t.kind | Should -Be 'storage'; $t.code | Should -Be '0044'; $t.name | Should -BeNullOrEmpty; $t.classic | Should -BeFalse
    }

    It 'classifies an ATR without the PC/SC RID as a CPU (T=CL) card' {
        $t = Get-CardType '3B8180018080'
        $t.kind | Should -Be 'cpu'; $t.classic | Should -BeFalse
    }

    It 'names the contact protocols' {
        Format-ProtocolName 1 | Should -Be 'T=0'
        Format-ProtocolName 2 | Should -Be 'T=1'
    }
}
