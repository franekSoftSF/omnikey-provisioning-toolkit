<#
.SYNOPSIS
  OMNIKEY Provisioning Toolkit - one entry point for every tool.

.DESCRIPTION
  Commands:
    get       show reader configuration
    verify    audit a reader against a profile            (exit 0 = PASS, 2 = FAIL)
    set       apply a profile (write + Apply + reboot)
    export    save the reader configuration as a profile
    testcard  test a card (ATR/UID, type, MIFARE Classic verdict)
    batch     batch provisioning station (USB hub, CSV audit trail)
    readers   list connected OMNIKEY readers, their model and what can be configured
    configure set the reader step by step: one question per parameter, then Apply
  Without a command an interactive menu is shown; it returns to the menu after each action.

  Without -ReaderMatch the single connected OMNIKEY reader is used (batch: all OMNIKEY readers).
  CheckProfile5022.ps1 and Batch-Omnikey5022-Provision.ps1 remain as compatibility wrappers.

.EXAMPLE
  .\Omnikey.ps1 readers
  .\Omnikey.ps1 get -ReaderMatch 3121
  .\Omnikey.ps1 verify -ProfilePath .\profiles\example-profile.json
  .\Omnikey.ps1 set -ProfilePath .\my-profile.json -Lang pl
  .\Omnikey.ps1 batch -ProfilePath .\my-profile.json -LogCsv .\prov.csv
  .\Omnikey.ps1
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet("get", "set", "verify", "export", "testcard", "batch", "readers", "configure")]
    [string]$Command,
    [Alias("Profile")][string]$ProfilePath = "",
    [ValidateSet("en", "pl")][string]$Lang = "en",
    [string]$ReaderMatch = "",
    [switch]$NoReboot,
    [int]$RebootWait = 10,
    [int]$CardTimeout = 30,
    [string]$OutProfile = ".\reader-profile.json",
    [switch]$Loop,
    [string]$LogCsv = ".\omnikey-provisioning.csv",
    [string]$InventoryMap = "",
    [int]$PollMs = 500,
    [int]$StableSec = 4,
    [int]$VerifyRetry = 30
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "OmnikeyToolkit/OmnikeyToolkit.psd1") -Force
$code = Invoke-OmnikeyCli @PSBoundParameters -Bound @($PSBoundParameters.Keys | Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters })
exit $code
