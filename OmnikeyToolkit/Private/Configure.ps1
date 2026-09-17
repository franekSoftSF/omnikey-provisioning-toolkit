# Interactive configuration ("configure"): one question per parameter the connected model supports,
# the reader's current value as default (Enter keeps it), a summary of the changes, an optional
# profile file, and - after confirmation - only the changed parameters are applied through the
# normal Set path. Everything is data-driven (lesson 1): questions are hashtables.

$script:ConfigQuestions = @(
    @{ key = 'iso14443a.enabled';           type = 'bool'; section = 'iso14443a'; field = 'enabled' }
    @{ key = 'iso14443a.mifarePreferred';   type = 'bool'; section = 'iso14443a'; field = 'mifarePreferred'; dependsOn = 'iso14443a.enabled' }
    @{ key = 'iso14443a.mifareKeyCache';    type = 'bool'; section = 'iso14443a'; field = 'mifareKeyCache'; dependsOn = 'iso14443a.enabled' }
    @{ key = 'iso14443a.baud';              type = 'baud'; section = 'iso14443a'; dependsOn = 'iso14443a.enabled' }
    @{ key = 'iso14443b.enabled';           type = 'bool'; section = 'iso14443b'; field = 'enabled' }
    @{ key = 'iso14443b.baud';              type = 'baud'; section = 'iso14443b'; dependsOn = 'iso14443b.enabled' }
    @{ key = 'iso15693.enabled';            type = 'bool'; section = 'iso15693';  field = 'enabled' }
    @{ key = 'felica.enabled';              type = 'bool'; section = 'felica';    field = 'enabled' }
    @{ key = 'felica.baud';                 type = 'baud'; section = 'felica'; dependsOn = 'felica.enabled' }
    @{ key = 'iclass.enabled';              type = 'bool'; section = 'iclass';    field = 'enabled' }
    @{ key = 'emdSuppression';              type = 'bool'; field = 'emdSuppression' }
    @{ key = 'sleepModeCardDetection';      type = 'bool'; field = 'sleepModeCardDetection' }
    @{ key = 'sleepModePollingFrequency';   type = 'freq'; field = 'sleepModePollingFrequency' }
    @{ key = 'pollingSearchOrder';          type = 'poll'; field = 'pollingSearchOrder' }
    @{ key = 'contactSlot.enabled';         type = 'bool'; section = 'contactSlot'; field = 'enabled' }
    @{ key = 'contactSlot.operatingMode';   type = 'mode'; section = 'contactSlot'; field = 'operatingMode'; dependsOn = 'contactSlot.enabled' }
    @{ key = 'contactSlot.voltageSequence'; type = 'volt'; section = 'contactSlot'; field = 'voltageSequence'; dependsOn = 'contactSlot.enabled' }
)

# value of one question in a profile (reader snapshot or preset; dictionary or JSON object)
function Get-ConfigCurrentValue($readerProfile, $q) {
    if ($null -eq $readerProfile) { return $null }
    $container = if ($q.section) { $readerProfile.($q.section) } else { $readerProfile }
    if ($null -eq $container) { return $null }
    if ($q.type -eq 'baud') {
        if ($null -eq $container.rx -and $null -eq $container.tx) { return $null }
        return @{ rx = @($container.rx | Where-Object { $null -ne $_ }); tx = @($container.tx | Where-Object { $null -ne $_ }) }
    }
    $container.($q.field)
}

# ---------- presets: ready-made starting points (OmnikeyToolkit/Presets/*.json, normal profiles) ----------
$script:PresetRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'Presets'

# presets usable with this model: every key in "_requires" must be supported
function Get-ConfigPreset($model) {
    if (-not (Test-Path $script:PresetRoot)) { return ,@() }
    ,@(Get-ChildItem $script:PresetRoot -Filter *.json | Sort-Object Name | ForEach-Object {
        $p = Get-Content $_.FullName -Raw | ConvertFrom-Json
        $req = @($p._requires)
        if (@($req | Where-Object { @($model.profileKeys) -notcontains $_ }).Count -eq 0) {
            @{ id = $_.BaseName; profile = $p }
        }
    })
}

# pollingSearchOrder default: drop technologies the operator has just switched off
function Get-PollingDefault($current, [hashtable]$answers) {
    if ($null -eq $current) { return $null }
    $enabledKey = @{ iso14443a = 'iso14443a.enabled'; iso14443b = 'iso14443b.enabled'; iso15693 = 'iso15693.enabled'; felica = 'felica.enabled'; iclass = 'iclass.enabled' }
    $kept = @($current | Where-Object { -not ($enabledKey.ContainsKey($_) -and $answers[$enabledKey[$_]] -eq $false) })
    if ($kept.Count -eq 0) { return ,@($current) }
    ,$kept
}

function Format-ConfigList($v) {
    if ($null -eq $v) { return "?" }
    $items = @($v | Where-Object { $null -ne $_ -and $_ -ne 106 })
    if ($items.Count -eq 0) { return "-" }
    $items -join ","
}

# value as shown in questions and in the change summary
function Format-ConfigValue([string]$type, $v) {
    if ($null -eq $v) { return "?" }
    switch ($type) {
        'baud' { return "rx:{0} tx:{1}" -f (Format-ConfigList $v.rx), (Format-ConfigList $v.tx) }
        'poll' { return (Format-ConfigList $v) }
        'volt' { if ($v -is [string]) { return $v }; return (Format-ConfigList $v) }
        default { return "$v" }
    }
}

function Split-ConfigAnswer([string]$answer) { @($answer -split '[,;\s]+' | Where-Object { $_ }) }

# parse one answer; returns @{ ok; value; keepReader }. Enter keeps $current (the suggested value),
# "d" asks to leave the value the reader has now (differs from $current when a preset is used).
function ConvertFrom-ConfigAnswer([string]$type, [string]$answer, $current, $model, $rates) {
    $a = ([string]$answer).Trim()
    if (-not $a) { return @{ ok = $true; value = $current } }                                          # Enter = value in brackets
    if ($a -match '^(d|default|domyslnie)$') { return @{ ok = $true; value = $current; keepReader = $true } }   # d = leave the reader's value
    switch ($type) {
        'bool' {
            if ($a -match '^(y|yes|t|tak|true|1)$') { return @{ ok = $true; value = $true } }
            if ($a -match '^(n|no|nie|f|false|0)$') { return @{ ok = $true; value = $false } }
        }
        'rates' {
            if ($a -eq '-') { return @{ ok = $true; value = @() } }
            $vals = @()
            foreach ($t in (Split-ConfigAnswer $a)) {
                $n = 0
                if (-not [int]::TryParse($t, [ref]$n) -or (($rates -notcontains $n) -and $n -ne 106)) { return @{ ok = $false } }
                if ($n -ne 106 -and $vals -notcontains $n) { $vals += $n }
            }
            return @{ ok = $true; value = @($vals | Sort-Object) }
        }
        'freq' {
            $n = 0
            if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $script:FreqNames.Count) { return @{ ok = $true; value = $script:FreqNames[$n - 1] } }
            $hit = @($script:FreqNames | Where-Object { $_ -eq $a })
            if ($hit.Count -eq 1) { return @{ ok = $true; value = $hit[0] } }
        }
        'poll' {
            $names = @(Split-ConfigAnswer $a | ForEach-Object { $_.ToLower() })
            if ($names.Count -ge 1 -and $names.Count -le 5 -and @($names | Where-Object { -not $script:PollCodes.ContainsKey($_) }).Count -eq 0) {
                return @{ ok = $true; value = $names }
            }
        }
        'mode' {
            $names = @($script:OperatingModeNames[0], $script:OperatingModeNames[1])
            $n = 0
            if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $names.Count) { return @{ ok = $true; value = $names[$n - 1] } }
            $hit = @($names | Where-Object { $_ -eq $a })
            if ($hit.Count -eq 1) { return @{ ok = $true; value = $hit[0] } }
        }
        'volt' {
            if ($a -eq 'auto') { return @{ ok = $true; value = 'auto' } }
            $names = @(Split-ConfigAnswer $a | ForEach-Object { $t = $_; @($script:VoltageCodes.Keys | Where-Object { $_ -eq $t }) | Select-Object -First 1 })
            $given = @(Split-ConfigAnswer $a)
            if ($names.Count -eq $given.Count -and $names.Count -ge 1 -and $names.Count -le 3 -and @($names | Select-Object -Unique).Count -eq $names.Count) {
                return @{ ok = $true; value = $names }
            }
        }
    }
    @{ ok = $false }
}

# ask until a valid answer (3 attempts); returns @{ value } so empty lists and $null survive (lesson 2)
function Read-ConfigAnswer([string]$prompt, [string]$type, $current, $model, $rates, $readerValue) {
    for ($i = 0; $i -lt 3; $i++) {
        $answer = [string](Read-Host $prompt)
        $r = ConvertFrom-ConfigAnswer $type $answer $current $model $rates
        if ($r.ok -and $r.keepReader) { return @{ value = $readerValue } }
        if ($r.ok) { return @{ value = $r.value } }
        Write-Host (T cfgInvalid $answer) -ForegroundColor Yellow
    }
    throw (T menuInvalid $answer)
}

# profile (ordered) from answers; $keys limits which questions are included
function ConvertTo-AnswerProfile([hashtable]$answers, [string[]]$keys) {
    $p = [ordered]@{}
    foreach ($q in $script:ConfigQuestions) {
        if ($keys -notcontains $q.key -or -not $answers.ContainsKey($q.key)) { continue }
        $v = $answers[$q.key]
        if ($null -eq $v) { continue }
        if ($q.type -eq 'baud') {
            $rx = @($v.rx); $tx = @($v.tx)
            if ($rx.Count -eq 0 -and $tx.Count -eq 0) { $rx = @(106); $tx = @(106) }   # 106 only (an empty pair would be skipped)
            if (-not $p.Contains($q.section)) { $p[$q.section] = [ordered]@{} }
            $p[$q.section]['rx'] = $rx; $p[$q.section]['tx'] = $tx
        }
        elseif ($q.section) {
            if (-not $p.Contains($q.section)) { $p[$q.section] = [ordered]@{} }
            $p[$q.section][$q.field] = $v
        }
        else { $p[$q.field] = $v }
    }
    $p
}

function Invoke-ReaderConfigurator([string]$readerMatch, [bool]$interactive, [string]$lang, [bool]$noReboot, [string]$backupDir = "") {
    if ($lang) { Set-MessageLanguage $lang }
    $match = Resolve-SingleReader $readerMatch $interactive
    $all = Get-ReaderList                           # assign first: piping the ,@() list would pass it as one item
    $reader = $all | Where-Object { $_ -match $match } | Select-Object -First 1
    $info = Invoke-WithReader $reader {
        param($card)
        $id = Read-Identity $card
        $m = Resolve-ReaderModel $id
        @{ Id = $id; Model = $m; Profile = (Get-ReaderProfile $card $m) }
    } $null
    Close-Context                                   # do not hold the reader while the operator answers
    if (-not $info) { throw ((T connectFail) + " ($script:lastErr)") }

    $model = $info.Model
    Write-Host ("{0}: {1}" -f (T reader), $reader) -ForegroundColor Cyan
    Write-Host ("{0}: {1}`n" -f (T serial), $(if ($info.Id.Serial) { $info.Id.Serial } else { "?" })) -ForegroundColor Cyan
    Write-ModelNote $model
    if (-not $model.known) { throw (T modelNoWrite $model.product) }
    Write-Host (T cfgTitle $model.product) -ForegroundColor Cyan

    # optional starting point: a preset fills the defaults, changes are still counted against the reader
    $preset = $null
    $presets = Get-ConfigPreset $model
    if ($presets.Count -gt 0) {
        $opts = "1 = " + (T presetCurrent)
        for ($i = 0; $i -lt $presets.Count; $i++) { $opts += ", {0} = {1}" -f ($i + 2), (T ("preset." + $presets[$i].id)) }
        Write-Host ""
        $pick = ([string](Read-Host (T cfgPreset $opts))).Trim()
        $n = 0
        if ($pick -and $pick -ne '1') {
            if (-not [int]::TryParse($pick, [ref]$n) -or $n -lt 2 -or $n -gt $presets.Count + 1) { throw (T menuInvalid $pick) }
            $preset = $presets[$n - 2]
            Write-Host (T cfgPresetChosen (T ("preset." + $preset.id))) -ForegroundColor Green
        }
    }

    $answers = @{}; $asked = @(); $changed = @()
    foreach ($q in $script:ConfigQuestions) {
        if (@($model.profileKeys) -notcontains $q.key) { continue }
        if ($q.dependsOn -and $answers.ContainsKey($q.dependsOn) -and $answers[$q.dependsOn] -eq $false) { continue }   # technology switched off
        if ($q.type -eq 'volt' -and $model.emvcoVoltage -and $answers['contactSlot.operatingMode'] -eq 'emvco') { continue }   # fixed in EMVCo mode
        $asked += $q.key
        $cur = Get-ConfigCurrentValue $info.Profile $q
        $def = $cur
        if ($preset) { $pv = Get-ConfigCurrentValue $preset.profile $q; if ($null -ne $pv) { $def = $pv } }
        if ($q.type -eq 'poll') { $def = Get-PollingDefault $def $answers }
        Write-Host ""
        Write-Host ("  " + (T ("q." + $q.key))) -ForegroundColor Cyan
        switch ($q.type) {
            'bool' { $new = (Read-ConfigAnswer (T cfgAskBool $q.key (Format-ConfigValue 'bool' $def)) 'bool' $def $model $null $cur).value }
            'baud' {
                $rates = $script:BaudRates[$q.section]
                $defRx = $null; $defTx = $null
                if ($def) { $defRx = $def.rx; $defTx = $def.tx }   # no if-expression: it would unroll @() to $null
                $curRx = $null; $curTx = $null
                if ($cur) { $curRx = $cur.rx; $curTx = $cur.tx }
                $rx = (Read-ConfigAnswer (T cfgAskRates "$($q.key) rx" (Format-ConfigList $defRx) ($rates -join ' ')) 'rates' $defRx $model $rates $curRx).value
                $tx = (Read-ConfigAnswer (T cfgAskRates "$($q.key) tx" (Format-ConfigList $defTx) ($rates -join ' ')) 'rates' $defTx $model $rates $curTx).value
                $new = if ($null -eq $rx -and $null -eq $tx) { $null } else { @{ rx = @($rx | Where-Object { $null -ne $_ }); tx = @($tx | Where-Object { $null -ne $_ }) } }
            }
            'freq' {
                $opts = (@(0..($script:FreqNames.Count - 1) | ForEach-Object { "{0}={1}" -f ($_ + 1), $script:FreqNames[$_] }) -join ' ')
                $new = (Read-ConfigAnswer (T cfgAskChoice $q.key (Format-ConfigValue 'freq' $def) $opts) 'freq' $def $model $null $cur).value
            }
            'poll' {
                $opts = (($script:PollCodes.Keys | Sort-Object) -join ' ')
                $new = (Read-ConfigAnswer (T cfgAskList $q.key (Format-ConfigValue 'poll' $def) $opts) 'poll' $def $model $null $cur).value
            }
            'mode' { $new = (Read-ConfigAnswer (T cfgAskChoice $q.key (Format-ConfigValue 'mode' $def) "1=iso7816 2=emvco") 'mode' $def $model $null $cur).value }
            'volt' {
                $opts = "5V 3V 1.8V | auto"
                $new = (Read-ConfigAnswer (T cfgAskList $q.key (Format-ConfigValue 'volt' $def) $opts) 'volt' $def $model $null $cur).value
            }
        }
        $answers[$q.key] = $new
        $before = Format-ConfigValue $q.type $cur; $after = Format-ConfigValue $q.type $new
        if ($before -ne $after) { $changed += @{ key = $q.key; before = $before; after = $after } }
    }

    $full = ConvertTo-AnswerProfile $answers $asked
    $delta = ConvertTo-AnswerProfile $answers @($changed | ForEach-Object { $_.key })
    [void](ConvertTo-OperationList ($full | ConvertTo-Json -Depth 4 | ConvertFrom-Json) $model)   # validate before anything is saved or written

    Write-Host ""
    if ($changed.Count -eq 0) { Write-Host (T cfgNoChanges) -ForegroundColor Green }
    else {
        Write-Host (T cfgChanges) -ForegroundColor Cyan
        foreach ($c in $changed) { Write-Host (T cfgChange $c.key $c.before $c.after) -ForegroundColor Yellow }
    }

    $path = ([string](Read-Host (T cfgSave))).Trim().Trim('"')
    if ($path) {
        $full | ConvertTo-Json -Depth 4 | Out-File $path -Encoding utf8
        Write-Host (T cfgSaved (Resolve-Path $path).Path) -ForegroundColor Green
    }
    if ($changed.Count -eq 0) { return [int]0 }

    $apply = ([string](Read-Host (T cfgApply $changed.Count))).Trim()
    if ($apply -notmatch '^(y|yes|t|tak)$') { Write-Host (T cfgNotApplied) -ForegroundColor Yellow; return [int]0 }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("omnikey-configure-{0}.json" -f [guid]::NewGuid().ToString('N'))
    try {
        $delta | ConvertTo-Json -Depth 4 | Out-File $tmp -Encoding utf8
        Write-Host ""
        [int](Invoke-OmnikeyTool -Mode Set -ProfilePath $tmp -Lang $(if ($lang) { $lang } else { 'en' }) -ReaderMatch ('^' + [regex]::Escape($reader) + '$') -NoReboot:$noReboot -BackupDir $backupDir)
    }
    finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}
