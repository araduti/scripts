# Install Hyper-V
Install-WindowsFeature -Name Hyper-V -IncludeManagementTools

# Create Storage Spaces for VM storage
$physicalDisks = Get-PhysicalDisk -CanPool $true
New-StoragePool -FriendlyName "VMStorage" -StorageSubsystemFriendlyName "Windows Storage*" -PhysicalDisks $physicalDisks
New-VirtualDisk -StoragePoolFriendlyName "VMStorage" -FriendlyName "VMStorageDisk" -ResiliencySettingName Simple -UseMaximumSize
Initialize-Disk -VirtualDisk (Get-VirtualDisk -FriendlyName "VMStorageDisk") -PartitionStyle GPT
New-Volume -DiskNumber (Get-Disk -FriendlyName "VMStorageDisk").Number -FileSystem NTFS -DriveLetter V -FriendlyName "VM Storage"

# Configure Hyper-V networking
New-VMSwitch -SwitchName "NATSwitch" -SwitchType Internal
New-NetIPAddress -IPAddress 172.21.21.1 -PrefixLength 24 -InterfaceAlias "vEthernet (NATSwitch)"
New-NetNat -Name "MyNATnetwork" -InternalIPInterfaceAddressPrefix 172.21.21.0/24

# Configure VM paths
Set-VMHost -VirtualHardDiskPath "V:\VMs" -VirtualMachinePath "V:\VMs"

# Create NAT forwarding rule for nested VM RDP
Add-NetNatStaticMapping -NatName "MyNATnetwork" -Protocol TCP -ExternalIPAddress 0.0.0.0 -InternalIPAddress 172.21.21.2 -InternalPort 3389 -ExternalPort 3390

# Download Windows Server ISO
$isoUrl = "https://go.microsoft.com/fwlink/p/?LinkID=2195167&clcid=0x409&culture=en-us&country=US"
$isoPath = "V:\WS2022.iso"
Invoke-WebRequest -Uri $isoUrl -OutFile $isoPath

# Create new VM
New-VM -Name "NestedVM" -MemoryStartupBytes 4GB -NewVHDPath "V:\VMs\NestedVM.vhdx" -NewVHDSizeBytes 127GB -Generation 2 -SwitchName "NATSwitch"
Set-VMProcessor -VMName "NestedVM" -Count 2 -ExposeVirtualizationExtensions $true
Add-VMDvdDrive -VMName "NestedVM" -Path $isoPath
Set-VMFirmware -VMName "NestedVM" -FirstBootDevice (Get-VMDvdDrive -VMName "NestedVM")

# Start the VM
Start-VM -Name "NestedVM"

# Create startup script for auto-launching Hyper-V
$startupScript = @'
# Wait for Hyper-V service to be ready
while (-not (Get-Service vmms -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 2 }

# Launch Hyper-V Manager and connect to VM
$hvManager = Start-Process -FilePath "virtmgmt.msc" -PassThru
Start-Sleep -Seconds 5

# Connect to VM in full screen
$vmconnect = Start-Process -FilePath "vmconnect.exe" -ArgumentList "localhost NestedVM /fullscreen" -PassThru
'@

$startupScriptPath = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\LaunchHyperV.ps1"
$startupScript | Out-File -FilePath $startupScriptPath -Encoding UTF8

# Create scheduled task to run at logon
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$startupScriptPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId (Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object -ExpandProperty UserName) -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName "LaunchHyperVManager" -Action $action -Trigger $trigger -Principal $principal

# Configure auto-logon for the current user
$RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $RegPath -Name "AutoAdminLogon" -Value "1"
Set-ItemProperty -Path $RegPath -Name "DefaultUsername" -Value $env:USERNAME
Set-ItemProperty -Path $RegPath -Name "DefaultPassword" -Value $env:PASSWORD  # Note: This should be set securely

# Restart the computer to apply changes
Restart-Computer -Force
