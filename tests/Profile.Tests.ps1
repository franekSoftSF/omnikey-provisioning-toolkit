#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Profile JSON -> operations (ConvertTo-OperationList): every op kind, partial profiles,
# validation errors (EN/PL) and per-model support.
# Pester scoping: variables set in BeforeAll/BeforeEach/BeforeDiscovery are used in other blocks
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    foreach ($f in $ComponentFiles) { . $f }
    Set-MessageLanguage en
}

Describe 'ConvertTo-OperationList: contactless keys' {
    It 'builds all 14 ops from the example profile, in order' {
        $ops = ConvertTo-OperationList (Get-Content $ExampleProfile -Raw | ConvertFrom-Json)
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
        $ops = ConvertTo-OperationList (ConvertTo-TestProfile $json)
        $ops.Count | Should -Be 1
        $ops[0].kind | Should -Be 'bool'
        $ops[0].tech | Should -Be $tech
        $ops[0].sub  | Should -Be $sub
        $ops[0].want | Should -BeOfType [bool]
    }

    It 'keeps explicit false values (not treated as missing)' {
        $ops = ConvertTo-OperationList (ConvertTo-TestProfile '{"iso14443a":{"enabled":false},"emdSuppression":false}')
        $ops.Count | Should -Be 2
        $ops[0].want | Should -BeFalse
        $ops[1].want | Should -BeFalse
    }

    It 'encodes baud lists as rx<<4|tx with a readable display' -ForEach @(
        @{ json = '{"iso14443a":{"rx":[212,424],"tx":[212,424]}}'; want = 0x33; disp = 'rx:106/212/424 tx:106/212/424' }
        @{ json = '{"iso14443b":{"rx":[848]}}';                    want = 0x40; disp = 'rx:106/848 tx:106' }
        @{ json = '{"felica":{"tx":[212]}}';                       want = 0x01; disp = 'rx:106 tx:106/212' }
        @{ json = '{"iso14443a":{"rx":[106,212],"tx":[106]}}';     want = 0x10; disp = 'rx:106/212 tx:106' }
    ) {
        $ops = ConvertTo-OperationList (ConvertTo-TestProfile $json)
        $ops.Count | Should -Be 1
        $ops[0].kind | Should -Be 'baud'
        $ops[0].want | Should -Be $want
        $ops[0].wantDisp | Should -Be $disp
    }

    It 'maps every sleep polling frequency name to its index' {
        $names = '41Hz', '20Hz', '10Hz', '5Hz', '2.5Hz', '1.3Hz', '0.7Hz', '0.3Hz', '0.15Hz', '0.08Hz'
        for ($i = 0; $i -lt $names.Count; $i++) {
            $op = (ConvertTo-OperationList ([pscustomobject]@{ sleepModePollingFrequency = $names[$i] }))[0]
            $op.kind | Should -Be 'freq'
            $op.idx  | Should -Be $i
        }
    }

    It 'pads polling order to 5 codes, is case-insensitive and hides "none" in the display' {
        $op = (ConvertTo-OperationList (ConvertTo-TestProfile '{"pollingSearchOrder":["ISO14443A","none","felica"]}'))[0]
        $op.kind | Should -Be 'poll'
        $op.wantHex | Should -Be '0200060000'
        $op.wantDisp | Should -Be 'iso14443a,felica'
    }

    It 'builds only the keys present in a partial profile' {
        $ops = ConvertTo-OperationList (ConvertTo-TestProfile '{"iso14443a":{"mifarePreferred":true},"pollingSearchOrder":["iso14443a"]}')
        @($ops | ForEach-Object { $_.name }) | Should -Be @('iso14443a.mifarePreferred', 'pollingSearchOrder')
    }

    It 'returns an empty list (not $null) for an empty profile' {
        $ops = ConvertTo-OperationList (ConvertTo-TestProfile '{}')
        $null -eq $ops | Should -BeFalse
        $ops.Count | Should -Be 0
    }

    It 'accepts a hashtable profile and ignores "_" metadata keys' {
        $ops = ConvertTo-OperationList @{ _generatedBy = 'wizard'; emdSuppression = $true; iso14443a = @{ _note = 'x'; enabled = $true } }
        @($ops | ForEach-Object { $_.name }) | Should -Be @('iso14443a.enabled', 'emdSuppression')
    }
}

Describe 'ConvertTo-OperationList: contact slot keys' {
    It 'maps contactSlot.enabled to the contact container (sub 85)' {
        $op = (ConvertTo-OperationList (ConvertTo-TestProfile '{"contactSlot":{"enabled":false}}'))[0]
        $op.kind | Should -Be 'bool'; $op.slot | Should -Be 'contact'; $op.sub | Should -Be '85'; $op.want | Should -BeFalse
    }

    It 'maps operatingMode <mode> to <code>' -ForEach @(
        @{ mode = 'iso7816'; code = 0 }
        @{ mode = 'EMVCo';   code = 1 }
    ) {
        $op = (ConvertTo-OperationList ([pscustomobject]@{ contactSlot = [pscustomobject]@{ operatingMode = $mode } }))[0]
        $op.kind | Should -Be 'mode'; $op.sub | Should -Be '83'; $op.want | Should -Be $code; $op.wantDisp | Should -Be $mode.ToLower()
    }

    It 'encodes voltageSequence <json> as 0x<hex>' -ForEach @(
        @{ json = '["5V","3V","1.8V"]'; hex = '1B'; disp = '5V,3V,1.8V' }
        @{ json = '["1.8V","3V","5V"]'; hex = '39'; disp = '1.8V,3V,5V' }
        @{ json = '["3v"]';             hex = '02'; disp = '3V' }
        @{ json = '"auto"';             hex = '00'; disp = 'auto' }
    ) {
        $op = (ConvertTo-OperationList (ConvertTo-TestProfile "{""contactSlot"":{""voltageSequence"":$json}}"))[0]
        $op.kind | Should -Be 'volt'; $op.sub | Should -Be '82'
        $op.want.ToString('X2') | Should -Be $hex
        $op.wantDisp | Should -Be $disp
    }
}

Describe 'ConvertTo-OperationList: validation' {
    It 'throws for <case>' -ForEach @(
        @{ case = 'unknown top-level key (typo)';     json = '{"emdSupression":true}';                          msg = "*Unknown profile key 'emdSupression'*" }
        @{ case = 'unknown nested key (typo)';        json = '{"iso14443a":{"mifarePrefered":true}}';           msg = "*Unknown profile key 'iso14443a.mifarePrefered'*" }
        @{ case = 'section that is not an object';    json = '{"iso14443a":true}';                              msg = "*iso14443a: expected an object*" }
        @{ case = 'non-boolean enable';               json = '{"iso14443a":{"enabled":"yes"}}';                 msg = "*iso14443a.enabled: expected true or false, got 'yes'*" }
        @{ case = 'unknown baud value';               json = '{"iso14443a":{"rx":[999]}}';                      msg = "*iso14443a.baud: unsupported bit rate '999'*" }
        @{ case = 'baud given as text';               json = '{"iso14443b":{"tx":["212"]}}';                    msg = "*iso14443b.baud: unsupported bit rate '212'*" }
        @{ case = '848 kbps for FeliCa';              json = '{"felica":{"rx":[848]}}';                         msg = "*felica.baud: unsupported bit rate '848' (use: 212 424*" }
        @{ case = 'unknown sleep frequency';          json = '{"sleepModePollingFrequency":"1Hz"}';             msg = "*sleepModePollingFrequency: '1Hz'*41Hz*0.08Hz*" }
        @{ case = 'unknown polling technology';       json = '{"pollingSearchOrder":["iso14443a","nfc"]}';      msg = "*pollingSearchOrder: 'nfc'*iso14443a*" }
        @{ case = 'polling order with 6 entries';     json = '{"pollingSearchOrder":["iso14443a","iso14443b","iclass","felica","iso15693","none"]}'; msg = "*at most 5 entries, got 6*" }
        @{ case = 'unknown operating mode';           json = '{"contactSlot":{"operatingMode":"emv"}}';         msg = "*contactSlot.operatingMode: 'emv' (use: emvco iso7816)*" }
        @{ case = 'unknown voltage';                  json = '{"contactSlot":{"voltageSequence":["12V"]}}';     msg = "*contactSlot.voltageSequence*'12V'*" }
        @{ case = 'repeated voltage';                 json = '{"contactSlot":{"voltageSequence":["5V","5V"]}}'; msg = "*contactSlot.voltageSequence*" }
        @{ case = 'four voltages';                    json = '{"contactSlot":{"voltageSequence":["5V","3V","1.8V","5V"]}}'; msg = "*contactSlot.voltageSequence*" }
    ) {
        { ConvertTo-OperationList (ConvertTo-TestProfile $json) } | Should -Throw -ExpectedMessage $msg
    }

    It 'accepts 106 in a baud list (always on) and numbers from both JSON parsers' {
        (ConvertTo-OperationList (ConvertTo-TestProfile '{"iso14443a":{"rx":[106,848]}}'))[0].want | Should -Be 0x40
        (ConvertTo-OperationList ([pscustomobject]@{ iso14443b = [pscustomobject]@{ tx = @([int64]424, [int32]212) } }))[0].want | Should -Be 0x03
    }

    It 'reports validation errors in Polish with -Lang pl' {
        Set-MessageLanguage pl
        try {
            { ConvertTo-OperationList (ConvertTo-TestProfile '{"iso14443a":{"enabled":1}}') } |
                Should -Throw -ExpectedMessage "*iso14443a.enabled: oczekiwano true lub false*"
        }
        finally { Set-MessageLanguage en }
    }
}

Describe 'ConvertTo-OperationList: model support' {
    BeforeAll {
        $m5022 = Resolve-ReaderModel @{ Product = 'OMNIKEY 5022' }
        $m3121 = Resolve-ReaderModel @{ Product = 'OMNIKEY 3121' }
        $m5422 = Resolve-ReaderModel @{ Product = 'OMNIKEY 5422' }
    }

    It 'accepts the full example profile for OMNIKEY 5022' {
        (ConvertTo-OperationList (Get-Content $ExampleProfile -Raw | ConvertFrom-Json) $m5022).Count | Should -Be 14
    }

    It 'rejects contact slot keys on OMNIKEY 5022' {
        { ConvertTo-OperationList (ConvertTo-TestProfile '{"contactSlot":{"enabled":true}}') $m5022 } |
            Should -Throw -ExpectedMessage '*contactSlot.enabled: not supported by OMNIKEY 5022*'
    }

    It 'rejects contactless keys on OMNIKEY 3121 before anything is sent' {
        { ConvertTo-OperationList (Get-Content $ExampleProfile -Raw | ConvertFrom-Json) $m3121 } |
            Should -Throw -ExpectedMessage '*iso14443a.enabled: not supported by OMNIKEY 3121*'
    }

    It 'accepts contact slot profiles on OMNIKEY 3121, including voltageSequence "auto"' {
        (ConvertTo-OperationList (ConvertTo-TestProfile '{"contactSlot":{"enabled":true,"operatingMode":"iso7816","voltageSequence":["5V","3V","1.8V"]}}') $m3121).Count | Should -Be 3
        (ConvertTo-OperationList (ConvertTo-TestProfile '{"contactSlot":{"operatingMode":"iso7816","voltageSequence":"auto"}}') $m3121).Count | Should -Be 2
    }

    It 'rejects a voltage sequence other than 5V together with EMVCo on OMNIKEY 3121 (it reports 5V in EMVCo mode)' {
        { ConvertTo-OperationList (ConvertTo-TestProfile '{"contactSlot":{"operatingMode":"emvco","voltageSequence":["5V","3V"]}}') $m3121 } |
            Should -Throw -ExpectedMessage '*in EMVCo mode OMNIKEY 3121 uses 5V only*'
        { ConvertTo-OperationList (ConvertTo-TestProfile '{"contactSlot":{"operatingMode":"emvco","voltageSequence":"auto"}}') $m3121 } | Should -Throw
        (ConvertTo-OperationList (ConvertTo-TestProfile '{"contactSlot":{"operatingMode":"emvco","voltageSequence":["5V"]}}') $m3121).Count | Should -Be 2
        (ConvertTo-OperationList (ConvertTo-TestProfile '{"contactSlot":{"operatingMode":"emvco"}}') $m3121).Count | Should -Be 1
    }

    It 'rejects FeliCa and 15693 keys on OMNIKEY 5422 (OK5422.cs has no such classes)' {
        { ConvertTo-OperationList (ConvertTo-TestProfile '{"felica":{"enabled":true}}') $m5422 } | Should -Throw -ExpectedMessage '*felica.enabled: not supported by OMNIKEY 5422*'
        { ConvertTo-OperationList (ConvertTo-TestProfile '{"iso15693":{"enabled":true}}') $m5422 } | Should -Throw
        (ConvertTo-OperationList (ConvertTo-TestProfile '{"iso14443a":{"enabled":true},"contactSlot":{"enabled":true}}') $m5422).Count | Should -Be 2
    }
}
