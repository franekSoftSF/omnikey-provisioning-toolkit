<#
.SYNOPSIS
  OMNIKEY 5022 batch provisioning (USB hub, large series of units).
  v10: implementation moved to the OmnikeyToolkit module (same CLI, CSV and exit codes);
  v9: Apply-All returns hashtable - empty-array unroll fix; v8: no PS closures.
  Full Set+Verify per unit, CSV audit with serial, product name, firmware and an inventory number column.

.DESCRIPTION
  Workflow per batch: plug units into a powered hub -> script waits until the reader
  count is stable (-StableSec) -> for each unit: reads serial/product/firmware,
  compares ALL profile parameters, applies only when needed, reboots, verifies by
  serial -> beep + CSV -> unplug batch -> next. Ctrl+C to finish. Resumable via CSV.
  Units whose model does not support every profile parameter are logged FAIL untouched.

  CSV columns: timestamp;serial;product_name;firmware;inventory_number;result;detail
  - inventory_number is left EMPTY for the client to fill in (e.g. in Excel),
    or is pre-filled from -InventoryMap <csv> with columns: serial;inventory_number

.EXAMPLE
  .\Batch-Omnikey5022-Provision.ps1 -ProfilePath .\my-profile.json -LogCsv C:\prov\omnikey-provisioning.csv
  .\Batch-Omnikey5022-Provision.ps1 -ProfilePath .\my-profile.json -InventoryMap .\inv.csv -Lang pl
#>
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [string]$LogCsv       = ".\omnikey-provisioning.csv",
    [string]$InventoryMap = "",
    [ValidateSet("en","pl")][string]$Lang = "en",
    [string]$ReaderMatch  = "5022",
    [int]$PollMs=500, [int]$StableSec=4, [int]$RebootWait=10, [int]$VerifyRetry=30
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "OmnikeyToolkit/OmnikeyToolkit.psd1") -Force
$code = Invoke-OmnikeyBatch -ProfilePath $ProfilePath -LogCsv $LogCsv -InventoryMap $InventoryMap -Lang $Lang -ReaderMatch $ReaderMatch -PollMs $PollMs -StableSec $StableSec -RebootWait $RebootWait -VerifyRetry $VerifyRetry
exit $code
