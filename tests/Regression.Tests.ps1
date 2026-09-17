#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Regression tests for the hard lessons in CLAUDE.md:
#  1. closures (GetNewClosure) cannot see script functions -> the op engine is data-only
#  2. empty arrays unroll to $null across function boundaries -> multi-value results are hashtables
# (lesson 3 - context recovery - is covered in Engine.Tests.ps1, lesson 4 in Repo/Module tests)
# Pester scoping: variables set in BeforeAll/BeforeEach/BeforeDiscovery are used in other blocks
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    foreach ($f in $ComponentFiles) { . $f }
    Set-MessageLanguage en
    $card = [IntPtr]::Zero
    $ops = ConvertTo-OperationList (Get-Content $ExampleProfile -Raw | ConvertFrom-Json)
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

Describe 'Lesson 1: data-only op engine' {
    It 'no shipped PowerShell file uses GetNewClosure or ScriptBlock::Create' {
        $files = Get-ChildItem $RepoRoot -Recurse -Include *.ps1, *.psm1 |
            Where-Object { $_.FullName -notmatch '[\\/](tests|\.git)[\\/]' }
        $files.Count | Should -BeGreaterThan 10
        foreach ($f in $files) {
            $src = Get-Content $f.FullName -Raw
            $src | Should -Not -Match 'GetNewClosure' -Because $f.Name
            $src | Should -Not -Match '\[scriptblock\]::Create' -Because $f.Name
        }
    }

    It 'operations are plain hashtables without any ScriptBlock (contactless and contact)' {
        $all = @($ops) + @(ConvertTo-OperationList (ConvertTo-TestProfile '{"contactSlot":{"enabled":true,"operatingMode":"emvco","voltageSequence":["5V"]}}'))
        foreach ($op in $all) {
            $op | Should -BeOfType [hashtable]
            Test-ContainsScriptBlock $op | Should -BeFalse -Because $op.name
            $op.kind | Should -BeIn @('bool', 'baud', 'freq', 'poll', 'mode', 'volt')
        }
    }

    It 'operations built in one scope are executed by Invoke-OpApply / Invoke-OpCheck in another' {
        $sent = [System.Collections.Generic.List[string]]::new()
        Mock Send-Escape { $sent.Add($apdu); '9000' }
        $data = $ops                       # hand over data only - no scriptblocks cross the boundary
        & { param($o) foreach ($op in $o) { Invoke-OpApply $card $op } } $data
        & { param($o) foreach ($op in $o) { [void](Invoke-OpCheck $card $op) } } $data
        @($sent | Select-Object -First $ops.Count) | Should -Be $ExampleProfileSetApdus
        $sent.Count | Should -Be ($ops.Count * 2)
    }
}

Describe 'Lesson 2: multi-value results are hashtables' {
    BeforeEach {
        $sent = [System.Collections.Generic.List[string]]::new()
    }

    It 'Invoke-OpApplyAll returns @{errors=@()} on success - never $null - and then sends Apply + Reboot' {
        Mock Send-Escape { $sent.Add($apdu); '9000' }
        $res = Invoke-OpApplyAll $card $ops
        $null -eq $res | Should -BeFalse
        $res | Should -BeOfType [hashtable]
        $res.ContainsKey('errors') | Should -BeTrue
        $null -eq $res.errors | Should -BeFalse
        $res.errors.Count | Should -Be 0
        @($sent) | Should -Be (@($ExampleProfileSetApdus) + $ApduApply + $ApduReboot)
    }

    It 'Invoke-OpApplyAll still reports success when the reader drops during Reboot' {
        Mock Send-Escape { if ($apdu -eq $ApduReboot) { throw 'SCardControl 0x80100017' }; '9000' }
        $res = Invoke-OpApplyAll $card $ops
        $res | Should -BeOfType [hashtable]
        $res.errors.Count | Should -Be 0
    }

    It 'Invoke-OpApplyAll returns the failed parameters and sends neither Apply nor Reboot' {
        Mock Send-Escape {
            $sent.Add($apdu)
            if ($apdu -eq "${ApduSetPrefix}A00387010100") { return '6A80' }                        # rejected
            if ($apdu -eq "${ApduSetPrefix}A0038E010100") { throw 'SCardControl 0x80100017' }    # escape error
            '9000'
        }
        $res = Invoke-OpApplyAll $card $ops
        $res | Should -BeOfType [hashtable]
        @($res.errors) | Should -Be @('emdSuppression(6A80)', 'sleepModeCardDetection(0x80100017)')
        $sent | Should -Not -Contain $ApduApply
        $sent | Should -Not -Contain $ApduReboot
    }

    It 'Invoke-OpCheckAll keeps empty bad/diff lists as arrays inside the result hashtable' {
        Mock Send-Escape { '9000' }
        $r = Invoke-OpCheckAll $card ([System.Collections.ArrayList]::new())
        $r | Should -BeOfType [hashtable]
        $r.ok | Should -BeTrue
        $null -eq $r.bad | Should -BeFalse
        $r.bad.Count | Should -Be 0
        $null -eq $r.diff | Should -BeFalse
    }

    It 'ConvertTo-OperationList and Get-ReaderList return lists even when empty' {
        $empty = ConvertTo-OperationList ([pscustomobject]@{})
        $null -eq $empty | Should -BeFalse
        $empty.Count | Should -Be 0

        $script:ctx = [IntPtr]::Zero
        Mock Invoke-NativeEstablishContext { @{ rc = 0; ctx = [IntPtr]42 } }
        Mock Invoke-NativeListReaders { @{ rc = 0; names = @('R1') } }
        $none = Get-ReaderList 'no-such'
        $null -eq $none | Should -BeFalse
        $none.Count | Should -Be 0
        (Get-ReaderList 'R1').Count | Should -Be 1
    }
}
