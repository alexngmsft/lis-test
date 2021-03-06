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

    Test different scenarios for LIS CDs
   .Parameter vmName
    Name of the VM.
    .Parameter hvServer
    Name of the Hyper-V server hosting the VM.
    .Parameter testParams
    Test data for this test case
#>

param([string] $vmName, [string] $hvServer, [string] $testParams)


function enable_gsi($vmName, $hvServer){
    #
    # Verify if the Guest services are enabled for this VM
    #
    $gsi = Get-VMIntegrationService -vmName $vmName -ComputerName $hvServer -Name "Guest Service Interface"
    if (-not $gsi) {
        "Error: Unable to retrieve Integration Service status from VM '${vmName}'"
        return $False
    }

    if (-not $gsi.Enabled) {
        # make sure VM is off
        Stop-VM -vmName $vmName -ComputerName $hvServer -force
        $sts = WaitForVMToStop $vmName $hvServer 200
        if (-not $sts){
             "Error: Unable to shutdown $vmName"
             return $false
        }
        Enable-VMIntegrationService -Name "Guest Service Interface" -vmName $vmName -ComputerName $hvServer
        if (-not $?)
        {
            "Error: Unable to enable Guest Service Interface for $vmName."
            return $false
        }
    }
    return $true
}

function get_logs(){
    $ipv4 = GetIPv4 $vmName $hvserver
    # Get LOGS

    GetfileFromVm $ipv4 $sshkey "/root/summary.log" $logdir
    GetfileFromVm $ipv4 $sshkey "/root/LIS_log.log" $logdir
    GetfileFromVm $ipv4 $sshkey "/root/kernel_install.log" $logdir

    $logFile = $logdir + "\LIS_log.log"
    $content = Get-Content $logFile
    Write-Output $content | Tee-Object -Append -file $summaryLog
}

function install_lis(){
    # Install, upgrade or uninstall LIS
    $remoteScript = "Install_LIS.sh"
    $sts = RunRemoteScript $remoteScript
    if(-not $sts[-1]){
        Write-Output "Error: Cannot install LIS"  >> $summaryLog
        get_logs
        return $false
    }
    #search for errors
    $sts = GetfileFromVm $ipv4 $sshkey "/root/state.txt" "."
    if(-not $sts[-1]){
        Write-Output "Error: Cannot get state file from vm"  >> $summaryLog
        get_logs
        return $false
    }
    $x = Select-String -Path ".\state.txt" -Pattern TestFailed
    if($x.Length -ne 0){
        Write-Output "Error: Errors at install LIS"  >> $summaryLog
        get_logs
        return $false
    }
    remove-item .\state.txt
    return $true
}

function verify_daemons_modules(){
    # Verify LIS Modules version and daemons
    $remoteScript = "CORE_LISmodules_version.sh"
    $sts = RunRemoteScript $remoteScript
    if(-not $sts[-1]){
        Write-Output "Error: Cannot verify LIS magic version on '${$vmName}'"
        get_logs
        return $false
    }

    $remoteScript = "check_lis_daemons.sh"
    $sts = RunRemoteScript $remoteScript
    if(-not $sts[-1]){
        Write-Output "Error: Not all deamons are running '${$vmName}'"
        get_logs
        return $false
    }

    return $true
}

function check_lis_version($version){
    $LIS_version=.\bin\plink.exe -i $sshkey root@$ipv4 "modinfo hv_vmbus | grep -w 'version:'"
    if ($LIS_version.Contains($version) -eq $False) {
        Write-Output "Error: LIS Version from host is not matching with the expected one from params."
        get_logs
        return $false
    }
    return $true
}

function verify_errors(){
    #search for errors
    $sts = GetfileFromVm $ipv4 $sshkey "/root/state.txt" "."
    if(-not $sts[-1]){
        Write-Output "Error: Cannot get state file from vm" >> $summaryLog
        get_logs
        return $false
    }
    $completed = Select-String -Path ".\state.txt" -Pattern TestCompleted
    if($completed.Length -eq 0){
        Write-Output "Error: Errors at state file. Check logs." >> $summaryLog
        get_logs
        return $false
    }
    return $true
}

function kernel_upgrade(){
    $completed = .\bin\plink.exe -i $sshkey root@$ipv4 "cat kernel_upgrade.log | grep 'Complete!'"
    if(-not $completed){
        Write-output "Kernel upgrade failed"
        get_logs
        return $false
    }
    return $true
}

#######################################################################
#
#   Main body script
#
#######################################################################


# Checking the input arguments
if (-not $vmName) {
    "Error: VM name is null!"
    return $retVal
}

if (-not $hvServer) {
    "Error: hvServer is null!"
    return $retVal
}

if (-not $testParams) {
    "Error: No testParams provided!"
    "This script requires the test case ID and VM details as the test parameters."
    return $retVal
}

#
# Checking the mandatory testParams. New parameters must be validated here.
#
$params = $testParams.Split(";")
foreach ($p in $params) {
    $fields = $p.Split("=")

    if ($fields[0].Trim() -eq "rootDir") {
        $rootDir = $fields[1].Trim()
    }
    if ($fields[0].Trim() -eq "TestLogDir") {
        $logdir = $fields[1].Trim()
    }
    if ($fields[0].Trim() -eq "ipv4") {
        $ipv4 = $fields[1].Trim()
    }
    if ($fields[0].Trim() -eq "sshkey") {
        $sshkey = $fields[1].Trim()
    }
    if ($fields[0].Trim() -eq "scenario") {
        $scenario = $fields[1].Trim()
    }
    if ($fields[0].Trim() -eq "IsoFilename") {
        $IsoFilename = $fields[1].Trim()
    }
    if ($fields[0].Trim() -eq "IsoFilename2") {
        $isofilename2 = $fields[1].Trim()
    }
    if ($fields[0].Trim() -eq "version") {
        $version = $fields[1].Trim()
    }
    if ($fields[0].Trim() -eq "version2") {
        $version2 = $fields[1].Trim()
    }
}

#
# Change the working directory for the log files
# Delete any previous summary.log file, then create a new one
#
if (-not (Test-Path $rootDir)) {
    "Error: The directory `"${rootDir}`" does not exist"
    return $false
}
cd $rootDir

# Source TCUtils.ps1 for test related functions
if (Test-Path ".\setupscripts\TCUtils.ps1")
{
    . .\setupScripts\TCUtils.ps1
}
else
{
    "Error: Could not find setupScripts\TCUtils.ps1"
    return $false
}

# Delete any previous summary.log file, then create a new one
$summaryLog = "${vmName}_summary.log"
del $summaryLog -ErrorAction SilentlyContinue

#
# Enable Guest Service Interface
#
$sts = enable_gsi $vmName $hvServer
if( -not $sts){
    Write-Output "Error: Cannot enable Guest Service Interface for '${$vmName}'"
    return $false
}

#
# Start VM
#
if ((Get-VM -ComputerName $hvServer -Name $vmName).State -eq "Off") {
    Start-VM -Name $vmName -ComputerName $hvServer -ErrorAction SilentlyContinue
    $sts = WaitForVMToStartSSH $ipv4 200
    if( -not $sts){
        Write-Output "Error: Cannot start $vmName"
        return $false
    }
}

Start-Sleep 10

switch ($scenario){
    "1" {
        # Mount and install LIS
        $sts = SendCommandToVM $ipv4 $sshkey "echo 'action=install' >> ~/constants.sh"
        if(-not $sts[-1]){
            Write-Output "Error: Unable to add action in constants.sh on $vmName"
            return $false
        }

        $sts = install_lis
        if( -not $sts[-1]){
            Write-Output "Error: Cannot install LIS for $vmName"
            return $false
        }
        $sts = verify_errors
        if(-not $sts[-1]){
            Write-Output "Error: Errors encountered at installing LIS $version"
            return $false
        }
        Write-output "Successfully installed LIS"
        # Reboot the VM
        Restart-VM -VMName $vmName -ComputerName $hvServer -Force
        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts[-1]){
            Write-Output "Error: Cannot restart $vmName"
            return $false
        }
        write-output "Successfully rebooted VM"
        $sts = verify_daemons_modules
        if( -not $sts[-1]){
            Write-Output "Error: Daemons/Modules verification failed for $vmName"
            return $false
        }

        $sts = check_lis_version $version
        if( -not $sts){
            Write-Output "Error: LIS version: $version from host is not the expected one after install."
            return $false
        }

        $sts = verify_errors
        if(-not $sts[-1]){
            Write-Output "Error: Errors encountered after installing LIS $version"
            return $false
        }

        $logFile = "LIS_log.log"
        bin\pscp -q -i ssh\${sshKey} root@${ipv4}:LIS_log.log $logdir
        $content = Get-Content $logFile
        Write-Output $content | Tee-Object -Append -file $summaryLog
    }

    "2" {
        # Mount and install LIS
        $sts = SendCommandToVM $ipv4 $sshkey "echo 'action=install' >> ~/constants.sh"
        if(-not $sts[-1]){
            Write-Output "Error: Unable to add action in constants.sh on $vmName"
            return $false
        }

        $sts = install_lis
        if( -not $sts){
            Write-Output "Error: Cannot install LIS for '${$vmName}'"
            return $false
        }

        $sts = verify_errors
        if(-not $sts[-1]){
            Write-Output "Error: Errors encountered at installing LIS $version"
            return $false
        }

        # Reboot the VM
        Restart-VM -VMName $vmName -ComputerName $hvServer -Force
        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts){
            Write-Output "Error: Cannot restart $vmName"
            return $false
        }

        $sts = verify_daemons_modules
        if( -not $sts){
            Write-Output "Error: Daemons/Modules verification failed for $vmName"
            return $false
        }

        $sts = check_lis_version $version
        if( -not $sts){
            Write-Output "Error: LIS version: $version from host is not the expected one after install."
            return $false
        }

        $sts = verify_errors
        if(-not $sts[-1]){
            Write-Output "Error: Errors encountered after installing LIS $version"
            return $false
        }
        Write-Output "Successfully installed LIS $version"

        # Attach the new iso.
        Stop-VM -vmName $vmName -ComputerName $hvServer -force
        $sts = .\setupscripts\InsertIsoInDvd.ps1 -vmName $vmName -hvServer $hvServer -testParams "isofilename=$IsoFilename2"
        if( -not $sts){
            Write-Output "Error: Cannot stop $vmName"
            return $false
        }

        Start-VM -Name $vmName -ComputerName $hvServer -ErrorAction SilentlyContinue
        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts){
            Write-Output "Error: Cannot start $vmName"
            return $false
        }

        $sts = SendCommandToVM $ipv4 $sshkey "sed -i 's/action=\S*/action=upgrade/g' constants.sh"
        if(-not $sts[-1]){
            Write-Output "Error: Unable to add action in constants.sh on $vmName"
            return $false
        }

        $sts = install_lis
        if( -not $sts){
            Write-Output "Error: Cannot install LIS for '${$vmName}'"
            return $false
        }
        $sts = verify_errors
        if(-not $sts[-1]){
            Write-Output "Error: Errors encountered at upgrading LIS $version2"
            return $false
        }
        Write-Output "Successfully upgraded LIS"

        # Reboot the VM
        Restart-VM -VMName $vmName -ComputerName $hvServer -Force
        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts){
            Write-Output "Error: Cannot restart $vmName"
            return $false
        }

        $sts = verify_daemons_modules
        if( -not $sts){
            Write-Output "Error: Daemons/Modules verification failed for $vmName'"
            return $false
        }

        $sts = check_lis_version $version2
        if( -not $sts){
            Write-Output "Error: LIS version: $version2 from host is not the expected one after upgrade."
            return $false
        }

        $sts = verify_errors
        if(-not $sts[-1]){
            Write-Output "Error: Errors encountered after upgrading LIS $version2"
            return $false
        }

    }

    "3" {
        # Mount and install LIS
        $sts = SendCommandToVM $ipv4 $sshkey "echo 'action=install' >> ~/constants.sh"
        if(-not $sts[-1]){
            Write-Output "Error: Unable to add action in constants.sh on $vmName"
            return $false
        }

        $sts = install_lis
        if( -not $sts){
            Write-Output "Error: Cannot install LIS for '${$vmName}'"
            return $false
        }

        $sts = verify_errors
        if( -not $sts){
            Write-Output "Error: Errors were encounted when installing LIS $vmName"
            return $false
        }

        # Reboot the VM
        Restart-VM -VMName $vmName -ComputerName $hvServer -Force
        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts){
            Write-Output "Error: Cannot restart $vmName"
            return $false
        }

        # validate install
        $sts = verify_daemons_modules
        if( -not $sts){
            Write-Output "Error: Daemons/Modules verification failed for $vmName"
            return $false
        }

        $sts = check_lis_version $version
        if( -not $sts){
            Write-Output "Error: LIS version: $version from host is not the expected one after install."
            return $false
        }

        $sts = verify_errors
        if( -not $sts){
            Write-Output "Error: Errors were encounted after installing LIS $vmName"
            return $false
        }

        # Attach the new iso.
        Stop-VM -vmName $vmName -ComputerName $hvServer -force
        .\setupscripts\InsertIsoInDvd.ps1 $vmName $hvServer "isofilename=$IsoFilename2"

        Start-VM -Name $vmName -ComputerName $hvServer -ErrorAction SilentlyContinue
        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts){
            Write-Output "Error: Cannot start $vmName"
            return $false
        }

        # Mount and upgrade LIS
        $sts = SendCommandToVM $ipv4 $sshkey "sed -i 's/action=\S*/action=upgrade/g' constants.sh"
        if(-not $sts[-1]){
            Write-Output "Error: Unable to add action in constants.sh on $vmName"
            return $false
        }

        $sts = install_lis
        if( -not $sts){
            Write-Output "Error: Cannot install LIS for '${$vmName}'"
            return $false
        }

        $sts = verify_errors
        if( -not $sts){
            Write-Output "Error: Errors were encounted when upgrading LIS $vmName"
            return $false
        }

        # Reboot the VM
        Restart-VM -VMName $vmName -ComputerName $hvServer -Force
        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts){
            Write-Output "Error: Cannot restart $vmName"
            return $false
        }

        # validate upgrade
        $sts = verify_daemons_modules
        if( -not $sts){
            Write-Output "Error: Daemons/Modules verification failed for $vmName"
            return $false
        }

        $sts = check_lis_version $version2
        if( -not $sts){
            Write-Output "Error: LIS version: $version2 from host is not the expected one after upgrade."
            return $false
        }

        $sts = verify_errors
        if( -not $sts){
            Write-Output "Error: Errors were encounted when upgrading LIS $vmName"
            return $false
        }

        # Unstall LIS
        $sts = SendCommandToVM $ipv4 $sshkey "sed -i 's/action=\S*/action=uninstall/g' constants.sh"
        if(-not $sts[-1]){
            Write-Output "Error: Unable to add action in constants.sh on $vmName"
            return $false
        }

        # Attach the new iso.
        Stop-VM -vmName $vmName -ComputerName $hvServer -force
        $sts = .\setupscripts\InsertIsoInDvd.ps1 $vmName $hvServer "isofilename=$IsoFilename"
        if( -not $sts){
            Write-Output "Error: Cannot attach LIS iso on $vmName"
            return $false
        }

        Start-VM -Name $vmName -ComputerName $hvServer -ErrorAction SilentlyContinue
        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts){
            Write-Output "Error: Cannot start $vmName"
            return $false
        }

        # Mount and install LIS
        $sts = SendCommandToVM $ipv4 $sshkey "sed -i 's/action=\S*/action=install/g' constants.sh"
        if(-not $sts[-1]){
            Write-Output "Error: Unable to add action in constants.sh on $vmName"
            return $false
        }

        $sts = install_lis
        if( -not $sts){
            Write-Output "Error: Cannot install LIS for '${$vmName}'"
            return $false
        }

        $sts = verify_errors
        if( -not $sts){
            Write-Output "Error: Errors were encounted when installing LIS $vmName"
            return $false
        }

        # Reboot the VM
        Restart-VM -VMName $vmName -ComputerName $hvServer -Force
        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts){
            Write-Output "Error: Cannot restart $vmName"
            return $false
        }

        # validate install
        $sts = verify_daemons_modules
        if( -not $sts){
            Write-Output "Error: Daemons/Modules verification failed for $vmName"
            return $false
        }

        $sts = check_lis_version $version
        if( -not $sts){
            Write-Output "Error: LIS version: $version from host is not the expected one after install."
            return $false
        }

        $sts = verify_errors
        if( -not $sts){
            Write-Output "Error: Errors were encounted after installing LIS $vmName"
            return $false
        }
    }

    "4"{
        # Mount and install LIS
        $sts = SendCommandToVM $ipv4 $sshkey "echo 'action=install' >> ~/constants.sh"
        if(-not $sts[-1]){
            Write-Output "Error: Unable to add action in constants.sh on $vmName"
            return $false
        }

        $sts = install_lis
        if( -not $sts[-1]){
            Write-Output "Error: Cannot install LIS for '${$vmName}'"
            return $false
        }
        $sts = verify_errors
        if( -not $sts[-1]){
            Write-Output "Error: Errors were encountered when installing LIS $vmName"
            return $false
        }
        Write-output "Successfully installed LIS $version"

        # Attach the new iso.
        Stop-VM -vmName $vmName -ComputerName $hvServer -force
        .\setupscripts\InsertIsoInDvd.ps1 $vmName $hvServer "isofilename=$IsoFilename2"

        Start-VM -Name $vmName -ComputerName $hvServer -ErrorAction SilentlyContinue
        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts[-1]){
            Write-Output "Error: Cannot start $vmName"
            return $false
        }

        # Upgrade kernel
        SendCommandToVM $ipv4 $sshkey "echo 'kernel version before upgrade:`uname -r`' >> kernel_install.log"
        if(-not $sts[-1]){
            Write-Output "Error: Unable to add action in constants.sh on $vmName"
            return $false
        }
        Write-Output "Successfully upgraded kernel"
        sleep 30
        # check if kernel upgraded
        $sts = kernel_upgrade
        if(-not $sts[-1]){
            Write-Output "Error at kernel upgrade"
            return $false;
        }
        # Mount and install LIS
        $sts = install_lis
        if( -not $sts[-1]){
            $sts = verify_errors
            if($sts -eq $true){
                Write-Output "Error: LIS installation succeded $vmName"
                return $false
            }
        }
        # Reboot the VM
        Restart-VM -VMName $vmName -ComputerName $hvServer -Force
        $ipv4 = GetIPv4 $vmName $hvserver
        while(-not $ipv4){
            sleep 5
            $ipv4 = GetIPv4 $vmName $hvserver
        }

        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts[-1]){
            Write-Output "Error: Cannot restart $vmName"
            return $false
        }

        $sts = verify_daemons_modules
        if( -not $sts){
            Write-Output "Error: Daemons/Modules verification failed for $vmName"
            return $false
        }

        $version="3.1"
        $sts = check_lis_version $version
        if( -not $sts){
            Write-Output "Error: LIS version: $version from host is not the expected one after kernel upgrade."
            return $false
        }
    }

    "5"{
        # Mount and install LIS
        $sts = SendCommandToVM $ipv4 $sshkey "echo 'action=install' >> ~/constants.sh"
        if(-not $sts[-1]){
            Write-Output "Error: Unable to add action in constants.sh on $vmName"
            return $false
        }
        $sts = install_lis
        if( -not $sts){
            Write-Output "Error: Cannot install LIS for '${$vmName}'"
            return $false
        }
        $sts = verify_errors
        if( -not $sts){
            Write-Output "Error: Errors were encountered when installing LIS $vmName"
            return $false
        }
        Write-output "Successfully installed LIS $version"

        # Reboot the VM
        Restart-VM -VMName $vmName -ComputerName $hvServer -Force
        $ipv4 = GetIPv4 $vmName $hvserver
        while(-not $ipv4){
            sleep 5
            $ipv4 = GetIPv4 $vmName $hvserver
        }

        Write-output "Rebooted VM"

        # validate install
        $sts = verify_daemons_modules
        if( -not $sts){
            Write-Output "Error: Cannot install LIS for $vmName"
            return $false
        }

        $sts = check_lis_version $version
        if( -not $sts){
            Write-Output "Error: LIS version: $version from host is not the expected one after install."
            return $false
        }

        $sts = verify_errors
        if( -not $sts){
            Write-Output "Error: Errors were encounted when installing LIS $vmName"
            return $false
        }
        Write-output "Daemons and modules status: OK"

        SendCommandToVM $ipv4 $sshkey "echo 'kernel version before upgrade:`uname -r`' >> kernel_install.log"
        # Upgrade kernel
        if(-not $sts[-1]){
            Write-Output "Error: Unable to install new kernel on $vmName"
            return $false
        }

        Sleep 30
        # check if kernel upgraded
        $sts = kernel_upgrade
        if(-not $sts[-1]){
            Write-Output "Error at kernel upgrade"
            return $false;
        }

        # Reboot the VM
        Restart-VM -VMName $vmName -ComputerName $hvServer -Force
        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts){
            Write-Output "Error: Cannot restart $vmName"
            return $false
        }
        Write-output "Rebooted VM"
        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts){
            Write-Output "Error: Cannot restart $vmName"
            return $false
        }

        # chech modules
        $sts = verify_daemons_modules
        if( -not $sts){
            Write-Output "Error: Daemons/Modules(LIS version) verification failed for $vmName"
            return $false
        }

        $version="3.1"
        $sts = check_lis_version $version
        if( -not $sts){
            Write-Output "Error: LIS version($version) from host is not the expected one after kernel upgrade."
            return $false
        }

        $sts = verify_errors
        if(-not $sts[-1]){
            Write-Output "Error: Errors were encountered in state.txt on $vmName"
            return $false
        }
    }

    "6" {
        # Mount and install LIS
        $sts = SendCommandToVM $ipv4 $sshkey "echo 'action=install' >> ~/constants.sh"
        if(-not $sts[-1]){
            Write-Output "Error: Unable to add action in constants.sh on $vmName"
            return $false
        }

        $sts = install_lis
        if( -not $sts){
            Write-Output "Error: Cannot install LIS for '${$vmName}'"
            return $false
        }
        $sts = verify_errors
        if(-not $sts[-1]){
            Write-Output "Error: Unable to add action in constants.sh on $vmName"
            return $false
        }

        # Reboot the VM
        Restart-VM -VMName $vmName -ComputerName $hvServer -Force
        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts){
            Write-Output "Error: Cannot restart $vmName"
            return $false
        }

        # validate install
        $sts = verify_daemons_modules
        if( -not $sts){
            Write-Output "Error: Daemons/Modules verification failed for $vmName after install."
            return $false
        }

        $sts = check_lis_version $version
        if( -not $sts){
            Write-Output "Error: LIS version: $version from host is not the expected one after install."
            return $false
        }

        $sts = verify_errors
        if(-not $sts[-1]){
            Write-Output "Error: Errors were encountered in state.txt on $vmName"
            return $false
        }

        # Attach the new iso.
        Stop-VM -vmName $vmName -ComputerName $hvServer -force
        .\setupscripts\InsertIsoInDvd.ps1 $vmName $hvServer "isofilename=$IsoFilename2"

        Start-VM -Name $vmName -ComputerName $hvServer -ErrorAction SilentlyContinue
        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts){
            Write-Output "Error: Cannot start $vmName"
            return $false
        }

        # Mount and upgrade LIS
        $sts = SendCommandToVM $ipv4 $sshkey "sed -i 's/action=\S*/action=upgrade/g' constants.sh"
        if(-not $sts[-1]){
            Write-Output "Error: Unable to add action in constants.sh on $vmName"
            return $false
        }

        $sts = install_lis
        if( -not $sts){
            Write-Output "Error: Cannot install LIS for '${$vmName}'"
            return $false
        }
        $sts = verify_errors
        if(-not $sts[-1]){
            Write-Output "Error: Unexpected behaviour in state.txt $vmName"
            return $false
        }

        # Reboot the VM
        Restart-VM -VMName $vmName -ComputerName $hvServer -Force
        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts){
            Write-Output "Error: Cannot restart $vmName"
            return $false
        }

        # validate upgrade
        $sts = verify_daemons_modules
        if( -not $sts){
            Write-Output "Error: Daemons/Modules verification failed for $vmName after upgrade."
            return $false
        }

        $sts = check_lis_version $version2
        if( -not $sts){
            Write-Output "Error: LIS version: $version2 from host is not the expected one after upgrade."
            return $false
        }

        $sts = verify_errors
        if(-not $sts[-1]){
            Write-Output "Error: Unexpected behaviour in state.txt on $vmName"
            return $false
        }

        SendCommandToVM $ipv4 $sshkey "echo 'kernel version before upgrade:`uname -r`' >> kernel_install.log"
        # upgrade kernel
        $sts = SendCommandToVM $ipv4 $sshkey "yum install -y kernel >> ~/kernel_install.log"
        if(-not $sts[-1]){
            Write-Output "Error: Unable to upgrade kernel on $vmName"
            return $false
        }

        Start-Sleep 30
        $sts = kernel_upgrade
        if(-not $sts[-1]){
            Write-Output "Error at kernel upgrade"
            return $false;
        }

        # Reboot the VM
        Restart-VM -VMName $vmName -ComputerName $hvServer -Force
        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts){
            Write-Output "Error: Cannot restart $vmName"
            return $false
        }
        SendCommandToVM $ipv4 $sshkey "echo 'kernel version after upgrade:`uname -r`' >> kernel_install.log"

        $sts = verify_errors
        if(-not $sts[-1]){
            Write-Output "Error: Unexpected behaviour in state.txt in $vmName"
            return $false
        }
    }

   "7"{
        # Mount and install LIS
        $sts = SendCommandToVM $ipv4 $sshkey "echo 'action=install' >> ~/constants.sh"
        if(-not $sts){
            Write-Output "Error: Unable to add action in constants.sh on $vmName"
            return $false
        }

        $sts = install_lis
        if( -not $sts[-1]){
            Write-Output "Error: Cannot install LIS for $vmName"
            return $false
        }

        $sts = verify_errors
        if( -not $sts[-1]){
            Write-Output "Error: Errors were encountered when installing LIS $vmName"
            return $false
        }
        Write-output "Successfully installed LIS $version"

        # Reboot the VM
        Restart-VM -VMName $vmName -ComputerName $hvServer -Force
        $sts = WaitForVMToStartSSH $ipv4 200
        if( -not $sts[-1]){
            Write-Output "Error: Cannot restart $vmName"
            return $false
        }

        # uninstall lis
        $sts = SendCommandToVM $ipv4 $sshkey "sed -i 's/action=\S*/action=uninstall/g' constants.sh"
        if(-not $sts[-1]){
            Write-Output "Error: Unable to add action in constants.sh on $vmName"
            return $false
        }

        $sts = install_lis
        if( -not $sts[-1]){
            Write-Output "Error: Cannot install LIS for '${$vmName}'"
            return $false
        }
        Write-Output "Successfully removed LIS"

        $ipv4 = GetIPv4 $vmName $hvserver
        $count=.\bin\plink.exe -i $sshkey root@$ipv4 "ls /lib/modules/$`(uname -r)`/extra/microsoft-hyper-v | wc -l"
        if ($count -ge 1) {
            Write-Output "Error: LIS modules from the LIS RPM's were't removed."
            get_logs
            return $false
        }
    }
}

get_logs

return $True