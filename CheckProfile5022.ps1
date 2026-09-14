<#
.SYNOPSIS
  OMNIKEY 5022 Configuration Tool (AViatoR family: 5022/5122/5422 contactless slot).
  Modes: Get (dump), Set (apply profile), Verify (audit against profile, for testing).
  Messages: English (default) or Polish (-Lang pl).

.DESCRIPTION
  Talks to the reader over PC/SC in DIRECT mode using HID proprietary escape APDUs
  (source: github.com/hidglobal/HID-OMNIKEY-Sample-Codes). No card required.

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
    "pollingSearchOrder": ["iso14443a","iso14443b","iclass","felica","iso15693"]  // up to 5; also: "none"
  }

.EXAMPLE
  .\CheckProfile5022.ps1 -Mode Get
  .\CheckProfile5022.ps1 -Mode Set    -Profile bank-profile.json
  .\CheckProfile5022.ps1 -Mode Verify -Profile bank-profile.json          # exit 0=PASS 2=FAIL
  .\CheckProfile5022.ps1 -Mode Set    -Profile bank-profile.json -Lang pl
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

# ---------------- i18n ----------------
$MSG = @{
  en = @{
    noService="Smart Card service not available."; noReader="No reader matching '{0}'. Available:`n{1}"
    reader="Reader"; serial="Serial"; connectFail="Cannot connect in DIRECT mode (reader busy?)."
    profileNeeded="-Profile <file.json> is required for mode {0}."; profileBad="Cannot parse profile: {0}"
    current="CURRENT CONFIGURATION"; setting="Applying profile..."; setOk="  [OK] {0} = {1}"
    setFail="  [ERROR] {0}: {1}"; applying="Apply + reboot..."; applied="Settings applied."
    verifying="AUDIT: comparing reader configuration with profile..."
    vOk="  [PASS] {0} = {1}"; vBad="  [FAIL] {0}: expected {1}, reader has {2}"
    vReadFail="  [FAIL] {0}: cannot read value"
    resultPass="AUDIT RESULT: PASS ({0} parameters checked)"; resultFail="AUDIT RESULT: FAIL ({0}/{1} mismatches)"
    rebootSkip="Reboot skipped (-NoReboot) - settings become active after reader replug."
    waitReboot="Waiting {0}s for reader re-enumeration..."
    cardWait="Present a card on the reader (waiting up to {0}s)..."
    cardTimeout="TIMEOUT - no card presented."; cardAtr="ATR"; cardUid="UID"
    cardIs="Card identified as: {0}"; cardRaw="Storage card, unknown code {0}"
    cardCpu="ISO 14443-4 CPU / processor card (T=CL) - e.g. banking EMV, PIV, JavaCard, or a dual-interface card presenting its processor side"
    verdictYes="VERDICT: reader sees this card as MIFARE CLASSIC - emulation/native Classic WORKS for this card."
    verdictNo="VERDICT: this card is NOT presented as MIFARE Classic."
    hintPrefOff="Note: mifarePreferred is DISABLED on this reader. A dual-interface card with Classic emulation will present as a CPU card. Enable it (Mode Set) and retest."
    hintPrefOn="mifarePreferred is ENABLED - if the card has a Classic emulation, it would have been presented as Classic. This card does not expose one (or uses a different technology)."
    prefState="Reader mifarePreferred: {0}"
    cardRemove="Remove the card..."; loopStart="Card test LOOP - Ctrl+C to finish."
    loopSum="Cards tested: {0}  |  MIFARE Classic: {1}  |  other: {2}"
    exported="Profile exported to: {0}"; exportHint="Feed it straight to the batch script:`n  .\Batch-Omnikey5022-Provision.ps1 -ProfilePath {0}"
  }
  pl = @{
    noService="Usluga karty inteligentnej niedostepna."; noReader="Brak czytnika pasujacego do '{0}'. Dostepne:`n{1}"
    reader="Czytnik"; serial="Nr seryjny"; connectFail="Nie mozna polaczyc w trybie DIRECT (czytnik zajety?)."
    profileNeeded="Tryb {0} wymaga -Profile <plik.json>."; profileBad="Nie mozna sparsowac profilu: {0}"
    current="AKTUALNA KONFIGURACJA"; setting="Wgrywam profil..."; setOk="  [OK] {0} = {1}"
    setFail="  [BLAD] {0}: {1}"; applying="Apply + reboot..."; applied="Ustawienia zapisane."
    verifying="AUDYT: porownuje konfiguracje czytnika z profilem..."
    vOk="  [PASS] {0} = {1}"; vBad="  [FAIL] {0}: oczekiwano {1}, czytnik ma {2}"
    vReadFail="  [FAIL] {0}: nie mozna odczytac wartosci"
    resultPass="WYNIK AUDYTU: PASS (sprawdzono parametrow: {0})"; resultFail="WYNIK AUDYTU: FAIL (niezgodnosci: {0}/{1})"
    rebootSkip="Pominieto reboot (-NoReboot) - ustawienia aktywne po przepieciu czytnika."
    waitReboot="Czekam {0}s na re-enumeracje czytnika..."
    cardWait="Przyloz karte do czytnika (czekam do {0}s)..."
    cardTimeout="TIMEOUT - nie przylozono karty."; cardAtr="ATR"; cardUid="UID"
    cardIs="Karta rozpoznana jako: {0}"; cardRaw="Karta pamieciowa, nieznany kod {0}"
    cardCpu="Karta procesorowa ISO 14443-4 (T=CL) - np. bankowa EMV, PIV, JavaCard lub karta dual-interface prezentujaca strone procesorowa"
    verdictYes="WERDYKT: czytnik widzi te karte jako MIFARE CLASSIC - emulacja/natywny Classic DZIALA dla tej karty."
    verdictNo="WERDYKT: ta karta NIE jest prezentowana jako MIFARE Classic."
    hintPrefOff="Uwaga: mifarePreferred jest WYLACZONE na tym czytniku. Karta dual-interface z emulacja Classic pokaze sie jako procesorowa. Wlacz (Mode Set) i powtorz test."
    hintPrefOn="mifarePreferred jest WLACZONE - gdyby karta miala emulacje Classic, zostalaby tak zaprezentowana. Ta karta jej nie udostepnia (lub to inna technologia)."
    prefState="mifarePreferred czytnika: {0}"
    cardRemove="Zdejmij karte..."; loopStart="PETLA testu kart - Ctrl+C konczy."
    loopSum="Przetestowano kart: {0}  |  MIFARE Classic: {1}  |  inne: {2}"
    exported="Profil wyeksportowany do: {0}"; exportHint="Mozesz go od razu podac do skryptu wsadowego:`n  .\Batch-Omnikey5022-Provision.ps1 -ProfilePath {0}"
  }
}
$M = $MSG[$Lang]
function T([string]$key, $a0="", $a1="") { $M[$key] -f $a0, $a1 }

# ---------------- WinSCard ----------------
if (-not ("OmniTool.WinSCard" -as [type])) {
Add-Type -TypeDefinition @"
namespace OmniTool {
using System;
using System.Runtime.InteropServices;
public static class WinSCard {
    [DllImport("winscard.dll")] public static extern int SCardEstablishContext(uint scope, IntPtr r1, IntPtr r2, out IntPtr ctx);
    [DllImport("winscard.dll")] public static extern int SCardReleaseContext(IntPtr ctx);
    [DllImport("winscard.dll", CharSet=CharSet.Unicode)] public static extern int SCardListReaders(IntPtr ctx, string groups, char[] readers, ref uint size);
    [DllImport("winscard.dll", CharSet=CharSet.Unicode)] public static extern int SCardConnect(IntPtr ctx, string reader, uint shareMode, uint protocols, out IntPtr card, out uint activeProtocol);
    [DllImport("winscard.dll")] public static extern int SCardDisconnect(IntPtr card, uint disposition);
    [DllImport("winscard.dll")] public static extern int SCardControl(IntPtr card, uint code, byte[] inBuf, uint inLen, byte[] outBuf, uint outLen, out uint retLen);
    [StructLayout(LayoutKind.Sequential)]
    public struct SCARD_IO_REQUEST { public uint dwProtocol; public uint cbPciLength; }
    [DllImport("winscard.dll", CharSet=CharSet.Unicode)] public static extern int SCardStatus(IntPtr card, char[] readerName, ref uint nameLen, out uint state, out uint protocol, byte[] atr, ref uint atrLen);
    [DllImport("winscard.dll")] public static extern int SCardTransmit(IntPtr card, ref SCARD_IO_REQUEST sendPci, byte[] sendBuf, uint sendLen, IntPtr recvPci, byte[] recvBuf, ref uint recvLen);
}
}
"@
}
$SCOPE=2; $DIRECT=3; $LEAVE=0; $ESCAPE=0x3136B0; $NO_READERS=0x8010002E

function HexToBytes([string]$h){ $h=$h -replace '\s',''; ,(0..($h.Length/2-1)|%{[byte]::Parse($h.Substring($_*2,2),'HexNumber')}) }
function BytesToHex([byte[]]$b,[int]$l){ if($l -le 0){return ""}; ($b[0..($l-1)]|%{$_.ToString("X2")}) -join '' }

$script:ctx=[IntPtr]::Zero
function Ensure-Context { if($script:ctx -ne [IntPtr]::Zero){return}; $c=[IntPtr]::Zero
    if([OmniTool.WinSCard]::SCardEstablishContext($SCOPE,[IntPtr]::Zero,[IntPtr]::Zero,[ref]$c) -eq 0){$script:ctx=$c} }
function Reset-Context { if($script:ctx -ne [IntPtr]::Zero){[void][OmniTool.WinSCard]::SCardReleaseContext($script:ctx);$script:ctx=[IntPtr]::Zero}; Ensure-Context }
function Get-ReaderList {
    Ensure-Context; if($script:ctx -eq [IntPtr]::Zero){return @()}
    $size=[uint32]0
    $rc=[OmniTool.WinSCard]::SCardListReaders($script:ctx,$null,$null,[ref]$size)
    if($rc -ne 0){ if(($rc -band 0xFFFFFFFF) -ne $NO_READERS){Reset-Context}; return @() }
    $buf=New-Object char[] $size
    $rc=[OmniTool.WinSCard]::SCardListReaders($script:ctx,$null,$buf,[ref]$size)
    if($rc -ne 0){ if(($rc -band 0xFFFFFFFF) -ne $NO_READERS){Reset-Context}; return @() }
    return ,@((-join $buf).Split([char]0) | Where-Object { $_ })
}
function Send-Escape([IntPtr]$card,[string]$apdu) {
    $in=HexToBytes $apdu; $out=New-Object byte[] 512; $ret=[uint32]0
    $rc=[OmniTool.WinSCard]::SCardControl($card,$ESCAPE,$in,$in.Length,$out,$out.Length,[ref]$ret)
    if($rc -ne 0){ throw ("SCardControl 0x{0:X8}" -f $rc) }
    BytesToHex $out $ret
}

# ---------------- APDU layer (HID AViatoR TLV) ----------------
# tech tags: A2=14443A A3=14443B A4=15693 A5=Felica A6=iClass A0=general
function Apdu-Get([string]$tech,[string]$sub) { "FF70076B0AA208A006A404" + $tech + "02" + $sub + "0000" }
function Apdu-Set([string]$tech,[string]$sub,[string]$val) { "FF70076B0BA209A107A405" + $tech + "03" + $sub + "01" + $val + "00" }
$APDU_APPLY  = "FF70076B08A206A104A902800000"
$APDU_REBOOT = "FF70076B08A206A104A902830000"
$APDU_SERIAL = "FF70076B08A206A004A002920000"
$APDU_POLL_GET = "FF70076B0AA208A006A404A002890000"
function Apdu-PollSet([byte[]]$order5) { "FF70076B0FA20DA10BA409A0078905" + (($order5|%{$_.ToString("X2")}) -join '') + "00" }

function Parse-Bool([string]$resp,[string]$sub) {
    if ($resp -match ('^BD03' + $sub + '01(00|01)9000$')) { return ($Matches[1] -eq "01") }
    return $null
}
function Parse-Byte([string]$resp,[string]$sub) {
    if ($resp -match ('^BD03' + $sub + '01([0-9A-F]{2})9000$')) { return [Convert]::ToByte($Matches[1],16) }
    return $null
}

# baud: bit 212=1 424=2 848=4; byte = rxNibble<<4 | txNibble; 106 always on
function BaudTo-Byte($rxList,$txList) {
    $map=@{212=1;424=2;848=4}; $rx=0; $tx=0
    foreach($v in @($rxList)){ if($map.ContainsKey([int]$v)){$rx=$rx -bor $map[[int]$v]} }
    foreach($v in @($txList)){ if($map.ContainsKey([int]$v)){$tx=$tx -bor $map[[int]$v]} }
    [byte](($rx -shl 4) -bor $tx)
}
function Byte-ToBaud([byte]$b) {
    $rx=@(106); $tx=@(106)
    if($b -band 0x10){$rx+=212}; if($b -band 0x20){$rx+=424}; if($b -band 0x40){$rx+=848}
    if($b -band 0x01){$tx+=212}; if($b -band 0x02){$tx+=424}; if($b -band 0x04){$tx+=848}
    @{rx=$rx;tx=$tx}
}

$FreqNames = @("41Hz","20Hz","10Hz","5Hz","2.5Hz","1.3Hz","0.7Hz","0.3Hz","0.15Hz","0.08Hz")
$PollNames = @{0="none";1="iso15693";2="iso14443a";3="iso14443b";4="iclass";6="felica"}
$PollCodes = @{"none"=0;"iso15693"=1;"iso14443a"=2;"iso14443b"=3;"iclass"=4;"felica"=6}

# ---------------- parameter registry ----------------
# each: Name, Get(card)->value(display), Set(card,$want), Compare(current,$want)
function Read-Serial([IntPtr]$card) {
    $r = Send-Escape $card $APDU_SERIAL
    if ($r -notmatch '^BD' -or $r -notmatch '9000$') { return "?" }
    $b=HexToBytes $r; if($b.Length -lt 5){return "?"}
    ((-join ($b[4..(3+[int]$b[3])]|%{[char]$_})) -replace "`0","").Trim()
}
function Get-BoolParam([IntPtr]$card,[string]$tech,[string]$sub) { Parse-Bool (Send-Escape $card (Apdu-Get $tech $sub)) $sub }
function Set-BoolParam([IntPtr]$card,[string]$tech,[string]$sub,[bool]$v) {
    $r = Send-Escape $card (Apdu-Set $tech $sub $(if($v){"01"}else{"00"}))
    if ($r -notmatch '9000$') { throw $r }
}
function Get-BaudParam([IntPtr]$card,[string]$tech) { $b = Parse-Byte (Send-Escape $card (Apdu-Get $tech "81")) "81"; if($null -ne $b){Byte-ToBaud $b} }
function Set-BaudParam([IntPtr]$card,[string]$tech,[byte]$v) {
    $r = Send-Escape $card (Apdu-Set $tech "81" ($v.ToString("X2")))
    if ($r -notmatch '9000$') { throw $r }
}
function Fmt-Baud($b) { "rx:" + (($b.rx -join "/")) + " tx:" + (($b.tx -join "/")) }

# ---------------- high level ----------------
function Dump-Config([IntPtr]$card) {
    $o=[ordered]@{}
    $o["iso14443a.enabled"]        = Get-BoolParam $card "A2" "80"
    $o["iso14443a.mifarePreferred"]= Get-BoolParam $card "A2" "84"
    $o["iso14443a.mifareKeyCache"] = Get-BoolParam $card "A2" "83"
    $o["iso14443a.baud"]           = Fmt-Baud (Get-BaudParam $card "A2")
    $o["iso14443b.enabled"]        = Get-BoolParam $card "A3" "80"
    $o["iso14443b.baud"]           = Fmt-Baud (Get-BaudParam $card "A3")
    $o["iso15693.enabled"]         = Get-BoolParam $card "A4" "80"
    $o["felica.enabled"]           = Get-BoolParam $card "A5" "80"
    $o["felica.baud"]              = Fmt-Baud (Get-BaudParam $card "A5")
    $o["iclass.enabled"]           = Get-BoolParam $card "A6" "83"
    $o["emdSuppression"]           = Get-BoolParam $card "A0" "87"
    $o["sleepModeCardDetection"]   = Get-BoolParam $card "A0" "8E"
    $f = Parse-Byte (Send-Escape $card (Apdu-Get "A0" "8D")) "8D"
    $o["sleepModePollingFrequency"]= if($null -ne $f -and $f -lt $FreqNames.Count){$FreqNames[$f]}else{"?($f)"}
    $pr = Send-Escape $card $APDU_POLL_GET
    if ($pr -match '^BD078905([0-9A-F]{10})9000$') {
        $codes = 0..4 | ForEach-Object { [Convert]::ToByte($Matches[1].Substring($_*2,2),16) }
        $o["pollingSearchOrder"] = (($codes | Where-Object {$_ -ne 0} | ForEach-Object { $PollNames[[int]$_] }) -join ",")
    } else { $o["pollingSearchOrder"] = "?" }
    $o
}

# ops are data-only (no closures: PS closures do not capture script functions)
function Build-Ops($p) {
    $ops = New-Object System.Collections.ArrayList
    function AddBool($name,$tech,$sub,$want){
        [void]$ops.Add(@{name=$name;kind="bool";tech=$tech;sub=$sub;want=[bool]$want;wantDisp=$want}) }
    function AddBaud($name,$tech,$rx,$tx){
        $wb=BaudTo-Byte $rx $tx
        [void]$ops.Add(@{name=$name;kind="baud";tech=$tech;want=$wb;wantDisp=(Fmt-Baud (Byte-ToBaud $wb))}) }
    if ($p.iso14443a) { $a=$p.iso14443a
        if ($null -ne $a.enabled)         { AddBool "iso14443a.enabled"         "A2" "80" $a.enabled }
        if ($null -ne $a.mifarePreferred) { AddBool "iso14443a.mifarePreferred" "A2" "84" $a.mifarePreferred }
        if ($null -ne $a.mifareKeyCache)  { AddBool "iso14443a.mifareKeyCache"  "A2" "83" $a.mifareKeyCache }
        if ($a.rx -or $a.tx)              { AddBaud "iso14443a.baud" "A2" $a.rx $a.tx } }
    if ($p.iso14443b) { $b=$p.iso14443b
        if ($null -ne $b.enabled) { AddBool "iso14443b.enabled" "A3" "80" $b.enabled }
        if ($b.rx -or $b.tx)      { AddBaud "iso14443b.baud" "A3" $b.rx $b.tx } }
    if ($p.iso15693 -and $null -ne $p.iso15693.enabled) { AddBool "iso15693.enabled" "A4" "80" $p.iso15693.enabled }
    if ($p.felica) {
        if ($null -ne $p.felica.enabled)   { AddBool "felica.enabled" "A5" "80" $p.felica.enabled }
        if ($p.felica.rx -or $p.felica.tx) { AddBaud "felica.baud" "A5" $p.felica.rx $p.felica.tx } }
    if ($p.iclass -and $null -ne $p.iclass.enabled) { AddBool "iclass.enabled" "A6" "83" $p.iclass.enabled }
    if ($null -ne $p.emdSuppression)         { AddBool "emdSuppression"         "A0" "87" $p.emdSuppression }
    if ($null -ne $p.sleepModeCardDetection) { AddBool "sleepModeCardDetection" "A0" "8E" $p.sleepModeCardDetection }
    if ($p.sleepModePollingFrequency) {
        $idx = [Array]::IndexOf($FreqNames, [string]$p.sleepModePollingFrequency)
        if ($idx -lt 0) { throw "sleepModePollingFrequency: '$($p.sleepModePollingFrequency)' (use: $($FreqNames -join ' '))" }
        [void]$ops.Add(@{name="sleepModePollingFrequency";kind="freq";idx=[byte]$idx;wantDisp=$FreqNames[$idx]}) }
    if ($p.pollingSearchOrder) {
        $names = @($p.pollingSearchOrder | ForEach-Object { ([string]$_).ToLower() })
        $codes = New-Object byte[] 5
        for ($i=0; $i -lt 5; $i++) {
            if ($i -lt $names.Count) {
                if (-not $PollCodes.ContainsKey($names[$i])) { throw "pollingSearchOrder: '$($names[$i])' (use: $(($PollCodes.Keys|Sort-Object) -join ' '))" }
                $codes[$i] = [byte]$PollCodes[$names[$i]]
            } else { $codes[$i] = 0 }
        }
        [void]$ops.Add(@{name="pollingSearchOrder";kind="poll";codes=$codes
                         wantHex=(($codes|%{$_.ToString("X2")}) -join '')
                         wantDisp=(($names | Where-Object {$_ -ne "none"}) -join ",")}) }
    ,$ops
}
function Invoke-OpApply([IntPtr]$card,$op){
    switch($op.kind){
        "bool" { Set-BoolParam $card $op.tech $op.sub $op.want }
        "baud" { Set-BaudParam $card $op.tech $op.want }
        "freq" { $r=Send-Escape $card (Apdu-Set "A0" "8D" ($op.idx.ToString("X2"))); if($r -notmatch '9000$'){throw $r} }
        "poll" { $r=Send-Escape $card (Apdu-PollSet $op.codes); if($r -notmatch '9000$'){throw $r} }
    }
}
function Invoke-OpCheck([IntPtr]$card,$op){
    switch($op.kind){
        "bool" { $h=Get-BoolParam $card $op.tech $op.sub; return @{ok=($h -eq $op.want);have=$h} }
        "baud" { $h=Get-BaudParam $card $op.tech; $hd=Fmt-Baud $h; return @{ok=($hd -eq $op.wantDisp);have=$hd} }
        "freq" { $f=Parse-Byte (Send-Escape $card (Apdu-Get "A0" "8D")) "8D"
                 $hn=if($null -ne $f -and $f -lt $FreqNames.Count){$FreqNames[$f]}else{"?"}
                 return @{ok=($hn -eq $op.wantDisp);have=$hn} }
        "poll" { $pr=Send-Escape $card $APDU_POLL_GET
                 if ($pr -match '^BD078905([0-9A-F]{10})9000$') {
                     $cc = 0..4 | ForEach-Object { [Convert]::ToByte($Matches[1].Substring($_*2,2),16) }
                     $hd = (($cc | Where-Object {$_ -ne 0} | ForEach-Object { $PollNames[[int]$_] }) -join ",")
                     return @{ok=($Matches[1] -eq $op.wantHex);have=$hd}
                 }
                 return @{ok=$false;have="?"} }
    }
}

# ---------------- TestCard support ----------------
$SHARE_SHARED=2; $PROTO_T0T1=3
# PC/SC part 3 storage card names (bytes after RID A0 00 00 03 06 + standard byte)
$StorageNames = @{
  "0001"=@("MIFARE Classic 1K",$true);   "0002"=@("MIFARE Classic 4K",$true)
  "0026"=@("MIFARE Mini",$true)
  "0036"=@("MIFARE Plus SL1 2K (Classic mode)",$true); "0037"=@("MIFARE Plus SL1 4K (Classic mode)",$true)
  "0038"=@("MIFARE Plus SL2 2K",$false); "0039"=@("MIFARE Plus SL2 4K",$false)
  "0003"=@("MIFARE Ultralight",$false);  "003A"=@("MIFARE Ultralight C",$false)
  "0030"=@("Topaz/Jewel",$false);        "000C"=@("FeliCa",$false)
}
function Send-Apdu([IntPtr]$card,[uint32]$proto,[string]$apduHex) {
    $pci=New-Object OmniTool.WinSCard+SCARD_IO_REQUEST
    $pci.dwProtocol=$proto; $pci.cbPciLength=8
    $in=HexToBytes $apduHex; $out=New-Object byte[] 512; $len=[uint32]$out.Length
    $rc=[OmniTool.WinSCard]::SCardTransmit($card,[ref]$pci,$in,$in.Length,[IntPtr]::Zero,$out,[ref]$len)
    if($rc -ne 0){ throw ("SCardTransmit 0x{0:X8}" -f $rc) }
    BytesToHex $out $len
}
function Beep-Ok{ try{[console]::Beep(1200,120);[console]::Beep(1600,180)}catch{} }
function Beep-Fail{ try{[console]::Beep(400,500)}catch{} }
function Wait-CardRemoved {
    Write-Host (T cardRemove) -ForegroundColor DarkGray
    while($true){
        $c=[IntPtr]::Zero; $pp=[uint32]0
        $rc=[OmniTool.WinSCard]::SCardConnect($script:ctx,$reader,$SHARE_SHARED,$PROTO_T0T1,[ref]$c,[ref]$pp)
        if($rc -ne 0){ break }                    # connect fails -> card removed
        [void][OmniTool.WinSCard]::SCardDisconnect($c,$LEAVE)
        Start-Sleep -Milliseconds 400
    }
}
function Invoke-CardTest([bool]$prefEnabled) {
    Write-Host ((T prefState $(if($prefEnabled){"ENABLED"}else{"DISABLED"})))
    Write-Host (T cardWait $CardTimeout)
    $c=[IntPtr]::Zero; $proto=[uint32]0
    $deadline=(Get-Date).AddSeconds($CardTimeout)
    while((Get-Date) -lt $deadline){
        if([OmniTool.WinSCard]::SCardConnect($script:ctx,$reader,$SHARE_SHARED,$PROTO_T0T1,[ref]$c,[ref]$proto) -eq 0){ break }
        Start-Sleep -Milliseconds 400
    }
    if($c -eq [IntPtr]::Zero){ Write-Host (T cardTimeout) -ForegroundColor Red; return 1 }
    try {
        $nl=[uint32]256; $nb=New-Object char[] 256; $st=[uint32]0; $pp=[uint32]0
        $atr=New-Object byte[] 36; $al=[uint32]$atr.Length
        [void][OmniTool.WinSCard]::SCardStatus($c,$nb,[ref]$nl,[ref]$st,[ref]$pp,$atr,[ref]$al)
        $atrHex=BytesToHex $atr $al
        Write-Host ("{0}: {1}" -f (T cardAtr),$atrHex)
        try { $u=Send-Apdu $c $proto "FFCA000000"
              if($u -match '^(.+)9000$'){ Write-Host ("{0}: {1}" -f (T cardUid),$Matches[1]) } } catch { }

        $isClassic=$false
        if($atrHex -match "A000000306..(....)"){
            $code=$Matches[1]
            if($StorageNames.ContainsKey($code)){
                $name,$classic=$StorageNames[$code]
                Write-Host (T cardIs $name) -ForegroundColor Cyan
                $isClassic=$classic
            } else {
                Write-Host (T cardRaw $code) -ForegroundColor Yellow
            }
        } else {
            Write-Host (T cardIs (T cardCpu)) -ForegroundColor Cyan
        }
        Write-Host ""
        if($isClassic){ Write-Host (T verdictYes) -ForegroundColor Green; return 0 }
        Write-Host (T verdictNo) -ForegroundColor Red
        if($prefEnabled){ Write-Host (T hintPrefOn) -ForegroundColor Yellow } else { Write-Host (T hintPrefOff) -ForegroundColor Yellow }
        return 2
    }
    finally { [void][OmniTool.WinSCard]::SCardDisconnect($c,$LEAVE) }
}

# ---------------- Export: dump reader config as a Batch-ready profile ----------------
function Baud-ToLists([IntPtr]$card,[string]$tech) {
    $b = Parse-Byte (Send-Escape $card (Apdu-Get $tech "81")) "81"
    if ($null -eq $b) { return $null }
    $full = Byte-ToBaud $b
    @{ rx = @($full.rx | Where-Object { $_ -ne 106 }); tx = @($full.tx | Where-Object { $_ -ne 106 }) }
}
function Export-Profile([IntPtr]$card,[string]$path) {
    $a = Baud-ToLists $card "A2"; $bb = Baud-ToLists $card "A3"; $fb = Baud-ToLists $card "A5"
    $prof = [ordered]@{
        iso14443a = [ordered]@{
            enabled         = Get-BoolParam $card "A2" "80"
            mifarePreferred = Get-BoolParam $card "A2" "84"
            mifareKeyCache  = Get-BoolParam $card "A2" "83"
            rx = $a.rx; tx = $a.tx
        }
        iso14443b = [ordered]@{ enabled = Get-BoolParam $card "A3" "80"; rx = $bb.rx; tx = $bb.tx }
        iso15693  = [ordered]@{ enabled = Get-BoolParam $card "A4" "80" }
        felica    = [ordered]@{ enabled = Get-BoolParam $card "A5" "80"; rx = $fb.rx; tx = $fb.tx }
        iclass    = [ordered]@{ enabled = Get-BoolParam $card "A6" "83" }
        emdSuppression         = Get-BoolParam $card "A0" "87"
        sleepModeCardDetection = Get-BoolParam $card "A0" "8E"
    }
    $f = Parse-Byte (Send-Escape $card (Apdu-Get "A0" "8D")) "8D"
    if ($null -ne $f -and $f -lt $FreqNames.Count) { $prof["sleepModePollingFrequency"] = $FreqNames[$f] }
    $pr = Send-Escape $card $APDU_POLL_GET
    if ($pr -match '^BD078905([0-9A-F]{10})9000$') {
        $codes = 0..4 | ForEach-Object { [Convert]::ToByte($Matches[1].Substring($_*2,2),16) }
        $prof["pollingSearchOrder"] = @($codes | Where-Object { $_ -ne 0 } | ForEach-Object { $PollNames[[int]$_] })
    }
    $prof | ConvertTo-Json -Depth 4 | Out-File $path -Encoding utf8
}

# ================= MAIN =================
Ensure-Context
if ($script:ctx -eq [IntPtr]::Zero) { throw (T noService) }
$all = Get-ReaderList
$reader = $all | Where-Object { $_ -match $ReaderMatch } | Select-Object -First 1
if (-not $reader) { throw (T noReader $ReaderMatch ($all -join "`n")) }

$prof = $null
if ($Mode -in "Set","Verify") {
    if (-not $Profile) { throw (T profileNeeded $Mode) }
    try { $prof = Get-Content $Profile -Raw | ConvertFrom-Json } catch { throw (T profileBad $_.Exception.Message) }
}

function Connect-Direct {
    $card=[IntPtr]::Zero; $p=[uint32]0
    if ([OmniTool.WinSCard]::SCardConnect($script:ctx,$reader,$DIRECT,0,[ref]$card,[ref]$p) -ne 0) { throw (T connectFail) }
    $card
}

$exit = 0
$card = Connect-Direct
try {
    $serial = Read-Serial $card
    Write-Host ("{0}: {1}" -f (T reader), $reader) -ForegroundColor Cyan
    Write-Host ("{0}: {1}`n" -f (T serial), $serial) -ForegroundColor Cyan

    switch ($Mode) {
        "Get" {
            Write-Host (T current) -ForegroundColor Cyan
            (Dump-Config $card).GetEnumerator() | ForEach-Object { Write-Host ("  {0,-28} {1}" -f $_.Key, $_.Value) }
        }
        "Set" {
            $ops = Build-Ops $prof
            Write-Host (T setting)
            $failed = $false
            foreach ($op in $ops) {
                try { Invoke-OpApply $card $op; Write-Host (T setOk $op.name $op.wantDisp) -ForegroundColor Green }
                catch { Write-Host (T setFail $op.name $_.Exception.Message) -ForegroundColor Red; $failed=$true }
            }
            if ($failed) { $exit = 1 }
            Write-Host (T applying)
            [void](Send-Escape $card $APDU_APPLY)
            if ($NoReboot) { Write-Host (T rebootSkip) -ForegroundColor Yellow }
            else {
                try { [void](Send-Escape $card $APDU_REBOOT) } catch { }
                Write-Host (T applied) -ForegroundColor Green
            }
        }
        "Export" {
            Export-Profile $card $OutProfile
            Write-Host (T current) -ForegroundColor Cyan
            (Dump-Config $card).GetEnumerator() | ForEach-Object { Write-Host ("  {0,-28} {1}" -f $_.Key, $_.Value) }
            $abs = (Resolve-Path $OutProfile).Path
            Write-Host ""
            Write-Host (T exported $abs) -ForegroundColor Green
            Write-Host (T exportHint $abs)
        }
        "TestCard" {
            $pref = Get-BoolParam $card "A2" "84"
            [void][OmniTool.WinSCard]::SCardDisconnect($card,$LEAVE)   # release DIRECT before SHARED card session
            if (-not $Loop) {
                $exit = Invoke-CardTest ([bool]$pref)
            } else {
                Write-Host (T loopStart) -ForegroundColor Cyan
                $nTotal=0; $nClassic=0; $nOther=0
                try {
                    while ($true) {
                        Write-Host ("--- #{0} ---" -f ($nTotal+1)) -ForegroundColor DarkCyan
                        $r = Invoke-CardTest ([bool]$pref)
                        if ($r -eq 1) { continue }        # timeout - keep waiting for next card
                        $nTotal++
                        if ($r -eq 0) { $nClassic++; Beep-Ok } else { $nOther++; Beep-Fail }
                        Wait-CardRemoved
                        Write-Host ""
                    }
                }
                finally {
                    Write-Host ""
                    Write-Host (T loopSum $nTotal $nClassic $nOther) -ForegroundColor Cyan
                    $exit = 0
                }
            }
        }
        "Verify" {
            $ops = Build-Ops $prof
            Write-Host (T verifying)
            $bad=0
            foreach ($op in $ops) {
                try {
                    $r = Invoke-OpCheck $card $op
                    if ($r.ok) { Write-Host (T vOk $op.name $op.wantDisp) -ForegroundColor Green }
                    else       { Write-Host (T vBad $op.name $op.wantDisp) -NoNewline -ForegroundColor Red
                                 Write-Host (", reader: {0}" -f $r.have) -ForegroundColor Red; $bad++ }
                }
                catch { Write-Host (T vReadFail $op.name) -ForegroundColor Red; $bad++ }
            }
            Write-Host ""
            if ($bad -eq 0) { Write-Host (T resultPass $ops.Count) -ForegroundColor Green; $exit=0 }
            else            { Write-Host (T resultFail $bad $ops.Count) -ForegroundColor Red;  $exit=2 }
        }
    }
}
finally {
    [void][OmniTool.WinSCard]::SCardDisconnect($card,$LEAVE)
    if ($Mode -eq "Set" -and -not $NoReboot) { Start-Sleep -Seconds 2 }
    [void][OmniTool.WinSCard]::SCardReleaseContext($script:ctx)
}
exit $exit
