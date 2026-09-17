# Reader model registry (data only). A model is recognised by the product name the reader reports
# (ReaderCapabilities ProductName, A0 82). Profile keys per model follow the HID sample classes
# OK5022.cs / OK5422.cs / OK5122.cs; OMNIKEY 3121 answers ContactSlotConfiguration (hardware probe).
# readerName = PC/SC reader name fragment (3121 enumerates as "OMNIKEY 3x21"), used for -ReaderMatch <model id>.
# verified = configuration verified on real hardware by this project.
# voltageAuto = $false: the reader does not keep contactSlot.voltageSequence "auto" (hardware test).

$script:ContactlessKeys = @(
    'iso14443a.enabled', 'iso14443a.mifarePreferred', 'iso14443a.mifareKeyCache', 'iso14443a.baud',
    'iso14443b.enabled', 'iso14443b.baud', 'iso15693.enabled', 'felica.enabled', 'felica.baud',
    'iclass.enabled', 'emdSuppression', 'sleepModeCardDetection', 'sleepModePollingFrequency',
    'pollingSearchOrder'
)
$script:ContactKeys = @('contactSlot.enabled', 'contactSlot.operatingMode', 'contactSlot.voltageSequence')

$script:Models = @(
    @{ id = '5022'; product = 'OMNIKEY 5022'; readerName = 'OMNIKEY 5022'; contactless = $true;  contact = $false; verified = $true;  exclude = @() }
    @{ id = '3121'; product = 'OMNIKEY 3121'; readerName = 'OMNIKEY 3x21'; contactless = $false; contact = $true;  verified = $true;  exclude = @()
       voltageAuto = $false }   # fw 1.6.0 accepts "auto" (00) but reports 03 (5V only) after reboot
    @{ id = '5422'; product = 'OMNIKEY 5422'; readerName = 'OMNIKEY 5422'; contactless = $true;  contact = $true;  verified = $false
       exclude = @('iso15693.enabled', 'felica.enabled', 'felica.baud', 'pollingSearchOrder') }
    @{ id = '5122'; product = 'OMNIKEY 5122'; readerName = 'OMNIKEY 5122'; contactless = $true;  contact = $true;  verified = $false
       exclude = @('iso15693.enabled', 'felica.enabled', 'felica.baud', 'pollingSearchOrder') }
)

function Get-ModelKeys([bool]$contactless, [bool]$contact, [string[]]$exclude) {
    $keys = @()
    if ($contactless) { $keys += $script:ContactlessKeys }
    if ($contact) { $keys += $script:ContactKeys }
    ,@($keys | Where-Object { $exclude -notcontains $_ })
}

# identity -> @{ id; product; known; verified; contactless; contact; profileKeys }
# Unknown products fall back to the slot counts the reader reports and are never written to.
function Resolve-ReaderModel($identity) {
    foreach ($m in $script:Models) {
        if ($identity.Product -and $identity.Product -eq $m.product) {
            return @{
                id = $m.id; product = $m.product; known = $true; verified = $m.verified; voltageAuto = ($m.voltageAuto -ne $false)
                contactless = $m.contactless; contact = $m.contact
                profileKeys = (Get-ModelKeys $m.contactless $m.contact $m.exclude)
            }
        }
    }
    $cl = [bool]($identity.ContactlessSlots -gt 0)
    $ct = [bool]($identity.ContactSlots -gt 0)
    @{
        id = $null; product = $(if ($identity.Product) { $identity.Product } else { '?' }); known = $false; verified = $false; voltageAuto = $true
        contactless = $cl; contact = $ct; profileKeys = (Get-ModelKeys $cl $ct @())
    }
}

function Read-Identity([IntPtr]$card) {
    $sn = ConvertFrom-AsciiResponse (Send-Escape $card $script:APDU_SERIAL)
    $pn = ConvertFrom-AsciiResponse (Send-Escape $card $script:APDU_PRODUCT)
    $fw = ConvertFrom-FirmwareResponse (Send-Escape $card $script:APDU_FW)
    $cs = $null; $cl = $null
    try { $cs = ConvertFrom-ByteResponse (Send-Escape $card $script:APDU_CONTACT_SLOTS) '8B' } catch { }
    try { $cl = ConvertFrom-ByteResponse (Send-Escape $card $script:APDU_CL_SLOTS) '8C' } catch { }
    @{ Serial = $sn; Product = $pn; Fw = $fw; ContactSlots = $cs; ContactlessSlots = $cl }
}

function Write-ModelNote($model) {
    if (-not $model.known) { Write-Host (T modelUnknown $model.product) -ForegroundColor Yellow; Write-Host "" }
    elseif (-not $model.verified) { Write-Host (T modelUnverified $model.product) -ForegroundColor Yellow; Write-Host "" }
}
