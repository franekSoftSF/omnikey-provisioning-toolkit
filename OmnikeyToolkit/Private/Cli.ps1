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
}
$script:CliModes = @{ get = 'Get'; set = 'Set'; verify = 'Verify'; export = 'Export'; testcard = 'TestCard' }

function Assert-CliParameters([string]$command, [string[]]$bound) {
    $allowed = $script:CliCommonParams + $script:CliCommandParams[$command]
    foreach ($b in $bound) {
        if ($allowed -notcontains $b) { throw (T cliNotFor $b $command) }
    }
}

# pick exactly one reader: explicit -ReaderMatch keeps the old "first match" rule,
# otherwise exactly one OMNIKEY reader must be connected
function Resolve-SingleReader([string]$readerMatch) {
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
    if ($omnikey.Count -gt 1) { throw (T cliMulti ($omnikey -join "`n")) }
    '^' + [regex]::Escape($omnikey[0]) + '$'
}

function Show-ReaderList([string]$readerMatch) {
    Initialize-Context
    if (-not (Test-ContextReady)) { throw (T noService) }
    $readers = Get-ReaderList $(if ($readerMatch) { $readerMatch } else { 'OMNIKEY' })
    try {
        if ($readers.Count -eq 0) { Write-Host (T readersNone) -ForegroundColor Yellow; return }
        foreach ($r in $readers) {
            Write-Host $r -ForegroundColor Cyan
            $info = Invoke-WithReader $r {
                param($card, $unused)
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

# interactive menu when Omnikey.ps1 runs without a command; returns $null for exit
function Read-MenuSelection {
    Write-Host (T menuTitle) -ForegroundColor Cyan
    Write-Host (T menuItems)
    $choice = ([string](Read-Host (T menuChoice))).Trim()
    $map = @{ '1' = 'get'; '2' = 'verify'; '3' = 'set'; '4' = 'export'; '5' = 'testcard'; '6' = 'batch'; '7' = 'readers' }
    if ($choice -eq '0' -or -not $choice) { return $null }
    if (-not $map.ContainsKey($choice)) { throw (T menuInvalid $choice) }
    $sel = @{ Command = $map[$choice]; ProfilePath = '' }
    if ($sel.Command -in 'verify', 'set', 'batch') { $sel.ProfilePath = ([string](Read-Host (T menuProfile))).Trim().Trim('"') }
    $sel
}
