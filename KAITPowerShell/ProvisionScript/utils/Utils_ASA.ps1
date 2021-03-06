<#
	.SYNOPSIS
		Provies helper functions for Stream Analytics scripting

	.Created
		3/23/2015 - Mike Veazie
#>

if(!$__IsLoadedASA__)
{
	# Flag to keep track if we've loaded these or not
	New-Variable -Name "__IsLoadedASA__" -Option:ReadOnly -Scope "Script" -Value $true -Force
	
	. .\utils\Constants.ps1
	. .\utils\Utils_Shared.ps1
	. .\utils\Utils_EH.ps1
	. .\utils\Utils_Storage.ps1
	
	Function Create-AzureStreamAnalyticsJobs
	{
		#make sure we're in service management mode to start off with
		Switch-AzureMode -Name AzureServiceManagement
		
		$resourceGroupName = Concat-AzurePrefix -Text $global:AzureProvisionSettings.StreamAnalytics.ResourceGroup	

		#Create each defined top level job
		foreach($job in $global:AzureProvisionSettings.StreamAnalytics.Jobs)
		{
			$jobName = Concat-AzurePrefix -Text $job.Name
			$job.Name = $jobName

			try
			{
				"Creating ASA Job '{0}." -f $jobName | Trace			
				#update each input for the job
				foreach($input in $job.Properties.Inputs)
				{
					#We need to update the json to have the azure prefix, and connection strings
					$input.Properties.Datasource.Properties.ServiceBusNamespace = Concat-AzurePrefix -Text $input.Properties.Datasource.Properties.ServiceBusNamespace
					
					#Getting/setting the shared access key
					$appSettingsKey = Get-AzureEventHubAppSettingsKey -EventHubName $input.Properties.Datasource.Properties.EventHubName -PolicyName $input.Properties.Datasource.Properties.SharedAccessPolicyName
					$asaManageConnectionString = Get-AzureAppSettingValue -Key $appSettingsKey
					$sharedAccessKeyPart = $asaManageConnectionString.Split(';') | ?{$_ -like 'SharedAccessKey=*'}				
					$input.Properties.Datasource.Properties.SharedAccessPolicyKey = $sharedAccessKeyPart.Substring($sharedAccessKeyPart.IndexOf('=') + 1)
				}
				
				#update each output for the job
				foreach($output in $job.Properties.Outputs)
				{
					#We need to update the storage accounts to have the azure prefix, and connection string key
					for($i = 0; $i -lt $output.Properties.Datasource.Properties.StorageAccounts.Count;$i++)
					{
						$storageAccountName = (Concat-AzurePrefix -Text $output.Properties.Datasource.Properties.StorageAccounts[$i].AccountName).ToLower()
						$output.Properties.Datasource.Properties.StorageAccounts[$i].AccountName = $storageAccountName
						$primaryStorageKey = (Get-AzureStorageKey -StorageAccountName $storageAccountName -ErrorAction:Continue).Primary
						$output.Properties.Datasource.Properties.StorageAccounts[$i].AccountKey = $primaryStorageKey
					}
					
					#we need to update Event Hub output with azure prefix and shared access key
					if($output.Properties.Datasource.Type -eq "Microsoft.ServiceBus/EventHub")
					{
						#We need to update the json to have the azure prefix, and connection strings
						$output.Properties.Datasource.Properties.ServiceBusNamespace = Concat-AzurePrefix -Text $output.Properties.Datasource.Properties.ServiceBusNamespace
						
						#Getting/setting the shared access key
						$appSettingsKey = Get-AzureEventHubAppSettingsKey -EventHubName $output.Properties.Datasource.Properties.EventHubName -PolicyName $output.Properties.Datasource.Properties.SharedAccessPolicyName
						$asaManageConnectionString = Get-AzureAppSettingValue -Key $appSettingsKey
						$sharedAccessKeyPart = $asaManageConnectionString.Split(';') | ?{$_ -like 'SharedAccessKey=*'}				
						$output.Properties.Datasource.Properties.SharedAccessPolicyKey = $sharedAccessKeyPart.Substring($sharedAccessKeyPart.IndexOf('=') + 1)
					}
				}
				
				# generate temp file name that will contain the ASA job configuration
				$tempAsaObjectFile = Join-Path -Path $Env:TEMP -ChildPath ([String]::Concat($jobName,".tmp"))
	
				#We'll need to concat these parameters in order to create an ASA job 
				$asaCommand = 'New-AzureStreamAnalyticsJob -ResourceGroupName "<resourceGroupName>" –File "<asaFile>"' 
				$asaCommand = $asaCommand.Replace('<resourceGroupName>', $resourceGroupName)
				$asaCommand = $asaCommand.Replace('<asaFile>', $tempAsaObjectFile)
	
				# Save the fully configured Job JSON out
				# Setting depth to 20 to ensure we never run into a deserialization issue. There is no performance impact here due to the small objects
				$job | ConvertTo-Json -Depth 20 | Out-File -FilePath $tempAsaObjectFile -Force

				# The ASA cmdlets are only available in the AzureResourceMode module
				# It is not supported to import both AzureResourceMode and the primary Azure PowerShell modules
				Switch-AzureMode -Name AzureResourceManager
				
				$resourceGroup = Get-AzureResourceGroup -Name $resourceGroupName -ErrorAction:SilentlyContinue
				if($resourceGroup -eq $null)
				{
					#build the command to create the resource group
					$resourceGroupCommand = 'New-AzureResourceGroup -Location "<locationName>" -Name "<resourceGroupName>" -Force'
					$resourceGroupCommand = $resourceGroupCommand.Replace('<resourceGroupName>', $resourceGroupName)
					$resourceGroupCommand = $resourceGroupCommand.Replace('<locationName>', $job.Location)

					"Running Cmdlet: `r`n{0}" -f $resourceGroupCommand
					Invoke-Expression -Command $resourceGroupCommand -ErrorAction:Continue
				}

				# Make sure the ASA provider is registered with this subscription before running any ASA commands
				Register-AzureProvider -ProviderNamespace Microsoft.StreamAnalytics -Force

				"Running Cmdlet: `r`n{0}" -f $asaCommand
				Invoke-Expression -Command $asaCommand -ErrorAction:Continue
				
				# create powershell command to start the job
				$asaCommand = 'Start-AzureStreamAnalyticsJob -ResourceGroupName "<resourceGroupName>" -Name "<jobName>" -OutputStartMode JobStartTime'
				$asaCommand = $asaCommand.Replace('<resourceGroupName>', $resourceGroupName)
				$asaCommand = $asaCommand.Replace('<jobName>', $jobName)

				"Running Cmdlet: `r`n{0}" -f $asaCommand
				Invoke-Expression -Command $asaCommand -ErrorAction:Continue

				# switch back to service management
				Switch-AzureMode -Name AzureServiceManagement
	
				#Clean house
				#Remove-Item -LiteralPath $tempAsaObjectFile -Confirm:$false -Force
			}
			catch [System.Exception]
			{
				"An exception ocurred while creating ASA Job '{0}'. Message: '{1}'" -f $jobName, $_.Exception.Message | Trace -Severity:Exception
			}
		}
	}

	Function Delete-AzureStreamAnalyticsJobs
	{
		"Deleting Azure Stream Analytics Jobs..." | Trace

		# The ASA cmdlets are only available in the AzureResourceMode module
		Switch-AzureMode -Name AzureResourceManager

		foreach($job in $global:AzureProvisionSettings.StreamAnalytics.Jobs)
		{
			$jobName = Concat-AzurePrefix -Text $job.Name
			$resourceGroupName = Concat-AzurePrefix -Text $global:AzureProvisionSettings.StreamAnalytics.ResourceGroup	
			$asaJob = Get-AzureStreamAnalyticsJob -ResourceGroupName $resourceGroupName -Name $jobName

			if($asaJob -eq $null)
			{
				"Job '{0}' in resource group '{1}' was not found." -f $jobName, $resourceGroupName | Trace			
			}
			else
			{
				"Deleting '{0}' in resource group '{1}'." -f $jobName, $resourceGroupName | Trace
				Remove-AzureStreamAnalyticsJob -ResourceGroupName $resourceGroupName -Name $jobName -Force
			}
		}

		# switch back to service management
		Switch-AzureMode -Name AzureServiceManagement
	}
}
