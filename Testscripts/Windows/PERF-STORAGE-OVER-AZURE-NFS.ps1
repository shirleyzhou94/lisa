# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
param(
    [object] $AllVmData,
    [object] $CurrentTestData
)
function Main {
    # Create test result
    $currentTestResult = Create-TestResultObject
    $resultArr = @()

    try {
        $resourceGroupName = $AllVMData.ResourceGroupName
        $storageAccountName = "lisa" + $(GetRandomCharacters -Length 15)
        $location = $AllVMData.Location
        $storageAccount = New-AzStorageAccount `
            -ResourceGroupName $resourceGroupName `
            -Name $storageAccountName `
            -SkuName Premium_LRS `
            -Location $location `
            -Kind FileStorage `
            -EnableHttpsTrafficOnly $false `
            -ErrorAction SilentlyContinue
        if (!$storageAccount) {
            $testResult = $resultFail
            throw "Fail to create storage account $storageAccountName in resouce group $resourceGroupName."
        }
        $nfsShareName = "nfsshare"
        $nfsShare = New-AzRmStorageShare -StorageAccountName $storageAccountName -ResourceGroupName $resourceGroupName -Name $nfsShareName -EnabledProtocol NFS -RootSquash NoRootSquash -QuotaGiB 1024
        if (!$nfsShare) {
            $testResult = $resultFail
            throw "Fail to create nfs share in storage account $storageAccountName of resouce group $resourceGroupName."
        }

        $updateRuleSet = Update-AzStorageAccountNetworkRuleSet -ResourceGroupName $resourceGroupName -Name $storageAccountName -DefaultAction Deny
        if (!$updateRuleSet -or $updateRuleSet.DefaultAction -ne "Deny") {
            $testResult = $resultFail
            throw "Fail to set -DefaultAction as Deny for Network Rule of storage account $storageAccountName."
        }
        $vnet = Get-AzVirtualNetwork -ResourceGroupName $resourceGroupName
        if (!$vnet) {
            $testResult = $resultFail
            throw "Fail to get Virtual Network in resouce group $resourceGroupName."
        }
        $subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet
        if (!$subnet) {
            $testResult = $resultFail
            throw "Fail to get subnet of Virtual Network $($vnet.Name) in resouce group $resourceGroupName."
        }
        $setVnet = Get-AzVirtualNetwork -ResourceGroupName $resourceGroupName -Name $vnet.Name | Set-AzVirtualNetworkSubnetConfig -Name $subnet[0].Name `
        -AddressPrefix $subnet[0].AddressPrefix -ServiceEndpoint "Microsoft.Storage"  -WarningAction SilentlyContinue | Set-AzVirtualNetwork
        if (!$setVnet) {
            $testResult = $resultFail
            throw "Fail to set service endpoint for Virtual Network $($vnet.Name) in resouce group $resourceGroupName."
        }
        $addNetRule = Add-AzStorageAccountNetworkRule -ResourceGroupName $resourceGroupName -Name $storageAccountName -VirtualNetworkResourceId $subnet[0].Id
        if (!$addNetRule) {
            $testResult = $resultFail
            throw "Fail to set network rule for storage account $storageAccountName."
        }
        # $storageAccount.PrimaryEndPoints.File.Split("/")[-2] => storageaccountname.file.core.windows.net
        # storageaccountname.file.core.windows.net:/storageaccountname/sharename
        $share = $storageAccount.PrimaryEndPoints.File.Split("/")[-2] + ":/$storageAccountName/$nfsShareName"
        $cmdAddConstants = "echo -e `"nfsshare=$($share)`" >> constants.sh"
        Run-LinuxCmd -username $user -password $password -ip $allVMData.PublicIP -port $allVMData.SSHPort -command $cmdAddConstants | Out-Null

        $myString = @"
chmod +x perf_fio_nfs.sh
./perf_fio_nfs_share.sh &> fioConsoleLogs.txt
. utils.sh
collect_VM_properties
"@

        $myString2 = @"
chmod +x *.sh
cp fio_jason_parser.sh gawk JSON.awk utils.sh /home/$user/FIOLog/jsonLog/
cd /home/$user/FIOLog/jsonLog/
./fio_jason_parser.sh
cp perf_fio.csv /home/$user
chmod 666 /home/$user/perf_fio.csv
"@
        Set-Content "$LogDir\StartFioTest.sh" $myString
        Set-Content "$LogDir\ParseFioTestLogs.sh" $myString2
        Copy-RemoteFiles -uploadTo $AllVmData.PublicIP -port $AllVmData.SSHPort -files $currentTestData.files -username $user -password $password -upload

        Copy-RemoteFiles -uploadTo $AllVmData.PublicIP -port $AllVmData.SSHPort -files "$constantsFile,$LogDir\StartFioTest.sh,$LogDir\ParseFioTestLogs.sh" -username $user -password $password -upload

        $null = Run-LinuxCmd -ip $AllVmData.PublicIP -port $AllVmData.SSHPort -username $user -password $password -command "chmod +x *.sh" -runAsSudo
        $testJob = Run-LinuxCmd -ip $AllVmData.PublicIP -port $AllVmData.SSHPort -username $user -password $password -command "./StartFioTest.sh" -RunInBackground -runAsSudo

        $FioStuckCounter = 0
        $MaxFioStuckAttempts = 10
        while ((Get-Job -Id $testJob).State -eq "Running") {
            $currentStatus = Run-LinuxCmd -ip $AllVmData.PublicIP -port $AllVmData.SSHPort -username $user -password $password -command "tail -1 fioConsoleLogs.txt"-runAsSudo
            Write-LogInfo "Current Test Status: $currentStatus"
            if ($currentStatus -imatch "Doing forceful exit of this job") {
                $FioStuckCounter++
                if ( $FioStuckCounter -eq $MaxFioStuckAttempts) {
                    throw "FIO is stuck, aborting the test"
                }
            } else {
                $FioStuckCounter = 0
            }
            Wait-Time -seconds 20
        }

        $finalStatus = Run-LinuxCmd -ip $AllVmData.PublicIP -port $AllVmData.SSHPort -username $user -password $password -command "cat state.txt"
        $testSummary = $null

        if ($finalStatus -imatch "TestFailed") {
            Write-LogErr "Test failed. Last known status : $currentStatus."
            $testResult = "FAIL"
        } elseif ($finalStatus -imatch "TestAborted") {
            Write-LogErr "Test Aborted. Last known status : $currentStatus."
            $testResult = "ABORTED"
        } elseif ($finalStatus -imatch "TestCompleted") {
            Copy-RemoteFiles -downloadFrom $AllVmData.PublicIP -port $AllVmData.SSHPort -username $user -password $password -download -downloadTo $LogDir -files "FIOTest-*.tar.gz"
            Copy-RemoteFiles -downloadFrom $AllVmData.PublicIP -port $AllVmData.SSHPort -username $user -password $password -download -downloadTo $LogDir -files "VM_properties.csv"
            $null = Run-LinuxCmd -ip $AllVmData.PublicIP -port $AllVmData.SSHPort -username $user -password $password -command "/home/$user/ParseFioTestLogs.sh"
            Copy-RemoteFiles -downloadFrom $AllVmData.PublicIP -port $AllVmData.SSHPort -username $user -password $password -download -downloadTo $LogDir -files "perf_fio.csv"
            Write-LogInfo "Test Completed."
            $testResult = "PASS"
        } elseif ($finalStatus -imatch "TestRunning") {
            Write-LogInfo "Powershell background job for test is completed but VM is reporting that test is still running. Please check $LogDir\zkConsoleLogs.txt"
            Write-LogInfo "Content of summary.log : $testSummary"
            $testResult = "PASS"
        }
        Write-LogInfo "Test result: $testResult"
        if ($testResult -ne "PASS") {
            return $testResult
        }

        try {
            foreach ($line in (Get-Content "$LogDir\perf_fio.csv")) {
                if ($line -imatch "Max IOPS of each mode") {
                    $maxIOPSforMode = $true
                    $maxIOPSforBlockSize = $false
                    $fioData = $false
                }
                if ($line -imatch "Max IOPS of each BlockSize") {
                    $maxIOPSforMode = $false
                    $maxIOPSforBlockSize = $true
                    $fioData = $false
                }
                if ($line -imatch "Iteration,TestType,BlockSize") {
                    $maxIOPSforMode = $false
                    $maxIOPSforBlockSize = $false
                    $fioData = $true
                }
                if ($maxIOPSforMode) {
                    Add-Content -Value $line -Path $LogDir\maxIOPSforMode.csv
                }
                if ($maxIOPSforBlockSize) {
                    Add-Content -Value $line -Path $LogDir\maxIOPSforBlockSize.csv
                }
                if ($fioData) {
                    Add-Content -Value $line -Path $LogDir\fioData.csv
                }
            }
            $fioDataCsv = Import-Csv -Path $LogDir\fioData.csv
            $TestDate = $(Get-Date -Format yyyy-MM-dd)
            $TestCaseName = $GlobalConfig.Global.$TestPlatform.ResultsDatabase.testTag
            if (!$TestCaseName) {
                $TestCaseName = $CurrentTestData.testName
            }
            for ($QDepth = $startThread; $QDepth -le $maxThread; $QDepth *= 2) {
                Write-LogInfo "Collected performance data for $QDepth QDepth."
                $resultMap = @{}
                $resultMap["TestCaseName"] = $TestCaseName
                $resultMap["TestDate"] = $TestDate
                $resultMap["HostType"] = "Azure"
                $resultMap["HostBy"] = ($CurrentTestData.SetupConfig.TestLocation).Replace('"','')
                $resultMap["HostOS"] = cat "$LogDir\VM_properties.csv" | Select-String "Host Version"| %{$_ -replace ",Host Version,",""}
                $resultMap["GuestOSType"] = "Linux"
                $resultMap["GuestDistro"] = cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
                $resultMap["GuestSize"] = $AllVmData.InstanceSize
                $resultMap["KernelVersion"] = cat "$LogDir\VM_properties.csv" | Select-String "Kernel version"| %{$_ -replace ",Kernel version,",""}
                $resultMap["DiskSetup"] = 'RAID0:12xP30'
                $resultMap["BlockSize_KB"] = [Int]((($fioDataCsv |  where { $_.Threads -eq "$QDepth"} | Select BlockSize)[0].BlockSize).Replace("K",""))
                $resultMap["QDepth"] = $QDepth
                $resultMap["seq_read_iops"] = [Float](($fioDataCsv |  where { $_.TestType -eq "read" -and  $_.Threads -eq "$QDepth"} | Select ReadIOPS).ReadIOPS)
                $resultMap["seq_read_lat_usec"] = [Float](($fioDataCsv |  where { $_.TestType -eq "read" -and  $_.Threads -eq "$QDepth"} | Select MaxOfReadMeanLatency).MaxOfReadMeanLatency)
                $resultMap["rand_read_iops"] = [Float](($fioDataCsv |  where { $_.TestType -eq "randread" -and  $_.Threads -eq "$QDepth"} | Select ReadIOPS).ReadIOPS)
                $resultMap["rand_read_lat_usec"] = [Float](($fioDataCsv |  where { $_.TestType -eq "randread" -and  $_.Threads -eq "$QDepth"} | Select MaxOfReadMeanLatency).MaxOfReadMeanLatency)
                $resultMap["seq_write_iops"] = [Float](($fioDataCsv |  where { $_.TestType -eq "write" -and  $_.Threads -eq "$QDepth"} | Select WriteIOPS).WriteIOPS)
                $resultMap["seq_write_lat_usec"] = [Float](($fioDataCsv |  where { $_.TestType -eq "write" -and  $_.Threads -eq "$QDepth"} | Select MaxOfWriteMeanLatency).MaxOfWriteMeanLatency)
                $resultMap["rand_write_iops"] = [Float](($fioDataCsv |  where { $_.TestType -eq "randwrite" -and  $_.Threads -eq "$QDepth"} | Select WriteIOPS).WriteIOPS)
                $resultMap["rand_write_lat_usec"] = [Float](($fioDataCsv |  where { $_.TestType -eq "randwrite" -and  $_.Threads -eq "$QDepth"} | Select MaxOfWriteMeanLatency).MaxOfWriteMeanLatency)
                $resultMap["TestType"] = "NFS"
                $currentTestResult.TestResultData += $resultMap
            }
        } catch {
            $ErrorMessage =  $_.Exception.Message
            $ErrorLine = $_.InvocationInfo.ScriptLineNumber
            Write-LogInfo "EXCEPTION : $ErrorMessage at line: $ErrorLine"
        }
    } catch {
        $ErrorMessage =  $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        Write-LogInfo "EXCEPTION : $ErrorMessage at line: $ErrorLine"
    } finally {
        if (!$testResult) {
            $testResult = "Aborted"
        }
        $resultArr += $testResult
    }
    $currentTestResult.TestResult = Get-FinalResultHeader -resultarr $resultArr
    return $currentTestResult
}

Main
