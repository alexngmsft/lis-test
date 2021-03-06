#####################################################################
#
# Linux on Hyper-V and Azure Test Code, ver. 1.0.0
# Copyright (c) Microsoft Corporation
#
# All rights reserved.
# Licensed under the Apache License, Version 2.0 (the ""License"");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
#
# THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
# OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
# ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR
# PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.
#
# See the Apache Version 2.0 License for specific language governing
# permissions and limitations under the License.
#
#####################################################################

<#
.Synopsis
 Run the VLAN Trunking test.

 Description:
    Use two VMs to test the VLAN trunking feature.

    The first VM is started by the LIS framework, while the second one will be managed by this script.

    The script expects a NIC param in the same format as the NET_{ADD|REMOVE|SWITCH}_NIC_MAC.ps1 scripts. It checks both VMs
    for a NIC connected to the specified network. If the first VM's NIC is not found, test will fail. In case the second VM is missing
    this NIC, it will call the NET_ADD_NIC_MAC.ps1 script directly and add it. If the NIC was added by this script, it will also clean-up
    after itself, unless the LEAVE_TRAIL param is set to `YES'.

    After both VMs are up, this script will configure each NIC inside the VM to use VLANs with the VM_VLAN_ID parameter. Then
    it will configure the NetAdapters to trunk mode and try to ping the other VM.

    If the above ping succeeded, the second VM will change its vlan ID and try to ping the first VM again. This must fail.

    The following testParams are mandatory:

        NIC=NIC type, Network Type, Network Name, MAC Address

            NIC Type can be one of the following:
                NetworkAdapter
                LegacyNetworkAdapter

            Network Type can be one of the following:
                External
                Internal
                Private

            Network Name is the name of a existing network.

            Only the Network Name parameter is used by this script, but the others are still necessary, in order to have the same
            parameters as the NET_ADD_NIC_MAC script.

            The following is an example of a testParam for removing a NIC

                "NIC=NetworkAdapter,Internal,InternalNet,001600112200"

        VM_VLAN_ID=vlan_id
            vlan_id is a positive integer < 4096.

        NATIVE_VLAN_ID=native_id
            native_id is a positive integer < 4096.

        VM2NAME=name_of_second_VM
            this is the name of the second VM. It will not be managed by the LIS framework, but by this script.

    The following testParams are optional:

        STATIC_IP=xx.xx.xx.xx
            xx.xx.xx.xx is a valid IPv4 Address. If not specified, a default value of 10.10.10.1 will be used.
            This will be assigned to VM1's test NIC.

		STATIC_IP2=xx.xx.xx.xx
			xx.xx.xx.xx is a valid IPv4 Address. If not specified, an IP Address from the same subnet as VM1's STATIC_IP
			will be computed (usually the first address != STATIC_IP in the subnet).

        NETMASK=yy.yy.yy.yy
            yy.yy.yy.yy is a valid netmask (the subnet to which the tested netAdapters belong). If not specified, a default value of 255.255.255.0 will be used.

        LEAVE_TRAIL=yes/no
            if set to yes and the NET_ADD_NIC_MAC.ps1 script was called from within this script for VM2, then it will not be removed
            at the end of the script. Also temporary bash scripts generated during the test will not be deleted.

    All test scripts must return a boolean ($true or $false)
    to indicate if the script completed successfully or not.

   .Parameter vmName
    Name of the first VM implicated in vlan trunking test .

    .Parameter hvServer
    Name of the Hyper-V server hosting the VM.

    .Parameter testParams
    Test data for this test case

    .Example
    NET_VLAN_TRUNKING -vmName sles11sp3x64 -hvServer localhost -testParams "NIC=NetworkAdapter,Private,Private,001600112200;VM_VLAN_ID=2;NATIVE_VLAN_ID=10;VM2NAME=second_sles11sp3x64;"
#>

param([string] $vmName, [string] $hvServer, [string] $testParams)

Set-PSDebug -Strict

# function which creates an /etc/sysconfig/network-scripts/ifcfg-ethX.ID file for interface ethX with vlan ID
function CreateVlanInterfaceConfig([String]$conIpv4,[String]$sshKey,[String]$MacAddr,[String]$staticIP,[String]$netmask,[String]$vlanID)
{

	# Add delimiter if needed
	if (-not $MacAddr.Contains(":"))
	{
		for ($i=2; $i -lt 16; $i=$i+2)
		{
			$MacAddr = $MacAddr.Insert($i,':')
			$i++
		}
	}

	# create command to be sent to VM. This determines the interface based on the MAC Address and calls CreateVlanConfig (from utils.sh) to create a new vlan interface

	$cmdToVM = @"
#!/bin/bash
		cd /root
		if [ -f utils.sh ]; then
			sed -i 's/\r//' utils.sh
			. utils.sh
		else
			exit 1
		fi

		# make sure we have synthetic network adapters present
		GetSynthNetInterfaces
		if [ 0 -ne `$? ]; then
			exit 2
		fi

		# get the interface with the given MAC address
		__sys_interface=`$(grep -il ${MacAddr} /sys/class/net/*/address)
		if [ 0 -ne `$? ]; then
			exit 3
		fi
		__sys_interface=`$(basename "`$(dirname "`$__sys_interface")")
		if [ -z "`$__sys_interface" ]; then
			exit 4
		fi

		LogMsg "CreateVlanConfig: interface `$__sys_interface" >> /root/NET_VLAN_TRUNKING.log 2>&1
		CreateVlanConfig `$__sys_interface $staticIP $netmask $vlanID >> /root/NET_VLAN_TRUNKING.log 2>&1
		__retVal=`$?
		LogMsg "CreateVlanConfig: returned `$__retVal" >> /root/NET_VLAN_TRUNKING.log 2>&1
		exit `$__retVal
"@

	$filename = "CreateVlanConfig.sh"

	# check for file
	if (Test-Path ".\${filename}")
	{
		Remove-Item ".\${filename}"
	}

	Add-Content $filename "$cmdToVM"

	# send file
	$retVal = SendFileToVM $conIpv4 $sshKey $filename "/root/${$filename}"

	# delete file unless the Leave_trail param was set to yes.
	if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
	{
		Remove-Item ".\${filename}"
	}

	# check the return Value of SendFileToVM
	if (-not $retVal)
	{
		return $false
	}

	# execute sent file
	$retVal = SendCommandToVM $conIpv4 $sshKey "cd /root && chmod u+x ${filename} && sed -i 's/\r//g' ${filename} && ./${filename}"

	return $retVal
}

# function which removes an /etc/sysconfig/network-scripts/ifcfg-ethX.ID file for interface ethX with vlan ID
function RemoveVlanInterfaceConfig([String]$conIpv4,[String]$sshKey,[String]$MacAddr,[String]$vlanID)
{

	# Add delimiter if needed
	if (-not $MacAddr.Contains(":"))
	{
		for ($i=2; $i -lt 16; $i=$i+2)
		{
			$MacAddr = $MacAddr.Insert($i,':')
			$i++
		}
	}

	# create command to be sent to VM. This determines the interface based on the MAC Address and calls RemoveVlanConfig (from utils.sh) to remove a previously created vlan interface
	$cmdToVM = @"
#!/bin/bash
		cd /root
		if [ -f utils.sh ]; then
			sed -i 's/\r//' utils.sh
			. utils.sh
		else
			exit 1
		fi

		# make sure we have synthetic network adapters present
		GetSynthNetInterfaces
		if [ 0 -ne `$? ]; then
			exit 2
		fi

		# get the interface with the given MAC address
		__sys_interface=`$(grep -il ${MacAddr} /sys/class/net/*/address)
		if [ -z "`$__sys_interface" ]; then
			exit 3
		fi
		__sys_interface=`$(basename "`$(dirname "`$__sys_interface")")
		if [ -z "`$__sys_interface" ]; then
			exit 4
		fi

		LogMsg "RemoveVlanConfig: interface `$__sys_interface" >> /root/NET_VLAN_TRUNKING.log 2>&1
		RemoveVlanConfig `$__sys_interface $vlanID >> /root/NET_VLAN_TRUNKING.log 2>&1
		__retVal=`$?
		LogMsg "RemoveVlanConfig: returned `$__retVal" >> /root/NET_VLAN_TRUNKING.log 2>&1
		exit `$__retVal
"@

	#"Sending command to vm: $cmdToVM"
	$filename = "RemoveVlanConfig.sh"

	# check for file
	if (Test-Path ".\${filename}")
	{
		Remove-Item ".\${filename}"
	}

	Add-Content $filename "$cmdToVM"

	# send file
	$retVal = SendFileToVM $conIpv4 $sshKey $filename "/root/${$filename}"

	# delete file unless the Leave_trail param was set to yes.
	if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
	{
		Remove-Item ".\${filename}"
	}

	# check the return Value of SendFileToVM
	if (-not $retVal)
	{
		return $false
	}

	# execute sent file
	$retVal = SendCommandToVM $conIpv4 $sshKey "cd /root && chmod u+x ${filename} && sed -i 's/\r//g' ${filename} && ./${filename}"

	return $retVal

}

# function which retrieves the interface with MacAddress $macAddr and vlanID $vlanID and then pings $pingTargetIPv4
function pingVMs([String]$conIpv4,[String]$pingTargetIpv4,[String]$sshKey,[int]$noPackets,[String]$macAddr,[String]$vlanID)
{

	# check the number of Packets to be sent to the VM
	if ($noPackets -lt 0)
	{
		return $false
	}

	# Add delimiter if needed
	if (-not $MacAddr.Contains(":"))
	{
		for ($i=2; $i -lt 16; $i=$i+2)
		{
			$MacAddr = $MacAddr.Insert($i,':')
			$i++
		}
	}

	$cmdToVM = @"
#!/bin/bash

                cd /root
                if [ -f utils.sh ]; then
                    sed -i 's/\r//' utils.sh
                    . utils.sh
                else
                    exit 1
                fi

				# get interface(s) with $vlanID from /proc
				__vlan_interface=`$(cat /proc/net/vlan/config | grep " $vlanID " | cut -d "|" -f 1 | sed 's/ *$//')
				if [ -z "`$__vlan_interface" ]; then
					exit 1
				fi

				# get interface with given MAC and select the one found above
				__sys_interface=`$(grep -il ${MacAddr} /sys/class/net/*/address | grep "/`$__vlan_interface/")
				if [ -z "`$__sys_interface" ]; then
					exit 2
				fi

				__sys_interface=`$(basename "`$(dirname "`$__sys_interface")")
				if [ -z "`$__sys_interface" ]; then
					exit 3
				fi

                CheckIPV6 $pingTargetIpv4
                if [[ `$? -eq 0 ]]; then
                    pingVersion="ping6"
                else
                    pingVersion="ping"
                fi

				LogMsg "PingVMs: pinging $pingTargetIpv4 using interface `$__sys_interface" >> /root/NET_VLAN_TRUNKING.log 2>&1
				# ping the remote host using an easily distinguishable pattern 0xcafed00d`null`vlan`null`trunk`null`
				`$pingVersion -I `$__sys_interface -c $noPackets -p "cafed00d00766c616e007472756e6b00" $pingTargetIpv4 >> /root/NET_VLAN_TRUNKING.log 2>&1
				__retVal=`$?

				LogMsg "PingVMs: ping returned `$__retVal" >> /root/NET_VLAN_TRUNKING.log 2>&1
				exit `$__retVal
"@

	#"pingVMs: sendig command to vm: $cmdToVM"
	$filename = "PingVMs.sh"

	# check for file
	if (Test-Path ".\${filename}")
	{
		Remove-Item ".\${filename}"
	}

	Add-Content $filename "$cmdToVM"

	# send file
	$retVal = SendFileToVM $conIpv4 $sshKey $filename "/root/${$filename}"

	# delete file unless the Leave_trail param was set to yes.
	if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
	{
		Remove-Item ".\${filename}"
	}

	# check the return Value of SendFileToVM
	if (-not $retVal)
	{
		return $false
	}

	# execute command
	$retVal = SendCommandToVM $conIpv4 $sshKey "cd /root && chmod u+x ${filename} && sed -i 's/\r//g' ${filename} && ./${filename}"

	return $retVal
}

#######################################################################
#
# Main script body
#
#######################################################################

#StopVMViaSSH $vmName $hvServer $sshKey 300

#
# Check input arguments
#
if ($vmName -eq $null)
{
    "Error: VM name is null"
    return $False
}

if ($hvServer -eq $null)
{
    "Error: hvServer is null"
    return $False
}

if ($testParams -eq $null)
{
    "Error: testParams is null"
    return $False
}

# Write out test Params
$testParams

# sshKey used to authenticate ssh connection and send commands
$sshKey = $null

# IP Address of first VM
$ipv4 = $null

# IP Address of second VM
$ipv4VM2 = $null

# Name of second VM
$vm2Name = $null

# name of the switch to which to connect
$netAdapterName = $null

# vlan id set on packets originating from VM NIC
$vlanId = $null

# wrong vlan id used to make sure VMs in different VLANs cannot talk to each other
$badVlanId = $null

# native VLAN id
$nativeVlanId = $null

# VM1 IPv4 Address
$vm1StaticIP = $null

# VM2 IPv4 Address
$vm2StaticIP = $null

# Netmask used by both VMs
$netmask = $null

# boolean to leave a trail
$leaveTrail = $null

# switch name
$networkName = $null

#Snapshot name
$snapshotParam = $null

# change working directory to root dir
$testParams -match "RootDir=([^;]+)"
if (-not $?)
{
	"Mandatory param RootDir=Path; not found!"
	return $false
}
$rootDir = $Matches[1]

if (Test-Path $rootDir)
{
	Set-Location -Path $rootDir
	if (-not $?)
	{
		"Could not change directory to $rootDir !"
		return $false
	}
	"Changed working directory to $rootDir"
}
else
{
	"RootDir = $rootDir is not a valid path"
	return $false
}

# Source TCUitls.ps1 for getipv4 and other functions
if (Test-Path ".\setupScripts\TCUtils.ps1")
{
	. .\setupScripts\TCUtils.ps1
}
else
{
	"Error: Could not find setupScripts\TCUtils.ps1"
	return $false
}

# Source NET_UTILS.ps1 for network functions
if (Test-Path ".\setupScripts\NET_UTILS.ps1")
{
    . .\setupScripts\NET_UTILS.ps1
}
else
{
    "Error: Could not find setupScripts\NET_Utils.ps1"
    return $false
}

$params = $testParams.Split(";")
foreach ($p in $params)
{
    $fields = $p.Split("=")

    switch ($fields[0].Trim())
    {
    "VM2NAME" { $vm2Name = $fields[1].Trim() }
    "SshKey"  { $sshKey  = $fields[1].Trim() }
    "ipv4"    { $ipv4    = $fields[1].Trim() }
    "VM_VLAN_ID" { $vlanId = $fields[1].Trim() }
    "NATIVE_VLAN_ID" { $nativeVlanId = $fields[1].Trim() }
    "STATIC_IP" { $vm1StaticIP = $fields[1].Trim() }
	"STATIC_IP2" { $vm2StaticIP = $fields[1].Trim() }
    "NETMASK" { $netmask = $fields[1].Trim() }
    "LEAVE_TRAIL" { $leaveTrail = $fields[1].Trim() }
    "SnapshotName" { $SnapshotName = $fields[1].Trim() }
    "NIC"
    {
        $nicArgs = $fields[1].Split(',')
        if ($nicArgs.Length -lt 4)
        {
            "Error: Incorrect number of arguments for NIC test parameter: $p"
            return $false

        }


        $nicType = $nicArgs[0].Trim()
        $networkType = $nicArgs[1].Trim()
        $networkName = $nicArgs[2].Trim()
        $vm1MacAddress = $nicArgs[3].Trim()
        $legacy = $false

		#
        # Validate the network adapter type
        #
        if ("NetworkAdapter" -notcontains $nicType)
        {
            "Error: Invalid NIC type: $nicType . Must be 'NetworkAdapter'"
            return $false
        }

		#
        # Validate the Network type
        #
        if (@("External", "Internal", "Private") -notcontains $networkType)
        {
            "Error: Invalid netowrk type: $networkType .  Network type must be either: External, Internal, Private"
            return $false
        }

        #
        #
        # Make sure the network exists
        #
        $vmSwitch = Get-VMSwitch -Name $networkName -ComputerName $hvServer
        if (-not $vmSwitch)
        {
            "Error: Invalid network name: $networkName . The network does not exist."
            return $false
        }

		$retVal = isValidMAC $vm1MacAddress

        if (-not $retVal)
        {
            "Invalid Mac Address $vm1MacAddress"
            return $false
        }


        #
        # Get Nic with given MAC Address
        #
        $vm1nic = Get-VMNetworkAdapter -VMName $vmName -ComputerName $hvServer -IsLegacy:$false | where {$_.MacAddress -eq $vm1MacAddress }
        if ($vm1nic)
        {
            "$vmName found NIC with MAC $vm1MacAddress ."
        }
        else
        {
            "Error: $vmName - No NIC found with MAC $vm1MacAddress ."
			return $false
        }
    }
    default   {}  # unknown param - just ignore it
    }
}

if (-not $vm2Name)
{
    "Error: test parameter vm2Name was not specified"
    return $False
}

# make sure vm2 is not the same as vm1
if ("$vm2Name" -like "$vmName")
{
	"Error: vm2 must be different from the test VM."
	return $false
}

if (-not $sshKey)
{
    "Error: test parameter sshKey was not specified"
    return $False
}

if (-not $ipv4)
{
    "Error: test parameter ipv4 was not specified"
    return $False
}

#set the parameter for the snapshot
$snapshotParam = "SnapshotName = ${SnapshotName}"

#revert VM2
.\setupScripts\RevertSnapshot.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $snapshotParam

#
# Verify the VMs exists
#
$vm1 = Get-VM -Name $vmName -ComputerName $hvServer -ErrorAction SilentlyContinue
if (-not $vm1)
{
    "Error: VM ${vmName} does not exist"
    return $False
}

$vm2 = Get-VM -Name $vm2Name -ComputerName $hvServer -ErrorAction SilentlyContinue
if (-not $vm2)
{
    "Error: VM ${vm2Name} does not exist"
    return $False
}

# hold testParam data for NET_ADD_NIC_MAC script
$vm2testParam = $null
$vm2MacAddress = $null

# remember if we added the NIC or it was already there.
$scriptAddedNIC = $false

# Check for a NIC of the given network type on VM2
$vm2nic = $null
$nic2 = Get-VMNetworkAdapter -VMName $vm2Name -ComputerName $hvServer -IsLegacy:$false | where { $_.SwitchName -like "$networkName" }


if ($nic2)
{
	# check if we received more than one
	if ($nic2 -is [system.array])
	{
		 "Warn Multiple NICs found in $vm2Name connected to $networkName . Will use the first one."
		$vm2nic = $nic2[0]
	}
	else
	{
		$vm2nic = $nic2
	}

	$vm2MacAddress = $vm2nic | select -ExpandProperty MacAddress

    $retVal = isValidMAC $vm2MacAddress
    if (-not $retVal)
    {
        "$vm2name : invalid mac $vm2MacAddress"
    }

	# make sure $vm2nic is in untagged mode to begin with
	Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm2Nic -Untagged

}
else
{
	# we need to add it here
    # try a few times
    for ($i = 0; $i -lt 3; $i++)
    {
        $vm2MacAddress = getRandUnusedMAC $hvServer
        if ($vm2MacAddress)
        {
            break
        }
    }
    $retVal = isValidMAC $vm2MacAddress
    if (-not $retVal)
    {
        "Could not find a valid MAC for $vm2Name. Received $vm2MacAddress"
        return $false
    }

	#construct NET_ADD_NIC_MAC Parameter
	$vm2testParam = "NIC=NetworkAdapter,$networkType,$networkName,$vm2MacAddress"

	if ( Test-Path ".\setupScripts\NET_ADD_NIC_MAC.ps1")
	{
		# Make sure VM2 is shutdown
		if (Get-VM -Name $vm2Name -ComputerName $hvServer |  Where { $_.State -like "Running" })
		{
			Stop-VM $vm2Name -force

			if (-not $?)
			{
				"Error: Unable to shut $vm2Name down (in order to add a new network Adapter)"
				return $false
			}

			# wait for VM to finish shutting down
			$timeout = 60
			while (Get-VM -Name $vm2Name -ComputerName $hvServer |  Where { $_.State -notlike "Off" })
			{
				if ($timeout -le 0)
				{
					"Error: Unable to shutdown $vm2Name"
					return $false
				}

				start-sleep -s 5
				$timeout = $timeout - 5
			}

		}

		.\setupScripts\NET_ADD_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
	}
	else
	{
		"Error: Could not find setupScripts\NET_ADD_NIC_MAC.ps1 ."
		return $false
	}

	if (-Not $?)
	{
		"Error Cannot add new NIC to $vm2Name"
		return $false
	}

	# get the newly added NIC
	$vm2nic = Get-VMNetworkAdapter -VMName $vm2Name -ComputerName $hvServer -IsLegacy:$false | where { $_.MacAddress -like "$vm2MacAddress" }

	if (-not $vm2nic)
	{
		"Could not retrieve the newly added NIC to VM2"
		return $false
	}

	$scriptAddedNIC = $true
}

"Tests VLAN trunking"

#
# Verify the VMs exists
#
$vm1 = Get-VM -Name $vmName -ComputerName $hvServer -ErrorAction SilentlyContinue
if (-not $vm1)
{
    "Error: VM ${vmName} does not exist"

    # if this script added the second NIC, then remove it unless the Leave_trail param was set.
    if ($scriptAddedNIC)
    {
        if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
        {
            if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
            {
                .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
            }
            else
            {
                "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
            }
        }
    }
    return $False
}

$vm2 = Get-VM -Name $vm2Name -ComputerName $hvServer -ErrorAction SilentlyContinue
if (-not $vm2)
{
    "Error: VM ${vm2Name} does not exist"
    return $False
}


if (-not $netmask)
{
    $netmask = "255.255.255.0"
}

if (-not $vm1StaticIP)
{
	$vm1StaticIP = getAddress "10.10.10.10" $netmask 1
}


# compute another ipv4 address for vm2
if (-not $vm2StaticIP)
{
    [int]$nth = 2
    do
    {
        $vm2StaticIP = getAddress $vm1StaticIP $netmask $nth
        $nth += 1
    } while ($vm2StaticIP -like $vm1StaticIP)


}
else
{
    $ipVersion = isValidIP $vm2StaticIP

    switch ($ipVersion)
    {
        InterNetwork {
            # make sure $vm2StaticIP is in the same subnet as $vm1StaticIP
            $retVal = containsAddress $vm1StaticIP $netmask $vm2StaticIP

            if (-not $retVal)
            {
                "$vm2StaticIP is not in the same subnet as $vm1StaticIP / $netmask"

                # if this script added the second NIC, then remove it unless the Leave_trail param was set.
                if ($scriptAddedNIC)
                {
                    if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
                    {
                        if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
                        {
                            .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
                        }
                        else
                        {
                            "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
                        }
                    }
                }

                return $false
            }
            break
        }
        InterNetworkV6 {
            break
        }
        $false {
            "$vm2StaticIP is not a valid ip address"
            # if this script added the second NIC, then remove it unless the Leave_trail param was set.
            if ($scriptAddedNIC)
            {
                if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
                {
                    if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
                    {
                        .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
                    }
                    else
                    {
                        "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
                    }
                }
            }
            return $false
        }
    }
}

"sshKey   = ${sshKey}"
"vm1 Name = ${vmName}"
"vm1 ipv4 = ${ipv4}"
"vm1 MAC = ${vm1MacAddress}"
"vm1 static IP = ${vm1StaticIP}"


#
# LIS Started VM1, so start VM2
#

if (Get-VM -Name $vm2Name -ComputerName $hvServer |  Where { $_.State -notlike "Running" })
{
	Start-VM -Name $vm2Name -ComputerName $hvServer
	if (-not $?)
	{
		"Error: Unable to start VM ${vm2Name}"
		$error[0].Exception

        # if this script added the second NIC, then remove it unless the Leave_trail param was set.
        if ($scriptAddedNIC)
        {
            if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
            {
                if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
                {
                    .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
                }
                else
                {
                    "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
                }
            }
        }
		return $False
	}
}


$timeout = 200 # seconds
if (-not (WaitForVMToStartKVP $vm2Name $hvServer $timeout))
{
    "Warning: $vm2Name never started KVP"
}

# get vm2 ipv4

$vm2ipv4 = GetIPv4 $vm2Name $hvServer

"vm2 Name = ${vm2Name}"
"vm2 ipv4 = ${vm2ipv4}"
"vm2 MAC = ${vm2MacAddress}"
"vm2 static IP = ${vm2StaticIP}"

"netmask = $netmask"
"Test vlan id = ${vlanID}"
"nativ vlan id = ${nativeVlanId}"

# wait for ssh to startg
$timeout = 120 #seconds
if (-not (WaitForVMToStartSSH $vm2ipv4 $timeout))
{
    "Error: VM ${vm2Name} never started"

    Stop-VM -VMName $vm2name -ComputerName $hvServer -force

    # if this script added the second NIC, then remove it unless the Leave_trail param was set.
    if ($scriptAddedNIC)
    {
        if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
        {
            if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
            {
                .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
            }
            else
            {
                "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
            }
        }
    }

    return $False
}

# send utils.sh to VM2
if (-not (Test-Path ".\remote-scripts\ica\utils.sh"))
{
	"Error: Unable to find remote-scripts\ica\utils.sh "

    Stop-VM -VMName $vm2name -ComputerName $hvServer -force

    # if this script added the second NIC, then remove it unless the Leave_trail param was set.
    if ($scriptAddedNIC)
    {
        if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
        {
            if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
            {
                .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
            }
            else
            {
                "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
            }
        }
    }

	return $false
}

"Sending .\remote-scripts\ica\utils.sh to $vm2ipv4 , authenticating with $sshKey"
$retVal = SendFileToVM "$vm2ipv4" "$sshKey" ".\remote-scripts\ica\utils.sh" "/root/utils.sh"

if (-not $retVal)
{
	"Failed sending file to VM!"

    Stop-VM -VMName $vm2name -ComputerName $hvServer -force

    # if this script added the second NIC, then remove it unless the Leave_trail param was set.
    if ($scriptAddedNIC)
    {
        if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
        {
            if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
            {
                .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
            }
            else
            {
                "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
            }
        }
    }
	return $False
}

# send vlan ifcfg file to each VM
$retVal = CreateVlanInterfaceConfig $ipv4 $sshKey $vm1MacAddress $vm1StaticIP $netmask $vlanID
if (-not $retVal)
{
	"Failed to create Vlan Interface on vm $ipv4 for interface with mac $vm1MacAddress , by setting a static IP of $vm1StaticIP netmask $netmask and vlan ID $vlanID"

Stop-VM -VMName $vm2name -ComputerName $hvServer -force

    # if this script added the second NIC, then remove it unless the Leave_trail param was set.
    if ($scriptAddedNIC)
    {
        if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
        {
            if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
            {
                .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
            }
            else
            {
                "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
            }
        }
    }

	return $false
}

$retVal = CreateVlanInterfaceConfig $vm2ipv4 $sshKey $vm2MacAddress $vm2StaticIP $netmask $vlanID
if (-not $retVal)
{
	"Failed to create Vlan Interface on vm $vm2ipv4 for interface with mac $vm2MacAddress , by setting a static IP of $vm2StaticIP netmask $netmask and vlan ID $vlanID"

    RemoveVlanInterfaceConfig $vm2ipv4 $sshKey $vm2MacAddress $vlanID

    Stop-VM -VMName $vm2name -ComputerName $hvServer -force

    # if this script added the second NIC, then remove it unless the Leave_trail param was set.
    if ($scriptAddedNIC)
    {
        if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
        {
            if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
            {
                .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
            }
            else
            {
                "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
            }
        }
    }
	return $false
}

Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm1Nic -Trunk -AllowedVlanIdList $vlanID -NativeVlanId $nativeVlanId
if (-not $?)
{
	"Failed to set $vm1Nic to Trunk Mode with an AllowedVlanIdList of $vlanID and a native VlanID $nativeVlanId"

    RemoveVlanInterfaceConfig $vm2ipv4 $sshKey $vm2MacAddress $vlanID

    Stop-VM -VMName $vm2name -ComputerName $hvServer -force

    # if this script added the second NIC, then remove it unless the Leave_trail param was set.
    if ($scriptAddedNIC)
    {
        if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
        {
            if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
            {
                .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
            }
            else
            {
                "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
            }
        }
    }

	return $false
}

Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm2NIC -Trunk -AllowedVlanIdList $vlanID -NativeVlanId $nativeVlanId
if (-not $?)
{
	"Failed to set $vm2Nic to Trunk Mode with an AllowedVlanIdList of $vlanID and a native VlanID $nativeVlanId"

    Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm1Nic -Untagged

    RemoveVlanInterfaceConfig $vm2ipv4 $sshKey $vm2MacAddress $vlanID

    Stop-VM -VMName $vm2name -ComputerName $hvServer -force

    # if this script added the second NIC, then remove it unless the Leave_trail param was set.
    if ($scriptAddedNIC)
    {
        if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
        {
            if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
            {
                .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
            }
            else
            {
                "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
            }
        }
    }

	return $false
}

"Trying to ping from vm1 with mac $vm1MacAddress to $vm2StaticIP "
# try to ping
$retVal = pingVMs $ipv4 $vm2StaticIP $sshKey 10 $vm1MacAddress $vlanID

"main script: retval should be false. Its value is [ $retVal ]"
if (-not $retVal)
{
	"Unable to ping $vm2StaticIP from $vm1StaticIP with MAC $vm1MacAddress"

    Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm1Nic -Untagged
    Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm2Nic -Untagged

    RemoveVlanInterfaceConfig $vm2ipv4 $sshKey $vm2MacAddress $vlanID

    Stop-VM -VMName $vm2name -ComputerName $hvServer -force

    # if this script added the second NIC, then remove it unless the Leave_trail param was set.
    if ($scriptAddedNIC)
    {
        if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
        {
            if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
            {
                .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
            }
            else
            {
                "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
            }
        }
    }

	return $false
}

"Trying to ping from vm2 with mac $vm2MacAddress to $vm1StaticIP "
$retVal = pingVMs $vm2ipv4 $vm1StaticIP $sshKey 10 $vm2MacAddress $vlanID

if (-not $retVal)
{
	"Unable to ping $vm1StaticIP from $vm2StaticIP with MAC $vm2MacAddress"

    Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm1Nic -Untagged
    Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm2Nic -Untagged

    RemoveVlanInterfaceConfig $vm2ipv4 $sshKey $vm2MacAddress $vlanID

    Stop-VM -VMName $vm2name -ComputerName $hvServer -force

    # if this script added the second NIC, then remove it unless the Leave_trail param was set.
    if ($scriptAddedNIC)
    {
        if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
        {
            if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
            {
                .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
            }
            else
            {
                "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
            }
        }
    }

	return $false
}

# now set VM2 to a different VLAN ID and try to ping the first VM again
# first remove the old vlan interface
$retVal = RemoveVlanInterfaceConfig $vm2ipv4 $sshKey $vm2MacAddress $vlanID

if (-not $retVal)
{
	"Warning: RemoveVLanInterfaceConfig failed."
}

$badVlanId = [int]$vlanID + [int]1

"Changing VlanID of second VM to $badVlanId"

$retVal = CreateVlanInterfaceConfig $vm2ipv4 $sshKey $vm2MacAddress $vm2StaticIP $netmask $badVlanId
if (-not $retVal)
{
	"Failed to create Vlan Interface on vm $vm2ipv4 for interface with mac $vm2MacAddress , by setting a static IP of $vm2StaticIP netmask $netmask and vlan ID $vlanID"

    Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm1Nic -Untagged
    Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm2Nic -Untagged

    RemoveVlanInterfaceConfig $vm2ipv4 $sshKey $vm2MacAddress $badVlanId

    Stop-VM -VMName $vm2name -ComputerName $hvServer -force

    # if this script added the second NIC, then remove it unless the Leave_trail param was set.
    if ($scriptAddedNIC)
    {
        if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
        {
            if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
            {
                .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
            }
            else
            {
                "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
            }
        }
    }

	return $false
}

# set the allowedvlanIdlist for the second VM to the new vlanID and try again to ping
Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm2Nic -Trunk -AllowedVlanIdList $badvlanID -NativeVlanId $nativeVlanId
if (-not $?)
{
	"Failed to set $vm2Nic to Trunk Mode with an AllowedVlanIdList of $vlanID and a native VlanID $nativeVlanId"

    Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm1Nic -Untagged
    Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm2Nic -Untagged

    RemoveVlanInterfaceConfig $vm2ipv4 $sshKey $vm2MacAddress $badVlanId

    Stop-VM -VMName $vm2name -ComputerName $hvServer -force

    # if this script added the second NIC, then remove it unless the Leave_trail param was set.
    if ($scriptAddedNIC)
    {
        if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
        {
            if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
            {
                .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
            }
            else
            {
                "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
            }
        }
    }

	return $false
}

# ping from the second VM to the first
$retVal = pingVMs $vm2ipv4 $vm1StaticIP $sshKey 10 $vm2MacAddress $badVlanId
"main script: pingVMs returned $retVal"

if ($retVal)
{
	"Ping from vm2: Able to ping $vm1StaticIP from $vm2StaticIP with MAC $vm2MacAddress although it should not have worked!"

    Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm1Nic -Untagged
    Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm2Nic -Untagged

    RemoveVlanInterfaceConfig $vm2ipv4 $sshKey $vm2MacAddress $badVlanId

    Stop-VM -VMName $vm2name -ComputerName $hvServer -force

    # if this script added the second NIC, then remove it unless the Leave_trail param was set.
    if ($scriptAddedNIC)
    {
        if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
        {
            if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
            {
                .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
            }
            else
            {
                "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
            }
        }
    }

	return $false
}

# set the allowedVlanIdList of the first VM also to the new vlanID and try to ping again
Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm1NIC -Trunk -AllowedVlanIdList $badvlanID -NativeVlanId $nativeVlanId
if (-not $?)
{
	"Failed to set $vm1Nic to Trunk Mode with an AllowedVlanIdList of $vlanID and a native VlanID $nativeVlanId"

    Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm1Nic -Untagged
    Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm2Nic -Untagged

    RemoveVlanInterfaceConfig $vm2ipv4 $sshKey $vm2MacAddress $badVlanId

    Stop-VM -VMName $vm2name -ComputerName $hvServer -force

    # if this script added the second NIC, then remove it unless the Leave_trail param was set.
    if ($scriptAddedNIC)
    {
        if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
        {
            if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
            {
                .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
            }
            else
            {
                "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
            }
        }
    }

	return $false
}

$retVal = pingVMs $vm2ipv4 $vm1StaticIP $sshKey 10 $vm2MacAddress $badVlanId
if ($retVal)
{
	"Able to ping $vm1StaticIP from $vm2StaticIP with MAC $vm2MacAddress although it should not have worked!"

    Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm1Nic -Untagged
    Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm2Nic -Untagged

    RemoveVlanInterfaceConfig $vm2ipv4 $sshKey $vm2MacAddress $badVlanId

    Stop-VM -VMName $vm2name -ComputerName $hvServer -force

    # if this script added the second NIC, then remove it unless the Leave_trail param was set.
    if ($scriptAddedNIC)
    {
        if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
        {
            if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
            {
                .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
            }
            else
            {
                "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
            }
        }
    }

	return $false
}

# undo everything we did
Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm1Nic -Untagged
Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm2Nic -Untagged

RemoveVlanInterfaceConfig $vm2ipv4 $sshKey $vm2MacAddress $badVlanId

Stop-VM -VMName $vm2name -ComputerName $hvServer -force

# if this script added the second NIC, then remove it unless the Leave_trail param was set.
if ($scriptAddedNIC)
{
    if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
    {
        if (Test-Path ".\setupScripts\NET_REMOVE_NIC_MAC.ps1")
        {
            .\setupScripts\NET_REMOVE_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
        }
        else
        {
            "Warning: Unable to find setupScripts\NET_REMOVE_NIC_MAC.ps1 in order to remove the added NIC"
        }
    }
}

"Test successful!"

return $true