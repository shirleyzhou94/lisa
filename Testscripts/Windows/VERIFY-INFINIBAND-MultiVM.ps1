# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
param([object] $AllVmData,
	[object] $CurrentTestData,
	[object] $TestProvider)

function Resolve-UninitializedIB {
	# SUSE, sometimes, needs to re-initializes IB port through rebooting
	if (-not @("UBUNTU").contains($global:detectedDistro)) {
		$endureSku = $CurrentTestData.TestParameters.param.Contains('endure_sku=yes')
		if ($endureSku) {
			Write-LogInfo "Endure SKU"
			$cmd = "ip addr show | grep 'eth1' | grep '172'"
		} else  {
			Write-LogInfo "SR-IOV SKU"
			$cmd = "lsmod | grep -P '^(?=.*mlx5_ib)(?=.*rdma_cm)(?=.*rdma_ucm)(?=.*ib_ipoib)'"
		}
		foreach ($VmData in $AllVMData) {
			$ibvOutput = ""
			$retries = 0
			while ($retries -lt 4) {
				$ibvOutput = Run-LinuxCmd -ip $VMData.PublicIP -port $VMData.SSHPort -username `
					$superUser -password $password $cmd -ignoreLinuxExitCode:$true -maxRetryCount 5
				if (-not $ibvOutput) {
					Write-LogWarn "IB is NOT initialized in $($VMData.RoleName)"
					if ($endureSku) {
						$cmdRestart = "systemctl restart waagent"
						Run-LinuxCmd -ip $VMData.PublicIP -port $VMData.SSHPort -username `
							$superUser -password $password $cmdRestart -ignoreLinuxExitCode:$true -maxRetryCount 5
						Start-Sleep -Seconds 30
					} else {
						$TestProvider.RestartAllDeployments($VmData)
						Start-Sleep -Seconds 20
					}
					$retries++
				} else {
					Write-LogInfo "IB is initialized in $($VMData.RoleName)"
					break
				}
			}
			if ($retries -eq 4) {
				Throw "After 3 reboots IB has NOT been initialized on $($VMData.RoleName)"
			}
		}
	}
}

function GetLogs {
	Copy-RemoteFiles -downloadFrom $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username $superUser `
		-password $password -download -downloadTo $LogDir -files "/root/TestExecution.log"
}

function Main {
	param (
		$AllVmData,
		$CurrentTestData
	)
	$resultArr = @()
	$global:CurrentTestResult = Create-TestResultObject
	# Define two different users in run-time
	$superUser="root"

	function Checking_Result {
		param (
			[Parameter(Mandatory=$true,
			ParameterSetName="")]
			[String[]]
			$Pattern,
			[Parameter(Mandatory=$true,
			ParameterSetName="")]
			[String[]]
			$Tag,
			[Parameter(Mandatory=$false,
			ParameterSetName=$null)]
			[String[]]
			$SkippedPattern
		)

		$logFileName = "$LogDir\InfiniBand-Verification-$Iteration-$TempName\TestExecution.log"

		Write-LogInfo "Analyzing $logFileName"
		$metaData = "InfiniBand-Verification-$Iteration-$TempName : $Tag"
		$SuccessLogs = Select-String -Path $logFileName -Pattern $Pattern
		if ( $null -ne $SkippedPattern ) {
			$SkippedLogs = Select-String -Path $logFileName -Pattern $SkippedPattern
		}
		if ($SuccessLogs.Count -eq 1) {
			$currentResult = $resultPass
		} elseif (($SkippedLogs.Count -eq 1) -or ($global:QuickTestOnly -eq "yes")) {
			$currentResult = $resultSkipped
		} else {
			$currentResult = $resultFail
		}
		Write-LogInfo "$Pattern : $currentResult"
		$global:CurrentTestResult.TestSummary += New-ResultSummary -testResult $currentResult -metaData $metaData `
			-checkValues "PASS,FAIL,ABORTED,SKIPPED" -testName $global:CurrentTestData.testName
	}

	try {
		$NoServer = $true
		$NoClient = $true
		$ClientMachines = @()
		$SlaveInternalIPs = ""
		foreach ($VmData in $AllVMData) {
			if ($VmData.RoleName -imatch "controller") {
				$ServerVMData = $VmData
				$NoServer = $false
			} elseif ($VmData.RoleName -imatch "Client" -or $VmData.RoleName -imatch "dependency") {
				$ClientMachines += $VmData
				$NoClient = $false
				if ($SlaveInternalIPs) {
					$SlaveInternalIPs += "," + $VmData.InternalIP
				} else {
					$SlaveInternalIPs = $VmData.InternalIP
				}
			}
		}
		if ($NoServer) {
			Throw "No any server VM defined. Be sure that, `
			server VM role name matches with the pattern `"*server*`". Aborting Test."
		}
		if ($NoClient) {
			Throw "No any client VM defined. Be sure that, `
			client machine role names matches with pattern `"*client*`" Aborting Test."
		}
		if ($ServerVMData.InstanceSize -eq "Standard_NC24r") {
			Write-LogInfo "Waiting 5 minutes to finish RDMA update for NCv1 VMs."
			Start-Sleep -Seconds 300
		}

		#Skip test case against distro CLEARLINUX and COREOS based here https://docs.microsoft.com/en-us/azure/virtual-machines/linux/sizes-hpc
		if (@("CLEARLINUX", "COREOS", "DEBIAN").contains($global:detectedDistro)) {
			Write-LogInfo "$($global:detectedDistro) is not supported! Test skipped!"
			return "SKIPPED"
		}

		# Ubuntu extra step: make sure the VM supports RDMA
		if (@("UBUNTU").contains($global:detectedDistro)) {
			$cmd = "lsb_release -r | awk '{print `$2}'"
			$release = Run-LinuxCmd -ip $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username `
				$user -password $password $cmd -ignoreLinuxExitCode:$true -maxRetryCount 5
			if ($release.Split(".")[0] -lt "16") {
				Write-LogInfo "Ubuntu $release is not supported! Test skipped"
				return "SKIPPED"
			}
		}

		# IBM Platform MPI shows 32-bit binary complexity in Ubuntu
		if (@("UBUNTU").contains($global:detectedDistro) -and ($MpiType -eq "ibm")) {
			Write-LogInfo "$($global:detectedDistro) is not supported IBM Platform MPI! Test skipped!"
			return "SKIPPED"
		}

		$VM_Size = ($ServerVMData.InstanceSize -split "_")[1] -replace "[^0-9]",''
		Write-LogInfo "Getting VM instance size: $VM_Size"
		#region CONFIGURE VMs for TEST

		Write-LogInfo "SERVER VM details :"
		Write-LogInfo "  RoleName : $($ServerVMData.RoleName)"
		Write-LogInfo "  Public IP : $($ServerVMData.PublicIP)"
		Write-LogInfo "  SSH Port : $($ServerVMData.SSHPort)"
		$i = 1
		foreach ( $ClientVMData in $ClientMachines ) {
			Write-LogInfo "CLIENT VM #$i details :"
			Write-LogInfo "  RoleName : $($ClientVMData.RoleName)"
			Write-LogInfo "  Public IP : $($ClientVMData.PublicIP)"
			Write-LogInfo "  SSH Port : $($ClientVMData.SSHPort)"
			$i += 1
		}
		$FirstRun = $true
		Provision-VMsForLisa -AllVMData $AllVMData -installPackagesOnRoleNames "none"
		foreach ($VmData in $AllVMData) {
			Run-LinuxCmd -ip $VMData.PublicIP -port $VMData.SSHPort -username $superUser -password `
				$password -maxRetryCount 5 "echo $($VmData.RoleName) > /etc/hostname" | Out-Null
			if ($VmData.RoleName -imatch "Client" -or $VmData.RoleName -imatch "dependency"){
				Run-LinuxCmd -ip $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username $superUser -password $password `
					-maxRetryCount 5 "echo '$($VmData.InternalIP) $($VmData.RoleName)' >> /etc/hosts" | Out-Null
			}
		}
		#endregion

		#region Generate constants.sh
		# We need to add extra parameters to constants.sh file apart from parameter properties defined in XML.
		# Hence, we are generating constants.sh file again in test script.
		$ExpectedSuccessCount = 1
		$ImbMpiTestIterations = 1
		$ImbRmaTestIterations = 1
		$ImbNbcTestIterations = 1
		$ImbP2pTestIterations = 1
		$ImbIoTestIterations = 1
		$OmbP2PTestIterations = 1
		$InfinibandNics = @("eth0")
		$MpiType = ""
		$BenchmarkType = "IMB"
		$installOFEDFromExtension = $false
		$QuickTestOnly = "no"
		$IsNDTest = "no"

		Write-LogInfo "Generating constants.sh ..."
		$constantsFile = "$LogDir\constants.sh"
		foreach ($TestParam in $CurrentTestData.TestParameters.param) {
			Add-Content -Value "$TestParam" -Path $constantsFile
			Write-LogInfo "$TestParam added to constants.sh"
			if ($TestParam -imatch "imb_mpi1_tests_iterations") {
				$ImbMpiTestIterations = [int]($TestParam.Replace("imb_mpi1_tests_iterations=", "").Trim('"'))
			}
			if ($TestParam -imatch "imb_rma_tests_iterations") {
				$ImbRmaTestIterations = [int]($TestParam.Replace("imb_rma_tests_iterations=", "").Trim('"'))
			}
			if ($TestParam -imatch "imb_nbc_tests_iterations") {
				$ImbNbcTestIterations = [int]($TestParam.Replace("imb_nbc_tests_iterations=", "").Trim('"'))
			}
			if ($TestParam -imatch "imb_p2p_tests_iterations") {
				$ImbP2pTestIterations = [int]($TestParam.Replace("imb_p2p_tests_iterations=", "").Trim('"'))
			}
			if ($TestParam -imatch "imb_io_tests_iterations") {
				$ImbIoTestIterations = [int]($TestParam.Replace("imb_io_tests_iterations=", "").Trim('"'))
			}
			if ($TestParam -imatch "omb_p2p_tests_iterations") {
				$OmbP2PTestIterations = [int]($TestParam.Replace("omb_p2p_tests_iterations=", "").Trim('"'))
			}
			if ($TestParam -imatch "ib_nics") {
				$InfinibandNicsRaw = [string]($TestParam.Replace("ib_nics=", "").Trim('"'))
				$InfinibandNics = $InfinibandNicsRaw.Split(" ")
			}
			if ($TestParam -imatch "num_reboot") {
				$RemainingRebootIterations = [string]($TestParam.Replace("num_reboot=", "").Trim('"'))
				$ExpectedSuccessCount = [int]($TestParam.Replace("num_reboot=", "").Trim('"')) + 1
			}
			if ($TestParam -imatch "mpi_type") {
				$MpiType = [string]($TestParam.Replace("mpi_type=", "").Trim('"'))
			}
			if ($TestParam -imatch "benchmark_type") {
				$BenchmarkType = [string]($TestParam.Replace("benchmark_type=", "").Trim('"'))
			}
			if ($TestParam -imatch "install_ofed_from_extension") {
				if($TestParam.Split("=")[1] -match "yes") {
					$installOFEDFromExtension = $true
				} else {
					$installOFEDFromExtension = $false
				}
			}
			if ($TestParam -imatch "quicktest_only") {
				$QuickTestOnly = [string]($TestParam.Replace("quicktest_only=", "").Trim('"'))
			}
			if ($TestParam -imatch "endure_sku") {
				$IsNDTest = [string]($TestParam.Replace("endure_sku=", "").Trim('"'))
			}
			if ($TestParam -imatch "usehpcimage") {
				$UseHPCImage = [string]($TestParam.Replace("usehpcimage=", "").Trim('"'))
			}
		}
		Add-Content -Value "master=`"$($ServerVMData.InternalIP)`"" -Path $constantsFile
		Write-LogInfo "master=$($ServerVMData.InternalIP) added to constants.sh"
		Add-Content -Value "slaves=`"$SlaveInternalIPs`"" -Path $constantsFile
		Write-LogInfo "slaves=$SlaveInternalIPs added to constants.sh"
		Add-Content -Value "VM_Size=`"$VM_Size`"" -Path $constantsFile
		Write-LogInfo "VM_Size=$VM_Size added to constants.sh"
		if ($IsNDTest -eq $null) {
			$IsNDTest = "no"
		}

		# Abort, ND test only support H16r, H16mr and NC24r
		if (($IsNDTest -eq "yes") -and ($ServerVMData.InstanceSize -notmatch "Standard_H16(r|mr)*$") -and ($ServerVMData.InstanceSize -notmatch "Standard_NC24r")) {
			throw "$ServerVMData.InstanceSize does not support ND test."
		}

		# A100 has 8 NICs, need special handle
		if($VM_Size -eq "96") {
			Add-Content -Value "a100_sku=yes" -Path $constantsFile
			Write-LogInfo "a100_sku=yes added to constants.sh"
		}
		
		Add-Content -Value "usehpcimage=`"$UseHPCImage`"" -Path $constantsFile
		Write-LogInfo "usehpcimage=$UseHPCImage added to constants.sh"

		Write-LogInfo "constants.sh created successfully..."
		#endregion

		#region Upload files to master VM
		foreach ($VMData in $AllVMData) {
			Copy-RemoteFiles -uploadTo $VMData.PublicIP -port $VMData.SSHPort `
				-files "$constantsFile,$($CurrentTestData.files)" -username $superUser -password $password -upload
		}
		#endregion

		if ($installOFEDFromExtension) {
			foreach ($VMData in $AllVMData) {
				$install_Output = Set-AzVMExtension -ResourceGroupName $VMData.ResourceGroupName -Location $CurrentTestData.SetupConfig.TestLocation -VMName $VMData.RoleName `
					-ExtensionName "InfiniBandDriverLinux" -Publisher "Microsoft.HpcCompute" -Type "InfiniBandDriverLinux" -TypeHandlerVersion "1.0"
				if ($install_Output.StatusCode -ne "OK") {
					Throw "Extension InfiniBandDriverLinux install failed on $($VMData.RoleName)!"
				}
			}
		}

		Write-LogInfo "SetupRDMA.sh is called"
		# Call SetupRDMA.sh here, and it handles all packages, MPI, Benchmark installation.
		foreach ($VMData in $AllVMData) {
			Run-LinuxCmd -ip $VMData.PublicIP -port $VMData.SSHPort -username $superUser `
				-password $password "/root/SetupRDMA.sh" -RunInBackground | Out-Null
			Wait-Time -seconds 2
		}

		$timeout = New-Timespan -Minutes 120
		$sw = [diagnostics.stopwatch]::StartNew()
		while ($sw.elapsed -lt $timeout){
			$vmCount = $AllVMData.Count
			foreach ($VMData in $AllVMData) {
				Wait-Time -seconds 60
				$state = Run-LinuxCmd -ip $VMData.PublicIP -port $VMData.SSHPort -username $user -password $password "cat /root/state.txt" -MaxRetryCount 5 -runAsSudo
				if ($state -eq "TestCompleted") {
					$setupRDMACompleted = Run-LinuxCmd -ip $VMData.PublicIP -port $VMData.SSHPort -username $user -password $password `
						-maxRetryCount 5 "cat /root/constants.sh | grep setup_completed=0" -runAsSudo
					if ($setupRDMACompleted -ne "setup_completed=0") {
						GetLogs
						Throw "SetupRDMA.sh run finished on $($VMData.RoleName) but setup was not successful!"
					}
					Write-LogInfo "SetupRDMA.sh finished on $($VMData.RoleName)"
					$vmCount--
				}

				if ($state -eq "TestSkipped") {
					Write-LogInfo "SetupRDMA finished with SKIPPED state!"
					GetLogs
					return $resultSkipped
				}

				if (($state -eq "TestFailed") -or ($state -eq "TestAborted")) {
					Write-LogErr "SetupRDMA.sh didn't finish successfully!"
					GetLogs
					return $resultAborted
				}
			}
			if ($vmCount -eq 0){
				break
			}
			Write-LogInfo "SetupRDMA.sh is still running on $vmCount VM(s)!"
		}
		if ($vmCount -eq 0){
			Write-LogInfo "SetupRDMA.sh is done"
		} else {
			Throw "SetupRDMA.sh didn't finish at least on one VM!"
		}

		# Reboot VM to apply RDMA changes
		Write-LogInfo "Rebooting All VMs!"
		$TestProvider.RestartAllDeployments($AllVMData)

		# In some cases, IB will not be initialized after reboot
		if ($IsNDTest -eq "no") {
			Resolve-UninitializedIB
		}
		$TotalSuccessCount = 0
		$Iteration = 0
		do {
			if ($FirstRun) {
				$FirstRun = $false
				$ContinueMPITest = $true
				foreach ($ClientVMData in $ClientMachines) {
					Write-LogInfo "Getting initial MAC address info from $($ClientVMData.RoleName)"
					foreach ($InfinibandNic in $InfinibandNics) {
						Run-LinuxCmd -ip $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username $superUser `
							-password $password -maxRetryCount 5 "ip addr show $InfinibandNic | grep ether | awk '{print `$2}' > InitialInfiniBandMAC-$InfinibandNic.txt"
					}
				}
			} else {
				$ContinueMPITest = $true
				if($VM_Size -ne "96") { # skip checking for A100: ib nic name is random (e.g.ibP257s154020)
					foreach ($ClientVMData in $ClientMachines) {
						Write-LogInfo "Step 1/2: Getting current MAC address info from $($ClientVMData.RoleName)"
						foreach ($InfinibandNic in $InfinibandNics) {
							$CurrentMAC = Run-LinuxCmd -ip $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username $superUser `
								-password $password -maxRetryCount 5 "ip addr show $InfinibandNic | grep ether | awk '{print `$2}'"
							$InitialMAC = Run-LinuxCmd -ip $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username $superUser `
								-password $password -maxRetryCount 5 "cat InitialInfiniBandMAC-$InfinibandNic.txt"
							if ($CurrentMAC -eq $InitialMAC) {
								Write-LogInfo "Step 2/2: MAC address verified in $($ClientVMData.RoleName)."
							} else {
								Write-LogErr "Step 2/2: MAC address swapped / changed in $($ClientVMData.RoleName)."
								$ContinueMPITest = $false
							}
						}
					}
				}
			}

			if ($ContinueMPITest) {
				#region EXECUTE TEST
				$Iteration += 1
				Write-LogInfo "******************Iteration - $Iteration/$ExpectedSuccessCount*******************"
				$TestJob = Run-LinuxCmd -ip $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username $superUser `
					-password $password -command "/root/TestRDMA_MultiVM.sh" -RunInBackground
				#endregion

				#region MONITOR TEST
				$backOffWait = 10
				$maxBackOffWait = 10 * 60
				while ((Get-Job -Id $TestJob).State -eq "Running") {
					$CurrentStatus = Run-LinuxCmd -ip $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username $superUser `
						-password $password -maxRetryCount 5 -command "tail -n 1 /root/TestExecution.log"
					Write-LogInfo "Current Test Status : $CurrentStatus"
					$temp=(Get-Job -Id $TestJob).State
					Write-LogInfo "--------------------------------------------------------------------$temp-------------------------"
					$FinalStatus = Run-LinuxCmd -ip $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username $superUser `
					-password $password -maxRetryCount 5 -command "cat /$superUser/state.txt"
					Write-LogInfo "$FinalStatus"
					Wait-Time -seconds $backOffWait
					if ($FinalStatus -ne "TestRunning") {
						Write-LogInfo "TestRDMA_MultiVM.sh finished the run!"
						break
					}
					$backOffWait = [math]::min($backOffWait*2, $maxBackOffWait)
				}

				$temp=(Get-Job -Id $TestJob).State
					Write-LogInfo "--------------------------------------------------------------------$temp-------------------------"
				Copy-RemoteFiles -downloadFrom $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username $superUser `
					-password $password -download -downloadTo $LogDir -files "/root/Setup-TestExecution*.log"
				Copy-RemoteFiles -downloadFrom $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username $superUser `
					-password $password -download -downloadTo $LogDir -files "/root/TestExecution*.log"
				Copy-RemoteFiles -downloadFrom $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username $superUser `
					-password $password -download -downloadTo $LogDir -files "/root/kernel-logs-*"
				Copy-RemoteFiles -downloadFrom $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username $superUser `
					-password $password -download -downloadTo $LogDir -files "/root/state.txt"
				# foreach ($InfinibandNic in $InfinibandNics) {
				# 	Copy-RemoteFiles -downloadFrom $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username $superUser `
				# 		-password $password -download -downloadTo $LogDir -files "/root/$InfiniBandNic-status*"
				# }
				Copy-RemoteFiles -downloadFrom $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username $superUser `
					-password $password -download -downloadTo $LogDir -files "/root/*-status*.txt"
				if ( $IsNDTest -eq "no" ) {
					Copy-RemoteFiles -downloadFrom $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username $superUser `
						-password $password -download -downloadTo $LogDir -files "/root/IMB*"
				}
				if ($BenchmarkType -eq "OMB") {
					Copy-RemoteFiles -downloadFrom $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username $superUser `
						-password $password -download -downloadTo $LogDir -files "/root/OMB*"
				}

				$ConsoleOutput = ( Get-Content -Path "$LogDir\TestExecution.log" | Out-String )
				$FinalStatus = Run-LinuxCmd -ip $ServerVMData.PublicIP -port $ServerVMData.SSHPort -username $superUser `
					-password $password -maxRetryCount 5 -command "cat /$superUser/state.txt"
				if ($Iteration -eq 1) {
					$TempName = "FirstBoot"
				} else {
					$TempName = "Reboot"
				}

				New-Item -Path "$LogDir\InfiniBand-Verification-$Iteration-$TempName" -Force -ItemType Directory | Out-Null
				# foreach ($InfinibandNic in $InfinibandNics) {
				# 	Move-Item -Path "$LogDir\$InfiniBandNic-status*" -Destination "$LogDir\InfiniBand-Verification-$Iteration-$TempName" | Out-Null
				# }
				Move-Item -Path "$LogDir\*-status*.txt" -Destination "$LogDir\InfiniBand-Verification-$Iteration-$TempName" | Out-Null
				if ( $IsNDTest -eq "no" ) {
					Move-Item -Path "$LogDir\IMB*" -Destination "$LogDir\InfiniBand-Verification-$Iteration-$TempName" | Out-Null
				}
				Move-Item -Path "$LogDir\kernel-logs-*" -Destination "$LogDir\InfiniBand-Verification-$Iteration-$TempName" | Out-Null
				Move-Item -Path "$LogDir\TestExecution*.log" -Destination "$LogDir\InfiniBand-Verification-$Iteration-$TempName" | Out-Null
				Move-Item -Path "$LogDir\Setup-TestExecution*.log" -Destination "$LogDir\InfiniBand-Verification-$Iteration-$TempName" | Out-Null
				Move-Item -Path "$LogDir\state.txt" -Destination "$LogDir\InfiniBand-Verification-$Iteration-$TempName" | Out-Null
				if ($BenchmarkType -eq "OMB") {
					Move-Item -Path "$LogDir\OMB*" -Destination "$LogDir\InfiniBand-Verification-$Iteration-$TempName" | Out-Null
				}

				#region Check if IB driver was correcly set up
				$logFileName = "$LogDir\InfiniBand-Verification-$Iteration-$TempName\TestExecution.log"
				$pattern = "INFINIBAND_VERIFICATION_FAILED_IBDRIVER"
				Write-LogInfo "Analyzing $logFileName"
				$metaData = "InfiniBand-Verification-$Iteration-$TempName : IB Driver"
				$SucessLogs = Select-String -Path $logFileName -Pattern $pattern
				if ($SucessLogs.Count -eq 1) {
					$currentResult = $resultFail
				} else {
					$currentResult = $resultPass
				}
				Write-LogInfo "$pattern : $currentResult"
				$global:CurrentTestResult.TestSummary += New-ResultSummary -testResult $currentResult -metaData $metaData `
					-checkValues "PASS,FAIL,ABORTED" -testName $CurrentTestData.testName
				#endregion

				#region Check if $InfinibandNic got IP address
				$currentResult = $resultPass
				Write-LogInfo "Analyzing $logFileName"
				$metaData = "InfiniBand-Verification-$Iteration-$TempName : IB NIC IP"
				foreach ($InfinibandNic in $InfinibandNics) {
					$pattern = "INFINIBAND_VERIFICATION_SUCCESS_$InfinibandNic"
					$SucessLogs = Select-String -Path $logFileName -Pattern $pattern
					if ($SucessLogs.Count -eq 1) {
						Write-LogInfo "$pattern : $resultPass"
					} else {
						Write-LogInfo "$pattern : $resultFail"
						$currentResult = $resultFail
					}
				}
				$global:CurrentTestResult.TestSummary += New-ResultSummary -testResult $currentResult -metaData $metaData `
				-checkValues "PASS,FAIL,ABORTED" -testName $CurrentTestData.testName
				#endregion

				#region Check ibv_ping_pong tests
				$pattern = "INFINIBAND_VERIFICATION_SUCCESS_IBV_PINGPONG"
				Write-LogInfo "Analyzing $logFileName"
				$metaData = "InfiniBand-Verification-$Iteration-$TempName : IBV_PINGPONG"
				if ( $IsNDTest -eq "yes" ) {
					$currentResult = $resultSkipped
				} else {
					$SuccessLogs = Select-String -Path $logFileName -Pattern $pattern
					if ($SuccessLogs.Count -eq 1) {
						$currentResult = $resultPass
					} else {
						# Get the actual tests that failed and output them
						$failedPingPongIBV = Select-String -Path $logFileName -Pattern '(_pingpong.*Failed)'
						foreach ($failedTest in $failedPingPongIBV) {
							Write-LogErr "$($failedTest.Line.Split()[-7..-1])"
						}
						$currentResult = $resultFail
					}
				}
				Write-LogInfo "$pattern : $currentResult"
				$global:CurrentTestResult.TestSummary += New-ResultSummary -testResult $currentResult -metaData $metaData `
					-checkValues "PASS,FAIL,ABORTED,SKIPPED" -testName $CurrentTestData.testName
				#endregion

				if ($BenchmarkType -eq "IMB") {
					#region Check MPI pingpong intranode tests
					Checking_Result "INFINIBAND_VERIFICATION_SUCCESS_IMB_MPI1_INTRANODE" "IMB PingPong Intranode" "INFINIBAND_VERIFICATION_SKIPPED_IMB_MPI1_INTRANODE"
					#endregion

					#region Check MPI1 all nodes tests
					if ($ImbMpiTestIterations -ge 1) {
						Checking_Result "INFINIBAND_VERIFICATION_SUCCESS_IMB_MPI1_ALLNODES" "IMB-MPI1" "INFINIBAND_VERIFICATION_SKIPPED_IMB_MPI1_ALLNODES"
					}
					#endregion

					#region Check IMB P2P all nodes tests
					if ($ImbP2pTestIterations -ge 1) {
						Checking_Result "INFINIBAND_VERIFICATION_SUCCESS_IMB_P2P_ALLNODES" "IMB-P2P" "INFINIBAND_VERIFICATION_SKIPPED_IMB_P2P_ALLNODES"
					}
					#endregion

					#region Check IO all nodes tests
					if ($ImbIoTestIterations -ge 1) {
						Checking_Result "INFINIBAND_VERIFICATION_SUCCESS_IMB_IO_ALLNODES" "IMB-IO" "INFINIBAND_VERIFICATION_SKIPPED_IMB_IO_ALLNODES"
					}
					#endregion

					#region Check RMA all nodes tests
					if ($ImbRmaTestIterations -ge 1) {
						Checking_Result "INFINIBAND_VERIFICATION_SUCCESS_IMB_RMA_ALLNODES" "IMB-RMA" "INFINIBAND_VERIFICATION_SKIPPED_IMB_RMA_ALLNODES"
					}
					#endregion

					#region Check NBC all nodes tests
					if ($ImbNbcTestIterations -ge 1) {
						Checking_Result "INFINIBAND_VERIFICATION_SUCCESS_IMB_NBC_ALLNODES" "IMB-NBC" "INFINIBAND_VERIFICATION_SKIPPED_IMB_NBC_ALLNODES"
					}
					#endregion
				} elseif ($BenchmarkType -eq "OMB") {
					#region Check OMB P2P all nodes tests
					if ($OmbP2PTestIterations -ge 1) {
						Checking_Result "INFINIBAND_VERIFICATION_SUCCESS_OMB_P2P_ALLNODES" "OMB-P2P" "INFINIBAND_VERIFICATION_SKIPPED_OMB_P2P_ALLNODES"
					}
					#endregion
				}

				if ($FinalStatus -imatch "TestCompleted") {
					Write-LogInfo "Test finished successfully."
					Write-LogInfo $ConsoleOutput
				} else {
					Write-LogErr "Test failed."
					Write-LogErr $ConsoleOutput
				}
				#endregion
			} else {
				$FinalStatus = "TestFailed"
			}

			if ($FinalStatus -imatch "TestFailed") {
				Write-LogErr "Test failed. Last known status : $CurrentStatus."
				$testResult = $resultFail
			} elseif ($FinalStatus -imatch "TestAborted") {
				Write-LogErr "Test ABORTED. Last known status : $CurrentStatus."
				$testResult = $resultAborted
				return $resultAborted
			} elseif ($FinalStatus -imatch "TestCompleted") {
				Write-LogInfo "Test Completed. Result : $FinalStatus."
				$testResult = $resultPass
				$TotalSuccessCount += 1
			} elseif ($FinalStatus -imatch "TestRunning") {
				Write-LogInfo "PowerShell background job for test is completed but VM is reporting that test is still running. Please check $LogDir\mdConsoleLogs.txt"
				Write-LogInfo "Contests of state.txt : $FinalStatus"
				$testResult = $resultFail
			}
			Write-LogInfo "**********************************************"
			if ($RemainingRebootIterations -gt 0) {
				if ($testResult -eq "PASS") {
					$TestProvider.RestartAllDeployments($AllVMData)
					# In some cases, IB will not be initialized after reboot
					if ($IsNDTest -eq "no") {
						Resolve-UninitializedIB
					}
					$RemainingRebootIterations -= 1
				} else {
					Write-LogErr "Stopping the test due to failures."
				}
			}
		}
		while (($ExpectedSuccessCount -ne $Iteration) -and ($testResult -eq "PASS"))

		if ($ExpectedSuccessCount -eq $TotalSuccessCount) {
			$testResult = $resultPass
		} else {
			$testResult = $resultFail
		}
		$resultArr += $testResult
		Write-LogInfo "Test Completed"
		Write-LogInfo "Test result : $testResult"
	} catch {
		$ErrorMessage =  $_.Exception.Message
		$ErrorLine = $_.InvocationInfo.ScriptLineNumber
		Write-LogErr "EXCEPTION : $ErrorMessage at line: $ErrorLine"
	} finally {
		if (!$testResult) {
			$testResult = $resultAborted
		}
		$resultArr = $testResult
	}
	$global:CurrentTestResult.TestResult = Get-FinalResultHeader -resultarr $resultArr
	return $global:CurrentTestResult
}

Main -AllVmData $AllVmData -CurrentTestData $CurrentTestData