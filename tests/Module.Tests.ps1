#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# The real module wiring: manifest, exports, private functions staying private, and a module-scoped
# smoke run of Invoke-OmnikeyTool with mocked PC/SC. This file does NOT dot-source the components.
# Pester scoping: variables set in BeforeAll/BeforeEach/BeforeDiscovery are used in other blocks
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $module = Import-Module $ModuleManifest -Force -PassThru
}

AfterAll {
    Remove-Module OmnikeyToolkit -Force -ErrorAction SilentlyContinue
}

Describe 'OmnikeyToolkit module' {
    It 'has a valid manifest (PowerShell 5.1+) and exports exactly the three entry points' {
        $m = Test-ModuleManifest $ModuleManifest
        $m.PowerShellVersion | Should -Be ([version]'5.1')
        @($module.ExportedFunctions.Keys | Sort-Object) | Should -Be @('Invoke-OmnikeyBatch', 'Invoke-OmnikeyCli', 'Invoke-OmnikeyTool')
        $module.ExportedVariables.Count | Should -Be 0
    }

    It 'the manifest exports the same functions as Export-ModuleMember' {
        $m = Import-PowerShellDataFile $ModuleManifest
        @($m.FunctionsToExport | Sort-Object) | Should -Be @($module.ExportedFunctions.Keys | Sort-Object)
    }

    It 'every component file listed in the psm1 exists, and every .ps1 in the module is listed' {
        foreach ($f in $ComponentFiles) { Test-Path $f | Should -BeTrue -Because $f }
        $onDisk = @(Get-ChildItem $ModuleRoot -Recurse -Filter *.ps1 | ForEach-Object { $_.FullName } | Sort-Object)
        @($ComponentFiles | ForEach-Object { (Resolve-Path $_).Path } | Sort-Object) | Should -Be $onDisk
    }

    It 'private functions are not visible outside the module' {
        Get-Command Send-Escape -ErrorAction SilentlyContinue | Where-Object { $_.ModuleName -eq 'OmnikeyToolkit' } | Should -BeNullOrEmpty
        Get-Command ConvertTo-OperationList -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'lesson 1 at the module boundary: a scriptblock from outside cannot call private functions, one from inside can' {
        $outside = { Format-GetApdu 'A0' '87' }
        $result = & $module { param($sb) try { & $sb } catch { 'not visible' } } $outside
        $result | Should -Be 'not visible'
        & $module { Format-GetApdu 'A0' '87' } | Should -Be 'FF70076B0AA208A006A404A002870000'
    }

    It 'importing twice in one session is safe (Add-Type guard, lesson 4)' {
        { Import-Module $ModuleManifest -Force } | Should -Not -Throw
        { Import-Module $ModuleManifest -Force } | Should -Not -Throw
        'OmniTool.WinSCard' -as [type] | Should -Not -BeNullOrEmpty
    }
}

Describe 'Module-scoped smoke run' {
    BeforeAll {
        $module = Import-Module $ModuleManifest -Force -PassThru
    }

    It 'Invoke-OmnikeyTool -Mode Get works through the exported function with mocked PC/SC' {
        $responses = New-Reader5022Sim
        Mock -ModuleName OmnikeyToolkit Invoke-NativeEstablishContext { @{ rc = 0; ctx = [IntPtr]42 } }
        Mock -ModuleName OmnikeyToolkit Invoke-NativeReleaseContext { }
        Mock -ModuleName OmnikeyToolkit Invoke-NativeListReaders { @{ rc = 0; names = @('HID Global OMNIKEY 5022 Smart Card Reader 0') } }
        Mock -ModuleName OmnikeyToolkit Invoke-NativeConnect { @{ rc = 0; card = [IntPtr]1; proto = 0 } }
        Mock -ModuleName OmnikeyToolkit Disconnect-Card { }
        Mock -ModuleName OmnikeyToolkit Send-Escape { $responses[$apdu] }   # mock bodies keep the test scope

        $all = @(Invoke-OmnikeyTool -Mode Get 6>&1)
        @($all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }) | Should -Be @(0)
        Get-HostText $all | Should -BeExactly (Get-FixtureText 'get-5022-en.txt')
    }
}
