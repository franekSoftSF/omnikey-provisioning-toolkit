# Way back for every change: a backup of the reader's settings before Omnikey.ps1 writes anything,
# and "restore" - from a backup of this reader, from any profile file, or factory defaults
# (HID ReaderConfigurationControl.RestoreFactoryDefaults). Backups are ordinary profiles plus a
# "_backup" block, so set/verify/batch accept them too.

$script:BackupDir = '.\omnikey-backups'

function Get-BackupFileName($model, $identity) {
    $serial = if ($identity.Serial) { $identity.Serial } else { 'no-serial' }
    $name = "{0}_{1}_{2}.json" -f $model.product, $serial, (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    $name -replace '[^A-Za-z0-9._-]', '-'
}

# snapshot of the reader as a profile in $dir; returns the file path
function Save-ReaderBackup([IntPtr]$card, $model, $identity, [string]$reader, [string]$dir) {
    if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    $snapshot = Get-ReaderProfile $card $model
    $out = [ordered]@{
        _backup = [ordered]@{
            product = $model.product; serial = [string]$identity.Serial; firmware = $identity.Fw
            reader = $reader; created = (Get-Date -Format s)
        }
    }
    foreach ($k in $snapshot.Keys) { $out[$k] = $snapshot[$k] }
    $path = Join-Path $dir (Get-BackupFileName $model $identity)
    $out | ConvertTo-Json -Depth 5 | Out-File $path -Encoding utf8
    Write-Host (T backupSaved (Resolve-Path $path).Path) -ForegroundColor DarkGray
    $path
}

# backups of this reader (same product and serial), newest first
function Get-ReaderBackup([string]$dir, $model, $identity) {
    if (-not (Test-Path $dir)) { return ,@() }
    $serial = [string]$identity.Serial
    ,@(Get-ChildItem $dir -Filter *.json | ForEach-Object {
        try { $p = Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { return }
        if ($p._backup -and $p._backup.product -eq $model.product -and [string]$p._backup.serial -eq $serial) {
            $c = $p._backup.created      # PowerShell 7 turns the ISO text into a DateTime, 5.1 keeps the string
            $created = if ($c -is [datetime]) { $c.ToString('yyyy-MM-dd HH:mm:ss') } else { ([string]$c) -replace 'T', ' ' }
            @{ path = $_.FullName; name = $_.Name; created = $created }
        }
    } | Sort-Object { $_.created } -Descending)
}

function Invoke-ReaderRestore([string]$readerMatch, [bool]$interactive, [string]$lang, [bool]$noReboot, [string]$profilePath, [string]$backupDir) {
    if ($lang) { Set-MessageLanguage $lang }
    $match = Resolve-SingleReader $readerMatch $interactive
    $all = Get-ReaderList
    $reader = $all | Where-Object { $_ -match $match } | Select-Object -First 1
    $info = Invoke-WithReader $reader {
        param($card)
        $id = Read-Identity $card
        @{ Id = $id; Model = (Resolve-ReaderModel $id) }
    } $null
    Close-Context
    if (-not $info) { throw ((T connectFail) + " ($script:lastErr)") }

    $model = $info.Model
    Write-Host ("{0}: {1}" -f (T reader), $reader) -ForegroundColor Cyan
    Write-Host ("{0}: {1}`n" -f (T serial), $(if ($info.Id.Serial) { $info.Id.Serial } else { "?" })) -ForegroundColor Cyan
    Write-ModelNote $model
    if (-not $model.known) { throw (T modelNoWrite $model.product) }
    Write-Host (T restoreTitle $model.product) -ForegroundColor Cyan

    $source = $profilePath
    if (-not $source) {
        $choice = ([string](Read-Host (T restoreChoose))).Trim()
        switch ($choice) {
            { $_ -in '', '1' } {
                $backups = Get-ReaderBackup $backupDir $model $info.Id
                if ($backups.Count -eq 0) { Write-Host (T restoreNoBackups $backupDir) -ForegroundColor Yellow; return [int]0 }
                for ($i = 0; $i -lt $backups.Count; $i++) { Write-Host (T restoreBackupLine ($i + 1) $backups[$i].created $backups[$i].name) }
                $pick = ([string](Read-Host (T restorePick))).Trim()
                $n = 1
                if ($pick -and (-not [int]::TryParse($pick, [ref]$n) -or $n -lt 1 -or $n -gt $backups.Count)) { throw (T menuInvalid $pick) }
                $source = $backups[$n - 1].path
                break
            }
            '2' {
                $source = ([string](Read-Host (T menuProfile))).Trim().Trim('"')
                if (-not $source) { throw (T profileNeeded 'restore') }
                break
            }
            '3' { return [int](Invoke-FactoryDefault $reader $model $info.Id $noReboot $backupDir) }
            default { throw (T menuInvalid $choice) }
        }
    }

    try { $prof = Get-Content $source -Raw | ConvertFrom-Json } catch { throw (T profileBad $_.Exception.Message) }
    $ops = ConvertTo-OperationList $prof $model
    $chk = Invoke-WithReader $reader { param($card, $o) Invoke-OpCheckAll $card $o } $ops
    Close-Context
    if ($null -eq $chk) { throw ((T connectFail) + " ($script:lastErr)") }
    if ($chk.ok) { Write-Host (T restoreSame) -ForegroundColor Green; return [int]0 }

    Write-Host ""
    Write-Host (T cfgChanges) -ForegroundColor Cyan
    foreach ($d in $chk.diff) { Write-Host (T cfgChange $d.name $(if ($null -eq $d.have) { "?" } else { $d.have }) $d.want) -ForegroundColor Yellow }
    $apply = ([string](Read-Host (T cfgApply $chk.diff.Count))).Trim()
    if ($apply -notmatch '^(y|yes|t|tak)$') { Write-Host (T cfgNotApplied) -ForegroundColor Yellow; return [int]0 }

    # write only the parameters that differ (same mapping as configure: op name = question key)
    $answers = @{}
    foreach ($name in $chk.bad) {
        $q = $script:ConfigQuestions | Where-Object { $_.key -eq $name } | Select-Object -First 1
        $answers[$name] = Get-ConfigCurrentValue $prof $q
    }
    $delta = ConvertTo-AnswerProfile $answers @($chk.bad)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("omnikey-restore-{0}.json" -f [guid]::NewGuid().ToString('N'))
    try {
        $delta | ConvertTo-Json -Depth 4 | Out-File $tmp -Encoding utf8
        Write-Host ""
        [int](Invoke-OmnikeyTool -Mode Set -ProfilePath $tmp -Lang $(if ($lang) { $lang } else { 'en' }) `
            -ReaderMatch ('^' + [regex]::Escape($reader) + '$') -NoReboot:$noReboot -BackupDir $backupDir)
    }
    finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

# factory defaults: warning + confirmation, backup first, then RestoreFactoryDefaults and reboot
function Invoke-FactoryDefault([string]$reader, $model, $identity, [bool]$noReboot, [string]$backupDir) {
    Write-Host ""
    Write-Host (T factoryWarn) -ForegroundColor Yellow
    $apply = ([string](Read-Host (T factoryConfirm $model.product))).Trim()
    if ($apply -notmatch '^(y|yes|t|tak)$') { Write-Host (T cfgNotApplied) -ForegroundColor Yellow; return [int]0 }
    $res = Invoke-WithReader $reader {
        param($card, $a)
        [void](Save-ReaderBackup $card $a.model $a.identity $a.reader $a.dir)
        $r = Send-Escape $card $script:APDU_FACTORY_DEFAULTS
        if ($r -notmatch '9000$') { throw $r }
        if (-not $a.noReboot) { try { [void](Send-Escape $card $script:APDU_REBOOT) } catch { } }
        @{ ok = $true }
    } @{ model = $model; identity = $identity; reader = $reader; dir = $backupDir; noReboot = $noReboot }
    Close-Context
    if (-not $res) { throw ((T factoryFail) + " ($script:lastErr)") }
    Write-Host (T factoryDone) -ForegroundColor Green
    if ($noReboot) { Write-Host (T rebootSkip) -ForegroundColor Yellow }
    [int]0
}
