<#
.SYNOPSIS
  OMNIKEY 5022 batch provisioning (USB hub, large series of units).
  v9: profile-driven (v8: no PS closures; v9: Apply-All returns hashtable - empty-array unroll fix) (same JSON as Omnikey5022-Tool), full Set+Verify per unit,
      CSV audit with serial, product name, firmware and an inventory number column.

.DESCRIPTION
  Workflow per batch: plug units into a powered hub -> script waits until the reader
  count is stable (-StableSec) -> for each unit: reads serial/product/firmware,
  compares ALL profile parameters, applies only when needed, reboots, verifies by
  serial -> beep + CSV -> unplug batch -> next. Ctrl+C to finish. Resumable via CSV.

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

$MSG = @{
  en = @{ wait="[WAIT] Plug in a batch of readers..."; unplug="[WAIT] Unplug the whole batch..."
          batch="[BATCH #{0}] Detected {1} unit(s)."; state="  [{0}] {1} fw:{2}"
          already="already compliant"; cfg="configured and verified"; readErr="read error"
          pend="  Rebooting {0} unit(s) - verifying in {1}s..."; sum="[BATCH #{0}] PASS: {1}  FAIL: {2}   | SESSION: {3} OK / {4} FAIL / total in CSV: {5}"
          done="Session finished. PASS: {0}, FAIL: {1}, total in CSV: {2}"; resume="Previously done (CSV): {0} unit(s)" }
  pl = @{ wait="[WAIT] Wepnij partie czytnikow..."; unplug="[WAIT] Odepnij cala partie..."
          batch="[PARTIA #{0}] Wykryto {1} szt."; state="  [{0}] {1} fw:{2}"
          already="juz zgodny z profilem"; cfg="skonfigurowano i zweryfikowano"; readErr="blad odczytu"
          pend="  Reboot {0} szt. - weryfikacja za {1}s..."; sum="[PARTIA #{0}] PASS: {1}  FAIL: {2}   | SESJA: {3} OK / {4} FAIL / w CSV: {5}"
          done="Koniec sesji. PASS: {0}, FAIL: {1}, w CSV: {2}"; resume="Zrobione wczesniej (CSV): {0} szt." }
}
$M=$MSG[$Lang]; function T($k,$a0="",$a1="",$a2="",$a3="",$a4="",$a5=""){ $M[$k] -f $a0,$a1,$a2,$a3,$a4,$a5 }

if (-not ("OmniBatch.WinSCard" -as [type])) {
Add-Type -TypeDefinition @"
namespace OmniBatch {
using System;
using System.Runtime.InteropServices;
public static class WinSCard {
    [DllImport("winscard.dll")] public static extern int SCardEstablishContext(uint scope, IntPtr r1, IntPtr r2, out IntPtr ctx);
    [DllImport("winscard.dll")] public static extern int SCardReleaseContext(IntPtr ctx);
    [DllImport("winscard.dll", CharSet=CharSet.Unicode)] public static extern int SCardListReaders(IntPtr ctx, string groups, char[] readers, ref uint size);
    [DllImport("winscard.dll", CharSet=CharSet.Unicode)] public static extern int SCardConnect(IntPtr ctx, string reader, uint shareMode, uint protocols, out IntPtr card, out uint activeProtocol);
    [DllImport("winscard.dll")] public static extern int SCardDisconnect(IntPtr card, uint disposition);
    [DllImport("winscard.dll")] public static extern int SCardControl(IntPtr card, uint code, byte[] inBuf, uint inLen, byte[] outBuf, uint outLen, out uint retLen);
}
}
"@
}
$SCOPE=2; $DIRECT=3; $LEAVE=0; $ESCAPE=0x3136B0; $NO_READERS=0x8010002E

function HexToBytes([string]$h){ $h=$h -replace '\s',''; ,(0..($h.Length/2-1)|%{[byte]::Parse($h.Substring($_*2,2),'HexNumber')}) }
function BytesToHex([byte[]]$b,[int]$l){ if($l -le 0){return ""}; ($b[0..($l-1)]|%{$_.ToString("X2")}) -join '' }

$script:ctx=[IntPtr]::Zero; $script:ctxResets=0; $script:lastErr=""
function Ensure-Context { if($script:ctx -ne [IntPtr]::Zero){return}; $c=[IntPtr]::Zero
    if([OmniBatch.WinSCard]::SCardEstablishContext($SCOPE,[IntPtr]::Zero,[IntPtr]::Zero,[ref]$c) -eq 0){$script:ctx=$c} }
function Reset-Context { if($script:ctx -ne [IntPtr]::Zero){[void][OmniBatch.WinSCard]::SCardReleaseContext($script:ctx);$script:ctx=[IntPtr]::Zero}; $script:ctxResets++; Ensure-Context }
function Get-Readers {
    Ensure-Context; if($script:ctx -eq [IntPtr]::Zero){return @()}
    $size=[uint32]0
    $rc=[OmniBatch.WinSCard]::SCardListReaders($script:ctx,$null,$null,[ref]$size)
    if($rc -ne 0){ if(($rc -band 0xFFFFFFFF) -ne $NO_READERS){Reset-Context}; return @() }
    $buf=New-Object char[] $size
    $rc=[OmniBatch.WinSCard]::SCardListReaders($script:ctx,$null,$buf,[ref]$size)
    if($rc -ne 0){ if(($rc -band 0xFFFFFFFF) -ne $NO_READERS){Reset-Context}; return @() }
    return ,@((-join $buf).Split([char]0) | Where-Object { $_ -and $_ -match $ReaderMatch })
}
function Send-Escape([IntPtr]$card,[string]$apdu) {
    $in=HexToBytes $apdu; $out=New-Object byte[] 512; $ret=[uint32]0
    $rc=[OmniBatch.WinSCard]::SCardControl($card,$ESCAPE,$in,$in.Length,$out,$out.Length,[ref]$ret)
    if($rc -ne 0){ throw ("0x{0:X8}" -f $rc) }
    BytesToHex $out $ret
}
function With-Reader([string]$reader,[scriptblock]$block) {
    $script:lastErr=""; Ensure-Context
    if($script:ctx -eq [IntPtr]::Zero){$script:lastErr="no-ctx";return $null}
    if(-not $reader){$script:lastErr="null-reader";return $null}
    $card=[IntPtr]::Zero; $p=[uint32]0
    $rc=[OmniBatch.WinSCard]::SCardConnect($script:ctx,$reader,$DIRECT,0,[ref]$card,[ref]$p)
    if($rc -ne 0){ $script:lastErr=("connect:0x{0:X8}" -f $rc)
        if(($rc -band 0xFFFFFFFF) -notin @($NO_READERS)){Reset-Context}; return $null }
    try { & $block $card } catch { $script:lastErr="escape:$($_.Exception.Message)"; $null }
    finally { [void][OmniBatch.WinSCard]::SCardDisconnect($card,$LEAVE) }
}

# ---------- AViatoR TLV ----------
function Apdu-Get([string]$tech,[string]$sub){ "FF70076B0AA208A006A404"+$tech+"02"+$sub+"0000" }
function Apdu-Set([string]$tech,[string]$sub,[string]$val){ "FF70076B0BA209A107A405"+$tech+"03"+$sub+"01"+$val+"00" }
$APDU_APPLY="FF70076B08A206A104A902800000"; $APDU_REBOOT="FF70076B08A206A104A902830000"
$APDU_SERIAL="FF70076B08A206A004A002920000"; $APDU_PRODUCT="FF70076B08A206A004A002820000"
$APDU_FW="FF70076B08A206A004A002850000";     $APDU_POLL_GET="FF70076B0AA208A006A404A002890000"
function Apdu-PollSet([byte[]]$o){ "FF70076B0FA20DA10BA409A0078905"+(($o|%{$_.ToString("X2")}) -join '')+"00" }

function Parse-Bool([string]$r,[string]$s){ if($r -match ('^BD03'+$s+'01(00|01)9000$')){return ($Matches[1] -eq "01")}; $null }
function Parse-Byte([string]$r,[string]$s){ if($r -match ('^BD03'+$s+'01([0-9A-F]{2})9000$')){return [Convert]::ToByte($Matches[1],16)}; $null }
function Parse-Ascii([string]$r){ if($r -notmatch '^BD' -or $r -notmatch '9000$'){return $null}
    $b=HexToBytes $r; if($b.Length -lt 5){return $null}; $len=[int]$b[3]; if($b.Length -lt (4+$len)){return $null}
    ((-join ($b[4..(3+$len)]|%{[char]$_})) -replace "`0","").Trim() }
function Read-Identity([IntPtr]$card) {
    $sn = Parse-Ascii (Send-Escape $card $APDU_SERIAL)
    $pn = Parse-Ascii (Send-Escape $card $APDU_PRODUCT)
    $fwr = Send-Escape $card $APDU_FW
    $fw = if ($fwr -match '^BD058503([0-9A-F]{2})([0-9A-F]{2})([0-9A-F]{2})9000$') {
        "{0}.{1}.{2}" -f [Convert]::ToByte($Matches[1],16),[Convert]::ToByte($Matches[2],16),[Convert]::ToByte($Matches[3],16)
    } else { "?" }
    @{ Serial=$sn; Product=$pn; Fw=$fw }
}

function BaudTo-Byte($rxL,$txL){ $m=@{212=1;424=2;848=4}; $rx=0;$tx=0
    foreach($v in @($rxL)){ if($m.ContainsKey([int]$v)){$rx=$rx -bor $m[[int]$v]} }
    foreach($v in @($txL)){ if($m.ContainsKey([int]$v)){$tx=$tx -bor $m[[int]$v]} }
    [byte](($rx -shl 4) -bor $tx) }
$FreqNames=@("41Hz","20Hz","10Hz","5Hz","2.5Hz","1.3Hz","0.7Hz","0.3Hz","0.15Hz","0.08Hz")
$PollNames=@{0="none";1="iso15693";2="iso14443a";3="iso14443b";4="iclass";6="felica"}
$PollCodes=@{"none"=0;"iso15693"=1;"iso14443a"=2;"iso14443b"=3;"iclass"=4;"felica"=6}

# ---------- ops from profile (data-only; no closures - see v8 fix) ----------
function Build-Ops($p) {
    $ops=New-Object System.Collections.ArrayList
    function AddBool($name,$tech,$sub,$want){
        [void]$ops.Add(@{name=$name;kind="bool";tech=$tech;sub=$sub;want=[bool]$want;wantDisp=$want}) }
    function AddBaud($name,$tech,$rx,$tx){
        $wb=BaudTo-Byte $rx $tx
        [void]$ops.Add(@{name=$name;kind="baud";tech=$tech;want=$wb;wantDisp=("0x{0:X2}" -f $wb)}) }
    if($p.iso14443a){ $a=$p.iso14443a
        if($null -ne $a.enabled){AddBool "iso14443a.enabled" "A2" "80" $a.enabled}
        if($null -ne $a.mifarePreferred){AddBool "iso14443a.mifarePreferred" "A2" "84" $a.mifarePreferred}
        if($null -ne $a.mifareKeyCache){AddBool "iso14443a.mifareKeyCache" "A2" "83" $a.mifareKeyCache}
        if($a.rx -or $a.tx){AddBaud "iso14443a.baud" "A2" $a.rx $a.tx} }
    if($p.iso14443b){ $b=$p.iso14443b
        if($null -ne $b.enabled){AddBool "iso14443b.enabled" "A3" "80" $b.enabled}
        if($b.rx -or $b.tx){AddBaud "iso14443b.baud" "A3" $b.rx $b.tx} }
    if($p.iso15693 -and $null -ne $p.iso15693.enabled){AddBool "iso15693.enabled" "A4" "80" $p.iso15693.enabled}
    if($p.felica){ if($null -ne $p.felica.enabled){AddBool "felica.enabled" "A5" "80" $p.felica.enabled}
        if($p.felica.rx -or $p.felica.tx){AddBaud "felica.baud" "A5" $p.felica.rx $p.felica.tx} }
    if($p.iclass -and $null -ne $p.iclass.enabled){AddBool "iclass.enabled" "A6" "83" $p.iclass.enabled}
    if($null -ne $p.emdSuppression){AddBool "emdSuppression" "A0" "87" $p.emdSuppression}
    if($null -ne $p.sleepModeCardDetection){AddBool "sleepModeCardDetection" "A0" "8E" $p.sleepModeCardDetection}
    if($p.sleepModePollingFrequency){
        $idx=[Array]::IndexOf($FreqNames,[string]$p.sleepModePollingFrequency)
        if($idx -lt 0){throw "sleepModePollingFrequency: '$($p.sleepModePollingFrequency)'"}
        [void]$ops.Add(@{name="sleepModePollingFrequency";kind="freq";idx=[byte]$idx;wantDisp=$FreqNames[$idx]}) }
    if($p.pollingSearchOrder){
        $names=@($p.pollingSearchOrder|%{([string]$_).ToLower()})
        $codes=New-Object byte[] 5
        for($i=0;$i -lt 5;$i++){ if($i -lt $names.Count){
            if(-not $PollCodes.ContainsKey($names[$i])){throw "pollingSearchOrder: '$($names[$i])'"}
            $codes[$i]=[byte]$PollCodes[$names[$i]] } else {$codes[$i]=0} }
        [void]$ops.Add(@{name="pollingSearchOrder";kind="poll";codes=$codes
                         wantHex=(($codes|%{$_.ToString("X2")}) -join '');wantDisp=($names -join ",")}) }
    ,$ops
}
function Invoke-OpApply([IntPtr]$card,$op){
    switch($op.kind){
        "bool" { $r=Send-Escape $card (Apdu-Set $op.tech $op.sub $(if($op.want){"01"}else{"00"})); if($r -notmatch '9000$'){throw $r} }
        "baud" { $r=Send-Escape $card (Apdu-Set $op.tech "81" ($op.want.ToString("X2")));           if($r -notmatch '9000$'){throw $r} }
        "freq" { $r=Send-Escape $card (Apdu-Set "A0" "8D" ($op.idx.ToString("X2")));               if($r -notmatch '9000$'){throw $r} }
        "poll" { $r=Send-Escape $card (Apdu-PollSet $op.codes);                                    if($r -notmatch '9000$'){throw $r} }
    }
}
function Invoke-OpCheck([IntPtr]$card,$op){
    switch($op.kind){
        "bool" { $h=Parse-Bool (Send-Escape $card (Apdu-Get $op.tech $op.sub)) $op.sub; return @{ok=($h -eq $op.want);have=$h} }
        "baud" { $h=Parse-Byte (Send-Escape $card (Apdu-Get $op.tech "81")) "81";       return @{ok=($h -eq $op.want);have=("0x{0:X2}" -f $h)} }
        "freq" { $h=Parse-Byte (Send-Escape $card (Apdu-Get "A0" "8D")) "8D";           return @{ok=($h -eq $op.idx);have=$h} }
        "poll" { $pr=Send-Escape $card $APDU_POLL_GET
                 if($pr -match '^BD078905([0-9A-F]{10})9000$'){ return @{ok=($Matches[1] -eq $op.wantHex);have=$Matches[1]} }
                 return @{ok=$false;have="?"} }
    }
}
# check all ops; returns @{ok; bad=@(names)}
function Check-All([IntPtr]$card,$ops){
    $bad=@()
    foreach($op in $ops){ try{ $r=Invoke-OpCheck $card $op; if(-not $r.ok){$bad+=$op.name} } catch { $bad+=$op.name } }
    @{ok=($bad.Count -eq 0); bad=$bad}
}
function Apply-All([IntPtr]$card,$ops){
    # returns a hashtable (never an array!) - empty arrays unroll to $null across
    # function boundaries in PowerShell, making success indistinguishable from a
    # connection failure (v9 fix)
    $bad=@()
    foreach($op in $ops){ try{ Invoke-OpApply $card $op } catch { $bad+=("{0}({1})" -f $op.name,$_.Exception.Message) } }
    if($bad.Count -eq 0){ [void](Send-Escape $card $APDU_APPLY); try{[void](Send-Escape $card $APDU_REBOOT)}catch{} }
    @{errors=$bad}
}

# ---------- CSV / inventory ----------
$CsvHeader="timestamp;serial;product_name;firmware;inventory_number;result;detail"
$inv=@{}
if($InventoryMap -and (Test-Path $InventoryMap)){
    Import-Csv $InventoryMap -Delimiter ';' | ForEach-Object { if($_.serial){$inv[$_.serial]=$_.inventory_number} }
}
function Write-Log([hashtable]$id,[string]$result,[string]$detail){
    if(-not (Test-Path $LogCsv)){ $CsvHeader | Out-File $LogCsv -Encoding utf8 }
    $invNo = if($id.Serial -and $inv.ContainsKey($id.Serial)){$inv[$id.Serial]}else{""}
    "{0};{1};{2};{3};{4};{5};{6}" -f (Get-Date -Format s),$id.Serial,$id.Product,$id.Fw,$invNo,$result,$detail |
        Out-File $LogCsv -Append -Encoding utf8
}
function Beep-Ok{ try{[console]::Beep(1200,120);[console]::Beep(1600,180)}catch{} }
function Beep-Fail{ try{[console]::Beep(400,600)}catch{} }

# dot-sourced (tests): expose functions only, never touch PC/SC or the CSV
if ($MyInvocation.InvocationName -eq '.') { return }

# ---------- profile + resume ----------
$prof = Get-Content $ProfilePath -Raw | ConvertFrom-Json
$ops  = Build-Ops $prof
$done=@{}
if(Test-Path $LogCsv){ Import-Csv $LogCsv -Delimiter ';' | Where-Object {$_.result -eq "PASS"} | ForEach-Object { $done[$_.serial]=$true } }

Ensure-Context
if($script:ctx -eq [IntPtr]::Zero){ throw "SCardSvr?" }
Write-Host "=== OMNIKEY BATCH PROVISIONING ($ReaderMatch) | profile: $ProfilePath | params: $($ops.Count) ===" -ForegroundColor Cyan
Write-Host ((T resume $done.Count) + " | CSV: $LogCsv`n")
$sPass=0;$sFail=0;$batchNo=0

try {
  while($true) {
    Write-Host (T wait) -ForegroundColor DarkGray
    $count=0;$stableFor=0
    while($true){
        Start-Sleep -Milliseconds $PollMs
        $now=(Get-Readers).Count
        if($now -gt 0 -and $now -eq $count){ $stableFor+=$PollMs; if($stableFor -ge ($StableSec*1000)){break} } else {$stableFor=0}
        $count=$now
    }
    $batchNo++
    $readers=Get-Readers
    Write-Host ("`n"+(T batch $batchNo $readers.Count)) -ForegroundColor Cyan

    $batch=@{}   # serial -> @{id; status; detail; verified}
    foreach($r in $readers){
        $data = With-Reader $r { param($card)
            $id = Read-Identity $card
            if(-not $id.Serial){ return $null }
            $chk = Check-All $card $ops
            @{ Id=$id; Compliant=$chk.ok; Bad=$chk.bad }
        }
        if(-not $data){
            Write-Host ("  [$r] "+(T readErr)+" ($script:lastErr)") -ForegroundColor Red
            Write-Log @{Serial="UNKNOWN";Product="?";Fw="?"} "FAIL" ((T readErr)+" ($r / $script:lastErr)"); $sFail++
            continue
        }
        $id=$data.Id; $sn=$id.Serial
        Write-Host (T state $sn $id.Product $id.Fw)
        if($data.Compliant){
            $batch[$sn]=@{id=$id;status="PASS";detail=(T already);verified=$true}
            continue
        }
        $res = With-Reader $r { param($card) Apply-All $card $ops }
        if($null -eq $res){ $batch[$sn]=@{id=$id;status="FAIL";detail="apply: connection lost ($script:lastErr)";verified=$true} }
        elseif($res.errors.Count -gt 0){ $batch[$sn]=@{id=$id;status="FAIL";detail=("apply: "+($res.errors -join ","));verified=$true} }
        else { $batch[$sn]=@{id=$id;status="PENDING";detail="";verified=$false} }
    }

    $pending=@($batch.Keys | Where-Object {-not $batch[$_].verified})
    if($pending.Count -gt 0){
        Write-Host (T pend $pending.Count $RebootWait)
        Start-Sleep -Seconds $RebootWait
        $trace=@{scans=0;maxR=0;seen=@{};errs=@{}}; $kick=$false
        for($i=0;$i -lt $VerifyRetry -and $pending.Count -gt 0;$i++){
            $trace.scans++
            $cur=Get-Readers
            $trace.maxR=[Math]::Max($trace.maxR,$cur.Count)
            foreach($r in $cur){
                $data = With-Reader $r { param($card)
                    $id=Read-Identity $card
                    if(-not $id.Serial){ return $null }
                    $chk=Check-All $card $ops
                    @{ Id=$id; Ok=$chk.ok; Bad=$chk.bad } }
                if(-not $data){ if($script:lastErr){$trace.errs[$script:lastErr]=$true}; continue }
                $sn=$data.Id.Serial; $trace.seen[$sn]=$true
                if($sn -in $pending){
                    if($data.Ok){ $batch[$sn]=@{id=$data.Id;status="PASS";detail=(T cfg);verified=$true} }
                    else        { $batch[$sn]=@{id=$data.Id;status="FAIL";detail=("mismatch: "+($data.Bad -join ","));verified=$true} }
                    $pending=@($pending | Where-Object {$_ -ne $sn})
                }
            }
            if(-not $kick -and $pending.Count -gt 0 -and $i -ge [int]($VerifyRetry/2)){ Reset-Context; $kick=$true }
            if($pending.Count -gt 0){ Start-Sleep -Milliseconds $PollMs }
        }
        foreach($sn in $pending){
            $diag=("scans:{0} maxReaders:{1} serialsSeen:[{2}] errors:[{3}] ctxResets:{4}" -f `
                   $trace.scans,$trace.maxR,(($trace.seen.Keys|Sort-Object) -join ","),(($trace.errs.Keys|Select -First 5) -join " | "),$script:ctxResets)
            $batch[$sn]=@{id=$batch[$sn].id;status="FAIL";detail="verify failed: $diag";verified=$true}
        }
    }

    $pass=0;$fail=0
    foreach($sn in $batch.Keys){
        $b=$batch[$sn]
        if($b.status -eq "PASS"){$pass++;$done[$sn]=$true}else{$fail++}
        Write-Log $b.id $b.status $b.detail
        Write-Host ("  {0}: {1} - {2}" -f $sn,$b.status,$b.detail) -ForegroundColor $(if($b.status -eq "PASS"){"Green"}else{"Red"})
    }
    $sPass+=$pass;$sFail+=$fail
    Write-Host (T sum $batchNo $pass $fail $sPass $sFail $done.Count) -ForegroundColor Cyan
    if($fail -eq 0){Beep-Ok}else{Beep-Fail}

    Write-Host (T unplug) -ForegroundColor DarkGray
    while((Get-Readers).Count -gt 0){ Start-Sleep -Milliseconds $PollMs }
    Write-Host ""
  }
}
finally {
    if($script:ctx -ne [IntPtr]::Zero){ [void][OmniBatch.WinSCard]::SCardReleaseContext($script:ctx) }
    Write-Host ("`n"+(T done $sPass $sFail $done.Count))
}
