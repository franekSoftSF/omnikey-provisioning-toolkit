<#
.SYNOPSIS
  OMNIKEY 5022 Configuration Tool (AViatoR family: 5022/5122/5422 contactless slot, 3121 contact slot).
  Modes: Get (dump), Set (apply profile), Verify (audit against profile, for testing).
  Messages: English (default) or Polish (-Lang pl).

.DESCRIPTION
  Talks to the reader over PC/SC in DIRECT mode using HID proprietary escape APDUs
  (source: github.com/hidglobal/HID-OMNIKEY-Sample-Codes). No card required.
  Compatibility wrapper: the implementation lives in the OmnikeyToolkit module next to this
  script; Omnikey.ps1 offers the same functions under one command.

  Supported parameters (JSON profile, all optional - only listed keys are set/verified):
  {
    "iso14443a": { "enabled": true, "mifarePreferred": true, "mifareKeyCache": false,
                   "rx": [212,424], "tx": [212,424] },          // 106 always on; allowed: 212,424,848
    "iso14443b": { "enabled": true, "rx": [212,424], "tx": [212,424] },
    "iso15693":  { "enabled": true },
    "felica":    { "enabled": true, "rx": [212], "tx": [212] },
    "iclass":    { "enabled": true },
    "emdSuppression": true,
    "sleepModeCardDetection": true,
    "sleepModePollingFrequency": "0.7Hz",   // 41Hz 20Hz 10Hz 5Hz 2.5Hz 1.3Hz 0.7Hz 0.3Hz 0.15Hz 0.08Hz
    "pollingSearchOrder": ["iso14443a","iso14443b","iclass","felica","iso15693"],  // up to 5; also: "none"
    "contactSlot": { "enabled": true, "operatingMode": "iso7816", "voltageSequence": ["5V","3V","1.8V"] }
  }

.EXAMPLE
  .\CheckProfile5022.ps1 -Mode Get
  .\CheckProfile5022.ps1 -Mode Set    -Profile my-profile.json
  .\CheckProfile5022.ps1 -Mode Verify -Profile my-profile.json          # exit 0=PASS 2=FAIL
  .\CheckProfile5022.ps1 -Mode Set    -Profile my-profile.json -Lang pl
#>
param(
    [ValidateSet("Get","Set","Verify","TestCard","Export")] [string]$Mode = "Get",
    [string]$Profile     = "",
    [ValidateSet("en","pl")] [string]$Lang = "en",
    [string]$ReaderMatch = "5022",
    [switch]$NoReboot,           # Set only: skip reboot (settings apply after next replug)
    [int]   $RebootWait  = 10,
    [int]   $CardTimeout = 30,   # TestCard: seconds to wait for a card
    [string]$OutProfile  = ".\reader-profile.json",  # Export: output profile path
    [switch]$Loop                # TestCard: test cards one after another until Ctrl+C
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "OmnikeyToolkit/OmnikeyToolkit.psd1") -Force
$code = Invoke-OmnikeyTool -Mode $Mode -ProfilePath $Profile -Lang $Lang -ReaderMatch $ReaderMatch -NoReboot:$NoReboot -RebootWait $RebootWait -CardTimeout $CardTimeout -OutProfile $OutProfile -Loop:$Loop
exit $code
