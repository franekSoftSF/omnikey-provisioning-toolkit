#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Op engine, reader models, Get/Export and the PC/SC transport (lesson 3) against simulated
# readers built from real OMNIKEY 5022 / 3121 responses. No winscard call is made.
# Pester scoping: variables set in BeforeAll/BeforeEach/BeforeDiscovery are used in other blocks
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    foreach ($f in $ComponentFiles) { . $f }
    Set-MessageLanguage en
    $card = [IntPtr]::Zero
    $exampleOps = ConvertTo-OperationList (Get-Content $ExampleProfile -Raw | ConvertFrom-Json)
}

Describe 'Op engine on a simulated OMNIKEY 5022' {
    BeforeEach {
        $sent = [System.Collections.Generic.List[string]]::new()
        $sim = New-Reader5022Sim
        Mock Send-Escape { $sent.Add($apdu); if ($sim.ContainsKey($apdu)) { $sim[$apdu] } elseif (Test-IsWriteApdu $apdu) { '9000' } else { '6A80' } }
    }

    It 'Invoke-OpApply sends exactly the documented SET APDUs for the example profile' {
        foreach ($op in $exampleOps) { Invoke-OpApply $card $op }
        @($sent) | Should -Be $ExampleProfileSetApdus
    }

    It 'Invoke-OpCheck reports ok for every example-profile parameter' {
        foreach ($op in $exampleOps) {
            $r = Invoke-OpCheck $card $op
            $r | Should -BeOfType [hashtable]
            $r.ok | Should -BeTrue -Because $op.name
        }
    }

    It 'Invoke-OpCheck reports <name> mismatch with the reader value' -ForEach @(
        @{ name = 'bool'; json = '{"iso14443a":{"mifarePreferred":false}}'; have = $true }
        @{ name = 'baud'; json = '{"iso14443a":{"rx":[212],"tx":[212]}}';   have = 'rx:106/212/424 tx:106/212/424' }
        @{ name = 'freq'; json = '{"sleepModePollingFrequency":"41Hz"}';    have = '0.7Hz' }
        @{ name = 'poll'; json = '{"pollingSearchOrder":["iso14443b"]}';    have = 'iso14443a,iso14443b,iclass,felica,iso15693' }
    ) {
        $r = Invoke-OpCheck $card (ConvertTo-OperationList (ConvertTo-TestProfile $json))[0]
        $r.ok | Should -BeFalse
        $r.have | Should -Be $have
    }

    It 'Invoke-OpCheck never sends a write APDU' {
        foreach ($op in $exampleOps) { [void](Invoke-OpCheck $card $op) }
        $sent.Count | Should -Be $exampleOps.Count
        @($sent | Where-Object { Test-IsWriteApdu $_ }) | Should -BeNullOrEmpty
    }

    It 'Invoke-OpApply throws the reader status when a SET is rejected' {
        Mock Send-Escape { '6A80' }
        { Invoke-OpApply $card (ConvertTo-OperationList (ConvertTo-TestProfile '{"emdSuppression":true}'))[0] } | Should -Throw -ExpectedMessage '6A80'
    }

    It 'Invoke-OpCheckAll lists mismatching and unreadable parameters with have/want' {
        $sim["${ApduGetPrefix}A202840000"] = 'BD038401009000'                        # mifarePreferred off
        Mock Send-Escape { if ($apdu -eq "${ApduGetPrefix}A0028D0000") { throw 'SCardControl 0x80100017' }; $sim[$apdu] }
        $r = Invoke-OpCheckAll $card $exampleOps
        $r.ok | Should -BeFalse
        @($r.bad) | Should -Be @('iso14443a.mifarePreferred', 'sleepModePollingFrequency')
        $r.diff[0].name | Should -Be 'iso14443a.mifarePreferred'; $r.diff[0].want | Should -BeTrue; $r.diff[0].have | Should -BeFalse
        $r.diff[1].have | Should -BeNullOrEmpty
    }

    It 'Get-ReaderConfiguration reads the contactless configuration' {
        $cfg = Get-ReaderConfiguration $card (Resolve-ReaderModel @{ Product = 'OMNIKEY 5022' })
        @($cfg.Keys) | Should -Be $ExampleProfileOpNames
        $cfg['sleepModePollingFrequency'] | Should -Be '0.7Hz'
        $cfg['pollingSearchOrder'] | Should -Be 'iso14443a,iso14443b,iclass,felica,iso15693'
    }

    It 'Export-ReaderProfile writes a profile equal to profiles/example-profile.json' {
        $path = Join-Path $TestDrive 'export-5022.json'
        Export-ReaderProfile $card $path (Resolve-ReaderModel @{ Product = 'OMNIKEY 5022' })
        (Get-Content $path -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 5 -Compress) |
            Should -Be (Get-Content $ExampleProfile -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 5 -Compress)
    }
}

Describe 'Op engine on a simulated OMNIKEY 3121 (contact slot)' {
    BeforeEach {
        $sent = [System.Collections.Generic.List[string]]::new()
        $sim = New-Reader3121Sim
        Mock Send-Escape { $sent.Add($apdu); if ($sim.ContainsKey($apdu)) { $sim[$apdu] } elseif (Test-IsWriteApdu $apdu) { '9000' } else { '9E0202049000' } }
        $m3121 = Resolve-ReaderModel @{ Product = 'OMNIKEY 3121' }
    }

    It 'sends the ContactSlotConfiguration SET APDUs' {
        $ops = ConvertTo-OperationList (ConvertTo-TestProfile '{"contactSlot":{"enabled":true,"operatingMode":"emvco"}}') $m3121
        $ops += ConvertTo-OperationList (ConvertTo-TestProfile '{"contactSlot":{"voltageSequence":["1.8V","3V","5V"]}}') $m3121
        foreach ($op in $ops) { Invoke-OpApply $card $op }
        @($sent) | Should -Be @("${ApduContactSetPrefix}85010100", "${ApduContactSetPrefix}83010100", "${ApduContactSetPrefix}82013900")
    }

    It 'Invoke-OpCheck compares contact slot values' {
        $modeOps = ConvertTo-OperationList (ConvertTo-TestProfile '{"contactSlot":{"enabled":true,"operatingMode":"emvco"}}') $m3121
        $voltOps = ConvertTo-OperationList (ConvertTo-TestProfile '{"contactSlot":{"voltageSequence":["5V","3V","1.8V"]}}') $m3121
        $r = @((Invoke-OpCheck $card $modeOps[0]), (Invoke-OpCheck $card $modeOps[1]), (Invoke-OpCheck $card $voltOps[0]))
        $r[0].ok | Should -BeTrue
        $r[1].ok | Should -BeFalse; $r[1].have | Should -Be 'iso7816'
        $r[2].ok | Should -BeTrue; $r[2].have | Should -Be '5V,3V,1.8V'
    }

    It 'Get-ReaderConfiguration shows only the contact slot' {
        $cfg = Get-ReaderConfiguration $card $m3121
        @($cfg.Keys) | Should -Be @('contactSlot.enabled', 'contactSlot.operatingMode', 'contactSlot.voltageSequence')
        @($cfg.Values) | Should -Be @($true, 'iso7816', '5V,3V,1.8V')
        @($sent | Where-Object { $_.StartsWith($ApduGetPrefix) }) | Should -BeNullOrEmpty -Because 'no contactless GETs on a contact reader'
    }

    It 'Export-ReaderProfile writes a contactSlot profile that validates for the 3121' {
        $path = Join-Path $TestDrive 'export-3121.json'
        Export-ReaderProfile $card $path $m3121
        $p = Get-Content $path -Raw | ConvertFrom-Json
        @($p.PSObject.Properties.Name) | Should -Be @('contactSlot')
        $p.contactSlot.enabled | Should -BeTrue
        $p.contactSlot.operatingMode | Should -Be 'iso7816'
        @($p.contactSlot.voltageSequence) | Should -Be @('5V', '3V', '1.8V')
        (ConvertTo-OperationList $p $m3121).Count | Should -Be 3
    }
}

Describe 'Reader models' {
    It 'Read-Identity + Resolve-ReaderModel recognise the simulated <product>' -ForEach @(
        @{ product = 'OMNIKEY 5022'; sim = 'New-Reader5022Sim'; serial = 'EXAMPLE0001'; fw = '2.0.0'; cl = $true;  ct = $false }
        @{ product = 'OMNIKEY 3121'; sim = 'New-Reader3121Sim'; serial = $null;         fw = '1.6.0'; cl = $false; ct = $true }
    ) {
        $responses = & $sim
        Mock Send-Escape { $responses[$apdu] }
        $id = Read-Identity $card
        $id.Product | Should -Be $product
        $id.Serial | Should -Be $serial
        $id.Fw | Should -Be $fw
        $m = Resolve-ReaderModel $id
        $m.known | Should -BeTrue; $m.verified | Should -BeTrue
        $m.contactless | Should -Be $cl; $m.contact | Should -Be $ct
    }

    It 'an unknown product is not writable and falls back to the reported slot counts' {
        $m = Resolve-ReaderModel @{ Product = 'OMNIKEY 5023'; ContactSlots = 0; ContactlessSlots = 1 }
        $m.known | Should -BeFalse
        $m.product | Should -Be 'OMNIKEY 5023'
        $m.contactless | Should -BeTrue; $m.contact | Should -BeFalse
        @($m.profileKeys) | Should -Contain 'iso14443a.enabled'
    }

    It '5122/5422 are known but not verified on hardware' {
        foreach ($p in 'OMNIKEY 5122', 'OMNIKEY 5422') {
            $m = Resolve-ReaderModel @{ Product = $p }
            $m.known | Should -BeTrue; $m.verified | Should -BeFalse; $m.contact | Should -BeTrue
        }
    }

    It 'Read-Identity tolerates escape errors on the slot-count GETs' {
        $sim = New-Reader5022Sim
        Mock Send-Escape { if ($apdu -in $ApduContactSlots, $ApduContactlessSlots) { throw 'SCardControl 0x80100001' }; $sim[$apdu] }
        $id = Read-Identity $card
        $id.Product | Should -Be 'OMNIKEY 5022'
        $id.ContactSlots | Should -BeNullOrEmpty
    }
}

Describe 'Transport (lesson 3: context recovery)' {
    BeforeEach {
        Mock Invoke-NativeEstablishContext { @{ rc = 0; ctx = [IntPtr]42 } }
        Mock Invoke-NativeReleaseContext { }
        Mock Disconnect-Card { }
        $script:ctx = [IntPtr]::Zero      # fresh context state; the release mock must not count this
    }

    It 'Get-ReaderList resets the context after SCARD_E_NO_SERVICE' {
        Mock Invoke-NativeListReaders { @{ rc = -2146435043; names = @() } }      # 0x8010001D
        $list = Get-ReaderList
        $null -eq $list | Should -BeFalse
        $list.Count | Should -Be 0
        Should -Invoke Invoke-NativeReleaseContext -Times 1 -Exactly
        Should -Invoke Invoke-NativeEstablishContext -Times 2 -Exactly
    }

    It 'Get-ReaderList keeps the context when there are simply no readers' {
        Mock Invoke-NativeListReaders { @{ rc = -2146435026; names = @() } }      # 0x8010002E
        (Get-ReaderList).Count | Should -Be 0
        Should -Invoke Invoke-NativeReleaseContext -Times 0 -Exactly
    }

    It 'Get-ReaderList filters by regex and always returns a list' {
        Mock Invoke-NativeListReaders { @{ rc = 0; names = @('HID Global OMNIKEY 5022 Smart Card Reader 0', 'HID Global OMNIKEY 3x21 Smart Card Reader 0') } }
        $one = Get-ReaderList '3x21'
        $one.Count | Should -Be 1
        $one[0] | Should -Be 'HID Global OMNIKEY 3x21 Smart Card Reader 0'
        (Get-ReaderList 'no-such').Count | Should -Be 0
    }

    It 'Invoke-WithReader records connect errors and resets the context' {
        Mock Invoke-NativeConnect { @{ rc = -2146435043; card = [IntPtr]::Zero; proto = 0 } }
        Invoke-WithReader 'r0' { 'never' } $null | Should -BeNullOrEmpty
        $script:lastErr | Should -Be 'connect:0x8010001D'
        Should -Invoke Invoke-NativeReleaseContext -Times 1 -Exactly
    }

    It 'Invoke-WithReader reports escape errors without the SCardControl prefix and always disconnects' {
        Mock Invoke-NativeConnect { @{ rc = 0; card = [IntPtr]7; proto = 0 } }
        Mock Invoke-NativeControl { @{ rc = -2146435049; out = (New-Object byte[] 512); len = 0 } }   # 0x80100017
        Invoke-WithReader 'r0' { param($c) Send-Escape $c $ApduSerial } $null | Should -BeNullOrEmpty
        $script:lastErr | Should -Be 'escape:0x80100017'
        Should -Invoke Disconnect-Card -Times 1 -Exactly
    }

    It 'Send-Escape turns a native error into "SCardControl 0x........"' {
        Mock Invoke-NativeControl { @{ rc = -2146435049; out = (New-Object byte[] 512); len = 0 } }
        { Send-Escape ([IntPtr]7) $ApduSerial } | Should -Throw -ExpectedMessage 'SCardControl 0x80100017'
    }
}
