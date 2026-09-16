#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Guards for the non-negotiable repo constraints (CLAUDE.md): stable CLI, P/Invoke
# namespace discipline (lesson 4), bilingual messages (lesson 6), LF line endings.
# Pester scoping: variables set in BeforeAll/BeforeEach/BeforeDiscovery are used in other blocks
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeDiscovery {
    $scripts = @(
        @{
            Name = 'CheckProfile5022.ps1'
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
        'OmniTool'  = 'ec61948a7501962773824a91559b871b20ac99c2e3b042f4ce8a44d6c7a7be89'
        'OmniBatch' = '78b7edd4d48904290a1ba7c86eefe3784448fb2f059128961ab8201888557e5e'
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
                Namespace = [regex]::Match($_.Value, 'namespace\s+(\w+)').Groups[1].Value
                Hash      = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($norm)) | ForEach-Object { $_.ToString('x2') })
            }
        }
    }
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
}

Describe 'P/Invoke namespaces (lesson 4)' {
    It '<Name> defines P/Invoke types only under a known namespace with its original signatures' -ForEach $scripts {
        $defs = @(Get-PInvokeDefinition (Join-Path $RepoRoot $Name))
        $defs.Count | Should -BeGreaterThan 0
        foreach ($d in $defs) {
            $PInvokeHistory.ContainsKey($d.Namespace) | Should -BeTrue -Because "namespace '$($d.Namespace)' is new: add it to `$PInvokeHistory with hash $($d.Hash)"
            $d.Hash | Should -Be $PInvokeHistory[$d.Namespace] -Because "P/Invoke signatures in '$($d.Namespace)' changed: rename the namespace (types cannot be redefined in a live session) and record the new one"
        }
    }

    It 'each namespace is defined by exactly one script' {
        $all = foreach ($s in 'CheckProfile5022.ps1', 'Batch-Omnikey5022-Provision.ps1') {
            Get-PInvokeDefinition (Join-Path $RepoRoot $s) | ForEach-Object { $_.Namespace }
        }
        @($all | Group-Object | Where-Object Count -gt 1) | Should -BeNullOrEmpty
    }

    It '<Name> guards Add-Type with an -as [type] check' -ForEach $scripts {
        $src = Get-Content (Join-Path $RepoRoot $Name) -Raw
        foreach ($d in Get-PInvokeDefinition (Join-Path $RepoRoot $Name)) {
            $src | Should -Match ('-not \("{0}\.WinSCard" -as \[type\]\)' -f $d.Namespace)
        }
    }
}

Describe 'Messages (lesson 6)' {
    It '<Name> has the same message keys and placeholders in en and pl' -ForEach $scripts {
        $path = Join-Path $RepoRoot $Name
        $msg = if ($Name -like 'Batch*') { & { . $path -ProfilePath $ExampleProfile; $MSG } } else { & { . $path; $MSG } }
        @($msg.Keys | Sort-Object) | Should -Be @('en', 'pl')
        @($msg.pl.Keys | Sort-Object) | Should -Be @($msg.en.Keys | Sort-Object)
        foreach ($k in $msg.en.Keys) {
            $ph = { param($s) @([regex]::Matches($s, '\{\d+[^}]*\}') | ForEach-Object Value | Sort-Object -Unique) }
            (& $ph $msg.pl[$k]) | Should -Be (& $ph $msg.en[$k]) -Because "placeholders of '$k'"
        }
    }

    It 'Batch CSV header is unchanged' {
        $header = & { . $BatchPath -ProfilePath $ExampleProfile; $CsvHeader }
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
