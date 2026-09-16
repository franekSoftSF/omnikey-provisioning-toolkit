#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Characterization tests for Batch-Omnikey5022-Provision.ps1 - no hardware, no
# winscard calls, no CSV: every reader exchange goes through a mocked Send-Escape.
# Pester scoping: variables set in BeforeAll/BeforeEach/BeforeDiscovery are used in other blocks
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . $BatchPath -ProfilePath $ExampleProfile   # Mandatory param; MAIN is not executed
    $card = [IntPtr]::Zero
}

Describe 'Batch: Build-Ops' {
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
        $ops = Build-Ops (ConvertTo-TestProfile '{"iso14443b":{"enabled":false},"sleepModeCardDetection":false}')
        $ops.Count | Should -Be 2
        $ops[0].want | Should -BeFalse
        $ops[1].want | Should -BeFalse
    }

    It 'encodes baud lists as rx<<4|tx with a hex display' -ForEach @(
        @{ json = '{"iso14443a":{"rx":[212,424],"tx":[212,424]}}'; want = 0x33; disp = '0x33' }
        @{ json = '{"iso14443b":{"rx":[848]}}';                    want = 0x40; disp = '0x40' }
        @{ json = '{"felica":{"tx":[212]}}';                       want = 0x01; disp = '0x01' }
        @{ json = '{"iso14443a":{"rx":[106,212],"tx":[106]}}';     want = 0x10; disp = '0x10' }
    ) {
        $ops = Build-Ops (ConvertTo-TestProfile $json)
        $ops.Count | Should -Be 1
        $ops[0].kind | Should -Be 'baud'
        $ops[0].want | Should -Be $want
        $ops[0].wantDisp | Should -Be $disp
    }

    It 'pads polling order to 5 codes and is case-insensitive (display keeps "none")' {
        # differs from CheckProfile5022, which hides "none"; unify in the module refactor
        $op = (Build-Ops (ConvertTo-TestProfile '{"pollingSearchOrder":["ISO14443A","none","felica"]}'))[0]
        $op.kind | Should -Be 'poll'
        $op.wantHex | Should -Be '0200060000'
        $op.wantDisp | Should -Be 'iso14443a,none,felica'
    }

    It 'builds only the keys present in a partial profile' {
        $ops = Build-Ops (ConvertTo-TestProfile '{"iso14443a":{"mifarePreferred":true},"sleepModePollingFrequency":"41Hz"}')
        @($ops | ForEach-Object { $_.name }) | Should -Be @('iso14443a.mifarePreferred', 'sleepModePollingFrequency')
        $ops[1].idx | Should -Be 0
    }

    It 'returns an empty list (not $null) for an empty profile' {
        $ops = Build-Ops (ConvertTo-TestProfile '{}')
        $null -eq $ops | Should -BeFalse
        $ops.Count | Should -Be 0
    }

    It 'throws naming the key and value for an unknown sleep frequency' {
        { Build-Ops (ConvertTo-TestProfile '{"sleepModePollingFrequency":"1Hz"}') } |
            Should -Throw -ExpectedMessage "*sleepModePollingFrequency: '1Hz'*"
    }

    It 'throws naming the key and value for an unknown polling technology' {
        { Build-Ops (ConvertTo-TestProfile '{"pollingSearchOrder":["nfc"]}') } |
            Should -Throw -ExpectedMessage "*pollingSearchOrder: 'nfc'*"
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

Describe 'Batch: parsers' {
    It 'Parse-Bool / Parse-Byte read values for the matching sub-tag only' {
        Parse-Bool (New-GetResponse '80' '01') '80' | Should -BeTrue
        Parse-Bool (New-GetResponse '80' '00') '80' | Should -BeFalse
        Parse-Bool (New-GetResponse '80' '01') '84' | Should -BeNullOrEmpty
        Parse-Byte (New-GetResponse '81' '77') '81' | Should -Be 0x77
        Parse-Byte '6A80' '81' | Should -BeNullOrEmpty
    }

    It 'BaudTo-Byte ignores 106 and unknown rates' {
        BaudTo-Byte @(106, 212, 999) @(848) | Should -Be 0x14
    }

    It 'Parse-Ascii decodes a TLV ASCII value and trims NUL/space padding' {
        Parse-Ascii (New-AsciiResponse '92' 'EXAMPLE001') | Should -Be 'EXAMPLE001'
        Parse-Ascii (New-AsciiResponse '82' "OMNIKEY 5022`0`0") | Should -Be 'OMNIKEY 5022'
    }

    It 'Parse-Ascii returns $null for <case>' -ForEach @(
        @{ case = 'error status';            resp = '6A80' }
        @{ case = 'missing 9000';            resp = 'BD0C920A4558414D504C45303031' }
        @{ case = 'response shorter than 5'; resp = 'BD9000' }
        @{ case = 'declared length too big'; resp = 'BD0592FF41429000' }
    ) {
        Parse-Ascii $resp | Should -BeNullOrEmpty
    }

    It 'Read-Identity reads serial, product name and firmware with the documented APDUs' {
        Mock Send-Escape {
            switch ($apdu) {
                $ApduSerial   { New-AsciiResponse '92' 'EXAMPLE001' }
                $ApduProduct  { New-AsciiResponse '82' 'OMNIKEY 5022' }
                $ApduFirmware { 'BD058503020A019000' }
            }
        }
        $id = Read-Identity $card
        $id | Should -BeOfType [hashtable]
        $id.Serial  | Should -Be 'EXAMPLE001'
        $id.Product | Should -Be 'OMNIKEY 5022'
        $id.Fw      | Should -Be '2.10.1'
    }

    It 'Read-Identity reports "?" firmware and no serial for failed responses' {
        Mock Send-Escape { '6A80' }
        $id = Read-Identity $card
        $id.Serial | Should -BeNullOrEmpty
        $id.Fw     | Should -Be '?'
    }
}

Describe 'Batch: op engine and Check-All' {
    BeforeEach {
        $sent = [System.Collections.Generic.List[string]]::new()
        $ops = Build-Ops (Get-Content $ExampleProfile -Raw | ConvertFrom-Json)
    }

    It 'Invoke-OpApply sends exactly the documented SET APDUs for the example profile' {
        Mock Send-Escape { $sent.Add($apdu); '9000' }
        foreach ($op in $ops) { Invoke-OpApply $card $op }
        @($sent) | Should -Be $ExampleProfileSetApdus
    }

    It 'Check-All returns ok with an empty bad list when the reader matches the profile' {
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
        $r = Check-All $card $ops
        $r | Should -BeOfType [hashtable]
        $r.ok | Should -BeTrue
        $null -eq $r.bad | Should -BeFalse
        $r.bad.Count | Should -Be 0
    }

    It 'Check-All lists mismatching and unreadable parameters by name' {
        Mock Send-Escape {
            if ($apdu -eq "${ApduGetPrefix}A0028D0000") { throw '0x80100017' }   # sleep freq: escape error
            switch -Regex ($apdu) {
                "^${ApduPollGet}$"                   { 'BD07890502030406019000'; break }
                "^${ApduGetPrefix}A2028400"          { New-GetResponse '84' '00'; break }  # mifarePreferred off
                "^${ApduGetPrefix}(..)02(..)0000$" {
                    $key = $Matches[1] + $Matches[2]
                    switch ($key) {
                        'A283'  { New-GetResponse '83' '00' }
                        'A281'  { New-GetResponse '81' '33' }
                        'A381'  { New-GetResponse '81' '33' }
                        'A581'  { New-GetResponse '81' '11' }
                        default { New-GetResponse $Matches[2] '01' }
                    }
                }
            }
        }
        $r = Check-All $card $ops
        $r.ok | Should -BeFalse
        @($r.bad) | Should -Be @('iso14443a.mifarePreferred', 'sleepModePollingFrequency')
    }

    It 'Invoke-OpCheck never sends a SET, Apply or Reboot APDU' {
        Mock Send-Escape { $sent.Add($apdu); '6A80' }
        [void](Check-All $card $ops)
        $sent.Count | Should -Be $ops.Count
        @($sent | Where-Object { $_.StartsWith($ApduSetPrefix) -or $_.StartsWith($ApduPollSet) -or $_ -in $ApduApply, $ApduReboot }) |
            Should -BeNullOrEmpty
    }
}
