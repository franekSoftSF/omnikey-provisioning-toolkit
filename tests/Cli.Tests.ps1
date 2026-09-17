#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Invoke-OmnikeyTool (CheckProfile5022.ps1) and Invoke-OmnikeyCli (Omnikey.ps1) against simulated
# readers: exit codes, write safety, and console text compared with output recorded on real
# OMNIKEY 5022 / 3121 hardware (tests/fixtures, serial masked).
# Pester scoping: variables set in BeforeAll/BeforeEach/BeforeDiscovery are used in other blocks
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    foreach ($f in $ComponentFiles) { . $f }

    $name5022 = 'HID Global OMNIKEY 5022 Smart Card Reader 0'
    $name3121 = 'HID Global OMNIKEY 3x21 Smart Card Reader 0'
    $nameOther = 'Yubico YubiKey OTP+FIDO+CCID 0'

    # runs a command, returns @{ code; text; out } with Write-Host output captured
    function Invoke-Captured([scriptblock]$command) {
        $all = @(& $command 6>&1)
        @{
            out  = @($all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
            text = Get-HostText $all
        }
    }
}

Describe 'Invoke-OmnikeyTool (CheckProfile5022.ps1)' {
    BeforeEach {
        Set-MessageLanguage en
        $script:ctx = [IntPtr]::Zero
        $sent = [System.Collections.Generic.List[string]]::new()
        $readerNames = @($name3121, $name5022, $nameOther)
        $sims = @{ 1 = (New-Reader5022Sim); 2 = (New-Reader3121Sim) }
        Mock Invoke-NativeEstablishContext { @{ rc = 0; ctx = [IntPtr]42 } }
        Mock Invoke-NativeReleaseContext { }
        Mock Invoke-NativeListReaders { @{ rc = 0; names = $readerNames } }
        Mock Invoke-NativeConnect { @{ rc = 0; card = [IntPtr]$(if ($reader -match '5022') { 1 } else { 2 }); proto = 2 } }
        Mock Disconnect-Card { }
        Mock Start-Sleep { }
        Mock Send-Escape {
            if (Test-IsWriteApdu $apdu) { $sent.Add($apdu); return '9000' }
            $s = $sims[[int]$card]
            if ($s.ContainsKey($apdu)) { $s[$apdu] } else { '9E0202049000' }
        }
    }

    It 'Get on OMNIKEY 5022 prints exactly what v1.0 printed on hardware (<lang>)' -ForEach @(
        @{ lang = 'en' }, @{ lang = 'pl' }
    ) {
        $r = Invoke-Captured { Invoke-OmnikeyTool -Mode Get -Lang $lang }
        @($r.out) | Should -Be @(0)
        $r.text | Should -BeExactly (Get-FixtureText "get-5022-$lang.txt")
        $sent.Count | Should -Be 0
    }

    It 'Verify of the example profile prints exactly what v1.0 printed on hardware (<lang>) and exits 0' -ForEach @(
        @{ lang = 'en' }, @{ lang = 'pl' }
    ) {
        $r = Invoke-Captured { Invoke-OmnikeyTool -Mode Verify -ProfilePath $ExampleProfile -Lang $lang }
        @($r.out) | Should -Be @(0)
        $r.text | Should -BeExactly (Get-FixtureText "verify-5022-$lang.txt")
        $sent.Count | Should -Be 0
    }

    It 'Set prints the hardware-recorded text and sends SETs, Apply and Reboot' {
        $r = Invoke-Captured { Invoke-OmnikeyTool -Mode Set -ProfilePath $ExampleProfile }
        @($r.out) | Should -Be @(0)
        $r.text | Should -BeExactly (Get-FixtureText 'set-5022-en.txt')
        @($sent) | Should -Be (@($ExampleProfileSetApdus) + $ApduApply + $ApduReboot)
    }

    It 'Set -NoReboot applies without rebooting' {
        $r = Invoke-Captured { Invoke-OmnikeyTool -Mode Set -ProfilePath $ExampleProfile -NoReboot }
        @($r.out) | Should -Be @(0)
        $sent | Should -Contain $ApduApply
        $sent | Should -Not -Contain $ApduReboot
        $r.text | Should -Match 'Reboot skipped'
    }

    It 'Get on OMNIKEY 3121 prints its contact slot configuration (recorded on hardware)' {
        $r = Invoke-Captured { Invoke-OmnikeyTool -Mode Get -ReaderMatch '3x21' }
        @($r.out) | Should -Be @(0)
        $r.text | Should -BeExactly (Get-FixtureText 'get-3121-en.txt')
    }

    It 'Verify with a mismatch exits 2 and keeps the v1.0 FAIL line format' {
        $sims[1]["${ApduGetPrefix}A202840000"] = 'BD038401009000'
        $r = Invoke-Captured { Invoke-OmnikeyTool -Mode Verify -ProfilePath $ExampleProfile }
        @($r.out) | Should -Be @(2)
        $r.text | Should -Match ([regex]::Escape('  [FAIL] iso14443a.mifarePreferred: expected True, reader has , reader: False'))
        $r.text | Should -Match ([regex]::Escape('AUDIT RESULT: FAIL (1/14 mismatches)'))
    }

    It 'Set with a rejected parameter exits 1 (Apply is still sent, as in v1.0)' {
        Mock Send-Escape {
            if ($apdu -eq "${ApduSetPrefix}A00387010100") { return '6A80' }
            if (Test-IsWriteApdu $apdu) { $sent.Add($apdu); return '9000' }
            $sims[[int]$card][$apdu]
        }
        $r = Invoke-Captured { Invoke-OmnikeyTool -Mode Set -ProfilePath $ExampleProfile }
        @($r.out) | Should -Be @(1)
        $r.text | Should -Match ([regex]::Escape('  [ERROR] emdSuppression: 6A80'))
        $sent | Should -Contain $ApduApply
    }

    It 'Set of a contactless profile on OMNIKEY 3121 throws before any write' {
        { Invoke-OmnikeyTool -Mode Set -ProfilePath $ExampleProfile -ReaderMatch '3x21' 6>$null } |
            Should -Throw -ExpectedMessage '*iso14443a.enabled: not supported by OMNIKEY 3121*'
        $sent.Count | Should -Be 0
    }

    It 'Set of a contact profile on OMNIKEY 3121 writes the contact slot' {
        $p = Join-Path $TestDrive 'contact.json'
        '{"contactSlot":{"operatingMode":"emvco"}}' | Set-Content $p
        $r = Invoke-Captured { Invoke-OmnikeyTool -Mode Set -ProfilePath $p -ReaderMatch '3x21' }
        @($r.out) | Should -Be @(0)
        @($sent) | Should -Be @("${ApduContactSetPrefix}83010100", $ApduApply, $ApduReboot)
    }

    It 'Set on an unknown reader model throws before any write' {
        $sims[1][$ApduProduct] = New-AsciiResponse '82' 'OMNIKEY 5023'
        { Invoke-OmnikeyTool -Mode Set -ProfilePath $ExampleProfile 6>$null } |
            Should -Throw -ExpectedMessage "*blocked for unknown reader model 'OMNIKEY 5023'*"
        $sent.Count | Should -Be 0
    }

    It 'Get on an unknown model prints a note and still reads' {
        $sims[1][$ApduProduct] = New-AsciiResponse '82' 'OMNIKEY 5023'
        $r = Invoke-Captured { Invoke-OmnikeyTool -Mode Get }
        @($r.out) | Should -Be @(0)
        $r.text | Should -Match "reader model 'OMNIKEY 5023' is not in the toolkit's model registry"
        $r.text | Should -Match 'iso14443a.enabled\s+True'
    }

    It 'Export writes the profile and prints the batch hint' {
        $out = Join-Path $TestDrive 'exported.json'
        $r = Invoke-Captured { Invoke-OmnikeyTool -Mode Export -OutProfile $out }
        @($r.out) | Should -Be @(0)
        Test-Path $out | Should -BeTrue
        $r.text | Should -Match 'Profile exported to: '
        $sent.Count | Should -Be 0
    }

    It 'throws <case>' -ForEach @(
        @{ case = 'when the Smart Card service is missing'; msg = 'Smart Card service not available.' }
        @{ case = 'when no reader matches';                 msg = "No reader matching 'no-such'*Yubico*" }
        @{ case = 'when -Profile is missing';               msg = '-Profile <file.json> is required for mode Verify.' }
        @{ case = 'when the profile is not JSON';           msg = 'Cannot parse profile: *' }
    ) {
        switch -Wildcard ($case) {
            '*service*'   { Mock Invoke-NativeEstablishContext { @{ rc = -2146435043; ctx = [IntPtr]::Zero } }; $cmd = { Invoke-OmnikeyTool -Mode Get }; break }
            '*no reader*' { $cmd = { Invoke-OmnikeyTool -Mode Get -ReaderMatch 'no-such' }; break }
            '*missing'    { $cmd = { Invoke-OmnikeyTool -Mode Verify }; break }
            '*not JSON'   { $cmd = { Invoke-OmnikeyTool -Mode Verify -ProfilePath (Join-Path $RepoRoot 'LICENSE') } }
        }
        { & $cmd 6>$null } | Should -Throw -ExpectedMessage $msg
        $sent.Count | Should -Be 0
    }

    Context 'TestCard' {
        BeforeEach {
            Mock Get-CardAtr { $atr }
            Mock Send-Apdu { '04A1B2C3D4E5F69000' }
        }

        It 'exits 1 on timeout' {
            Mock Invoke-NativeConnect { if ($share -eq 3) { @{ rc = 0; card = [IntPtr]1; proto = 0 } } else { @{ rc = -2146434967; card = [IntPtr]::Zero; proto = 0 } } }
            $r = Invoke-Captured { Invoke-OmnikeyTool -Mode TestCard -CardTimeout 0 }
            @($r.out) | Should -Be @(1)
            $r.text | Should -Match 'TIMEOUT - no card presented.'
        }

        It 'exits 0 for a MIFARE Classic card on the 5022' {
            $atr = New-StorageAtr '0001'
            $r = Invoke-Captured { Invoke-OmnikeyTool -Mode TestCard -CardTimeout 1 }
            @($r.out) | Should -Be @(0)
            $r.text | Should -Match 'Reader mifarePreferred: ENABLED'
            $r.text | Should -Match 'UID: 04A1B2C3D4E5F6'
            $r.text | Should -Match 'Card identified as: MIFARE Classic 1K'
        }

        It 'exits 2 for a CPU card on the 5022 with the mifarePreferred hint' {
            $atr = '3B8180018080'
            $r = Invoke-Captured { Invoke-OmnikeyTool -Mode TestCard -CardTimeout 1 }
            @($r.out) | Should -Be @(2)
            $r.text | Should -Match 'mifarePreferred is ENABLED'
        }

        It 'exits 0 for a contact card on the 3121, without contactless lines' {
            $atr = '3BFF1300008131FE45'
            $r = Invoke-Captured { Invoke-OmnikeyTool -Mode TestCard -CardTimeout 1 -ReaderMatch '3x21' }
            @($r.out) | Should -Be @(0)
            $r.text | Should -Match 'Card identified as: contact smart card \(ISO 7816\), protocol T=1'
            $r.text | Should -Not -Match 'mifarePreferred'
            $r.text | Should -Not -Match 'UID'
        }
    }
}

Describe 'Invoke-OmnikeyCli (Omnikey.ps1)' {
    BeforeEach {
        Set-MessageLanguage en
        $script:ctx = [IntPtr]::Zero
        $readerNames = @($name3121, $name5022, $nameOther)
        Mock Invoke-NativeEstablishContext { @{ rc = 0; ctx = [IntPtr]42 } }
        Mock Invoke-NativeReleaseContext { }
        Mock Invoke-NativeListReaders { @{ rc = 0; names = $readerNames } }
        Mock Invoke-OmnikeyTool { 7 }
        Mock Invoke-OmnikeyBatch { 0 }
    }

    It 'maps <command> to Invoke-OmnikeyTool -Mode <mode>' -ForEach @(
        @{ command = 'get'; mode = 'Get' }, @{ command = 'verify'; mode = 'Verify' }, @{ command = 'set'; mode = 'Set' }
        @{ command = 'export'; mode = 'Export' }, @{ command = 'TestCard'; mode = 'TestCard' }
    ) {
        Invoke-OmnikeyCli -Command $command -ProfilePath 'p.json' -ReaderMatch '5022' | Should -Be 7
        Should -Invoke Invoke-OmnikeyTool -Times 1 -Exactly -ParameterFilter { $Mode -eq $mode -and $ReaderMatch -eq '5022' }
    }

    It 'without -ReaderMatch uses the single OMNIKEY reader, matched exactly' {
        $readerNames = @($name5022, $nameOther)
        Invoke-OmnikeyCli -Command get | Should -Be 7
        Should -Invoke Invoke-OmnikeyTool -Times 1 -Exactly -ParameterFilter { $ReaderMatch -eq ('^' + [regex]::Escape($name5022) + '$') }
    }

    It 'without -ReaderMatch refuses to guess between several OMNIKEY readers' {
        { Invoke-OmnikeyCli -Command get } | Should -Throw -ExpectedMessage "Several readers found*$name3121*$name5022*"
        Should -Invoke Invoke-OmnikeyTool -Times 0 -Exactly
    }

    It 'accepts a model id as -ReaderMatch (3121 enumerates as "OMNIKEY 3x21")' {
        Invoke-OmnikeyCli -Command get -ReaderMatch 3121 | Should -Be 7
        Should -Invoke Invoke-OmnikeyTool -Times 1 -Exactly -ParameterFilter { $ReaderMatch -eq [regex]::Escape('OMNIKEY 3x21') }
    }

    It 'rejects parameters that do not belong to the command' {
        { Invoke-OmnikeyCli -Command get -Loop -Bound @('Command', 'Loop') } | Should -Throw -ExpectedMessage "-Loop cannot be used with 'get'."
        { Invoke-OmnikeyCli -Command verify -ProfilePath p.json -LogCsv x.csv -Bound @('Command', 'ProfilePath', 'LogCsv') } | Should -Throw -ExpectedMessage "-LogCsv cannot be used with 'verify'."
        Should -Invoke Invoke-OmnikeyTool -Times 0 -Exactly
    }

    It 'requires a profile for <command>' -ForEach @(@{ command = 'verify' }, @{ command = 'set' }, @{ command = 'batch' }) {
        { Invoke-OmnikeyCli -Command $command } | Should -Throw -ExpectedMessage "-Profile <file.json> is required for mode $command."
    }

    It 'batch runs the station on all OMNIKEY readers by default' {
        Invoke-OmnikeyCli -Command batch -ProfilePath p.json -LogCsv prov.csv | Should -Be 0
        Should -Invoke Invoke-OmnikeyBatch -Times 1 -Exactly -ParameterFilter { $ReaderMatch -eq 'OMNIKEY' -and $LogCsv -eq 'prov.csv' -and $ProfilePath -eq 'p.json' }
    }

    It 'the menu runs the chosen command' {
        $answers = [System.Collections.Queue]::new([object[]]@('2', '"p.json"'))
        Mock Read-Host { $answers.Dequeue() }
        $r = Invoke-Captured { Invoke-OmnikeyCli -ReaderMatch 5022 }
        @($r.out) | Should -Be @(7)
        Should -Invoke Invoke-OmnikeyTool -Times 1 -Exactly -ParameterFilter { $Mode -eq 'Verify' -and $ProfilePath -eq 'p.json' }
    }

    It 'the menu exits with 0 on "0" and rejects unknown choices' {
        Mock Read-Host { '0' }
        (Invoke-Captured { Invoke-OmnikeyCli }).out | Should -Be @(0)
        Mock Read-Host { '9' }
        { Invoke-OmnikeyCli 6>$null } | Should -Throw -ExpectedMessage "Unknown choice: '9'"
        Should -Invoke Invoke-OmnikeyTool -Times 0 -Exactly
    }

    It 'readers lists every OMNIKEY reader with model, firmware and what can be configured' {
        $nameCrescendo = 'HID Global Crescendo NFC Reader 0'
        $readerNames = @($nameCrescendo, $name3121, $name5022, $nameOther)
        $sims = @{ 1 = (New-Reader5022Sim); 2 = (New-Reader3121Sim) }
        Mock Invoke-NativeConnect { @{ rc = 0; card = [IntPtr]$(if ($reader -match '5022') { 1 } else { 2 }); proto = 0 } }
        Mock Disconnect-Card { }
        Mock Send-Escape { $s = $sims[[int]$card]; if ($s.ContainsKey($apdu)) { $s[$apdu] } else { '9E0202049000' } }
        $r = Invoke-Captured { Invoke-OmnikeyCli -Command readers }
        @($r.out) | Should -Be @(0)
        Should -Invoke Invoke-NativeConnect -Times 0 -Exactly -ParameterFilter { $reader -notmatch 'OMNIKEY' } -Because 'no escape commands to non-OMNIKEY readers'
        $r.text | Should -BeExactly (@(
            $nameCrescendo
            '    not an OMNIKEY reader - no configuration commands are sent to it (none published by HID)'
            $name3121
            '    model: OMNIKEY 3121  fw: 1.6.0  serial: ?'
            '    contactless slot: no  contact slot: yes  configuration: supported'
            $name5022
            '    model: OMNIKEY 5022  fw: 2.0.0  serial: EXAMPLE0001'
            '    contactless slot: yes  contact slot: no  configuration: supported'
        ) -join "`n")
    }
}
