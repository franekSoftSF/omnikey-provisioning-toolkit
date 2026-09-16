#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Characterization tests for CheckProfile5022.ps1 - no hardware, no winscard calls:
# every reader exchange goes through a mocked Send-Escape.
# Pester scoping: variables set in BeforeAll/BeforeEach/BeforeDiscovery are used in other blocks
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . $CheckProfilePath
    $card = [IntPtr]::Zero
}

Describe 'CheckProfile5022: Build-Ops' {
    It 'builds all 14 ops from the example profile, in order' {
        $ops = Build-Ops (Get-Content $ExampleProfile -Raw | ConvertFrom-Json)
        @($ops | ForEach-Object { $_.name }) | Should -Be $ExampleProfileOpNames
    }

    It 'maps <json> to tech <tech> sub <sub>' -ForEach @(
        @{ json = '{"iso14443a":{"enabled":true}}';         tech = 'A2'; sub = '80' }
        @{ json = '{"iso14443a":{"mifarePreferred":true}}'; tech = 'A2'; sub = '84' }
        @{ json = '{"iso14443a":{"mifareKeyCache":true}}';  tech = 'A2'; sub = '83' }
        @{ json = '{"iso14443b":{"enabled":true}}';         tech = 'A3'; sub = '80' }
        @{ json = '{"iso15693":{"enabled":true}}';          tech = 'A4'; sub = '80' }
        @{ json = '{"felica":{"enabled":true}}';            tech = 'A5'; sub = '80' }
        @{ json = '{"iclass":{"enabled":true}}';            tech = 'A6'; sub = '83' }
        @{ json = '{"emdSuppression":true}';                tech = 'A0'; sub = '87' }
        @{ json = '{"sleepModeCardDetection":true}';        tech = 'A0'; sub = '8E' }
    ) {
        $ops = Build-Ops (ConvertTo-TestProfile $json)
        $ops.Count | Should -Be 1
        $ops[0].kind | Should -Be 'bool'
        $ops[0].tech | Should -Be $tech
        $ops[0].sub  | Should -Be $sub
        $ops[0].want | Should -BeOfType [bool]
    }

    It 'keeps explicit false values (not treated as missing)' {
        $ops = Build-Ops (ConvertTo-TestProfile '{"iso14443a":{"enabled":false},"emdSuppression":false}')
        $ops.Count | Should -Be 2
        $ops[0].want | Should -BeFalse
        $ops[1].want | Should -BeFalse
    }

    It 'encodes baud lists as rx<<4|tx with a Fmt-Baud display' -ForEach @(
        @{ json = '{"iso14443a":{"rx":[212,424],"tx":[212,424]}}'; want = 0x33; disp = 'rx:106/212/424 tx:106/212/424' }
        @{ json = '{"iso14443b":{"rx":[848]}}';                    want = 0x40; disp = 'rx:106/848 tx:106' }
        @{ json = '{"felica":{"tx":[212]}}';                       want = 0x01; disp = 'rx:106 tx:106/212' }
        @{ json = '{"iso14443a":{"rx":[106,212],"tx":[106]}}';     want = 0x10; disp = 'rx:106/212 tx:106' }
    ) {
        $ops = Build-Ops (ConvertTo-TestProfile $json)
        $ops.Count | Should -Be 1
        $ops[0].kind | Should -Be 'baud'
        $ops[0].want | Should -Be $want
        $ops[0].wantDisp | Should -Be $disp
    }

    It 'maps every sleep polling frequency name to its index' {
        $names = '41Hz', '20Hz', '10Hz', '5Hz', '2.5Hz', '1.3Hz', '0.7Hz', '0.3Hz', '0.15Hz', '0.08Hz'
        for ($i = 0; $i -lt $names.Count; $i++) {
            $op = (Build-Ops ([pscustomobject]@{ sleepModePollingFrequency = $names[$i] }))[0]
            $op.kind | Should -Be 'freq'
            $op.idx  | Should -Be $i
        }
    }

    It 'pads polling order to 5 codes, is case-insensitive and hides "none" in the display' {
        $op = (Build-Ops (ConvertTo-TestProfile '{"pollingSearchOrder":["ISO14443A","none","felica"]}'))[0]
        $op.kind | Should -Be 'poll'
        $op.wantHex | Should -Be '0200060000'
        $op.wantDisp | Should -Be 'iso14443a,felica'
    }

    It 'builds only the keys present in a partial profile' {
        $ops = Build-Ops (ConvertTo-TestProfile '{"iso14443a":{"mifarePreferred":true},"pollingSearchOrder":["iso14443a"]}')
        @($ops | ForEach-Object { $_.name }) | Should -Be @('iso14443a.mifarePreferred', 'pollingSearchOrder')
    }

    It 'returns an empty list (not $null) for an empty profile' {
        $ops = Build-Ops (ConvertTo-TestProfile '{}')
        $null -eq $ops | Should -BeFalse
        $ops.Count | Should -Be 0
    }

    It 'throws a readable error for an unknown sleep frequency' {
        { Build-Ops (ConvertTo-TestProfile '{"sleepModePollingFrequency":"1Hz"}') } |
            Should -Throw -ExpectedMessage "*sleepModePollingFrequency: '1Hz'*41Hz*0.08Hz*"
    }

    It 'throws a readable error for an unknown polling technology' {
        { Build-Ops (ConvertTo-TestProfile '{"pollingSearchOrder":["iso14443a","nfc"]}') } |
            Should -Throw -ExpectedMessage "*pollingSearchOrder: 'nfc'*iso14443a*"
    }

    It 'throws for invalid <case> (pending: validation lands with the module refactor, backlog 3)' -ForEach @(
        @{ case = 'baud value';          json = '{"iso14443a":{"rx":[999]}}' }
        @{ case = 'non-boolean enable';  json = '{"iso14443a":{"enabled":"yes"}}' }
        @{ case = 'polling order > 5';   json = '{"pollingSearchOrder":["iso14443a","iso14443b","iclass","felica","iso15693","none"]}' }
    ) {
        Set-ItResult -Skipped -Because 'profile value validation is implemented in the module refactor (CLAUDE.md backlog 3)'
        { Build-Ops (ConvertTo-TestProfile $json) } | Should -Throw
    }
}

Describe 'CheckProfile5022: parsers' {
    It 'Parse-Bool reads 00/01 for the matching sub-tag' {
        Parse-Bool (New-GetResponse '84' '01') '84' | Should -BeTrue
        Parse-Bool (New-GetResponse '84' '00') '84' | Should -BeFalse
    }

    It 'Parse-Bool returns $null for <case>' -ForEach @(
        @{ case = 'other sub-tag';   resp = 'BD038001019000' }
        @{ case = 'non-bool value';  resp = 'BD038401029000' }
        @{ case = 'error status';    resp = '6A80' }
        @{ case = 'missing 9000';    resp = 'BD03840101' }
        @{ case = 'empty response';  resp = '' }
    ) {
        Parse-Bool $resp '84' | Should -BeNullOrEmpty
    }

    It 'Parse-Byte reads the value byte' {
        Parse-Byte (New-GetResponse '8D' '06') '8D' | Should -Be 6
        Parse-Byte (New-GetResponse '81' 'FF') '81' | Should -Be 255
    }

    It 'Parse-Byte returns $null for a mismatched or failed response' {
        Parse-Byte (New-GetResponse '81' '33') '8D' | Should -BeNullOrEmpty
        Parse-Byte '6A82' '81' | Should -BeNullOrEmpty
    }

    It 'BaudTo-Byte ignores 106 (always on) and unknown rates' {
        BaudTo-Byte @(106, 212, 424, 848) @(106) | Should -Be 0x70
        BaudTo-Byte @() @() | Should -Be 0
        BaudTo-Byte $null @(424) | Should -Be 0x02
    }

    It 'Byte-ToBaud always includes 106 and round-trips with BaudTo-Byte' {
        foreach ($b in 0x00, 0x11, 0x33, 0x77, 0x40, 0x04) {
            $lists = Byte-ToBaud ([byte]$b)
            $lists.rx[0] | Should -Be 106
            $lists.tx[0] | Should -Be 106
            BaudTo-Byte $lists.rx $lists.tx | Should -Be $b
        }
    }

    It 'Read-Serial decodes the TLV ASCII serial and trims NUL/space padding' {
        Mock Send-Escape { New-AsciiResponse '92' "EXAMPLE001`0 " }
        Read-Serial $card | Should -Be 'EXAMPLE001'
        Should -Invoke Send-Escape -Times 1 -Exactly -ParameterFilter { $apdu -eq $ApduSerial }
    }

    It 'Read-Serial returns "?" for a failed response' {
        Mock Send-Escape { '6A80' }
        Read-Serial $card | Should -Be '?'
    }
}

Describe 'CheckProfile5022: card classification (TestCard)' {
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
        $t.kind | Should -Be 'storage'
        $t.code | Should -Be '0044'
        $t.name | Should -BeNullOrEmpty
        $t.classic | Should -BeFalse
    }

    It 'classifies an ATR without the PC/SC RID as a CPU (T=CL) card' {
        $t = Get-CardType '3B8180018080'
        $t.kind | Should -Be 'cpu'
        $t.classic | Should -BeFalse
    }
}

Describe 'CheckProfile5022: op engine (Invoke-OpApply / Invoke-OpCheck)' {
    BeforeEach {
        $sent = [System.Collections.Generic.List[string]]::new()
    }

    It 'sends exactly the documented SET APDUs for the example profile' {
        Mock Send-Escape { $sent.Add($apdu); '9000' }
        foreach ($op in (Build-Ops (Get-Content $ExampleProfile -Raw | ConvertFrom-Json))) { Invoke-OpApply $card $op }
        @($sent) | Should -Be $ExampleProfileSetApdus
    }

    It 'Invoke-OpApply throws the reader status when a SET is rejected' {
        Mock Send-Escape { '6A80' }
        $op = (Build-Ops (ConvertTo-TestProfile '{"emdSuppression":true}'))[0]
        { Invoke-OpApply $card $op } | Should -Throw -ExpectedMessage '6A80'
    }

    It 'Invoke-OpCheck reports ok for matching reader values of every kind' {
        Mock Send-Escape {
            switch -Regex ($apdu) {
                "^${ApduPollGet}$"             { 'BD07890502030406019000'; break }
                "^${ApduGetPrefix}(..)02(..)0000$" {
                    $key = $Matches[1] + $Matches[2]
                    switch ($key) {
                        'A283'  { New-GetResponse '83' '00' }
                        'A281'  { New-GetResponse '81' '33' }
                        'A381'  { New-GetResponse '81' '33' }
                        'A581'  { New-GetResponse '81' '11' }
                        'A08D'  { New-GetResponse '8D' '06' }
                        default { New-GetResponse $Matches[2] '01' }
                    }
                }
            }
        }
        foreach ($op in (Build-Ops (Get-Content $ExampleProfile -Raw | ConvertFrom-Json))) {
            $r = Invoke-OpCheck $card $op
            $r | Should -BeOfType [hashtable]
            $r.ok | Should -BeTrue -Because $op.name
        }
    }

    It 'Invoke-OpCheck reports <name> mismatch with the reader value' -ForEach @(
        @{ name = 'bool';  json = '{"iso14443a":{"mifarePreferred":true}}';   resp = 'BD038401009000';          have = $false }
        @{ name = 'baud';  json = '{"iso14443a":{"rx":[212],"tx":[212]}}';    resp = 'BD038101009000';          have = 'rx:106 tx:106' }
        @{ name = 'freq';  json = '{"sleepModePollingFrequency":"0.7Hz"}';    resp = 'BD038D01009000';          have = '41Hz' }
        @{ name = 'poll';  json = '{"pollingSearchOrder":["iso14443a"]}';     resp = 'BD07890503020000009000';  have = 'iso14443b,iso14443a' }
    ) {
        Mock Send-Escape { $resp }
        $r = Invoke-OpCheck $card (Build-Ops (ConvertTo-TestProfile $json))[0]
        $r.ok | Should -BeFalse
        $r.have | Should -Be $have
    }

    It 'Invoke-OpCheck is not ok when the reader answers with an error' {
        Mock Send-Escape { '6A80' }
        foreach ($op in (Build-Ops (Get-Content $ExampleProfile -Raw | ConvertFrom-Json))) {
            (Invoke-OpCheck $card $op).ok | Should -BeFalse -Because $op.name
        }
    }

    It 'Invoke-OpCheck never sends a SET, Apply or Reboot APDU' {
        Mock Send-Escape { $sent.Add($apdu); '6A80' }
        foreach ($op in (Build-Ops (Get-Content $ExampleProfile -Raw | ConvertFrom-Json))) { [void](Invoke-OpCheck $card $op) }
        $sent.Count | Should -BeGreaterThan 0
        @($sent | Where-Object { $_.StartsWith($ApduSetPrefix) -or $_.StartsWith($ApduPollSet) -or $_ -in $ApduApply, $ApduReboot }) |
            Should -BeNullOrEmpty
    }
}
