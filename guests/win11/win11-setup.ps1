# First-logon setup for win11, run once by autounattend.xml's
# FirstLogonCommands from the drivers cdrom. Log: C:\win11-setup.log
#
# Idempotent: safe to run again by hand from that cdrom if a step failed.
Start-Transcript -Path C:\win11-setup.log -Append

$drive = Split-Path -Qualifier $PSCommandPath

# 1. Every virtio driver (the NIC included — setup only had it in windowsPE)
#    plus the qemu guest agent, which is what `virsh shutdown --mode agent`
#    and `virsh qemu-agent-command` talk to.
Start-Process -Wait -FilePath "$drive\virtio-win-guest-tools.exe" `
  -ArgumentList '/install', '/quiet', '/norestart'

# 2. Local admin by SID: the answer file names the group, and the name is
#    localized ("Administrateurs" on fr-CA).
$admins = (Get-LocalGroup -SID 'S-1-5-32-544').Name
if (-not (Get-LocalGroupMember -Group $admins -Member ludo -ErrorAction SilentlyContinue)) {
  Add-LocalGroupMember -Group $admins -Member ludo
}

# 3. Static IPv4 on VLAN10, IPv6 unbound. VLAN10 has no DHCP, and gaming-01's
#    macvtap reflects the guest's own NDP/DAD back at it — the reason the
#    arcade guests are IPv4-only too. Wait for the NIC the drivers just added.
for ($i = 0; $i -lt 60; $i++) {
  $nic = Get-NetAdapter -Physical | Where-Object { $_.MacAddress -eq '52-54-00-00-43-01' }
  if ($nic) { break }
  Start-Sleep -Seconds 2
}
if ($nic) {
  Disable-NetAdapterBinding -Name $nic.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
  Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Disabled
  Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
  Get-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
  New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress 192.0.2.143 -PrefixLength 23 -DefaultGateway 192.0.2.254
  Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses 192.0.2.254
  Set-DnsClient -InterfaceIndex $nic.ifIndex -ConnectionSpecificSuffix lab.example
  # Private profile, so the RDP rule below (Private/Domain) applies.
  Set-NetConnectionProfile -InterfaceIndex $nic.ifIndex -NetworkCategory Private -ErrorAction SilentlyContinue
} else {
  Write-Warning 'virtio NIC 02:00:00:00:00:01 never appeared; network NOT configured'
}

# 4. Remote Desktop on. It will not accept `ludo` until that account has a
#    password — see the note in autounattend.xml.
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'

# 5. Answer ping from the LAN, so the fleet can tell it is up.
Enable-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In' -ErrorAction SilentlyContinue

# 6. The RTC is UTC (see libvirt-domain.xml): tell Windows, which otherwise
#    reads it as local time and runs four hours ahead in summer. And no Fast
#    Startup: it turns shutdown into a half-hibernation, which is not the
#    state to hand arcade1's card back in.
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation -Name RealTimeIsUniversal -Type DWord -Value 1
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Type DWord -Value 0

# 7. Never sleep: a VM that suspends looks off to libvirt's callers.
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /hibernate off

Stop-Transcript
