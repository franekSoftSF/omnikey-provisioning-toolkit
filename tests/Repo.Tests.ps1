#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Guards for the non-negotiable repo constraints (CLAUDE.md): stable CLI, thin wrappers, P/Invoke
# namespace discipline (lesson 4), bilingual messages and LF line endings (lesson 6), release content.
# Pester scoping: variables set in BeforeAll/BeforeEach/BeforeDiscovery are used in other blocks
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeDiscovery {
    $scripts = @(
        @{
            Name = 'CheckProfile5022.ps1'
            Entry = 'Invoke-OmnikeyTool'
            # name | attributes+type | default. New parameters may only be APPENDED
            # (CheckProfile5022 is not an advanced script: parameters bind by position).
            Params = @(
                'Mode | [ValidateSet("Get","Set","Verify","TestCard","Export")][string] | "Get"'
                'Profile | [string] | ""'
                'Lang | [ValidateSet("en","pl")][string] | "en"'
                'ReaderMatch | [string] | "5022"'
                'NoReboot | [switch] | '
                'RebootWait | [int] | 10'
                'CardTimeout | [int] | 30'
                'OutProfile | [string] | ".\reader-profile.json"'
                'Loop | [switch] | '
            )
        }
        @{
            Name = 'Batch-Omnikey5022-Provision.ps1'
            Entry = 'Invoke-OmnikeyBatch'
            Params = @(
                'ProfilePath | [Parameter(Mandatory)][string] | '
                'LogCsv | [string] | ".\omnikey-provisioning.csv"'
                'InventoryMap | [string] | ""'
                'Lang | [ValidateSet("en","pl")][string] | "en"'
                'ReaderMatch | [string] | "5022"'
                'PollMs | [int] | 500'
                'StableSec | [int] | 4'
                'RebootWait | [int] | 10'
                'VerifyRetry | [int] | 30'
            )
        }
        @{
            Name = 'Omnikey.ps1'
            Entry = 'Invoke-OmnikeyCli'
            Params = @(
                'Command | [Parameter(Position = 0)][ValidateSet("get", "set", "verify", "export", "testcard", "batch", "readers")][string] | '
                'ProfilePath | [Alias("Profile")][string] | ""'
                'Lang | [ValidateSet("en", "pl")][string] | "en"'
                'ReaderMatch | [string] | ""'
                'NoReboot | [switch] | '
                'RebootWait | [int] | 10'
                'CardTimeout | [int] | 30'
                'OutProfile | [string] | ".\reader-profile.json"'
                'Loop | [switch] | '
                'LogCsv | [string] | ".\omnikey-provisioning.csv"'
                'InventoryMap | [string] | ""'
                'PollMs | [int] | 500'
                'StableSec | [int] | 4'
                'VerifyRetry | [int] | 30'
            )
        }
    )
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    function Get-ScriptAst([string]$path) {
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    }

    # Every P/Invoke definition ever shipped, by namespace. .NET types cannot be unloaded
    # from a live session, so a namespace name must never be reused with other signatures:
    # change signatures => new namespace name => add a NEW line here (never edit old ones).
    $PInvokeHistory = @{
        'OmniTool'  = 'ec61948a7501962773824a91559b871b20ac99c2e3b042f4ce8a44d6c7a7be89'   # v1.0 CheckProfile5022.ps1, v1.2 module
        'OmniBatch' = '78b7edd4d48904290a1ba7c86eefe3784448fb2f059128961ab8201888557e5e'   # v1.0 Batch script (retired, name reserved)
    }

    function Get-PInvokeDefinition([string]$path) {
        $ast = Get-ScriptAst $path
        $ast.FindAll({
            param($n)
            ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
             $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
            $n.Value -match 'namespace\s+\w+' -and $n.Value -match 'DllImport'
        }, $true) | ForEach-Object {
            $norm = ($_.Value -replace '\s+', ' ').Trim()
            $sha = [System.Security.Cryptography.SHA256]::Create()
            @{
                Path      = $path
                Namespace = [regex]::Match($_.Value, 'namespace\s+(\w+)').Groups[1].Value
                Hash      = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($norm)) | ForEach-Object { $_.ToString('x2') })
            }
        }
    }
    $shippedPs = @(Get-ChildItem $RepoRoot -Recurse -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '[\\/](tests|\.git)[\\/]' })
}

Describe 'CLI contract of <Name>' -ForEach $scripts {
    It 'keeps every existing parameter unchanged and in its position' {
        $ast = Get-ScriptAst (Join-Path $RepoRoot $Name)
        $actual = @($ast.ParamBlock.Parameters | ForEach-Object {
            '{0} | {1} | {2}' -f $_.Name.VariablePath.UserPath,
                (($_.Attributes | ForEach-Object { $_.Extent.Text }) -join ''),
                $(if ($_.DefaultValue) { $_.DefaultValue.Extent.Text } else { '' })
        })
        $actual.Count | Should -BeGreaterOrEqual $Params.Count
        @($actual | Select-Object -First $Params.Count) | Should -Be $Params
    }

    It 'is a thin wrapper: import the module, call <Entry>, exit with its code' {
        $ast = Get-ScriptAst (Join-Path $RepoRoot $Name)
        $statements = @($ast.EndBlock.Statements | ForEach-Object { ($_.Extent.Text -replace '\s+', ' ').Trim() })
        $statements.Count | Should -Be 4
        $statements[0] | Should -Be '$ErrorActionPreference = "Stop"'
        $statements[1] | Should -Be 'Import-Module (Join-Path $PSScriptRoot "OmnikeyToolkit/OmnikeyToolkit.psd1") -Force'
        $statements[2] | Should -Match ('^\$code = ' + $Entry + ' ')
        $statements[3] | Should -Be 'exit $code'
    }
}

Describe 'P/Invoke namespaces (lesson 4)' {
    It 'defines P/Invoke types only under known namespaces with their original signatures' {
        $defs = @($shippedPs | ForEach-Object { Get-PInvokeDefinition $_.FullName })
        $defs.Count | Should -BeGreaterThan 0
        foreach ($d in $defs) {
            $PInvokeHistory.ContainsKey($d.Namespace) | Should -BeTrue -Because "namespace '$($d.Namespace)' is new: add it to `$PInvokeHistory with hash $($d.Hash)"
            $d.Hash | Should -Be $PInvokeHistory[$d.Namespace] -Because "P/Invoke signatures in '$($d.Namespace)' ($($d.Path)) changed: rename the namespace (types cannot be redefined in a live session) and record the new one"
        }
    }

    It 'each namespace is defined in exactly one file, guarded by an -as [type] check' {
        $defs = @($shippedPs | ForEach-Object { Get-PInvokeDefinition $_.FullName })
        @($defs | Group-Object { $_.Namespace } | Where-Object Count -gt 1) | Should -BeNullOrEmpty
        foreach ($d in $defs) {
            Get-Content $d.Path -Raw | Should -Match ('-not \("{0}\.WinSCard" -as \[type\]\)' -f $d.Namespace)
        }
    }

    It 'only Transport.ps1 calls the native type (everything else is mockable)' {
        $users = @($shippedPs | Where-Object { (Get-Content $_.FullName -Raw) -match '\[OmniTool\.WinSCard\]|OmniTool\.WinSCard\+' } | ForEach-Object { $_.Name } | Sort-Object)
        $users | Should -Be @('Transport.ps1')
    }
}

Describe 'Messages (lesson 6)' {
    BeforeAll {
        $msg = & { . (Join-Path $ModuleRoot 'Private/Messages.ps1'); $script:MSG }
    }

    It 'has the same message keys and placeholders in en and pl' {
        @($msg.Keys | Sort-Object) | Should -Be @('en', 'pl')
        @($msg.pl.Keys | Sort-Object) | Should -Be @($msg.en.Keys | Sort-Object)
        foreach ($k in $msg.en.Keys) {
            $ph = { param($s) @([regex]::Matches($s, '\{\d+[^}]*\}') | ForEach-Object Value | Sort-Object -Unique) }
            (& $ph $msg.pl[$k]) | Should -Be (& $ph $msg.en[$k]) -Because "placeholders of '$k'"
        }
    }

    It 'every T key used in the module exists' {
        $used = foreach ($f in $ComponentFiles) {
            [regex]::Matches((Get-Content $f -Raw), '\(T\s+([A-Za-z]+)') | ForEach-Object { $_.Groups[1].Value }
        }
        foreach ($k in ($used | Sort-Object -Unique)) { $msg.en.ContainsKey($k) | Should -BeTrue -Because "T $k" }
    }

    It 'Batch CSV header is unchanged' {
        $header = & { . (Join-Path $ModuleRoot 'Private/Batch.ps1'); $script:CsvHeader }
        $header | Should -BeExactly 'timestamp;serial;product_name;firmware;inventory_number;result;detail'
    }
}

Describe 'Line endings (lesson 6)' {
    It 'text files in the repo use LF only' {
        $exts = '.ps1', '.psd1', '.psm1', '.md', '.json', '.yml', '.yaml', '.txt', '.gitattributes', '.gitignore'
        $files = Get-ChildItem $RepoRoot -Recurse -File -Force |
            Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and ($exts -contains $_.Extension -or $exts -contains $_.Name) }
        $files.Count | Should -BeGreaterThan 0
        $crlf = @($files | Where-Object { [IO.File]::ReadAllText($_.FullName).Contains("`r") } |
            ForEach-Object { $_.FullName.Substring($RepoRoot.Length + 1) })
        $crlf | Should -BeNullOrEmpty
    }
}

Describe 'Release package' {
    It 'release.yml ships the entry scripts, the module, profiles, README and LICENSE' {
        $yml = Get-Content (Join-Path $RepoRoot '.github/workflows/release.yml') -Raw
        $line = [regex]::Match($yml, 'RELEASE_FILES:\s*(.+)').Groups[1].Value.Trim()
        @($line -split '\s+' | Sort-Object) | Should -Be @('Batch-Omnikey5022-Provision.ps1', 'CheckProfile5022.ps1', 'LICENSE', 'Omnikey.ps1', 'OmnikeyToolkit', 'profiles', 'README.md' | Sort-Object)
    }
}
