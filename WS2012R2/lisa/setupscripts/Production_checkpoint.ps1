########################################################################
#
# Linux on Hyper-V and Azure Test Code, ver. 1.0.0
# Copyright (c) Microsoft Corporation
#
# All rights reserved.
# Licensed under the Apache License, Version 2.0 (the ""License"");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
#
# THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
# OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
# ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR
# PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.
#
# See the Apache Version 2.0 License for specific language governing
# permissions and limitations under the License.
#

<#
.Synopsis
    Verify Production Checkpoint feature.

.Description
    Tests to see if the virtual machine Production Checkpoint operation
    works as expected. Steps:
     - Create a file on VM
     - Take a Production Checkpoint
     - Create a second file on VM
     - Revert to the Production Checkpoint
     - Boot the VM, only the first file should exist

    A typical test case definition for this test script would look
    similar to the following:
        <test>
            <testName>ProductionCheckpoint</testName>
            <testScript>setupscripts\Production_checkpoint.ps1</testScript> 
            <testParams>
                <param>TC_COVERED=PC-01</param>
            </testParams>
            <timeout>2400</timeout>
            <OnError>Continue</OnError>
        </test>

.Parameter vmName
    Name of the VM to perform the test with.

.Parameter hvServer
    Name of the Hyper-V server hosting the VM.

.Parameter testParams
    A semicolon separated list of test parameters.

.Example
    setupScripts\Production_checkpoint.ps1 -vmName "myVm" -hvServer "localhost"
     -TestParams "TC_COVERED=PC-01"
#>

param([string] $vmName, [string] $hvServer, [string] $testParams)

#######################################################################
# Runs a remote script on the VM an returns the log.
#######################################################################
function RunRemoteScript($remoteScript)
{
    $retValue = $False
    $stateFile     = "state.txt"
    $TestCompleted = "TestCompleted"
    $TestAborted   = "TestAborted"
    $TestRunning   = "TestRunning"
    $timeout       = 6000

    "./${remoteScript} > ${remoteScript}.log" | out-file -encoding ASCII -filepath runtest.sh

    .\bin\pscp -i ssh\${sshKey} .\runtest.sh root@${ipv4}:
    if (-not $?)
    {
       Write-Output "ERROR: Unable to copy runtest.sh to the VM"
       return $False
    }

    .\bin\pscp -i ssh\${sshKey} .\remote-scripts\ica\${remoteScript} root@${ipv4}:
    if (-not $?)
    {
       Write-Output "ERROR: Unable to copy ${remoteScript} to the VM"
       return $False
    }

    .\bin\plink.exe -i ssh\${sshKey} root@${ipv4} "dos2unix ${remoteScript} 2> /dev/null"
    if (-not $?)
    {
        Write-Output "ERROR: Unable to run dos2unix on ${remoteScript}"
        return $False
    }

    .\bin\plink.exe -i ssh\${sshKey} root@${ipv4} "dos2unix runtest.sh  2> /dev/null"
    if (-not $?)
    {
        Write-Output "ERROR: Unable to run dos2unix on runtest.sh"
        return $False
    }

    .\bin\plink.exe -i ssh\${sshKey} root@${ipv4} "chmod +x ${remoteScript}   2> /dev/null"
    if (-not $?)
    {
        Write-Output "ERROR: Unable to chmod +x ${remoteScript}"
        return $False
    }
    .\bin\plink.exe -i ssh\${sshKey} root@${ipv4} "chmod +x runtest.sh  2> /dev/null"
    if (-not $?)
    {
        Write-Output "ERROR: Unable to chmod +x runtest.sh " -
        return $False
    }

    # Run the script on the vm
    .\bin\plink.exe -i ssh\${sshKey} root@${ipv4} "./runtest.sh"

    # Return the state file
    while ($timeout -ne 0 )
    {
    .\bin\pscp -q -i ssh\${sshKey} root@${ipv4}:${stateFile} . #| out-null
    $sts = $?
    if ($sts)
    {
        if (test-path $stateFile)
        {
            $contents = Get-Content -Path $stateFile
            if ($null -ne $contents)
            {
                    if ($contents -eq $TestCompleted)
                    {
                        Write-Output "Info : state file contains Testcompleted"
                        $retValue = $True
                        break

                    }

                    if ($contents -eq $TestAborted)
                    {
                         Write-Output "Info : State file contains TestAborted failed. "
                         break

                    }
                    #Start-Sleep -s 1
                    $timeout--

                    if ($timeout -eq 0)
                    {
                        Write-Output "Error : Timed out on Test Running , Exiting test execution."
                        break
                    }

            }
            else
            {
                Write-Output "Warn : state file is empty"
                break
            }

        }
        else
        {
             Write-Host "Warn : ssh reported success, but state file was not copied"
             break
        }
    }
    else #
    {
         Write-Output "Error : pscp exit status = $sts"
         Write-Output "Error : unable to pull state.txt from VM."
         break
    }
    }

    # Get the logs
    $remoteScriptLog = $remoteScript+".log"

    bin\pscp -q -i ssh\${sshKey} root@${ipv4}:${remoteScriptLog} .
    $sts = $?
    if ($sts)
    {
        if (test-path $remoteScriptLog)
        {
            $contents = Get-Content -Path $remoteScriptLog
            if ($null -ne $contents)
            {
                    if ($null -ne ${TestLogDir})
                    {
                        move "${remoteScriptLog}" "${TestLogDir}\${remoteScriptLog}"

                    }

                    else
                    {
                        Write-Output "INFO: $remoteScriptLog is copied in ${rootDir}"
                    }

            }
            else
            {
                Write-Output "Warn: $remoteScriptLog is empty"
            }
        }
        else
        {
             Write-Output "Warn: ssh reported success, but $remoteScriptLog file was not copied"
        }
    }

    # Cleanup
    del state.txt -ErrorAction "SilentlyContinue"
    del runtest.sh -ErrorAction "SilentlyContinue"

    return $retValue
}

#######################################################################
# Create a file on the VM.
#######################################################################
function CreateFile([string] $fileName)
{
    .\bin\plink -i ssh\${sshKey} root@${ipv4} "touch ${fileName}"
    if (-not $?)
    {
        Write-Output "ERROR: Unable to create file" | Out-File -Append $summaryLog
        return $False
    }

    return  $True
}

#######################################################################
# Checks if test file is present or not.
#######################################################################
function CheckFile([string] $fileName)
{
    $retVal = $true
    .\bin\plink.exe -i ssh\${sshKey} root@${ipv4} "stat ${fileName} 2>/dev/null" | out-null
    if (-not $?)
    {
        $retVal = $false
    }

    return  $retVal
}

#######################################################################
#
# Main script body
#
#######################################################################
$retVal = $false

# Define and cleanup the summaryLog
$summaryLog  = "${vmName}_summary.log"
echo "Covers Production Checkpoint Testing" > $summaryLog

# Check input arguments
if ($vmName -eq $null)
{
    "ERROR: VM name is null"
    return $retVal
}

# Check input params
$params = $testParams.Split(";")

foreach ($p in $params)
{
  $fields = $p.Split("=")

  switch ($fields[0].Trim())
    {
    "TC_COVERED"  { $TC_COVERED = $fields[1].Trim() }
    "sshKey"      { $sshKey = $fields[1].Trim() }
    "ipv4"        { $ipv4 = $fields[1].Trim() }
    "rootdir"     { $rootDir = $fields[1].Trim() }
     default  {}
    }
}

if ($null -eq $sshKey)
{
    "ERROR: Test parameter sshKey was not specified"
    return $False
}

if ($null -eq $ipv4)
{
    "ERROR: Test parameter ipv4 was not specified"
    return $False
}

if ($null -eq $rootdir)
{
    "ERROR: Test parameter rootdir was not specified"
    return $False
}

echo $params

# Change the working directory to where we need to be
cd $rootDir

Write-output "This script covers test case: ${TC_COVERED}" | Tee-Object -Append -file $summaryLog

# Source the TCUtils.ps1 file
. .\setupscripts\TCUtils.ps1

#Check if the host supports production checkpoints
$osInfo = GWMI Win32_OperatingSystem -ComputerName $hvServer
if (-not $osInfo)
{
    "Error: Unable to collect Operating System information"
    return $False
}

[System.Int32]$buildNR = $osInfo.BuildNumber

if ($buildNR -le 10500){
    Write-Output "ERROR: This Windows Server version doesn't support production checkpoints"
    return $false
}

# Check if the Vm VHD in not on the same drive as the backup destination
$vm = Get-VM -Name $vmName -ComputerName $hvServer
if (-not $vm)
{
    "Error: VM '${vmName}' does not exist"
    return $False
}

# Send utils.sh to VM
echo y | .\bin\pscp -i ssh\${sshKey} .\remote-scripts\ica\utils.sh root@${ipv4}:
if (-not $?)
{
    Write-Output "ERROR: Unable to copy utils.sh to the VM"
    return $False
}

# Check to see Linux VM is running VSS backup daemon
$sts = RunRemoteScript "STOR_VSS_Check_VSS_Daemon.sh"
if (-not $sts[-1])
{
    Write-Output "ERROR executing $remoteScript on VM. Exiting test case!" >> $summaryLog
    Write-Output "ERROR: Running $remoteScript script failed on VM!"
    return $False
}

Write-Output "VSS Daemon is running " >> $summaryLog

# Create a file on the VM
$sts = CreateFile "TestFile1"
if (-not $sts[-1])
{
    Write-Output "ERROR: Can not create file"
    return $False
}

#Check if we can set the Production Checkpoint as default
if ($vm.CheckpointType -ne "ProductionOnly"){
    Set-VM -Name $vmName -CheckpointType ProductionOnly
    if (-not $?)
    {
       Write-Output "Error: Could not set Production as Checkpoint type"  | Out-File -Append $summaryLog
       return $false
    }
}

$random = Get-Random -minimum 1024 -maximum 4096
$snapshot = "TestSnapshot_$random"
Checkpoint-VM -Name $vmName -SnapshotName $snapshot -ComputerName $hvServer
if (-not $?)
{
    Write-Output "Error: Could not create checkpoint" | Out-File -Append $summaryLog
    $error[0].Exception.Message
    return $False
}

# Create another file on the VM
$sts = CreateFile "TestFile2"
if (-not $sts[-1])
{
    Write-Output "ERROR: Can not create file"
    return $False
}

Restore-VMSnapshot -VMName $vmName -Name $snapshot -ComputerName $hvServer -Confirm:$false
if (-not $?)
{
    Write-Output "Error: Could not restore checkpoint" | Out-File -Append $summaryLog
    $error[0].Exception.Message
    return $False
}

#
# Starting the VM
#
Start-VM $vmName -ComputerName $hvServer

#
# Waiting for the VM to run again and respond to SSH - port 22
#
$timeout = 300
while ($timeout -gt 0) {
    if ( (TestPort $ipv4) ) {
        break
    }

    Start-Sleep -seconds 2
    $timeout -= 2
}

if ($timeout -eq 0) {
    Write-Output "Error: Test case timed out waiting for VM to boot" | Out-File -Append $summaryLog
    return $False
}

$sts = CheckFile "TestFile1"
if (-not $sts)
{
    Write-Output "ERROR: TestFile1 is not present"
    Write-Output "TestFile1 should be present on the VM" >> $summaryLog
    return $False
}

$sts = CheckFile "TestFile2"
if ($sts)
{
    Write-Output "ERROR: TestFile2 is present"
    Write-Output "TestFile2 should not be present on the VM" >> $summaryLog
    return $False
}

Write-Output "Only the first file is present. Test succeeded" >> $summaryLog
#
# Delete the snapshot
#
"Info : Deleting Snapshot ${Snapshot} of VM ${vmName}"
Remove-VMSnapshot -VMName $vmName -Name $snapshot -ComputerName $hvServer
if ( -not $?)
{
   Write-Output "Error: Could not delete snapshot"  | Out-File -Append $summaryLog
}

return $true