# Helpers for Omnikey.ps1 (one entry point for all commands).

$script:CliCommonParams = @('Command', 'Lang', 'ReaderMatch')
$script:CliCommandParams = @{
    get      = @()
    set      = @('ProfilePath', 'NoReboot', 'RebootWait')
    verify   = @('ProfilePath')
    export   = @('OutProfile')
    testcard = @('CardTimeout', 'Loop')
    batch    = @('ProfilePath', 'LogCsv', 'InventoryMap', 'PollMs', 'StableSec', 'RebootWait', 'VerifyRetry')
    readers  = @()
    configure = @('NoReboot')
    restore  = @('ProfilePath', 'NoReboot')
}
$script:CliModes = @{ get = 'Get'; set = 'Set'; verify = 'Verify'; export = 'Export'; testcard = 'TestCard' }

function Assert-CliParameter([string]$command, [string[]]$bound) {
    $allowed = $script:CliCommonParams + $script:CliCommandParams[$command]
    foreach ($b in $bound) {
        if ($allowed -notcontains $b) { throw (T cliNotFor $b $command) }
    }
}

# pick exactly one reader: explicit -ReaderMatch keeps the old "first match" rule, otherwise
# exactly one OMNIKEY reader must be connected - or, in the menu ($interactive), the operator picks one
function Resolve-SingleReader([string]$readerMatch, [bool]$interactive = $false) {
    Initialize-Context
    if (-not (Test-ContextReady)) { throw (T noService) }
    $all = Get-ReaderList
    if ($readerMatch) {
        $hit = @($all | Where-Object { $_ -match $readerMatch })
        if ($hit.Count -gt 0) { return $readerMatch }
        # a model id ("3121") finds the reader by its PC/SC name ("OMNIKEY 3x21")
        $model = @($script:Models | Where-Object { $_.id -eq $readerMatch })
        if ($model.Count -eq 1) {
            $byModel = [regex]::Escape($model[0].readerName)
            if (@($all | Where-Object { $_ -match $byModel }).Count -gt 0) { return $byModel }
        }
        throw (T noReader $readerMatch ($all -join "`n"))
    }
    $omnikey = @($all | Where-Object { $_ -match 'OMNIKEY' })
    if ($omnikey.Count -eq 0) { throw (T cliNoOmnikey ($all -join "`n")) }
    $pick = 0
    if ($omnikey.Count -gt 1) {
        if (-not $interactive) { throw (T cliMulti ($omnikey -join "`n")) }
        Write-Host (T menuReaders) -ForegroundColor Cyan
        for ($i = 0; $i -lt $omnikey.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $omnikey[$i]) }
        $answer = ([string](Read-Host (T menuReader))).Trim()
        $n = 0
        if (-not [int]::TryParse($answer, [ref]$n) -or $n -lt 1 -or $n -gt $omnikey.Count) { throw (T menuInvalid $answer) }
        $pick = $n - 1
    }
    '^' + [regex]::Escape($omnikey[$pick]) + '$'
}

# lists OMNIKEY readers and other HID Global readers; escape commands are sent ONLY to OMNIKEY
# readers (other HID products, e.g. "Crescendo NFC Reader", have no public HID commands)
function Show-ReaderList([string]$readerMatch) {
    Initialize-Context
    if (-not (Test-ContextReady)) { throw (T noService) }
    $readers = Get-ReaderList $(if ($readerMatch) { $readerMatch } else { 'OMNIKEY|^HID Global' })
    try {
        if ($readers.Count -eq 0) { Write-Host (T readersNone) -ForegroundColor Yellow; return }
        foreach ($r in $readers) {
            Write-Host $r -ForegroundColor Cyan
            if ($r -notmatch 'OMNIKEY') { Write-Host (T readersNotProbed) -ForegroundColor DarkGray; continue }
            $info = Invoke-WithReader $r {
                param($card)
                $id = Read-Identity $card
                @{ Id = $id; Model = (Resolve-ReaderModel $id) }
            } $null
            if (-not $info) { Write-Host ("    " + (T connectFail) + " ($script:lastErr)") -ForegroundColor Red; continue }
            $m = $info.Model
            $cfg = if (-not $m.known) { T cfgReadOnly } elseif ($m.verified) { T cfgVerified } else { T cfgExperimental }
            Write-Host (T readersModel $m.product $info.Id.Fw $(if ($info.Id.Serial) { $info.Id.Serial } else { "?" }))
            Write-Host (T readersSlots $(if ($m.contactless) { T yes } else { T no }) $(if ($m.contact) { T yes } else { T no }) $cfg)
        }
    }
    finally { Close-Context }
}

# interactive menu when Omnikey.ps1 runs without a command; returns $null for exit,
# @{ Invalid } for an unknown choice (the menu loop shows it and asks again)
function Read-MenuSelection {
    Write-Host (T menuTitle) -ForegroundColor Cyan
    Write-Host (T menuItems)
    $choice = ([string](Read-Host (T menuChoice))).Trim()
    $map = @{ '1' = 'get'; '2' = 'verify'; '3' = 'set'; '4' = 'export'; '5' = 'testcard'; '6' = 'batch'; '7' = 'readers'; '8' = 'configure'; '9' = 'restore' }
    if ($choice -eq '0') { return $null }
    if (-not $map.ContainsKey($choice)) { return @{ Command = $null; Invalid = $choice } }
    $sel = @{ Command = $map[$choice]; ProfilePath = '' }
    if ($sel.Command -in 'verify', 'set', 'batch') { $sel.ProfilePath = ([string](Read-Host (T menuProfile))).Trim().Trim('"') }
    $sel
}
