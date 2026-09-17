#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# "configure": questions per supported parameter with the reader's value as default, change summary,
# optional profile file, and only the changed parameters written through the normal Set path.
# Pester scoping: variables set in BeforeAll/BeforeEach/BeforeDiscovery are used in other blocks
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    foreach ($f in $ComponentFiles) { . $f }
    $m5022 = Resolve-ReaderModel @{ Product = 'OMNIKEY 5022' }
    $m3121 = Resolve-ReaderModel @{ Product = 'OMNIKEY 3121'; }

    function Invoke-Captured([scriptblock]$command) {
        $all = @(& $command 6>&1)
        @{ out = @($all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }); text = Get-HostText $all }
    }
}

Describe 'Configure questions' {
    It 'every profile key has a question and an EN/PL description' {
        @($script:ConfigQuestions | ForEach-Object { $_.key }) | Should -Be (@($script:ContactlessKeys) + @($script:ContactKeys))
        foreach ($q in $script:ConfigQuestions) {
            $script:MSG.en.ContainsKey("q.$($q.key)") | Should -BeTrue -Because $q.key
            $script:MSG.pl.ContainsKey("q.$($q.key)") | Should -BeTrue -Because $q.key
        }
    }

    It 'parses <type> answer "<answer>"' -ForEach @(
        @{ type = 'bool';  answer = 'y';           ok = $true;  value = $true }
        @{ type = 'bool';  answer = 'TAK';         ok = $true;  value = $true }
        @{ type = 'bool';  answer = 'nie';         ok = $true;  value = $false }
        @{ type = 'bool';  answer = 'maybe';       ok = $false; value = $null }
        @{ type = 'rates'; answer = '424, 212';    ok = $true;  value = @(212, 424) }
        @{ type = 'rates'; answer = '106 848';     ok = $true;  value = @(848) }
        @{ type = 'rates'; answer = '999';         ok = $false; value = $null }
        @{ type = 'freq';  answer = '7';           ok = $true;  value = '0.7Hz' }
        @{ type = 'freq';  answer = '0.08hz';      ok = $true;  value = '0.08Hz' }
        @{ type = 'freq';  answer = '11';          ok = $false; value = $null }
        @{ type = 'poll';  answer = 'ISO14443A iclass'; ok = $true; value = @('iso14443a', 'iclass') }
        @{ type = 'poll';  answer = 'iso14443a,nfc';    ok = $false; value = $null }
        @{ type = 'mode';  answer = '2';           ok = $true;  value = 'emvco' }
        @{ type = 'mode';  answer = 'ISO7816';     ok = $true;  value = 'iso7816' }
        @{ type = 'volt';  answer = 'auto';        ok = $true;  value = 'auto' }
        @{ type = 'volt';  answer = '3v, 1.8V';    ok = $true;  value = @('3V', '1.8V') }
        @{ type = 'volt';  answer = '5V,5V';       ok = $false; value = $null }
    ) {
        $r = ConvertFrom-ConfigAnswer $type $answer $null $m3121 @(212, 424, 848)
        $r.ok | Should -Be $ok
        if ($ok) { @($r.value) | Should -Be @($value) }
    }

    It 'an empty answer keeps the current value, including an empty rate list' {
        (ConvertFrom-ConfigAnswer 'bool' '' $false $m5022 $null).value | Should -BeFalse
        $r = ConvertFrom-ConfigAnswer 'rates' '  ' @() $m5022 @(212)
        $r.ok | Should -BeTrue
        $null -eq $r.value | Should -BeFalse
        @($r.value).Count | Should -Be 0
        (ConvertFrom-ConfigAnswer 'rates' '-' @(212) $m5022 @(212)).value.Count | Should -Be 0
    }

    It 'formats values for the prompts and the change summary' {
        Format-ConfigValue 'baud' @{ rx = @(); tx = @(212, 424) } | Should -Be 'rx:- tx:212,424'
        Format-ConfigValue 'volt' 'auto' | Should -Be 'auto'
        Format-ConfigValue 'volt' @('5V', '3V') | Should -Be '5V,3V'
        Format-ConfigValue 'bool' $false | Should -Be 'False'
        Format-ConfigValue 'freq' $null | Should -Be '?'
    }
}

Describe 'Invoke-ReaderConfigurator' {
    BeforeEach {
        Set-MessageLanguage en
        $script:ctx = [IntPtr]::Zero
        $sent = [System.Collections.Generic.List[string]]::new()
        $prompts = [System.Collections.Generic.List[string]]::new()
        $sims = @{ 1 = (New-Reader5022Sim); 2 = (New-Reader3121Sim) }
        Mock Invoke-NativeEstablishContext { @{ rc = 0; ctx = [IntPtr]42 } }
        Mock Invoke-NativeReleaseContext { }
        Mock Invoke-NativeListReaders { @{ rc = 0; names = @('HID Global OMNIKEY 3x21 Smart Card Reader 0', 'HID Global OMNIKEY 5022 Smart Card Reader 0') } }
        Mock Invoke-NativeConnect { @{ rc = 0; card = [IntPtr]$(if ($reader -match '5022') { 1 } else { 2 }); proto = 0 } }
        Mock Disconnect-Card { }
        Mock Start-Sleep { }
        Mock Send-Escape {
            if (Test-IsWriteApdu $apdu) { $sent.Add($apdu); return '9000' }
            $s = $sims[[int]$card]
            if ($s.ContainsKey($apdu)) { $s[$apdu] } else { '9E0202049000' }
        }
        function Initialize-AnswerQueue([object[]]$list) {
            $script:answerQueue = [System.Collections.Queue]::new($list)
        }
        Mock Read-Host { $prompts.Add($Prompt); $script:answerQueue.Dequeue() }
    }

    It 'OMNIKEY 5022: Enter on every question changes nothing and writes nothing' {
        Initialize-AnswerQueue (@('') * 17 + @(''))                       # 14 parameters (3 baud = rx + tx) + save
        $r = Invoke-Captured { Invoke-ReaderConfigurator '5022' $false 'en' $false }
        @($r.out) | Should -Be @(0)
        $prompts.Count | Should -Be 18
        $prompts[0] | Should -Be 'iso14443a.enabled [True] (y/n)'
        $prompts[3] | Should -Be 'iso14443a.baud rx kbps [212,424] (list of 212 424 848; - = none; 106 is always on)'
        $prompts[10] | Should -Be 'felica.baud rx kbps [212] (list of 212 424; - = none; 106 is always on)'
        $prompts[15] | Should -Match '^sleepModePollingFrequency \[0\.7Hz\] \(1=41Hz .*7=0\.7Hz'
        $prompts[16] | Should -Match '^pollingSearchOrder \[iso14443a,iso14443b,iclass,felica,iso15693\]'
        $r.text | Should -Match 'CONFIGURE OMNIKEY 5022'
        $r.text | Should -Match 'Present dual-interface cards as MIFARE Classic'
        $r.text | Should -Match 'No changes.'
        $sent.Count | Should -Be 0
    }

    It 'OMNIKEY 5022: writes only the changed parameters and saves the full profile' {
        $answers = @('') * 17
        $answers[1] = 'n'          # mifarePreferred
        $answers[4] = '212'        # 14443A tx
        $answers[15] = '1'         # sleep frequency 41Hz
        $saved = Join-Path $TestDrive 'configured.json'
        Initialize-AnswerQueue ($answers + @($saved, 'y'))
        $r = Invoke-Captured { Invoke-ReaderConfigurator '5022' $false 'en' $false }
        @($r.out) | Should -Be @(0)
        $r.text | Should -Match ([regex]::Escape('iso14443a.mifarePreferred: True -> False'))
        $r.text | Should -Match ([regex]::Escape('iso14443a.baud: rx:212,424 tx:212,424 -> rx:212,424 tx:212'))
        $r.text | Should -Match ([regex]::Escape('sleepModePollingFrequency: 0.7Hz -> 41Hz'))
        $prompts[-1] | Should -Be 'Write 3 change(s) to the reader now (Apply + reboot)? (y/N)'
        @($sent) | Should -Be @("${ApduSetPrefix}A20384010000", "${ApduSetPrefix}A20381013100", "${ApduSetPrefix}A0038D010000", $ApduApply, $ApduReboot)

        $p = Get-Content $saved -Raw | ConvertFrom-Json
        $p.iso14443a.mifarePreferred | Should -BeFalse
        @($p.iso14443a.tx) | Should -Be @(212)
        $p.sleepModePollingFrequency | Should -Be '41Hz'
        $p.emdSuppression | Should -BeTrue
        (ConvertTo-OperationList $p $m5022).Count | Should -Be 14
    }

    It 'answering no to the last question writes nothing' {
        $answers = @('') * 17; $answers[0] = 'n'
        Initialize-AnswerQueue ($answers + @('', 'n'))
        $r = Invoke-Captured { Invoke-ReaderConfigurator '5022' $false 'en' $false }
        @($r.out) | Should -Be @(0)
        $r.text | Should -Match 'Nothing was written to the reader.'
        $sent.Count | Should -Be 0
    }

    It 'removing all extra bit rates writes 106 kbps only' {
        $answers = @('') * 17; $answers[3] = '-'; $answers[4] = '-'
        Initialize-AnswerQueue ($answers + @('', 'y'))
        [void](Invoke-Captured { Invoke-ReaderConfigurator '5022' $false 'en' $false })
        @($sent) | Should -Be @("${ApduSetPrefix}A20381010000", $ApduApply, $ApduReboot)
    }

    It 'OMNIKEY 3121: asks only contact slot questions; EMVCo skips the voltage question' {
        Initialize-AnswerQueue @('', '2', '', 't')                         # enabled, mode=emvco, save, apply
        $r = Invoke-Captured { Invoke-ReaderConfigurator '3121' $false 'pl' $false }
        @($r.out) | Should -Be @(0)
        $prompts.Count | Should -Be 4
        $prompts[0] | Should -Be 'contactSlot.enabled [True] (t/n)'
        $prompts[1] | Should -Be 'contactSlot.operatingMode [iso7816] (1=iso7816 2=emvco)'
        $r.text | Should -Match 'KONFIGURACJA OMNIKEY 3121'
        @($sent) | Should -Be @("${ApduContactSetPrefix}83010100", $ApduApply, $ApduReboot)
    }

    It 'OMNIKEY 3121: voltage sequence "auto" can be chosen in ISO 7816 mode' {
        Initialize-AnswerQueue @('', '', 'auto', '', 'y')
        [void](Invoke-Captured { Invoke-ReaderConfigurator '3121' $false 'en' $false })
        $prompts[2] | Should -Be 'contactSlot.voltageSequence [5V,3V,1.8V] (comma-separated: 5V 3V 1.8V | auto)'
        @($sent) | Should -Be @("${ApduContactSetPrefix}82010000", $ApduApply, $ApduReboot)
    }

    It 'three invalid answers stop without writing' {
        Initialize-AnswerQueue @('maybe', 'perhaps', 'dunno')
        { Invoke-ReaderConfigurator '5022' $false 'en' $false 6>$null } | Should -Throw -ExpectedMessage "Unknown choice: 'dunno'"
        $sent.Count | Should -Be 0
    }

    It 'an unknown reader model is refused before any question' {
        $sims[1][$ApduProduct] = New-AsciiResponse '82' 'OMNIKEY 5023'
        Initialize-AnswerQueue @()
        { Invoke-ReaderConfigurator '5022' $false 'en' $false 6>$null } | Should -Throw -ExpectedMessage "*blocked for unknown reader model 'OMNIKEY 5023'*"
        $prompts.Count | Should -Be 0
        $sent.Count | Should -Be 0
    }
}
