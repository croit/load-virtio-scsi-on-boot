Purpose of this script
* make Windows load the VirtIO SCSI and/or Block driver on boot without reboot or external programs

Prerequisites
* VirtIO SCSI driver (vioscsi) must be installed OR path to the INF file must be given as argument
* VirtIO Block driver (viostor) must be installed OR path to the INF file must be given as argument
* Windows 7/8 or Windows Server 2008

Remarks
* On Windows before Windows Server 2022 and Windows 10 2004 the software device created by the script will not be removed automatically, but this can be done via device manager. It can also be left there, no harm in that.
* You should have a backup of your system.
* This script was tested only
  * on Windows Server 2025 Standard Edition (24H2)
  * on Windows Server 2022 Datacenter Edition (21H2)
  * with virtio drivers version .266 .271 .285 
  * on Windows Server 2016 Standard Edition
  * with virtio drivers version .271
* nearly all code in here was written by AI

How to use
either 
* install the vioscsi.inf/viostor.inf before *OR*
* tell the script to do it by `-ScsiInfPath` and/or `-BlockInfPath` parameter OR
* use `virtio-win-guest-tools.exe /S` to install it

depending on the set security policy it might be required to run the script via
`PowerShell /ExecutionPolicy Bypass /File <path-to-this-script-file> [-Driver <scsi|block|both>] [-ScsiInfPath <path>] [-BlockInfPath <path>]`

Driver options:
- `scsi`  (default) - Install VirtIO SCSI driver only
- `block`           - Install VirtIO Block driver only
- `both`            - Install both drivers

How does the script work?
* install the driver(s), if requested
* create a software based device via Win32-API
* add some registry settings
* use pnputil to install the driver for this device
* use pnputil to remove the device
The driver-to-device assignment marks the driver for being loaded on boot.
Now the Windows is ready for migration to a VirtIO based SCSI or Block disk.

The ISO-File contains the content of this repo only.
