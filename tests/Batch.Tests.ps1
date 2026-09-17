#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Batch station building blocks against simulated readers: unit decision, apply, post-reboot
# verification matched by serial, CSV audit trail and resume state. No hardware, no winscard.
# Pester scoping: variables set in BeforeAll/BeforeEach/BeforeDiscovery are used in other blocks
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    foreach ($f in $ComponentFiles) { . $f }
    Set-MessageLanguage en
    $ops = ConvertTo-OperationList (Get-Content $ExampleProfile -Raw | ConvertFrom-Json)

    function Get-SerialSim([string]$serial) { $s = New-Reader5022Sim; $s[$ApduSerial] = New-AsciiResponse '92' $serial; $s }
}

Describe 'Batch units' {
    BeforeEach {
        $script:ctx = [IntPtr]::Zero; $script:ctxResets = 0
        $sent = [System.Collections.Generic.List[string]]::new()
        # reader name -> card handle -> simulated reader
        $handles = @{ 'R1' = 1; 'R2' = 2 }
        $sims = @{ 1 = (Get-SerialSim 'EXAMPLE0001'); 2 = (Get-SerialSim 'EXAMPLE0002') }
        Mock Invoke-NativeEstablishContext { @{ rc = 0; ctx = [IntPtr]42 } }
        Mock Invoke-NativeReleaseContext { }
        Mock Invoke-NativeConnect { @{ rc = 0; card = [IntPtr]$handles[$reader]; proto = 0 } }
        Mock Disconnect-Card { }
        Mock Start-Sleep { }
        Mock Send-Escape {
            $s = $sims[[int]$card]
            if (Test-IsWriteApdu $apdu) { $sent.Add("$([int]$card):$apdu"); return '9000' }
            if ($s.ContainsKey($apdu)) { $s[$apdu] } else { '6A80' }
        }
    }

    It 'a compliant unit is PASS "already compliant" without any write' {
        $state = Get-BatchUnitState 'R1' $ops
        $state.Supported | Should -BeTrue
        $state.Compliant | Should -BeTrue
        $entry = Invoke-BatchUnitApply 'R1' $ops $state
        $entry.status | Should -Be 'PASS'; $entry.detail | Should -Be 'already compliant'; $entry.verified | Should -BeTrue
        $sent.Count | Should -Be 0
    }

    It 'a non-compliant unit gets every SET, Apply and Reboot and waits for verification' {
        $sims[1]["${ApduGetPrefix}A202840000"] = 'BD038401009000'
        $state = Get-BatchUnitState 'R1' $ops
        $state.Compliant | Should -BeFalse
        @($state.Bad) | Should -Be @('iso14443a.mifarePreferred')
        $entry = Invoke-BatchUnitApply 'R1' $ops $state
        $entry.status | Should -Be 'PENDING'; $entry.verified | Should -BeFalse
        @($sent) | Should -Be (@($ExampleProfileSetApdus) + $ApduApply + $ApduReboot | ForEach-Object { "1:$_" })
    }

    It 'a rejected SET is FAIL with the parameter and reader status, without Apply/Reboot' {
        $sims[1]["${ApduGetPrefix}A202840000"] = 'BD038401009000'
        Mock Send-Escape {
            if ($apdu -eq "${ApduSetPrefix}A00387010100") { return '6A80' }
            if (Test-IsWriteApdu $apdu) { $sent.Add($apdu); return '9000' }
            $sims[[int]$card][$apdu]
        }
        $entry = Invoke-BatchUnitApply 'R1' $ops (Get-BatchUnitState 'R1' $ops)
        $entry.status | Should -Be 'FAIL'
        $entry.detail | Should -Be 'apply: emdSuppression(6A80)'
        $sent | Should -Not -Contain $ApduApply
    }

    It 'a unit of an unknown model is FAIL "unsupported model" and never written' {
        $sims[1][$ApduProduct] = New-AsciiResponse '82' 'OMNIKEY 5023'
        $sims[1]["${ApduGetPrefix}A202840000"] = 'BD038401009000'
        $state = Get-BatchUnitState 'R1' $ops
        $state.Supported | Should -BeFalse
        $entry = Invoke-BatchUnitApply 'R1' $ops $state
        $entry.status | Should -Be 'FAIL'; $entry.detail | Should -Be 'unsupported model: OMNIKEY 5023'
        $sent.Count | Should -Be 0
    }

    It 'a reader without a serial number (OMNIKEY 3121) is a read error naming the product' {
        $sims[1] = New-Reader3121Sim
        Get-BatchUnitState 'R1' $ops | Should -BeNullOrEmpty
        $script:lastErr | Should -Be 'no-serial:OMNIKEY 3121'
        $sent.Count | Should -Be 0
    }

    It 'verification matches units by serial even when the reader order changes' {
        $batch = @{
            'EXAMPLE0001' = @{ id = @{ Serial = 'EXAMPLE0001' }; status = 'PENDING'; detail = ''; verified = $false }
            'EXAMPLE0002' = @{ id = @{ Serial = 'EXAMPLE0002' }; status = 'PENDING'; detail = ''; verified = $false }
        }
        $handles = @{ 'R1' = 2; 'R2' = 1 }                       # USB indices shuffled after reboot
        Mock Invoke-NativeListReaders { @{ rc = 0; names = @('R2', 'R1') } }
        Invoke-BatchVerify $batch $ops '' 10 5 100
        $batch['EXAMPLE0001'].status | Should -Be 'PASS'; $batch['EXAMPLE0001'].detail | Should -Be 'configured and verified'
        $batch['EXAMPLE0002'].status | Should -Be 'PASS'
        $sent.Count | Should -Be 0
    }

    It 'verification reports a mismatch after reboot by parameter name' {
        $batch = @{ 'EXAMPLE0001' = @{ id = @{ Serial = 'EXAMPLE0001' }; status = 'PENDING'; detail = ''; verified = $false } }
        $sims[1]["${ApduGetPrefix}A0028D0000"] = 'BD038D01009000'
        Mock Invoke-NativeListReaders { @{ rc = 0; names = @('R1') } }
        Invoke-BatchVerify $batch $ops '' 10 5 100
        $batch['EXAMPLE0001'].status | Should -Be 'FAIL'
        $batch['EXAMPLE0001'].detail | Should -Be 'mismatch: sleepModePollingFrequency'
    }

    It 'a unit that never comes back is FAIL with the diagnostic trace (and one context kick)' {
        $batch = @{ 'EXAMPLE0009' = @{ id = @{ Serial = 'EXAMPLE0009' }; status = 'PENDING'; detail = ''; verified = $false } }
        Mock Invoke-NativeListReaders { @{ rc = 0; names = @('R2') } }
        Invoke-BatchVerify $batch $ops '' 10 4 100
        $batch['EXAMPLE0009'].detail | Should -Be 'verify failed: scans:4 maxReaders:1 serialsSeen:[EXAMPLE0002] errors:[] ctxResets:1'
    }
}

Describe 'Batch CSV' {
    It 'writes the header once and one ";"-separated line per unit, with the inventory number' {
        $csv = Join-Path $TestDrive 'prov.csv'
        Mock Get-Date { '2026-09-17T10:00:00' }
        $inv = @{ 'EXAMPLE0001' = 'INV-42' }
        Write-ProvisioningLog $csv $inv @{ Serial = 'EXAMPLE0001'; Product = 'OMNIKEY 5022'; Fw = '2.0.0' } 'PASS' 'already compliant'
        Write-ProvisioningLog $csv $inv @{ Serial = 'UNKNOWN'; Product = '?'; Fw = '?' } 'FAIL' 'read error (R1 / connect:0x80100069)'
        @(Get-Content $csv) | Should -Be @(
            'timestamp;serial;product_name;firmware;inventory_number;result;detail'
            '2026-09-17T10:00:00;EXAMPLE0001;OMNIKEY 5022;2.0.0;INV-42;PASS;already compliant'
            '2026-09-17T10:00:00;UNKNOWN;?;?;;FAIL;read error (R1 / connect:0x80100069)'
        )
    }

    It 'resume state contains only PASS serials; the inventory map is read from serial;inventory_number' {
        $csv = Join-Path $TestDrive 'resume.csv'
        @('timestamp;serial;product_name;firmware;inventory_number;result;detail'
          '2026-09-17T10:00:00;EXAMPLE0001;OMNIKEY 5022;2.0.0;;PASS;already compliant'
          '2026-09-17T10:01:00;EXAMPLE0002;OMNIKEY 5022;2.0.0;;FAIL;mismatch: emdSuppression') | Set-Content $csv
        $done = Read-ResumeState $csv
        @($done.Keys) | Should -Be @('EXAMPLE0001')
        (Read-ResumeState (Join-Path $TestDrive 'missing.csv')).Count | Should -Be 0

        $map = Join-Path $TestDrive 'inv.csv'
        @('serial;inventory_number', 'EXAMPLE0001;INV-1', ';INV-X') | Set-Content $map
        $inv = Read-InventoryMap $map
        $inv.Count | Should -Be 1
        $inv['EXAMPLE0001'] | Should -Be 'INV-1'
        (Read-InventoryMap '').Count | Should -Be 0
    }
}
