# OmnikeyToolkit - one implementation behind Omnikey.ps1, CheckProfile5022.ps1 and
# Batch-Omnikey5022-Provision.ps1. Components are plain .ps1 files dot-sourced in this order
# (tests dot-source the same list, see tests/TestHelpers.ps1).
$ErrorActionPreference = "Stop"

$ComponentFiles = @(
    'Private/Messages.ps1'
    'Private/Native.ps1'
    'Private/Transport.ps1'
    'Private/Apdu.ps1'
    'Private/Models.ps1'
    'Private/Profile.ps1'
    'Private/Engine.ps1'
    'Private/Card.ps1'
    'Private/Batch.ps1'
    'Private/Cli.ps1'
    'Private/Configure.ps1'
    'Private/Restore.ps1'
    'Public/Invoke-OmnikeyTool.ps1'
    'Public/Invoke-OmnikeyBatch.ps1'
    'Public/Invoke-OmnikeyCli.ps1'
)
foreach ($file in $ComponentFiles) { . (Join-Path $PSScriptRoot $file) }

Export-ModuleMember -Function 'Invoke-OmnikeyCli', 'Invoke-OmnikeyTool', 'Invoke-OmnikeyBatch'
