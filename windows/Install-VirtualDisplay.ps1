[CmdletBinding()]
param([switch]$DownloadOnly, [switch]$UpdateOwnedModes)
$ErrorActionPreference = 'Stop'
$driverVersion = '25.7.23'
$expectedHash = 'E24210692B442B39AF763536330CE78B423F19342B7A7792C26DE3944E418B3A'
$cache = Join-Path $env:LOCALAPPDATA 'OpenDisplay\driver-cache\25.7.23'
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$archive = Join-Path $cache 'driver.zip'
if (-not (Test-Path -LiteralPath $archive)) {
    Invoke-WebRequest -Uri "https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/$driverVersion/VirtualDisplayDriver-x86.Driver.Only.zip" -OutFile $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expectedHash) { throw 'Driver archive checksum does not match the reviewed release.' }
Expand-Archive -LiteralPath $archive -DestinationPath $cache -Force
$driver = Join-Path $cache 'VirtualDisplayDriver'
$signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $driver 'mttvdd.cat')
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=SignPath Foundation') { throw 'Driver catalog signature did not validate.' }
if ($DownloadOnly) { Write-Output "Verified signed driver cached at $driver"; exit 0 }

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Run this script as administrator to install the virtual display. The download-only check does not need administrator rights.' }
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit PowerShell.' }
$existing = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match '^ROOT\\(MTTVDD|OPENDISPLAY)' -or $_.FriendlyName -eq 'Virtual Display Driver' }
if ($existing -and -not $UpdateOwnedModes) { Write-Output 'A virtual display driver is already installed. Reuse it in Windows display settings; no changes made.'; exit 0 }

# The driver's documented settings directory; preserve any existing configuration.
$configDir = 'C:\VirtualDisplayDriver'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
$configPath = Join-Path $configDir 'vdd_settings.xml'
$receipt = Join-Path $configDir 'opendisplay-device.txt'
if ($UpdateOwnedModes) {
    if (-not (Test-Path -LiteralPath $receipt)) { throw 'No OpenDisplay installation receipt; existing driver configuration was not changed.' }
    $deviceId = (Get-Content -LiteralPath $receipt -Raw).Trim() -replace ' \(restart required\)$',''
    if ($deviceId -notmatch '^ROOT\\OPENDISPLAY\\[0-9]{4}$' -or -not ($existing | Where-Object InstanceId -eq $deviceId)) { throw 'The saved OpenDisplay device does not match the installed adapter.' }
}
if (-not (Test-Path -LiteralPath $configPath) -or $UpdateOwnedModes) {
    if ($UpdateOwnedModes) {
        Copy-Item -LiteralPath $configPath -Destination ($configPath + '.before-auto-size') -Force
        [xml]$config = Get-Content -LiteralPath $configPath
    } else { [xml]$config = Get-Content -LiteralPath (Join-Path $driver 'vdd_settings.xml') }
    $globalSettings = $config.SelectSingleNode('/vdd_settings/global')
    $resolutions = $config.SelectSingleNode('/vdd_settings/resolutions')
    if (-not $UpdateOwnedModes) {
        $globalSettings.RemoveAll()
        $rate = $config.CreateElement('g_refresh_rate'); $rate.InnerText = '60'; [void]$globalSettings.AppendChild($rate)
        $resolutions.RemoveAll()
    }
    foreach ($size in @(@(1920,1200),@(1600,1200),@(1920,1080),@(1600,1000),@(2048,1536),@(2160,1620),@(2224,1668),@(2266,1488),@(2360,1640),@(2388,1668),@(2420,1668),@(2732,2048),@(2752,2064))) {
        foreach ($mode in @($size,@($size[1],$size[0]))) {
            $width = [string]$mode[0]; $height = [string]$mode[1]
            if ($resolutions.SelectSingleNode("resolution[width='$width' and height='$height']")) { continue }
            $res = $config.CreateElement('resolution')
            foreach ($entry in @(@('width',$mode[0]),@('height',$mode[1]),@('refresh_rate',30))) { $item = $config.CreateElement($entry[0]); $item.InnerText = [string]$entry[1]; [void]$res.AppendChild($item) }
            [void]$resolutions.AppendChild($res)
        }
    }
    $config.Save($configPath)
}
if ($UpdateOwnedModes) {
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.','MTTVirtualDisplayPipe',[IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(2000)
        $command = [Text.Encoding]::Unicode.GetBytes('RELOAD_DRIVER')
        $pipe.Write($command,0,$command.Length)
        $pipe.Flush()
    } catch { throw 'Display sizes were saved, but the virtual driver did not accept the reload request. Restart Windows when convenient.' }
    finally { $pipe.Dispose() }
    Write-Output 'Added automatic iPad display sizes and requested a virtual-driver reload. Refresh OpenDisplay to see the updated display modes.'
    exit 0
}
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class OpenDisplayDriverSetup {
    [StructLayout(LayoutKind.Sequential)] public struct DeviceData { public int Size; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved; }
    [DllImport("setupapi.dll",SetLastError=true)] static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid cls, IntPtr parent);
    [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiCreateDeviceInfo(IntPtr set,string name,ref Guid cls,string desc,IntPtr parent,uint flags,ref DeviceData data);
    [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiSetDeviceRegistryProperty(IntPtr set,ref DeviceData data,uint prop,byte[] buffer,uint length);
    [DllImport("setupapi.dll",SetLastError=true)] static extern bool SetupDiCallClassInstaller(uint action,IntPtr set,ref DeviceData data);
    [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiGetDeviceInstanceId(IntPtr set,ref DeviceData data,StringBuilder result,int length,out int needed);
    [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("newdev.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool UpdateDriverForPlugAndPlayDevices(IntPtr parent,string hardwareId,string inf,uint flags,out bool restart);
    static void Check(bool ok) { if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    public static string Install(string inf) {
        Guid cls = new Guid("4d36e968-e325-11ce-bfc1-08002be10318");
        IntPtr set = SetupDiCreateDeviceInfoList(ref cls, IntPtr.Zero);
        if(set == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        var d = new DeviceData { Size=Marshal.SizeOf(typeof(DeviceData)) }; bool registered=false;
        try {
            Check(SetupDiCreateDeviceInfo(set,"OpenDisplay",ref cls,"OpenDisplay Virtual Monitor",IntPtr.Zero,1,ref d));
            byte[] ids=Encoding.Unicode.GetBytes("Root\\MttVDD\0\0");
            Check(SetupDiSetDeviceRegistryProperty(set,ref d,1,ids,(uint)ids.Length));
            Check(SetupDiCallClassInstaller(0x19,set,ref d)); registered=true;
            bool restart; Check(UpdateDriverForPlugAndPlayDevices(IntPtr.Zero,"Root\\MttVDD",inf,0,out restart));
            var id=new StringBuilder(512); int needed; Check(SetupDiGetDeviceInstanceId(set,ref d,id,id.Capacity,out needed));
            return id.ToString() + (restart ? " (restart required)" : "");
        } catch { if(registered) SetupDiCallClassInstaller(0x05,set,ref d); throw; }
        finally { SetupDiDestroyDeviceInfoList(set); }
    }
}
'@
$result = [OpenDisplayDriverSetup]::Install((Join-Path $driver 'MttVDD.inf'))
Set-Content -LiteralPath $receipt -Value $result
Write-Output "Installed: $result"
Write-Output 'Open Windows Display settings, choose Extend, keep your physical screen as the main display, and arrange the new display beside it. Then refresh OpenDisplay.'
Write-Output "To undo this added device, use Device Manager or pnputil /remove-device with the exact device ID saved in $receipt. This script never reboots the PC."
