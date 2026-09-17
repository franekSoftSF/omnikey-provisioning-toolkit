#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# The way back: automatic backups before writes, restore from a backup / profile, factory defaults.
# Pester scoping: variables set in BeforeAll/BeforeEach/BeforeDiscovery are used in other blocks
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    foreach ($f in $ComponentFiles) { . $f }

    function Invoke-Captured([scriptblock]$command) {
        $all = @(& $command 6>&1)
        @{ out = @($all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }); text = Get-HostText $all }
    }
}

Describe 'Backups and restore' {
    BeforeEach {
        Set-MessageLanguage en
        $script:ctx = [IntPtr]::Zero
        $sent = [System.Collections.Generic.List[string]]::new()
        $prompts = [System.Collections.Generic.List[string]]::new()
        $sims = @{ 1 = (New-Reader5022Sim); 2 = (New-Reader3121Sim) }
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
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
        function Initialize-AnswerQueue([object[]]$list) { $script:answerQueue = [System.Collections.Queue]::new($list) }
        Mock Read-Host { $prompts.Add($Prompt); $script:answerQueue.Dequeue() }
    }

    It 'Set with -BackupDir saves the reader settings before writing; without it nothing is saved' {
        [void](Invoke-Captured { Invoke-OmnikeyTool -Mode Set -ProfilePath $ExampleProfile -BackupDir $dir })
        $files = @(Get-ChildItem $dir -Filter *.json)
        $files.Count | Should -Be 1
        $files[0].Name | Should -Match '^OMNIKEY-5022_EXAMPLE0001_\d{8}-\d{6}-\d{3}\.json$'
        $b = Get-Content $files[0].FullName -Raw | ConvertFrom-Json
        $b._backup.product | Should -Be 'OMNIKEY 5022'
        $b._backup.serial | Should -Be 'EXAMPLE0001'
        $b.iso14443a.mifarePreferred | Should -BeTrue
        (ConvertTo-OperationList $b (Resolve-ReaderModel @{ Product = 'OMNIKEY 5022' })).Count | Should -Be 14

        $other = Join-Path $TestDrive 'none'
        [void](Invoke-Captured { Invoke-OmnikeyTool -Mode Set -ProfilePath $ExampleProfile })
        Test-Path $other | Should -BeFalse
    }

    It 'restore from the newest backup writes back only what changed since (and backs up first)' {
        [void](Invoke-Captured { Invoke-OmnikeyTool -Mode Set -ProfilePath $ExampleProfile -BackupDir $dir -NoReboot })   # backup of the original state
        $sent.Clear()
        $sims[1]["${ApduGetPrefix}A202840000"] = 'BD038401009000'     # someone switched mifarePreferred off
        $sims[1]["${ApduGetPrefix}A0028D0000"] = 'BD038D01009000'     # and sleep frequency to 41Hz
        Initialize-AnswerQueue @('', '', 'y')                         # backup source, newest, apply
        $r = Invoke-Captured { Invoke-ReaderRestore '5022' $false 'en' $false '' $dir }
        @($r.out) | Should -Be @(0)
        $r.text | Should -Match ([regex]::Escape('iso14443a.mifarePreferred: False -> True'))
        $r.text | Should -Match ([regex]::Escape('sleepModePollingFrequency: 41Hz -> 0.7Hz'))
        @($sent) | Should -Be @("${ApduSetPrefix}A20384010100", "${ApduSetPrefix}A0038D010600", $ApduApply, $ApduReboot)
        @(Get-ChildItem $dir -Filter *.json).Count | Should -Be 2 -Because 'the state before restoring is backed up too'
    }

    It 'lists only backups of the same model and serial, newest first' {
        [void](New-Item -ItemType Directory -Path $dir)
        $model = Resolve-ReaderModel @{ Product = 'OMNIKEY 5022' }
        foreach ($b in @(
            @{ n = 'a.json'; product = 'OMNIKEY 5022'; serial = 'EXAMPLE0001'; created = '2026-09-17T10:00:00' }
            @{ n = 'b.json'; product = 'OMNIKEY 5022'; serial = 'EXAMPLE0001'; created = '2026-09-17T12:00:00' }
            @{ n = 'c.json'; product = 'OMNIKEY 5022'; serial = 'EXAMPLE0002'; created = '2026-09-17T13:00:00' }
            @{ n = 'd.json'; product = 'OMNIKEY 3121'; serial = '';            created = '2026-09-17T14:00:00' })) {
            @{ _backup = @{ product = $b.product; serial = $b.serial; created = $b.created } } | ConvertTo-Json | Set-Content (Join-Path $dir $b.n)
        }
        'not json' | Set-Content (Join-Path $dir 'broken.json')
        $list = Get-ReaderBackup $dir $model @{ Serial = 'EXAMPLE0001' }
        @($list | ForEach-Object { $_.name }) | Should -Be @('b.json', 'a.json')
        $list[0].created | Should -Be '2026-09-17 12:00:00'
        @((Get-ReaderBackup $dir (Resolve-ReaderModel @{ Product = 'OMNIKEY 3121' }) @{ Serial = $null }) | ForEach-Object { $_.name }) | Should -Be @('d.json')
    }

    It 'without backups it says so and writes nothing' {
        Initialize-AnswerQueue @('1')
        $r = Invoke-Captured { Invoke-ReaderRestore '5022' $false 'en' $false '' $dir }
        @($r.out) | Should -Be @(0)
        $r.text | Should -Match 'No backups of this reader'
        $sent.Count | Should -Be 0
    }

    It 'restore from a profile file given on the command line; nothing to do when the reader matches' {
        Initialize-AnswerQueue @()
        $r = Invoke-Captured { Invoke-ReaderRestore '5022' $false 'en' $false $ExampleProfile $dir }
        @($r.out) | Should -Be @(0)
        $r.text | Should -Match 'already matches'
        $prompts.Count | Should -Be 0
        $sent.Count | Should -Be 0
    }

    It 'factory defaults: "n" writes nothing' {
        Initialize-AnswerQueue @('3', 'n')
        $r = Invoke-Captured { Invoke-ReaderRestore '5022' $false 'en' $false '' $dir }
        $r.text | Should -Match 'reset ALL settings'
        $sent.Count | Should -Be 0
        Test-Path $dir | Should -BeFalse
    }

    It 'factory defaults: backup, RestoreFactoryDefaults, reboot (no reboot with -NoReboot)' {
        Initialize-AnswerQueue @('3', 'tak')
        $r = Invoke-Captured { Invoke-ReaderRestore '3121' $false 'pl' $false '' $dir }
        @($r.out) | Should -Be @(0)
        $prompts[1] | Should -Be 'Przywrocic ustawienia fabryczne w OMNIKEY 3121 teraz? (t/N)'
        @($sent) | Should -Be @($ApduFactoryDefaults, $ApduReboot)
        @(Get-ChildItem $dir -Filter 'OMNIKEY-3121_no-serial_*.json').Count | Should -Be 1

        $sent.Clear()
        Initialize-AnswerQueue @('3', 'y')
        [void](Invoke-Captured { Invoke-ReaderRestore '5022' $false 'en' $true '' $dir })
        @($sent) | Should -Be @($ApduFactoryDefaults)
    }

    It 'an unknown model is refused before any question' {
        $sims[1][$ApduProduct] = New-AsciiResponse '82' 'OMNIKEY 5023'
        Initialize-AnswerQueue @()
        { Invoke-ReaderRestore '5022' $false 'en' $false '' $dir 6>$null } | Should -Throw -ExpectedMessage "*blocked for unknown reader model*"
        $sent.Count | Should -Be 0
    }

    It 'Omnikey.ps1 set / configure / restore pass the backup folder; menu item 9 is restore' {
        Mock Invoke-OmnikeyTool { 0 }
        Mock Invoke-ReaderConfigurator { 0 }
        Mock Invoke-ReaderRestore { 0 }
        [void](Invoke-OmnikeyCli -Command set -ProfilePath p.json -ReaderMatch 5022)
        Should -Invoke Invoke-OmnikeyTool -Times 1 -Exactly -ParameterFilter { $BackupDir -eq '.\omnikey-backups' }
        [void](Invoke-OmnikeyCli -Command configure -ReaderMatch 5022)
        Should -Invoke Invoke-ReaderConfigurator -Times 1 -Exactly -ParameterFilter { $backupDir -eq '.\omnikey-backups' }
        Initialize-AnswerQueue @('9', '0')
        [void](Invoke-Captured { Invoke-OmnikeyCli -ReaderMatch 5022 })
        Should -Invoke Invoke-ReaderRestore -Times 1 -Exactly -ParameterFilter { $backupDir -eq '.\omnikey-backups' -and $interactive -eq $true }
    }
}
