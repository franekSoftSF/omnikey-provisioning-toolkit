#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Regression tests for the hard lessons in CLAUDE.md:
#  1. closures (GetNewClosure) cannot see script functions -> the op engine is data-only
#  2. empty arrays unroll to $null across function boundaries -> multi-value results are hashtables
# Pester scoping: variables set in BeforeAll/BeforeEach/BeforeDiscovery are used in other blocks
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeDiscovery {
    $scripts = @(
        @{ Name = 'CheckProfile5022';                File = 'CheckProfile5022.ps1' }
        @{ Name = 'Batch-Omnikey5022-Provision';     File = 'Batch-Omnikey5022-Provision.ps1' }
    )
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Lesson 1 canary: PowerShell closures do not see script functions' {
    It 'a GetNewClosure() scriptblock cannot call a function defined in the calling scope' {
        function Get-LessonOneValue { 42 }
        { Get-LessonOneValue }.Invoke() | Should -Be 42
        { { Get-LessonOneValue }.GetNewClosure().Invoke() } | Should -Throw -Because 'this is why ops must stay data-only'
    }
}

Describe 'Lesson 2 canary: empty arrays unroll to $null' {
    It 'a function returning @() yields $null, a hashtable wrapper does not' {
        function Get-EmptyArray { $bad = @(); $bad }
        function Get-EmptyResult { $bad = @(); @{ errors = $bad } }
        $null -eq (Get-EmptyArray) | Should -BeTrue
        $null -eq (Get-EmptyResult) | Should -BeFalse
        (Get-EmptyResult).errors.Count | Should -Be 0
    }
}

Describe 'Lesson 1 in <Name>: data-only op engine' -ForEach $scripts {
    BeforeAll {
        $path = Join-Path $RepoRoot $File
        if ($Name -like 'Batch*') { . $path -ProfilePath $ExampleProfile } else { . $path }
        $card = [IntPtr]::Zero
        $ops = Build-Ops (Get-Content $ExampleProfile -Raw | ConvertFrom-Json)
    }

    It 'source contains no GetNewClosure / ScriptBlock::Create' {
        $src = Get-Content $path -Raw
        $src | Should -Not -Match 'GetNewClosure'
        $src | Should -Not -Match '\[scriptblock\]::Create'
    }

    It 'Build-Ops produces plain hashtables without any ScriptBlock' {
        foreach ($op in $ops) {
            $op | Should -BeOfType [hashtable]
            Test-ContainsScriptBlock $op | Should -BeFalse -Because $op.name
            $op.kind | Should -BeIn @('bool', 'baud', 'freq', 'poll')
        }
    }

    It 'ops built in one scope are executed by Invoke-OpApply / Invoke-OpCheck in another' {
        $sent = [System.Collections.Generic.List[string]]::new()
        Mock Send-Escape { $sent.Add($apdu); '9000' }
        $data = $ops                       # hand over data only - no scriptblocks cross the boundary
        & { param($o) foreach ($op in $o) { Invoke-OpApply $card $op } } $data
        & { param($o) foreach ($op in $o) { [void](Invoke-OpCheck $card $op) } } $data
        @($sent | Select-Object -First $ops.Count) | Should -Be $ExampleProfileSetApdus
        $sent.Count | Should -Be ($ops.Count * 2)
    }

    It 'Build-Ops returns a list even for an empty profile' {
        $empty = Build-Ops ([pscustomobject]@{})
        $null -eq $empty | Should -BeFalse
        $empty.Count | Should -Be 0
    }
}

Describe 'Lesson 2 in Batch-Omnikey5022-Provision: Apply-All / Check-All results' {
    BeforeAll {
        . $BatchPath -ProfilePath $ExampleProfile
        $card = [IntPtr]::Zero
        $ops = Build-Ops (Get-Content $ExampleProfile -Raw | ConvertFrom-Json)
    }
    BeforeEach {
        $sent = [System.Collections.Generic.List[string]]::new()
    }

    It 'Apply-All returns @{errors=@()} on success - never $null - and then sends Apply + Reboot' {
        Mock Send-Escape { $sent.Add($apdu); '9000' }
        $res = Apply-All $card $ops
        $null -eq $res | Should -BeFalse
        $res | Should -BeOfType [hashtable]
        $res.ContainsKey('errors') | Should -BeTrue
        $null -eq $res.errors | Should -BeFalse
        $res.errors.Count | Should -Be 0
        @($sent) | Should -Be (@($ExampleProfileSetApdus) + $ApduApply + $ApduReboot)
    }

    It 'Apply-All still reports success when the reader drops during Reboot' {
        Mock Send-Escape { if ($apdu -eq $ApduReboot) { throw '0x80100017' }; '9000' }
        $res = Apply-All $card $ops
        $res | Should -BeOfType [hashtable]
        $res.errors.Count | Should -Be 0
    }

    It 'Apply-All returns the failed parameters and sends neither Apply nor Reboot' {
        Mock Send-Escape {
            $sent.Add($apdu)
            if ($apdu -eq "${ApduSetPrefix}A00387010100") { return '6A80' }   # emdSuppression rejected
            '9000'
        }
        $res = Apply-All $card $ops
        $res | Should -BeOfType [hashtable]
        @($res.errors) | Should -Be @('emdSuppression(6A80)')
        $sent | Should -Not -Contain $ApduApply
        $sent | Should -Not -Contain $ApduReboot
    }

    It 'Check-All keeps an empty bad list as an array inside the result hashtable' {
        Mock Send-Escape { '9000' }
        $r = Check-All $card ([System.Collections.ArrayList]::new())
        $r | Should -BeOfType [hashtable]
        $r.ok | Should -BeTrue
        $null -eq $r.bad | Should -BeFalse
        $r.bad.Count | Should -Be 0
    }
}
