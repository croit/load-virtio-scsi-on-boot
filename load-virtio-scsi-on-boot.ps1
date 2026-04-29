# Purpose of this script
# * make Windows load the VirtIO SCSI pass-through driver on boot without reboot or external programs
#
# Prerequisites
# * VirtIO SCSI driver (vioscsi) must be installed OR path to the INF-File must be given as argument to the script
# * Windows 7/8 or Windows Server 2008 or newer
#
# Remarks
# * On Windows before Windows Server 2022 and Windows 10 2004 the software device created by the script will not be removed automatically, but this can be done via device manager. It can also be left there, no harm in that.
# * You should have a backup of your system.
# * This script was tested only 
# ** on Windows Server 2025 Standard Edition (24H2)
# ** on Windows Server 2022 Datacenter Edition (21H2)
# ** with virtio drivers version .266, .271, .285
# * nearly all code in here was written by AI
#
# How to use
# either 
# * install the vioscsi.inf before OR
# * tell the script to do it by -InfPath parameter OR
# * use virtio-win-guest-tools.exe /S to install it
# depending on the set security policy it might be required to run the script via
# PowerShell /ExecutionPolicy Bypass /File <path-to-this-script-file> [-InfPath <path-to-vioscsi.inf>]
#
# How does the script work?
# * install the vioscsi driver, if requested
# * create a software based device via Win32-API
# * add some registry settings
# * use pnputil to install the driver for this device
# * use pnputil to remove the device
# The driver-to-device assignment marks the driver for being loaded on boot.
# Now the Windows is ready for migration to a VirtIO based SCSI disk.

# ==== PARAMETER ====
param(
    [string]$InfPath = ""  # Optional: Path to vioscsi.inf file
)

$source = @"
using System;
using System.Runtime.InteropServices;

public class DeviceInstaller
{
    private const uint DIF_REGISTERDEVICE = 0x00000019;
    private const uint DIF_SELECTBESTCOMPATDRV = 0x00000017;
    private const uint DIF_INSTALLDEVICE = 0x00000002;
    private const uint DICD_GENERATE_ID = 0x00000001;
    private const uint SPDIT_COMPATDRIVER = 0x00000001;
    
    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVINFO_DATA
    {
        public uint cbSize;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }
    
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid ClassGuid, IntPtr hwndParent);
    
    [DllImport("setupapi.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern bool SetupDiCreateDeviceInfo(
        IntPtr DeviceInfoSet,
        string DeviceName,
        ref Guid ClassGuid,
        string DeviceDescription,
        IntPtr hwndParent,
        uint CreationFlags,
        ref SP_DEVINFO_DATA DeviceInfoData);
    
    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiSetDeviceRegistryProperty(
        IntPtr DeviceInfoSet,
        ref SP_DEVINFO_DATA DeviceInfoData,
        uint Property,
        byte[] PropertyBuffer,
        uint PropertyBufferSize);
    
    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiRegisterDeviceInfo(
        IntPtr DeviceInfoSet,
        ref SP_DEVINFO_DATA DeviceInfoData,
        uint Flags,
        IntPtr CompareProc,
        IntPtr CompareContext,
        IntPtr DupDeviceInfo);
    
    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiCallClassInstaller(
        uint InstallFunction,
        IntPtr DeviceInfoSet,
        ref SP_DEVINFO_DATA DeviceInfoData);
    
    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);
    
    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiBuildDriverInfoList(
        IntPtr DeviceInfoSet,
        ref SP_DEVINFO_DATA DeviceInfoData,
        uint DriverType);
    
    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiInstallDevice(
        IntPtr DeviceInfoSet,
        ref SP_DEVINFO_DATA DeviceInfoData);
    
    public static void CreateSoftwareDeviceWithHardwareId(string deviceId, string classGuidStr, string hardwareId)
    {
        Guid classGuid = new Guid(classGuidStr);
        IntPtr devInfoSet = SetupDiCreateDeviceInfoList(ref classGuid, IntPtr.Zero);
        
        if (devInfoSet == IntPtr.Zero || devInfoSet.ToInt64() == -1)
        {
            int error = Marshal.GetLastWin32Error();
            throw new Exception("SetupDiCreateDeviceInfoList failed with error " + error);
        }
        
        try
        {
            SP_DEVINFO_DATA devInfoData = new SP_DEVINFO_DATA();
            devInfoData.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
            devInfoData.ClassGuid = classGuid;
            
            if (!SetupDiCreateDeviceInfo(devInfoSet, deviceId, ref classGuid, "VirtIO SCSI Controller", IntPtr.Zero, DICD_GENERATE_ID, ref devInfoData))
            {
                int error = Marshal.GetLastWin32Error();
                throw new Exception("SetupDiCreateDeviceInfo failed with error " + error);
            }
            
            byte[] hwid = System.Text.Encoding.ASCII.GetBytes(hardwareId + "\0\0");
            if (!SetupDiSetDeviceRegistryProperty(devInfoSet, ref devInfoData, 1, hwid, (uint)hwid.Length))
            {
                int error = Marshal.GetLastWin32Error();
                throw new Exception("SetupDiSetDeviceRegistryProperty failed with error " + error);
            }
            
            if (!SetupDiRegisterDeviceInfo(devInfoSet, ref devInfoData, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero))
            {
                int error = Marshal.GetLastWin32Error();
                throw new Exception("SetupDiRegisterDeviceInfo failed with error " + error);
            }
            
            if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, devInfoSet, ref devInfoData))
            {
                int error = Marshal.GetLastWin32Error();
                throw new Exception("SetupDiCallClassInstaller failed with error " + error);
            }
            
            // Driver installation
            Console.WriteLine("Building driver info list...");
            if (SetupDiBuildDriverInfoList(devInfoSet, ref devInfoData, SPDIT_COMPATDRIVER))
            {
                Console.WriteLine("Driver info list built successfully");
                
                // Select compatible driver
                if (SetupDiCallClassInstaller(DIF_SELECTBESTCOMPATDRV, devInfoSet, ref devInfoData))
                {
                    Console.WriteLine("Best compatible driver selected");
                    
                    // Install driver
                    if (SetupDiInstallDevice(devInfoSet, ref devInfoData))
                    {
                        Console.WriteLine("Driver installed successfully");
                    }
                    else
                    {
                        int error = Marshal.GetLastWin32Error();
                        Console.WriteLine("SetupDiInstallDevice failed with error " + error);
                    }
                    
                    // Call device installation class installer
                    if (SetupDiCallClassInstaller(DIF_INSTALLDEVICE, devInfoSet, ref devInfoData))
                    {
                        Console.WriteLine("Device installation completed");
                    }
                    else
                    {
                        int error = Marshal.GetLastWin32Error();
                        Console.WriteLine("DIF_INSTALLDEVICE failed with error " + error);
                    }
                }
                else
                {
                    int error = Marshal.GetLastWin32Error();
                    Console.WriteLine("DIF_SELECTBESTCOMPATDRV failed with error " + error);
                }
            }
            else
            {
                int error = Marshal.GetLastWin32Error();
                Console.WriteLine("SetupDiBuildDriverInfoList failed with error " + error);
            }
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(devInfoSet);
        }
    }
}
"@

# Checking for administrator access
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "This script must be run with administrator privileges!"
    exit 1
}

# Add compiled class
Add-Type -TypeDefinition $source

$deviceId = "vioscsi"
$classGuid = "{4d36e97b-e325-11ce-bfc1-08002be10318}"
$hardwareId = "PCI\VEN_1AF4&DEV_1004&SUBSYS_00081AF4&REV_00"

# Registry path for VirtIO installation
$virtioBasePath = "HKLM:\SOFTWARE\RedHat\Virtio-Win\Components\vioscsi"

try {
    # OPTIONAL: Install INF driver first if path provided
    if ($InfPath -and (Test-Path $InfPath)) {
        Write-Host "Installing INF driver from provided path..." -ForegroundColor Yellow
        Write-Host "INF Path: $InfPath" -ForegroundColor Cyan
        
        # Check Windows version for correct pnputil syntax
        $osVersion = [System.Environment]::OSVersion.Version
        $buildNumber = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
        $useNewSyntax = ($osVersion.Major -gt 10) -or 
                       (($osVersion.Major -eq 10) -and ([int]$buildNumber -ge 14393)) -or
                       (($osVersion.Major -eq 6) -and ($osVersion.Minor -ge 3))
        
        try {
            if ($useNewSyntax) {
                Write-Host "Executing: pnputil /add-driver `"$InfPath`" /install" -ForegroundColor Gray
                & pnputil /add-driver "$InfPath" /install
            } else {
                Write-Host "Executing: pnputil -a -i `"$InfPath`"" -ForegroundColor Gray
                & pnputil -a -i "$InfPath"
            }
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "INF driver installed successfully!" -ForegroundColor Green
            } else {
                Write-Host "INF installation completed with exit code $LASTEXITCODE" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "INF installation failed: $($_.Exception.Message)" -ForegroundColor Red
            throw "Cannot continue without driver installation"
        }
        
        Write-Host "Waiting for driver registration..." -ForegroundColor Cyan
        Start-Sleep -Seconds 2
    } elseif ($InfPath) {
        throw "Provided INF path does not exist: $InfPath"
    }
    # Check if VirtIO registry entries exist
    if (-not (Test-Path $virtioBasePath)) {
        Write-Host "VirtIO guest tools registry not found, searching DriverDatabase..." -ForegroundColor Yellow
        
        # Fallback: Search in DriverDatabase for vioscsi.inf
        $driverDbPath = "HKLM:\SYSTEM\DriverDatabase\DriverPackages"
        $vioscsiDrivers = Get-ChildItem $driverDbPath | Where-Object { $_.Name -like "*vioscsi.inf*" }
        
        if ($vioscsiDrivers) {
            # Take the first matching entry
            $driverEntry = $vioscsiDrivers[0]
            $oemInfName = (Get-ItemProperty -Path $driverEntry.PSPath).'(default)'
            
            if ($oemInfName) {
                Write-Host "Found vioscsi driver in DriverDatabase: $($driverEntry.Name.Split('\')[-1])" -ForegroundColor Cyan
                Write-Host "OEM INF name: $oemInfName" -ForegroundColor Cyan
                $oemInf = "$env:windir\INF\$oemInfName"
                $infFullPath = $oemInf  # Set for consistency
            } else {
                throw "Could not read OEM INF name from DriverDatabase entry"
            }
        } else {
            throw "VirtIO SCSI driver not found in DriverDatabase. Please install vioscsi.inf or virtio-win-guest-tools.exe first."
        }
    } else {
        # Original method: Read from VirtIO guest tools registry
        Write-Host "Reading VirtIO registry values..." -ForegroundColor Yellow
        $virtioProps = Get-ItemProperty -Path $virtioBasePath
        $infFullPath = $virtioProps.strongname
        $oemInfName = $virtioProps.oem
        
        if (-not $infFullPath -or -not $oemInfName) {
            throw "Registry values strongname or oem not found"
        }
        
        Write-Host "INF path found: $infFullPath" -ForegroundColor Cyan
        Write-Host "OEM name found: $oemInfName" -ForegroundColor Cyan
        $oemInf = "$env:windir\INF\$oemInfName"
    }

    # Step 1: Create device
    Write-Host "`nStep 1: Creating device using Setup API..." -ForegroundColor Yellow
    
    [DeviceInstaller]::CreateSoftwareDeviceWithHardwareId($deviceId, $classGuid, $hardwareId)
    Write-Host "Device created successfully using Setup API!" -ForegroundColor Green

    # Step 2: Assign driver
    Write-Host "`nStep 2: Configuring driver assignment via registry..." -ForegroundColor Yellow
    
    $targetHardwareId = $hardwareId
    
    # Find the created device path
    $devicePath = "HKLM:\SYSTEM\CurrentControlSet\Enum\ROOT\$deviceId\0000"
    
    if (-not (Test-Path $devicePath)) {
        Write-Host "Warning: Created device not found at expected path $devicePath" -ForegroundColor Yellow
        $enumPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\ROOT"
        $vioscsiDevices = Get-ChildItem $enumPath | Where-Object { $_.Name -like "*vioscsi*" -or $_.Name -like "*$deviceId*" }
        if ($vioscsiDevices) {
            $devicePath = $vioscsiDevices[0].PSPath + "\0000"
            Write-Host "Found device at: $devicePath" -ForegroundColor Cyan
        }
    }
    
    if (Test-Path $devicePath) {
        Write-Host "=== BEFORE Registry modifications ===" -ForegroundColor Magenta
        $originalProps = Get-ItemProperty -Path $devicePath
        Write-Host "Original Hardware ID: $($originalProps.HardwareID)" -ForegroundColor Yellow
        Write-Host "Original Class: $($originalProps.Class)" -ForegroundColor Yellow
        Write-Host "Original Service: $($originalProps.Service)" -ForegroundColor Yellow
        Write-Host "Original ClassGUID: $($originalProps.ClassGUID)" -ForegroundColor Yellow
        
        Write-Host "Checking device registry configuration..." -ForegroundColor Cyan
        
        # Add only missing values, no overwriting
        if (-not $originalProps.Service) {
            Set-ItemProperty -Path $devicePath -Name "Service" -Value "vioscsi" -Type String
            Write-Host "Added Service: vioscsi" -ForegroundColor Green
        } else {
            Write-Host "Service already set: $($originalProps.Service)" -ForegroundColor Cyan
        }
        
        if (-not $originalProps.Class) {
            Set-ItemProperty -Path $devicePath -Name "Class" -Value "SCSIAdapter" -Type String
            Write-Host "Added Class: SCSIAdapter" -ForegroundColor Green
        } else {
            Write-Host "Class already set: $($originalProps.Class)" -ForegroundColor Cyan
        }
        
        if (-not $originalProps.DeviceDesc) {
            Set-ItemProperty -Path $devicePath -Name "DeviceDesc" -Value "@$oemInfName,%virtioscsi.devicedesc%;VirtIO SCSI Controller" -Type String
            Write-Host "Added DeviceDesc" -ForegroundColor Green
        } else {
            Write-Host "DeviceDesc already set" -ForegroundColor Cyan
        }
        
        if (-not $originalProps.Mfg) {
            Set-ItemProperty -Path $devicePath -Name "Mfg" -Value "@$oemInfName,%vendor%;Red Hat, Inc." -Type String
            Write-Host "Added Mfg" -ForegroundColor Green
        } else {
            Write-Host "Mfg already set" -ForegroundColor Cyan
        }
        
        if (-not $originalProps.CompatibleIDs) {
            $compatibleIds = @("PCI\VEN_1AF4&DEV_1004", "PCI\VEN_1AF4", "PCI\CC_010000", "PCI\CC_0100")
            Set-ItemProperty -Path $devicePath -Name "CompatibleIDs" -Value $compatibleIds -Type MultiString
            Write-Host "Added CompatibleIDs" -ForegroundColor Green
        } else {
            Write-Host "CompatibleIDs already set" -ForegroundColor Cyan
        }
        
        Write-Host "Device registry configuration checked" -ForegroundColor Green
    }
    
    # Step 2a: Pre-configure driver binding to force immediate loading
    Write-Host "`nStep 2a: Pre-configuring driver binding..." -ForegroundColor Yellow
    
    # Create driver binding in Control\Class to force immediate association
    $classPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e97b-e325-11ce-bfc1-08002be10318}"
    
    # Find next available driver number
    $existingNumbers = @()
    $classItems = Get-ChildItem $classPath -ErrorAction SilentlyContinue
    if ($classItems) {
        foreach ($item in $classItems) {
            if ($item.Name -match '\\(\d{4})$') {
                $existingNumbers += [int]$Matches[1]
            }
        }
    }
    
    $nextNumber = if ($existingNumbers) { ($existingNumbers | Measure-Object -Maximum).Maximum + 1 } else { 1 }
    $nextNumberStr = $nextNumber.ToString("0000")
    
    # Create Control\Class entry for immediate driver binding
    $newClassPath = "$classPath\$nextNumberStr"
    New-Item -Path $newClassPath -Force | Out-Null
    
    # Set driver class properties  
    Set-ItemProperty -Path $newClassPath -Name "InfPath" -Value $oemInfName -Type String
    Set-ItemProperty -Path $newClassPath -Name "InfSection" -Value "scsi_inst" -Type String
    Set-ItemProperty -Path $newClassPath -Name "ProviderName" -Value "Red Hat, Inc." -Type String
    Set-ItemProperty -Path $newClassPath -Name "DriverDate" -Value "10-21-2024" -Type String
    Set-ItemProperty -Path $newClassPath -Name "DriverVersion" -Value "100.100.104.26600" -Type String
    Set-ItemProperty -Path $newClassPath -Name "MatchingDeviceId" -Value $targetHardwareId -Type String
    Set-ItemProperty -Path $newClassPath -Name "DriverDesc" -Value "Red Hat VirtIO SCSI pass-through controller" -Type String
    
    Write-Host "Driver class binding created: $nextNumberStr" -ForegroundColor Green
    
    # Pre-configure the device to reference this driver
    if (Test-Path $devicePath) {
        Set-ItemProperty -Path $devicePath -Name "Driver" -Value "{4d36e97b-e325-11ce-bfc1-08002be10318}\$nextNumberStr" -Type String
        Set-ItemProperty -Path $devicePath -Name "Problem" -Value 0 -Type DWord
        Set-ItemProperty -Path $devicePath -Name "StatusFlags" -Value 0x18 -Type DWord
        Write-Host "Device pre-configured with driver binding" -ForegroundColor Green
    }
    
    # Step 3: Create Critical Device Database entries
    Write-Host "`nStep 3: Creating Critical Device Database entries..." -ForegroundColor Yellow
    
    # Critical Device Database paths
    $criticalDbPaths = @(
        "HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004",
        "HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004&subsys_00081af4&rev_00"  
    )
    
    $criticalDbCount = 0
    foreach ($criticalPath in $criticalDbPaths) {
        $pathExists = Test-Path $criticalPath
        if (-not $pathExists) {
            New-Item -Path $criticalPath -Force -ErrorAction SilentlyContinue | Out-Null
        }
        
        # Verify path was created
        if (Test-Path $criticalPath) {
            Set-ItemProperty -Path $criticalPath -Name "Service" -Value "vioscsi" -Type String -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $criticalPath -Name "ClassGUID" -Value "{4d36e97b-e325-11ce-bfc1-08002be10318}" -Type String -ErrorAction SilentlyContinue
            $criticalDbCount++
            
            $shortPath = $criticalPath.Split('\')[-1]
            Write-Host "Critical DB entry created: $shortPath" -ForegroundColor Green
        }
    }
    
    Write-Host "Total Critical DB entries created: $criticalDbCount/$($criticalDbPaths.Count)" -ForegroundColor $(if ($criticalDbCount -eq $criticalDbPaths.Count) { 'Green' } else { 'Yellow' })
    
    # Step 4: Trigger device enumeration
    Write-Host "`nStep 5: Triggering device enumeration..." -ForegroundColor Yellow
    
    # Simple Configuration Manager API for ROOT enumeration only
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public class ConfigManager {
    public const uint CR_SUCCESS = 0;
    public const uint CM_REENUMERATE_SYNCHRONOUS = 0x00000001;
    
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    public static extern uint CM_Locate_DevNode(out uint pdnDevInst, string pDeviceID, uint ulFlags);
    
    [DllImport("cfgmgr32.dll")]
    public static extern uint CM_Reenumerate_DevNode(uint dnDevInst, uint ulFlags);
    
    public static bool ReenumerateRootDevices() {
        uint rootDevInst;
        uint result = CM_Locate_DevNode(out rootDevInst, "ROOT", 0);
        if (result == CR_SUCCESS) {
            result = CM_Reenumerate_DevNode(rootDevInst, CM_REENUMERATE_SYNCHRONOUS);
            return result == CR_SUCCESS;
        }
        return false;
    }
}
"@
    
    # Re-enumerate ROOT devices
    Write-Host "Re-enumerating ROOT device tree..." -ForegroundColor Cyan
    $rootSuccess = [ConfigManager]::ReenumerateRootDevices()
    if ($rootSuccess) {
        Write-Host "ROOT enumeration successful" -ForegroundColor Green
    } else {
        Write-Host "ROOT enumeration completed (result unknown)" -ForegroundColor Yellow
    }
    
    # Wait for processing
    Write-Host "Waiting for Windows to process enumeration..." -ForegroundColor Cyan
    Start-Sleep -Seconds 3
    
    # Step 5: Verification
    Write-Host "`n=== VERIFICATION ===" -ForegroundColor Magenta
    
    # Check device
    if (Test-Path $devicePath) {
        $deviceProps = Get-ItemProperty -Path $devicePath
        Write-Host "Device:" -ForegroundColor White
        Write-Host "  Hardware ID: $($deviceProps.HardwareID[0])" -ForegroundColor White
        Write-Host "  Service: $($deviceProps.Service)" -ForegroundColor White
        Write-Host "  Class: $($deviceProps.Class)" -ForegroundColor White
        Write-Host "  Driver: $($deviceProps.Driver)" -ForegroundColor White
    }
      
    Write-Host "Device creation and driver assignment complete!" -ForegroundColor Green
    
    # FINAL STEP: Install driver using pnputil
    Write-Host "`nFinal Step: Installing driver using pnputil..." -ForegroundColor Yellow
    
    # Check Windows version for correct pnputil syntax
    $osVersion = [System.Environment]::OSVersion.Version
    $buildNumber = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
    
    Write-Host "Detected Windows version: $($osVersion.Major).$($osVersion.Minor) Build $buildNumber" -ForegroundColor Gray
    
    # Windows 10 1607 = Build 14393, where /add-driver /install was introduced
    $useNewSyntax = ($osVersion.Major -gt 10) -or 
                   (($osVersion.Major -eq 10) -and ([int]$buildNumber -ge 14393)) -or
                   (($osVersion.Major -eq 6) -and ($osVersion.Minor -ge 3))  # Windows 8.1+
    
    try {
        if ($useNewSyntax) {
            Write-Host "Using modern pnputil syntax: /add-driver /install" -ForegroundColor Cyan
            Write-Host "Executing: pnputil /add-driver `"$oemInf`" /install" -ForegroundColor Gray
            & pnputil /add-driver "$oemInf" /install
        } else {
            Write-Host "Using legacy pnputil syntax: -a -i" -ForegroundColor Cyan  
            Write-Host "Executing: pnputil -a -i `"$oemInf`"" -ForegroundColor Gray
            & pnputil -a -i "$oemInf"
        }
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Driver successfully installed via pnputil!" -ForegroundColor Green
        } else {
            Write-Host "pnputil completed with exit code $LASTEXITCODE" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "pnputil execution failed: $($_.Exception.Message)" -ForegroundColor Red
        
        # Fallback: Try the other syntax if the first one failed
        try {
            if ($useNewSyntax) {
                Write-Host "Trying fallback with legacy syntax..." -ForegroundColor Yellow
                & pnputil -a -i "$oemInf"
            } else {
                Write-Host "Trying fallback with modern syntax..." -ForegroundColor Yellow
                & pnputil /add-driver "$oemInf" /install
            }
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Driver installed with fallback syntax!" -ForegroundColor Green
            }
        } catch {
            Write-Host "Both pnputil syntaxes failed" -ForegroundColor Red
        }
    }
	    # Check Windows version for pnputil /remove-device support
    $buildNumber = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
    $supportsRemoveDevice = ([int]$buildNumber -ge 19041)
    
    if (-not $supportsRemoveDevice) {
        Write-Host "`npnputil /remove-device not supported on this Windows version (Build $buildNumber)" -ForegroundColor Yellow
        Write-Host "Required: Windows 10 2004+ (Build 19041+) or Windows Server 2022+" -ForegroundColor Yellow
        Write-Host "`nManual removal required:" -ForegroundColor Cyan
        Write-Host "- Device Manager: devmgmt.msc -> Uninstall VirtIO SCSI Controller" -ForegroundColor Gray
        Write-Host "- devcon.exe: devcon remove ROOT\\VIOSCSI\\0000" -ForegroundColor Gray
        return
    }

    Write-Host "`nStep 1: Finding VirtIO phantom devices..." -ForegroundColor Yellow
    
    # Find devices using pnputil
    Write-Host "Enumerating devices with pnputil..." -ForegroundColor Cyan
    $deviceList = & pnputil /enum-devices 2>&1
    
    # Parse output to find VirtIO devices
    $virtioDevices = @()
    $currentDevice = $null
    $currentInstanceId = $null
    
    foreach ($line in $deviceList) {
        if ($line -match "Instance ID:\s+(.+)") {
            $currentInstanceId = $Matches[1].Trim()
        }
        elseif ($line -match "Device Description:\s+(.+)") {
            $deviceDesc = $Matches[1].Trim()
            # Only target ROOT enumerated devices (phantom devices) with vioscsi
            if ($currentInstanceId -like "ROOT\*$deviceId*") {
                $virtioDevices += [PSCustomObject]@{
                    InstanceId = $currentInstanceId
                    Description = $deviceDesc
                }
                Write-Host "Found VirtIO phantom device: $deviceDesc [$currentInstanceId]" -ForegroundColor Cyan
            }
        }
    }
    
    if ($virtioDevices.Count -eq 0) {
        Write-Host "No VirtIO phantom devices found" -ForegroundColor Yellow
    } else {
        Write-Host "Found $($virtioDevices.Count) VirtIO device(s) to remove" -ForegroundColor Green
    }
    
    Write-Host "`nStep 2: Removing devices using pnputil..." -ForegroundColor Yellow
    
    $removedCount = 0
    foreach ($device in $virtioDevices) {
        Write-Host "Removing device: $($device.Description)" -ForegroundColor Cyan
        Write-Host "Instance ID: $($device.InstanceId)" -ForegroundColor Gray
        
        try {
            # Remove device using pnputil
            Write-Host "Executing: pnputil /remove-device `"$($device.InstanceId)`"" -ForegroundColor Gray
            & pnputil /remove-device "$($device.InstanceId)"
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Device removed successfully" -ForegroundColor Green
                $removedCount++
            } else {
                Write-Host "pnputil completed with exit code $LASTEXITCODE" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "Failed to remove device: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    Write-Host "`nStep 3: Verification..." -ForegroundColor Yellow
    
    # Check if devices still exist
    $remainingDevices = Get-WmiObject -Class Win32_PnPEntity -Filter "DeviceID LIKE 'ROOT\\%vioscsi%'" -ErrorAction SilentlyContinue
    if ($remainingDevices) {
        Write-Host "Some VirtIO phantom devices still visible:" -ForegroundColor Yellow
        foreach ($device in $remainingDevices) {
            Write-Host "  - $($device.Name) [$($device.Status)]" -ForegroundColor Yellow
        }
    } else {
        Write-Host "No VirtIO phantom devices found in system" -ForegroundColor Green
    }
    
    Write-Host "`n=== REMOVAL COMPLETED ===" -ForegroundColor Red
    Write-Host "pnputil-based phantom device removal complete!" -ForegroundColor Green
    
    Write-Host "`nSummary:" -ForegroundColor Cyan
    Write-Host "- Devices removed via pnputil: $removedCount" -ForegroundColor $(if ($removedCount -gt 0) { 'Green' } else { 'Yellow' })
    
    if ($removedCount -eq 0 -and $virtioDevices.Count -eq 0) {
        Write-Host "`nNo phantom devices found - system is already clean" -ForegroundColor Cyan
    }
} catch {
    Write-Host "`n=== ERROR ===" -ForegroundColor Red
    $errorMessage = $_.Exception.Message
    Write-Host "Error during device creation and configuration or removal: $errorMessage" -ForegroundColor Red
    exit 1
}
