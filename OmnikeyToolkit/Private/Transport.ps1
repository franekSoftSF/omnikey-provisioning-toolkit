# PC/SC transport - the only file that calls [OmniTool.WinSCard].
# Every native call sits behind a small Invoke-Native* function so tests can mock it.
# Lesson 3: Windows stops SCardSvr when the last reader disappears, which invalidates the
# context - Initialize-/Reset-Context with auto-recovery in Get-ReaderList / Invoke-WithReader.

$script:ctx = [IntPtr]::Zero; $script:ctxResets = 0; $script:lastErr = ""

function ConvertFrom-HexString([string]$h) {
    $h = $h -replace '\s', ''
    if (-not $h) { return ,([byte[]]@()) }
    ,([byte[]](0..($h.Length / 2 - 1) | ForEach-Object { [byte]::Parse($h.Substring($_ * 2, 2), 'HexNumber') }))
}
function ConvertTo-HexString([byte[]]$b, [int]$l) {
    if ($l -le 0) { return "" }
    ($b[0..($l - 1)] | ForEach-Object { $_.ToString("X2") }) -join ''
}
# "SCardControl 0x80100017" -> "0x80100017" (batch CSV details keep the bare code)
function Format-TransportError([string]$message) { $message -replace '^SCard(Control|Transmit) ', '' }

# ---------- native wrappers ----------
function Invoke-NativeEstablishContext {
    $c = [IntPtr]::Zero
    $rc = [OmniTool.WinSCard]::SCardEstablishContext($script:SCOPE, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$c)
    @{ rc = $rc; ctx = $c }
}
function Invoke-NativeReleaseContext([IntPtr]$c) { [void][OmniTool.WinSCard]::SCardReleaseContext($c) }
function Invoke-NativeListReaders([IntPtr]$c) {
    $size = [uint32]0
    $rc = [OmniTool.WinSCard]::SCardListReaders($c, $null, $null, [ref]$size)
    if ($rc -ne 0) { return @{ rc = $rc; names = @() } }
    $buf = New-Object char[] $size
    $rc = [OmniTool.WinSCard]::SCardListReaders($c, $null, $buf, [ref]$size)
    if ($rc -ne 0) { return @{ rc = $rc; names = @() } }
    @{ rc = 0; names = @((-join $buf).Split([char]0) | Where-Object { $_ }) }
}
function Invoke-NativeConnect([IntPtr]$c, [string]$reader, [uint32]$share, [uint32]$protocols) {
    $card = [IntPtr]::Zero; $p = [uint32]0
    $rc = [OmniTool.WinSCard]::SCardConnect($c, $reader, $share, $protocols, [ref]$card, [ref]$p)
    @{ rc = $rc; card = $card; proto = $p }
}
function Disconnect-Card([IntPtr]$card) { [void][OmniTool.WinSCard]::SCardDisconnect($card, $script:LEAVE) }
function Invoke-NativeControl([IntPtr]$card, [byte[]]$in) {
    $out = New-Object byte[] 512; $ret = [uint32]0
    $rc = [OmniTool.WinSCard]::SCardControl($card, $script:ESCAPE, $in, $in.Length, $out, $out.Length, [ref]$ret)
    @{ rc = $rc; out = $out; len = $ret }
}
function Invoke-NativeTransmit([IntPtr]$card, [uint32]$proto, [byte[]]$in) {
    $pci = New-Object OmniTool.WinSCard+SCARD_IO_REQUEST
    $pci.dwProtocol = $proto; $pci.cbPciLength = 8
    $out = New-Object byte[] 512; $len = [uint32]$out.Length
    $rc = [OmniTool.WinSCard]::SCardTransmit($card, [ref]$pci, $in, $in.Length, [IntPtr]::Zero, $out, [ref]$len)
    @{ rc = $rc; out = $out; len = $len }
}
function Get-CardAtr([IntPtr]$card) {
    $nl = [uint32]256; $nb = New-Object char[] 256; $st = [uint32]0; $pp = [uint32]0
    $atr = New-Object byte[] 36; $al = [uint32]$atr.Length
    [void][OmniTool.WinSCard]::SCardStatus($card, $nb, [ref]$nl, [ref]$st, [ref]$pp, $atr, [ref]$al)
    ConvertTo-HexString $atr $al
}

# ---------- context ----------
function Initialize-Context {
    if ($script:ctx -ne [IntPtr]::Zero) { return }
    $r = Invoke-NativeEstablishContext
    if ($r.rc -eq 0) { $script:ctx = $r.ctx }
}
function Reset-Context {
    if ($script:ctx -ne [IntPtr]::Zero) { Invoke-NativeReleaseContext $script:ctx; $script:ctx = [IntPtr]::Zero }
    $script:ctxResets++
    Initialize-Context
}
function Close-Context {
    if ($script:ctx -ne [IntPtr]::Zero) { Invoke-NativeReleaseContext $script:ctx; $script:ctx = [IntPtr]::Zero }
}
function Test-ContextReady { $script:ctx -ne [IntPtr]::Zero }

# reader names, optionally filtered by regex; any error other than "no readers" resets the context
function Get-ReaderList([string]$match = "") {
    Initialize-Context
    if ($script:ctx -eq [IntPtr]::Zero) { return ,@() }
    $r = Invoke-NativeListReaders $script:ctx
    if ($r.rc -ne 0) {
        if (($r.rc -band 0xFFFFFFFF) -ne $script:NO_READERS) { Reset-Context }
        return ,@()
    }
    ,@($r.names | Where-Object { -not $match -or $_ -match $match })
}

# ---------- connections and exchanges ----------
function Connect-Direct([string]$reader) {
    $c = Invoke-NativeConnect $script:ctx $reader $script:DIRECT 0
    if ($c.rc -ne 0) { throw (T connectFail) }
    $c.card
}
function Send-Escape([IntPtr]$card, [string]$apdu) {
    $r = Invoke-NativeControl $card (ConvertFrom-HexString $apdu)
    if ($r.rc -ne 0) { throw ("SCardControl 0x{0:X8}" -f $r.rc) }
    ConvertTo-HexString $r.out $r.len
}
function Send-Apdu([IntPtr]$card, [uint32]$proto, [string]$apduHex) {
    $r = Invoke-NativeTransmit $card $proto (ConvertFrom-HexString $apduHex)
    if ($r.rc -ne 0) { throw ("SCardTransmit 0x{0:X8}" -f $r.rc) }
    ConvertTo-HexString $r.out $r.len
}

# DIRECT session for one reader; the block must be defined INSIDE this module (lesson 1: a block
# from outside cannot see private functions). Returns the block result or $null + $script:lastErr.
function Invoke-WithReader([string]$reader, [scriptblock]$block, $argument) {
    $script:lastErr = ""; Initialize-Context
    if ($script:ctx -eq [IntPtr]::Zero) { $script:lastErr = "no-ctx"; return $null }
    if (-not $reader) { $script:lastErr = "null-reader"; return $null }
    $c = Invoke-NativeConnect $script:ctx $reader $script:DIRECT 0
    if ($c.rc -ne 0) {
        $script:lastErr = ("connect:0x{0:X8}" -f $c.rc)
        if (($c.rc -band 0xFFFFFFFF) -notin @($script:NO_READERS)) { Reset-Context }
        return $null
    }
    try { & $block $c.card $argument }
    catch { $script:lastErr = "escape:$(Format-TransportError $_.Exception.Message)"; $null }
    finally { Disconnect-Card $c.card }
}

function Invoke-BeepOk { try { [console]::Beep(1200, 120); [console]::Beep(1600, 180) } catch { } }
function Invoke-BeepFail([int]$ms = 500) { try { [console]::Beep(400, $ms) } catch { } }
