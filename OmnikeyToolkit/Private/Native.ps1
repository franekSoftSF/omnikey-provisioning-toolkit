# winscard.dll P/Invoke - lesson 4: .NET types cannot be unloaded from a live session.
# These signatures are byte-for-byte the ones shipped as OmniTool in CheckProfile5022.ps1 v1.0,
# so the namespace name is kept. Any signature change => NEW namespace name (tests/Repo.Tests.ps1).
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
$script:SCOPE=2; $script:DIRECT=3; $script:LEAVE=0; $script:ESCAPE=0x3136B0; $script:NO_READERS=0x8010002E
$script:SHARE_SHARED=2; $script:PROTO_T0T1=3; $script:PROTO_T0=1; $script:PROTO_T1=2
