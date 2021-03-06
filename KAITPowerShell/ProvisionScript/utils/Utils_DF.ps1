<#
	.SYNOPSIS
		Provies helper functions for Data Factory scripting

	.LINK
		http://azure.microsoft.com/en-us/documentation/articles/data-factory-monitor-manage-using-powershell/#CreateLinkedServices
		
	.Created
		3/23/2015 - Mike Veazie
#>

if(!$__IsLoadedDF__)
{
	# Flag to keep track if we've loaded these or not
	New-Variable -Name "__IsLoadedDF__" -Option:ReadOnly -Scope "Script" -Value $true -Force
	
	. .\utils\Constants.ps1
	. .\utils\Utils_Shared.ps1
	. .\utils\Utils_Storage.ps1
	
	Function Create-AzureDataFactoryAndPipelines
	{
		Param(
			[switch]$WaitForHDInsightCluster = $true,
			$HDInsightClusterWaitSeconds = 30
		)
		
		if($WaitForHDInsightCluster)
		{
			$clusterName = Concat-AzurePrefix -Text $global:AzureProvisionSettings.HDInsight.ClusterName
				
			do
			{
				$clusterReady = $false
				$cluster = Get-AzureHDInsightCluster -Name $clusterName -ErrorAction:SilentlyContinue
				if($cluster -ne $null)
				{
					if($cluster.State -eq 'Running')
					{
						$clusterReady = $true
					}
				}
				
				"Waiting for HDInsight Cluster '{0}' to be ready" -f $clusterName | Trace
				[System.Threading.Thread]::Sleep($HDInsightClusterWaitSeconds * 1000)
			}
			while(!$clusterReady)
			
			"HDInsight Cluster '{0}' is ready" -f $clusterName | Trace
		}
		
		#The data factory cmdlets are only available in the AzureResourceMode module
		#	It is not supported to import both AzureResourceMode and the primary Azure PowerShell modules
		Switch-AzureMode -Name AzureResourceManager
		
		# Make sure the ADF provider is registered with this subscription before running any ASA commands
		Register-AzureProvider -ProviderNamespace Microsoft.DataFactory -Force

		try
		{
			$dfSettings = $global:AzureProvisionSettings.DataFactory
			$resourceGroupName = Concat-AzurePrefix -Text $dfSettings.ResourceGroup
			$resourceGroup = Get-AzureResourceGroup -Name $resourceGroupName -ErrorAction:SilentlyContinue
			
			if($resourceGroup -eq $null)
			{
				$resourceGroup = New-AzureResourceGroup -Name $resourceGroupName -Location $dfSettings.Region -ErrorAction:Continue			
			}
			
			$dataFactoryName = Concat-AzurePrefix -Text $dfSettings.Name
			$dataFactory = Get-AzureDataFactory -Name $dataFactoryName -ResourceGroupName $resourceGroupName -ErrorAction:SilentlyContinue			
			
			if($dataFactory -eq $null)
			{
				$dataFactory = New-AzureDataFactory -Name $dataFactoryName -ResourceGroupName $resourceGroupName -Location $dfSettings.Region -ErrorAction:Continue
			}
			
			if($dataFactory -eq $null)
			{
				"The data factory could not be created" | Trace -Severity:Error
			}
			else			
			{
				"Creating data factory pipeline" | Trace
				
				#Each of the local directory can contain 0-M json files for each associated data factory object				
				#It's required to created the linked services first
				foreach($dfObject in $dfSettings.LinkedServices)
				{					
					Create-AzureDataFactoryObject -Type "LinkedService" -DataFactoryObject $dfObject -DataFactoryName $dataFactoryName -ResourceGroupName $resourceGroupName
				}
				
				"Creating data sets" | Trace
				
				#Create datasets second
				foreach($dfObject in $dfSettings.DataSets)
				{
					Create-AzureDataFactoryObject -Type "DataSet" -DataFactoryObject $dfObject -DataFactoryName $dataFactoryName -ResourceGroupName $resourceGroupName
				}
						
				"Creating pipelines" | Trace
				
				#Create pipelines third
				foreach($dfObject in $dfSettings.Pipelines)
				{
					Create-AzureDataFactoryObject -Type "Pipeline" -DataFactoryObject $dfObject -DataFactoryName $dataFactoryName -ResourceGroupName $resourceGroupName
				}
			}
		}
		catch [System.Exception]
		{
			"An exception ocurred while working with the data factory. Message: '{0}'" -f $_.Exception.Message | Trace -Severity:Exception
		}
		
		Switch-AzureMode -Name AzureServiceManagement
	}
		
	Function Create-AzureDataFactoryObject
	{
		Param(
			[Parameter()][ValidateSet('LinkedService','DataSet','Pipeline')][string]$Type,
			$DataFactoryObject,
			$DataFactoryName,
			$ResourceGroupName
		)
		
		try
		{
			#We're building the powershell cmdlet off of the parameters
			$cmdletTable = @{
				'LinkedService'='New-AzureDataFactoryLinkedService'
				'DataSet'='New-AzureDataFactoryDataset'
				'Pipeline'='New-AzureDataFactoryPipeline'
			}		
			
			#We will need to add the connection string to the data factory file if it's azure storage.
			if($DataFactoryObject.Properties.Type -eq "AzureStorage")
			{
				#We're just going to rebuild this connection string. If you download this file from Azure it will be starred out (****)
				#	Example: "connectionString": "DefaultEndpointsProtocol=https;AccountName=inceptiondata;AccountKey=**********",
				#	The account key will always be different when you provision the storage accounts as well
				$storageAccountName = (Concat-AzurePrefix -Text $DataFactoryObject.properties.typeProperties.connectionString).ToLower()
							
				#We need to switch back to the primary azure module to work with storage cmdlets
				Switch-AzureMode -Name AzureServiceManagement
				$connectionString = Get-AzureStorageConnectionString -StorageAccountName $storageAccountName
				Switch-AzureMode -Name AzureResourceManager
				
				$DataFactoryObject.properties.typeProperties.connectionString = $connectionString					
			}
			elseif($DataFactoryObject.Properties.Type -eq "HDInsight")
			{
				#Need to update the cluster Uri and credentials
				$hdiProvisionSettings = $global:AzureProvisionSettings.HDInsight				
				$clusterName = Concat-AzurePrefix -Text $hdiProvisionSettings.ClusterName
				
				$DataFactoryObject.properties.typeProperties.clusterUri = [string]::Concat('https://',$clusterName,'.azurehdinsight.net/')
				$DataFactoryObject.properties.typeProperties.userName = $hdiProvisionSettings.Admin
				$DataFactoryObject.properties.typeProperties.password = $hdiProvisionSettings.Password
			}
			elseif($Type -eq "Pipeline")
			{
				#Update each pipeline's start time to be StartProcessingMinutes minutes from creation. Datafactory is picky about formatting. This also needs to be UTC.
				$sliceStart = [System.DateTimeOffset]::UtcNow.DateTime.AddMinutes($global:AzureProvisionSettings.DataFactory.StartProcessingMinutes)
				$DataFactoryObject.Properties.Start = [string]::Concat($sliceStart.ToString("s"),"Z")
				$DataFactoryObject.Properties.End = [string]::Concat($sliceStart.AddDays(1).ToString("s"),"Z")
				
				"Pipeline '{0}' is scheduled to start at '{1} UTC'" -f $DataFactoryObject.Name, $DataFactoryObject.Properties.Start | Trace
				
				#Updating the extended properties on each activity
				for($i = 0; $i -lt $DataFactoryObject.Properties.Activities.Count;$i++)
				{
					if(!([string]::IsNullOrEmpty([string]$DataFactoryObject.Properties.Activities[$i].Transformation.ExtendedProperties.RawDataStorageAccount)))
					{
						$storageAccountName = (Concat-AzurePrefix -Text $DataFactoryObject.Properties.Activities[$i].Transformation.ExtendedProperties.RawDataStorageAccount).ToLower()
						"Activity '{0}' storage account updated to '{1}'" -f $DataFactoryObject.Properties.Activities[$i].Name, $storageAccountName | Trace						
						$DataFactoryObject.Properties.Activities[$i].Transformation.ExtendedProperties.RawDataStorageAccount = $storageAccountName
					}
				}
			}
					
			#Store this out in appdata/temp while we create this linked service. This contains the raw JSON
			$tempDFObjectFile = Join-Path -Path $Env:TEMP -ChildPath ([String]::Concat($DataFactoryObject.Name,".tmp"))
					
			#Save this back to a temp file so the connection string is now available. We'll create this linked service and then nuke this file
			#	Setting depth to 20 to ensure we never run into a deserialization issue. There is no performance impact here due to the small objects
			$DataFactoryObject | ConvertTo-Json -Depth 20 | Out-File -FilePath $tempDFObjectFile -Force
										
			"Creating {0} {1}" -f $Type, $DataFactoryObject.Name | Trace		
			$azureDfCmdlet = "{0} -File '{1}' -DataFactoryName '{2}' -ResourceGroupName '{3}' -Force -ErrorAction:Continue" -f $cmdletTable[$Type], $tempDFObjectFile, $DataFactoryName, $ResourceGroupName
			
			"Running Cmdlet: {0}" -f $azureDfCmdlet | Trace
			Invoke-Expression -Command $azureDfCmdlet
			
			#Clean house
			#Remove-Item -LiteralPath $tempDFObjectFile -Confirm:$false -Force
		}
		catch [System.Exception]
		{
			"An exception ocurred while creating data factory object '{0}'. Message: '{1}'" -f $Type, $_.Exception.Message | Trace -Severity:Exception
		}
	}

	Function Delete-AzureDataFactory
	{
		"Deleting Data Factory..." | Trace

		# The data factory cmdlets are only available in the AzureResourceMode module
		Switch-AzureMode -Name AzureResourceManager

		$dfSettings = $global:AzureProvisionSettings.DataFactory
		$dataFactoryName = Concat-AzurePrefix -Text $dfSettings.Name
		$resourceGroupName = Concat-AzurePrefix -Text $dfSettings.ResourceGroup
		$dataFactory = Get-AzureDataFactory -Name $dataFactoryName -ResourceGroupName $resourceGroupName -ErrorAction:SilentlyContinue			

		if($dataFactory -eq $null)
		{
			"Data Factory '{0}' in resource group '{1}' was not found." -f $dataFactoryName, $resourceGroupName | Trace			
		}
		else
		{
			"Deleting '{0}' in resource group '{1}'." -f $dataFactoryName, $resourceGroupName | Trace
			Remove-AzureDataFactory -ResourceGroupName $resourceGroupName -Name $dataFactoryName -Force
		}

		# switch back to service management
		Switch-AzureMode -Name AzureServiceManagement
	}
}