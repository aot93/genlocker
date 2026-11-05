<#
.SYNOPSIS
    Genlocker - force an NVIDIA Quadro Sync / RTX PRO Sync card to lock to external
    house sync (BNC) and keep retrying until the lock holds.

.DESCRIPTION
    Talks to the driver through NVAPI (the same GSync API the NVIDIA Control Panel's
    "Synchronize Displays" page uses). Each attempt:
        1. checks a house sync signal is present on the BNC input
        2. releases the current sync group (clean slate)
        3. sets the sync source to house sync on the server's Sync device
        4. re-forms the sync group (one server display, the rest clients)
        5. waits for every GPU to report "synced" and requires that to hold
           continuously for -HoldSeconds
    Failed attempts are retried with a growing back-off.

    No install or compiler needed: it runs on the stock Windows PowerShell 5.1
    (64-bit). It needs Administrator rights for everything except -Action Status.

.PARAMETER Action
    Lock   (default) Lock, verify the hold, then exit. Exit code 0 = locked.
    Watch  Lock, then keep monitoring and re-lock whenever the lock is lost.
    Status Print the current sync state. Exit code 0 = locked, 1 = not locked.
    Unlock Remove all displays from the sync group.

.EXAMPLE
    .\genlocker.ps1
.EXAMPLE
    .\genlocker.ps1 -Action Watch -LogFile C:\ProgramData\Genlocker\genlocker.log
.EXAMPLE
    .\genlocker.ps1 -SignalType TriLevel -MasterDisplayId 0x80061086 -HoldSeconds 15
#>
[CmdletBinding()]
param(
    [ValidateSet('Lock', 'Watch', 'Status', 'Unlock')]
    [string]$Action = 'Lock',

    # Lock must stay good this long, continuously, to count as a success.
    [int]$HoldSeconds = 10,

    # How long one attempt waits for the GPUs to report a lock before giving up.
    [int]$LockTimeoutSeconds = 20,

    # 0 = retry forever. (Watch always retries forever.)
    [int]$MaxAttempts = 10,

    # House sync signal type. Keep = leave whatever is configured in the Control Panel.
    [ValidateSet('Keep', 'None', 'TTL', 'BiLevel', 'TriLevel', 'Composite')]
    [string]$SignalType = 'Keep',

    [ValidateSet('Keep', 'Rising', 'Falling', 'Both')]
    [string]$Polarity = 'Keep',

    # Display to use as the sync server (hex 0x... or decimal, as printed by -Action Status).
    [string]$MasterDisplayId,

    # Displays to leave out of the sync group, e.g. a GUI monitor.
    [string[]]$ExcludeDisplayId = @(),

    # Re-apply the configuration even if the card already reports a good lock.
    [switch]$Force,

    # Watch mode: how long the lock may be lost before Genlocker steps in.
    [double]$LossGraceSeconds = 2,

    [int]$PollMilliseconds = 250,

    [string]$LogFile
)

$ErrorActionPreference = 'Stop'

$NvGSyncSource = @'
using System;
using System.Runtime.InteropServices;

namespace Genlocker
{
    public class NvApiException : Exception
    {
        public readonly int Status;
        public NvApiException(string function, int status, string message)
            : base(string.Format("{0} failed: {1} ({2})", function, message, status))
        {
            Status = status;
        }
    }

    public class Capabilities
    {
        public uint BoardId, Revision, ExtendedRevision, MaxMulDivValue;
        public bool MulDivSupported;
    }

    public class GpuInfo
    {
        public IntPtr Handle, ProxyHandle;
        public int Connector;
        public string Name;
    }

    public class DisplayInfo
    {
        public uint DisplayId;
        public bool Masterable;
        public int SyncState;
        public IntPtr Gpu;
    }

    public class Topology
    {
        public GpuInfo[] Gpus;
        public DisplayInfo[] Displays;
    }

    public class SyncStatus
    {
        public bool Synced, StereoSynced, SignalAvailable;
    }

    public class StatusParams
    {
        public uint RefreshRate, HouseSyncIncoming;
        public bool HouseSync;
        public int[] Rj45Io = new int[2];
        public bool[] Rj45Ethernet = new bool[2];
    }

    public class ControlParams
    {
        public int Polarity, VideoMode, Source, MultiplyDivideMode;
        public uint Interval, MultiplyDivideValue;
        public bool Interlace, SyncSourceIsOutput;
        // The whole struct as read from the driver, so Set preserves skew/startup delay.
        internal byte[] Raw;
    }

    // Thin wrapper over the NVAPI GSync functions. Struct layouts and function IDs
    // are taken from the public NVAPI SDK (nvapi.h / nvapi_interface.h), x64 only.
    public static class NvGSync
    {
        public const int SYNC_UNSYNCED = 0, SYNC_SLAVE = 1, SYNC_MASTER = 2;
        public const int SOURCE_VSYNC = 0, SOURCE_HOUSESYNC = 1;
        const int NVAPI_NO_IMPLEMENTATION = -3, NVAPI_NVIDIA_DEVICE_NOT_FOUND = -6;

        const uint ID_Initialize = 0x0150E828;
        const uint ID_GetErrorMessage = 0x6C2D048C;
        const uint ID_GetDriverAndBranchVersion = 0x2926AAAD;
        const uint ID_GPU_GetFullName = 0xCEEE8E9F;
        const uint ID_GetPhysicalGpuFromDisplayId = 0x9EA74659;
        const uint ID_GSync_EnumSyncDevices = 0xD9639601;
        const uint ID_GSync_QueryCapabilities = 0x44A3F1D1;
        const uint ID_GSync_GetTopology = 0x4562BC38;
        const uint ID_GSync_SetSyncStateSettings = 0x60ACDFDD;
        const uint ID_GSync_GetControlParameters = 0x16DE1C6A;
        const uint ID_GSync_SetControlParameters = 0x8BBFF88B;
        const uint ID_GSync_GetSyncStatus = 0xF1F5B434;
        const uint ID_GSync_GetStatusParameters = 0x70D404EC;

        const int GPU_SIZE = 40;    // NV_GSYNC_GPU
        static int dispStride = 96; // NV_GSYNC_DISPLAY_V2 (V1 = 16), whichever the driver accepted
        static int dispVer = 2;

        [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
        static extern IntPtr QueryInterface(uint id);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnVoid();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnEnum(IntPtr handles, ref uint count);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnHandleBuf(IntPtr handle, IntPtr buf);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnTopology(IntPtr dev, ref uint gpuCount, IntPtr gpus, ref uint dispCount, IntPtr disps);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnSetSyncState(uint count, IntPtr disps, uint flags);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnSyncStatus(IntPtr dev, IntPtr gpu, IntPtr status);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnErrorMessage(int status, IntPtr msg);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnGpuFromDisplay(uint displayId, out IntPtr gpu);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnDriverVersion(out uint version, IntPtr branch);

        static T Fn<T>(uint id) where T : class
        {
            IntPtr p = QueryInterface(id);
            if (p == IntPtr.Zero)
                throw new NvApiException("nvapi_QueryInterface(0x" + id.ToString("X8") + ")", NVAPI_NO_IMPLEMENTATION, "function not provided by this driver");
            return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
        }

        static uint Ver(int size, int ver) { return (uint)size | ((uint)ver << 16); }
        static uint U32(IntPtr p, int off) { return unchecked((uint)Marshal.ReadInt32(p, off)); }
        static void W32(IntPtr p, int off, uint v) { Marshal.WriteInt32(p, off, unchecked((int)v)); }

        static IntPtr Alloc(int size)
        {
            IntPtr p = Marshal.AllocHGlobal(size);
            Marshal.Copy(new byte[size], 0, p, size);
            return p;
        }

        static void Check(string function, int status)
        {
            if (status != 0) throw new NvApiException(function, status, ErrorMessage(status));
        }

        // Calls fn with the newest struct version the driver accepts; buf must hold sizes[0].
        // Returns the index into sizes/versions that worked.
        static int CallVersioned(string name, FnHandleBuf fn, IntPtr handle, IntPtr buf, int[] sizes, int[] versions)
        {
            int first = 0;
            for (int i = 0; i < sizes.Length; i++)
            {
                Marshal.Copy(new byte[sizes[0]], 0, buf, sizes[0]);
                W32(buf, 0, Ver(sizes[i], versions[i]));
                int st = fn(handle, buf);
                if (st == 0) return i;
                if (i == 0) first = st;
            }
            Check(name, first);
            return -1;
        }

        public static string ErrorMessage(int status)
        {
            IntPtr buf = Alloc(64);
            try
            {
                if (Fn<FnErrorMessage>(ID_GetErrorMessage)(status, buf) == 0)
                    return Marshal.PtrToStringAnsi(buf);
            }
            catch (Exception) { }
            finally { Marshal.FreeHGlobal(buf); }
            return "NVAPI status " + status;
        }

        public static void Initialize()
        {
            try
            {
                Check("NvAPI_Initialize", Fn<FnVoid>(ID_Initialize)());
            }
            catch (DllNotFoundException)
            {
                throw new NvApiException("NvAPI_Initialize", -2, "nvapi64.dll not found - is the NVIDIA driver installed?");
            }
        }

        public static string DriverVersion()
        {
            IntPtr buf = Alloc(64);
            try
            {
                uint v;
                Check("NvAPI_SYS_GetDriverAndBranchVersion", Fn<FnDriverVersion>(ID_GetDriverAndBranchVersion)(out v, buf));
                return string.Format("{0}.{1:00} ({2})", v / 100, v % 100, Marshal.PtrToStringAnsi(buf));
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        public static string GpuName(IntPtr gpu)
        {
            IntPtr buf = Alloc(64);
            try
            {
                if (Fn<FnHandleBuf>(ID_GPU_GetFullName)(gpu, buf) == 0)
                    return Marshal.PtrToStringAnsi(buf);
            }
            catch (NvApiException) { }
            finally { Marshal.FreeHGlobal(buf); }
            return "GPU";
        }

        public static IntPtr GpuFromDisplay(uint displayId)
        {
            IntPtr gpu;
            try
            {
                if (Fn<FnGpuFromDisplay>(ID_GetPhysicalGpuFromDisplayId)(displayId, out gpu) == 0)
                    return gpu;
            }
            catch (NvApiException) { }
            return IntPtr.Zero;
        }

        public static IntPtr[] EnumSyncDevices()
        {
            IntPtr buf = Alloc(IntPtr.Size * 4);
            try
            {
                uint count = 0;
                int st = Fn<FnEnum>(ID_GSync_EnumSyncDevices)(buf, ref count);
                if (st == NVAPI_NVIDIA_DEVICE_NOT_FOUND) return new IntPtr[0];
                Check("NvAPI_GSync_EnumSyncDevices", st);
                IntPtr[] r = new IntPtr[Math.Min((int)count, 4)];
                for (int i = 0; i < r.Length; i++) r[i] = Marshal.ReadIntPtr(buf, i * IntPtr.Size);
                return r;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        public static Capabilities QueryCapabilities(IntPtr dev)
        {
            IntPtr buf = Alloc(28);
            try
            {
                int v = CallVersioned("NvAPI_GSync_QueryCapabilities", Fn<FnHandleBuf>(ID_GSync_QueryCapabilities),
                                      dev, buf, new int[] { 28, 20, 16 }, new int[] { 3, 2, 1 });
                Capabilities c = new Capabilities();
                c.BoardId = U32(buf, 4);
                c.Revision = U32(buf, 8);
                if (v <= 1) c.ExtendedRevision = U32(buf, 16);
                if (v == 0)
                {
                    c.MulDivSupported = (U32(buf, 20) & 1) != 0;
                    c.MaxMulDivValue = U32(buf, 24);
                }
                return c;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        public static Topology GetTopology(IntPtr dev)
        {
            FnTopology fn = Fn<FnTopology>(ID_GSync_GetTopology);
            uint gpuCount = 0, dispCount = 0;
            Check("NvAPI_GSync_GetTopology", fn(dev, ref gpuCount, IntPtr.Zero, ref dispCount, IntPtr.Zero));

            int[] strides = { 96, 16 };
            int[] versions = { 2, 1 };
            int first = 0;
            for (int v = 0; v < strides.Length; v++)
            {
                uint gc = gpuCount, dc = dispCount;
                int stride = strides[v];
                IntPtr gb = Alloc(Math.Max((int)gc, 1) * GPU_SIZE);
                IntPtr db = Alloc(Math.Max((int)dc, 1) * stride);
                try
                {
                    for (int i = 0; i < gc; i++) W32(gb, i * GPU_SIZE, Ver(GPU_SIZE, 1));
                    for (int i = 0; i < dc; i++) W32(db, i * stride, Ver(stride, versions[v]));
                    int st = fn(dev, ref gc, gc > 0 ? gb : IntPtr.Zero, ref dc, dc > 0 ? db : IntPtr.Zero);
                    if (st != 0)
                    {
                        if (v == 0) first = st;
                        continue;
                    }
                    dispStride = stride;
                    dispVer = versions[v];

                    Topology t = new Topology();
                    t.Gpus = new GpuInfo[gc];
                    for (int i = 0; i < gc; i++)
                    {
                        GpuInfo g = new GpuInfo();
                        g.Handle = Marshal.ReadIntPtr(gb, i * GPU_SIZE + 8);
                        g.Connector = Marshal.ReadInt32(gb, i * GPU_SIZE + 16);
                        g.ProxyHandle = Marshal.ReadIntPtr(gb, i * GPU_SIZE + 24);
                        g.Name = GpuName(g.Handle);
                        t.Gpus[i] = g;
                    }
                    t.Displays = new DisplayInfo[dc];
                    for (int i = 0; i < dc; i++)
                    {
                        DisplayInfo d = new DisplayInfo();
                        d.DisplayId = U32(db, i * stride + 4);
                        d.Masterable = (U32(db, i * stride + 8) & 1) != 0;
                        d.SyncState = Marshal.ReadInt32(db, i * stride + 12);
                        d.Gpu = GpuFromDisplay(d.DisplayId);
                        t.Displays[i] = d;
                    }
                    return t;
                }
                finally
                {
                    Marshal.FreeHGlobal(gb);
                    Marshal.FreeHGlobal(db);
                }
            }
            Check("NvAPI_GSync_GetTopology", first);
            return null;
        }

        // Displays not listed are removed from the sync group by the driver.
        public static void SetSyncState(uint[] displayIds, int[] states)
        {
            int n = displayIds.Length;
            IntPtr buf = Alloc(Math.Max(n, 1) * dispStride);
            try
            {
                for (int i = 0; i < n; i++)
                {
                    W32(buf, i * dispStride, Ver(dispStride, dispVer));
                    W32(buf, i * dispStride + 4, displayIds[i]);
                    W32(buf, i * dispStride + 12, (uint)states[i]);
                }
                Check("NvAPI_GSync_SetSyncStateSettings", Fn<FnSetSyncState>(ID_GSync_SetSyncStateSettings)((uint)n, buf, 0));
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        public static ControlParams GetControl(IntPtr dev)
        {
            IntPtr buf = Alloc(72);
            try
            {
                int v = CallVersioned("NvAPI_GSync_GetControlParameters", Fn<FnHandleBuf>(ID_GSync_GetControlParameters),
                                      dev, buf, new int[] { 72, 64 }, new int[] { 2, 1 });
                ControlParams c = new ControlParams();
                c.Raw = new byte[v == 0 ? 72 : 64];
                Marshal.Copy(buf, c.Raw, 0, c.Raw.Length);
                c.Polarity = Marshal.ReadInt32(buf, 4);
                c.VideoMode = Marshal.ReadInt32(buf, 8);
                c.Interval = U32(buf, 12);
                c.Source = Marshal.ReadInt32(buf, 16);
                uint bits = U32(buf, 20);
                c.Interlace = (bits & 1) != 0;
                c.SyncSourceIsOutput = (bits & 2) != 0;
                if (v == 0)
                {
                    c.MultiplyDivideMode = Marshal.ReadInt32(buf, 64);
                    c.MultiplyDivideValue = Marshal.ReadByte(buf, 68);
                }
                return c;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        public static void SetControl(IntPtr dev, ControlParams c)
        {
            IntPtr buf = Alloc(c.Raw.Length);
            try
            {
                Marshal.Copy(c.Raw, 0, buf, c.Raw.Length);
                W32(buf, 4, (uint)c.Polarity);
                W32(buf, 8, (uint)c.VideoMode);
                W32(buf, 12, c.Interval);
                W32(buf, 16, (uint)c.Source);
                uint bits = U32(buf, 20) & ~3u;
                if (c.Interlace) bits |= 1;
                if (c.SyncSourceIsOutput) bits |= 2;
                W32(buf, 20, bits);
                Check("NvAPI_GSync_SetControlParameters", Fn<FnHandleBuf>(ID_GSync_SetControlParameters)(dev, buf));
                Marshal.Copy(buf, c.Raw, 0, c.Raw.Length);
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        public static StatusParams GetStatusParams(IntPtr dev)
        {
            IntPtr buf = Alloc(36);
            try
            {
                CallVersioned("NvAPI_GSync_GetStatusParameters", Fn<FnHandleBuf>(ID_GSync_GetStatusParameters),
                              dev, buf, new int[] { 36, 32 }, new int[] { 2, 1 });
                StatusParams s = new StatusParams();
                s.RefreshRate = U32(buf, 4);
                s.Rj45Io[0] = Marshal.ReadInt32(buf, 8);
                s.Rj45Io[1] = Marshal.ReadInt32(buf, 12);
                s.Rj45Ethernet[0] = U32(buf, 16) != 0;
                s.Rj45Ethernet[1] = U32(buf, 20) != 0;
                s.HouseSyncIncoming = U32(buf, 24);
                s.HouseSync = U32(buf, 28) != 0;
                return s;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        public static SyncStatus GetSyncStatus(IntPtr dev, IntPtr gpu)
        {
            IntPtr buf = Alloc(16);
            try
            {
                W32(buf, 0, Ver(16, 1));
                Check("NvAPI_GSync_GetSyncStatus", Fn<FnSyncStatus>(ID_GSync_GetSyncStatus)(dev, gpu, buf));
                SyncStatus s = new SyncStatus();
                s.Synced = U32(buf, 4) != 0;
                s.StereoSynced = U32(buf, 8) != 0;
                s.SignalAvailable = U32(buf, 12) != 0;
                return s;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }
    }
}
'@

$VideoModes = @{ None = 0; TTL = 1; BiLevel = 2; TriLevel = 3; Composite = 4 }
$VideoModeNames = @{ 0 = 'None'; 1 = 'TTL'; 2 = 'Bi-level (NTSC/PAL/SECAM)'; 3 = 'Tri-level (HDTV)'; 4 = 'Composite' }
$Polarities = @{ Rising = 0; Falling = 1; Both = 2 }
$PolarityNames = @{ 0 = 'Rising edge'; 1 = 'Falling edge'; 2 = 'Both edges' }
$ConnectorNames = @{ 0 = 'none'; 1 = 'primary'; 2 = 'secondary'; 3 = 'tertiary'; 4 = 'quaternary' }
$SyncStateNames = @{ 0 = 'unsynced'; 1 = 'client'; 2 = 'SERVER' }

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Good', 'Warn', 'Error', 'Detail')]
        [string]$Level = 'Info'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level.ToUpper().PadRight(6), $Message
    $color = @{ Info = 'Gray'; Good = 'Green'; Warn = 'Yellow'; Error = 'Red'; Detail = 'DarkGray' }[$Level]
    Write-Host $line -ForegroundColor $color
    if ($LogFile) {
        try { Add-Content -LiteralPath $LogFile -Value $line } catch { }
    }
}

# Accepts 0x80061086, 2147880070, or the negative number PowerShell makes of an unquoted 0x8... literal.
function ConvertTo-DisplayId([string]$Text) {
    $Text = $Text.Trim()
    if ($Text -match '^0x([0-9a-fA-F]{1,8})$') { return [Convert]::ToUInt32($Matches[1], 16) }
    if ($Text -match '^-?\d+$') {
        $n = [int64]$Text
        if ($n -lt 0) { $n += 4294967296 }
        return [uint32]$n
    }
    throw "Invalid display id '$Text' - use the hex id shown by -Action Status, e.g. 0x80061086"
}

# NVAPI doesn't document the units of the rate fields; scale whatever we get into a plausible Hz range.
function ConvertTo-Hz([double]$Raw) {
    $v = $Raw
    while ($v -gt 250) { $v /= 10 }
    return [Math]::Round($v, 3)
}

function Get-SyncSnapshot {
    $handles = [Genlocker.NvGSync]::EnumSyncDevices()
    $devices = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $handles.Length; $i++) {
        $h = $handles[$i]
        $topo = [Genlocker.NvGSync]::GetTopology($h)
        $gpus = foreach ($g in $topo.Gpus) {
            # A GPU that can't report status counts as not synced rather than failing the whole snapshot.
            try { $st = [Genlocker.NvGSync]::GetSyncStatus($h, $g.Handle) } catch { $st = New-Object Genlocker.SyncStatus }
            [pscustomobject]@{ Info = $g; Status = $st }
        }
        $devices.Add([pscustomobject]@{
                Index    = $i
                Handle   = $h
                Caps     = [Genlocker.NvGSync]::QueryCapabilities($h)
                Control  = [Genlocker.NvGSync]::GetControl($h)
                Status   = [Genlocker.NvGSync]::GetStatusParams($h)
                Gpus     = @($gpus)
                Displays = @($topo.Displays)
            })
    }
    return , $devices.ToArray()
}

function Get-AllDisplays($Snapshot) {
    foreach ($dev in $Snapshot) {
        foreach ($d in $dev.Displays) { [pscustomobject]@{ Device = $dev; Display = $d } }
    }
}

function Get-ActiveDisplays($Snapshot) {
    @(Get-AllDisplays $Snapshot | Where-Object { $script:Excluded -notcontains $_.Display.DisplayId })
}

function Format-DisplayId([uint32]$Id) { '0x{0:X8}' -f $Id }

function Write-SyncStatus($Snapshot) {
    foreach ($dev in $Snapshot) {
        $c = $dev.Control; $s = $dev.Status; $caps = $dev.Caps
        Write-Log ('Sync device {0}: board P{1:X} FPGA rev {2}.{3}' -f $dev.Index, $caps.BoardId, $caps.Revision, $caps.ExtendedRevision)
        if ($s.HouseSync) {
            Write-Log ('  House sync (BNC): PRESENT, ~{0} Hz (raw {1})' -f (ConvertTo-Hz $s.HouseSyncIncoming), $s.HouseSyncIncoming) Good
        }
        else {
            Write-Log '  House sync (BNC): NOT DETECTED' Warn
        }
        Write-Log ('  Display refresh: ~{0} Hz (raw {1})' -f (ConvertTo-Hz $s.RefreshRate), $s.RefreshRate)
        Write-Log ('  Sync source: {0} | signal type: {1} | polarity: {2} | interval: {3}{4}' -f `
            $(if ($c.Source -eq 1) { 'HOUSE SYNC' } else { 'VSync (internal/display)' }),
            $VideoModeNames[$c.VideoMode], $PolarityNames[$c.Polarity], $c.Interval,
            $(if ($c.MultiplyDivideMode -ne 0) { " | mul/div mode $($c.MultiplyDivideMode) x$($c.MultiplyDivideValue)" } else { '' }))
        foreach ($g in $dev.Gpus) {
            $level = if ($g.Status.Synced) { 'Good' } else { 'Warn' }
            Write-Log ('  GPU "{0}" ({1} connector): synced={2} signal={3}' -f $g.Info.Name, $ConnectorNames[$g.Info.Connector], `
                    $g.Status.Synced, $g.Status.SignalAvailable) $level
        }
        foreach ($d in $dev.Displays) {
            $gpu = $dev.Gpus | Where-Object { $_.Info.Handle -eq $d.Gpu } | Select-Object -First 1
            Write-Log ('  Display {0}: {1}{2}{3}{4}' -f (Format-DisplayId $d.DisplayId), $SyncStateNames[$d.SyncState],
                $(if ($d.Masterable) { ', server-capable' } else { '' }),
                $(if ($gpu) { ", on $($gpu.Info.Name)" } else { '' }),
                $(if ($script:Excluded -contains $d.DisplayId) { ' (excluded)' } else { '' }))
        }
    }
}

function Test-Lock($Snapshot) {
    $problems = New-Object System.Collections.Generic.List[string]
    $active = Get-ActiveDisplays $Snapshot

    $masters = @($active | Where-Object { $_.Display.SyncState -eq 2 })
    if ($masters.Count -ne 1) {
        $problems.Add("expected 1 server display, found $($masters.Count)")
    }
    else {
        $mdev = $masters[0].Device
        if ($mdev.Control.Source -ne 1) { $problems.Add("sync source on device $($mdev.Index) is VSync, not house sync") }
        if (-not $mdev.Status.HouseSync) { $problems.Add("no house sync on BNC of device $($mdev.Index)") }
    }

    $unsynced = @($active | Where-Object { $_.Display.SyncState -eq 0 })
    if ($unsynced.Count -gt 0) {
        $problems.Add('not in sync group: ' + (($unsynced | ForEach-Object { Format-DisplayId $_.Display.DisplayId }) -join ', '))
    }

    # Only GPUs driving synced displays are expected to lock (e.g. ignore a GUI-only GPU).
    $mapped = @($active | Where-Object { $_.Display.Gpu -ne [IntPtr]::Zero })
    foreach ($dev in $Snapshot) {
        foreach ($g in $dev.Gpus) {
            $relevant = ($mapped.Count -eq 0) -or (@($mapped | Where-Object { $_.Display.Gpu -eq $g.Info.Handle }).Count -gt 0)
            if ($relevant -and -not $g.Status.Synced) {
                $problems.Add("GPU '$($g.Info.Name)' on device $($dev.Index) not synced (signal available: $($g.Status.SignalAvailable))")
            }
        }
    }

    [pscustomobject]@{ Locked = ($problems.Count -eq 0); Reason = ($problems -join '; ') }
}

function Get-LockPlan($Snapshot) {
    $active = Get-ActiveDisplays $Snapshot
    if ($active.Count -eq 0) { throw 'No active displays attached to the Sync device(s)' }
    $masterable = @($active | Where-Object { $_.Display.Masterable })
    if ($masterable.Count -eq 0) { throw 'None of the displays can act as sync server' }

    $choice = $null
    if ($null -ne $script:MasterId) {
        $choice = $masterable | Where-Object { $_.Display.DisplayId -eq $script:MasterId } | Select-Object -First 1
        if (-not $choice) { throw "Display $(Format-DisplayId $script:MasterId) is not attached, excluded, or not server-capable" }
    }
    # Otherwise keep the existing server if it sits on the card receiving house sync,
    # else the first server-capable display on that card, else any.
    if (-not $choice) { $choice = $masterable | Where-Object { $_.Display.SyncState -eq 2 -and $_.Device.Status.HouseSync } | Select-Object -First 1 }
    if (-not $choice) { $choice = $masterable | Where-Object { $_.Device.Status.HouseSync } | Select-Object -First 1 }
    if (-not $choice) { $choice = $masterable[0] }

    [pscustomobject]@{ Master = $choice; Active = $active }
}

function Set-AllUnsynced($Snapshot) {
    $all = @(Get-AllDisplays $Snapshot)
    if ($all.Count -eq 0) { return }
    $ids = [uint32[]]@($all | ForEach-Object { $_.Display.DisplayId })
    $states = [int[]]@($all | ForEach-Object { 0 })
    [Genlocker.NvGSync]::SetSyncState($ids, $states)
}

function Set-HouseSyncSource([IntPtr]$Handle) {
    $c = [Genlocker.NvGSync]::GetControl($Handle)
    $c.Source = 1
    $c.SyncSourceIsOutput = $false
    if ($SignalType -ne 'Keep') { $c.VideoMode = $VideoModes[$SignalType] }
    if ($Polarity -ne 'Keep') { $c.Polarity = $Polarities[$Polarity] }
    [Genlocker.NvGSync]::SetControl($Handle, $c)
}

function Test-RateMatch($Device) {
    $house = ConvertTo-Hz $Device.Status.HouseSyncIncoming
    $refresh = ConvertTo-Hz $Device.Status.RefreshRate
    if ($house -gt 0 -and $refresh -gt 0 -and $Device.Control.MultiplyDivideMode -eq 0 -and [Math]::Abs($house - $refresh) -gt 0.5) {
        Write-Log "House sync (~$house Hz) and display refresh (~$refresh Hz) look different - the lock cannot hold unless the output timing matches the reference." Warn
    }
}

# Polls until the lock has held for $HoldSeconds (true), or it drops / never arrives within $TimeoutSeconds (false).
function Wait-LockHold([double]$TimeoutSeconds) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lockedAt = $null
    $lastReason = ''
    while ($true) {
        $t = Test-Lock (Get-SyncSnapshot)
        $now = $sw.Elapsed.TotalSeconds
        if ($t.Locked) {
            if ($null -eq $lockedAt) {
                $lockedAt = $now
                Write-Log ('Lock reported after {0:N1}s - checking it holds for {1}s' -f $now, $HoldSeconds)
            }
            elseif ($now - $lockedAt -ge $HoldSeconds) {
                return $true
            }
        }
        else {
            if ($null -ne $lockedAt) {
                Write-Log ('Lock dropped after holding {0:N1}s: {1}' -f ($now - $lockedAt), $t.Reason) Warn
                return $false
            }
            if ($now -ge $TimeoutSeconds) {
                if ($TimeoutSeconds -gt 0) { Write-Log "No lock within ${TimeoutSeconds}s: $($t.Reason)" Warn }
                return $false
            }
            if ($t.Reason -ne $lastReason) {
                Write-Log "Waiting: $($t.Reason)" Detail
                $lastReason = $t.Reason
            }
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
}

function Invoke-LockAttempt([int]$Attempt) {
    $snap = Get-SyncSnapshot
    if (-not ($snap | Where-Object { $_.Status.HouseSync })) {
        Write-Log 'No house sync signal on any Sync device BNC input - check the cable and the generator' Warn
        return $false
    }
    $plan = Get-LockPlan $snap
    $master = $plan.Master
    $mdev = $master.Device
    Write-Log "Server display $(Format-DisplayId $master.Display.DisplayId) on Sync device $($mdev.Index); $($plan.Active.Count - 1) client display(s)"
    if (-not $mdev.Status.HouseSync) { Write-Log "Sync device $($mdev.Index) has no house sync signal but the server display is on it" Warn }
    Test-RateMatch $mdev

    # Each retry gives the hardware a little longer to settle.
    $settleMs = [Math]::Min(1000 + 500 * ($Attempt - 1), 5000)

    Write-Log 'Releasing current sync group'
    Set-AllUnsynced $snap
    Start-Sleep -Milliseconds $settleMs

    Write-Log 'Setting sync source to house sync'
    Set-HouseSyncSource $mdev.Handle
    Start-Sleep -Milliseconds 500

    Write-Log 'Forming sync group'
    $ids = [uint32[]]@($plan.Active | ForEach-Object { $_.Display.DisplayId })
    $states = [int[]]@($plan.Active | ForEach-Object { if ($_.Display.DisplayId -eq $master.Display.DisplayId) { 2 } else { 1 } })
    [Genlocker.NvGSync]::SetSyncState($ids, $states)

    # The driver can fall back to VSync when the sync group changes; put house sync back.
    Start-Sleep -Milliseconds 500
    if ([Genlocker.NvGSync]::GetControl($mdev.Handle).Source -ne 1) {
        Write-Log 'Driver reverted the source to VSync - re-applying house sync' Warn
        Set-HouseSyncSource $mdev.Handle
    }

    return (Wait-LockHold $LockTimeoutSeconds)
}

function Invoke-LockLoop([bool]$CheckExisting, [int]$Max) {
    if ($CheckExisting) {
        $t = Test-Lock (Get-SyncSnapshot)
        if ($t.Locked) {
            Write-Log 'Already locked to house sync - confirming it holds'
            if (Wait-LockHold 0) {
                Write-Log "Existing genlock held for ${HoldSeconds}s - nothing to do" Good
                return $true
            }
        }
        else {
            Write-Log "Not locked: $($t.Reason)"
        }
    }
    for ($n = 1; $Max -le 0 -or $n -le $Max; $n++) {
        Write-Log ('--- Attempt {0}{1} ---' -f $n, $(if ($Max -gt 0) { " of $Max" } else { '' }))
        try {
            if (Invoke-LockAttempt $n) {
                Write-Log "GENLOCKED: lock to house sync held for ${HoldSeconds}s (attempt $n)" Good
                return $true
            }
        }
        catch {
            Write-Log "Attempt $n failed: $($_.Exception.Message)" Error
        }
        if ($Max -le 0 -or $n -lt $Max) {
            $backoff = [Math]::Min(2 * $n, 10)
            Write-Log "Retrying in ${backoff}s"
            Start-Sleep -Seconds $backoff
        }
    }
    Write-Log "Could not establish a stable genlock after $Max attempts" Error
    return $false
}

# ---------------------------------------------------------------------------

if (-not [Environment]::Is64BitProcess) {
    Write-Log 'Run this from 64-bit PowerShell (NVAPI is loaded as nvapi64.dll)' Error
    exit 2
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Action -ne 'Status' -and -not $isAdmin) {
    Write-Log 'Changing sync settings requires Administrator - run from an elevated prompt' Error
    exit 3
}

try {
    $Excluded = [uint32[]]@($ExcludeDisplayId | ForEach-Object { ConvertTo-DisplayId $_ })
    $MasterId = if ($MasterDisplayId) { ConvertTo-DisplayId $MasterDisplayId } else { $null }
}
catch {
    Write-Log $_.Exception.Message Error
    exit 2
}

if (-not ('Genlocker.NvGSync' -as [type])) { Add-Type -TypeDefinition $NvGSyncSource -Language CSharp }

try {
    [Genlocker.NvGSync]::Initialize()
    try { Write-Log "NVIDIA driver $([Genlocker.NvGSync]::DriverVersion())" } catch { }
    $snap = Get-SyncSnapshot
}
catch {
    Write-Log $_.Exception.Message Error
    exit 2
}
if ($snap.Count -eq 0) {
    Write-Log 'No Quadro Sync / RTX PRO Sync device found' Error
    exit 2
}
Write-SyncStatus $snap

switch ($Action) {
    'Status' {
        $t = Test-Lock $snap
        if ($t.Locked) { Write-Log 'LOCKED to house sync' Good; exit 0 }
        Write-Log "NOT locked: $($t.Reason)" Warn
        exit 1
    }
    'Unlock' {
        Set-AllUnsynced $snap
        Write-Log 'All displays removed from the sync group' Good
        exit 0
    }
}

$maxAttempts = if ($Action -eq 'Watch') { 0 } else { $MaxAttempts }
$ok = Invoke-LockLoop -CheckExisting (-not $Force) -Max $maxAttempts

if ($Action -eq 'Lock') {
    try { Write-SyncStatus (Get-SyncSnapshot) } catch { }
    if ($ok) { exit 0 } else { exit 1 }
}

Write-Log "Watching the lock (Ctrl+C to stop); re-locking if it stays lost for ${LossGraceSeconds}s"
$lostSince = $null
while ($true) {
    try {
        $t = Test-Lock (Get-SyncSnapshot)
        if ($t.Locked) {
            if ($null -ne $lostSince) { Write-Log 'Lock recovered by itself' Good }
            $lostSince = $null
        }
        elseif ($null -eq $lostSince) {
            $lostSince = Get-Date
            Write-Log "Lock lost: $($t.Reason)" Warn
        }
        elseif (((Get-Date) - $lostSince).TotalSeconds -ge $LossGraceSeconds) {
            Write-Log 'Re-establishing genlock' Warn
            [void](Invoke-LockLoop -CheckExisting $false -Max 0)
            $lostSince = $null
        }
    }
    catch {
        Write-Log "Monitor error: $($_.Exception.Message)" Error
        Start-Sleep -Seconds 2
    }
    Start-Sleep -Milliseconds $PollMilliseconds
}
