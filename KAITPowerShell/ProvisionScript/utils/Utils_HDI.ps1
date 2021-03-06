<#
	.SYNOPSIS
		Provies helper functions for HDInsight scripting

	.Created
		3/23/2015 - Mike Veazie
#>

if(!$__IsLoadedHDI__)
{
	# Flag to keep track if we've loaded these or not
	New-Variable -Name "__IsLoadedHDI__" -Option:ReadOnly -Scope "Script" -Value $true -Force
	
	. .\utils\Constants.ps1
	. .\utils\Utils_Shared.ps1
	. .\utils\Utils_Storage.ps1
	
	Function Create-AzureHDInsightCluster
	{
		Param(
			[Switch]$SetConfigurationValues = $true
		)
		try
		{
			$clusterSettings = $global:AzureProvisionSettings.HDInsight		
			$clusterName = Concat-AzurePrefix -Text $clusterSettings.ClusterName
			
			"Creating Azure HDInsight Cluster with name '{0}'" -f $clusterName | Trace
			if((Get-AzureHDInsightCluster -Name $clusterName) -eq $null)
			{
				"The cluster was not found. Creating it now." | Trace
				
				#We need to use the DNS name of the storage account to create the cluster
				$storageAccountName = (Concat-AzurePrefix -Text $clusterSettings.DefaultStorageAccount).ToLower()
				$storageConnStr = Get-AzureStorageConnectionString -StorageAccountName $storageAccountName
				
				#We just need the account key out of the connection string
				$storageAccountKeyPart = $storageConnStr.Split(';')[2]
				$storageAccountKey = $storageAccountKeyPart.Substring($storageAccountKeyPart.IndexOf('=') + 1)
				
				$hdiCredentials = New-Object System.Management.Automation.PSCredential($clusterSettings.Admin, (ConvertTo-SecureString -String $clusterSettings.Password -AsPlainText -Force))
				
				"StorageAccountName: {0}`tStorageAccountKey: {1}`tAdmin: {2}" -f $storageAccountName, $storageAccountKey, $hdiCredentials.UserName | Trace -Severity:Verbose
				
				New-AzureHDInsightCluster -Name $clusterName `
					-ClusterSizeInNodes $clusterSettings.Nodes `
					-Credential $hdiCredentials `
					-DefaultStorageAccountName $storageAccountName `
					-DefaultStorageAccountKey $storageAccountKey `
					-DefaultStorageContainerName $clusterSettings.DefaultStorageContainer `
					-Location $clusterSettings.Region
			}
			else
			{
				"The cluster already exists." | Trace
			}
			
			if($SetConfigurationValues)
			{
				$cmdBuilder = New-Object System.Text.StringBuilder
				
				#Set configuration options on the cluster
				foreach($option in $clusterSettings.ConfigurationOptions)
				{
					$cmdBuilder.AppendLine($option.Command) | Out-Null
				}
				
				"Invoking hive script to set configuration values`r`n{0}" -f $cmdBuilder.ToString() | Trace
				Use-AzureHDInsightCluster -Name $clusterName
				Invoke-AzureHDInsightHiveJob -JobName "Set Config Values" -Query $cmdBuilder.ToString()
			}
		}
		catch [System.Exception]
		{
			"An exception ocurred while creating the HDInsight Cluster. Exception message: {0}" -f $_.Exception.Message | Trace -Severity:Exception
		}
	}

	Function Delete-AzureHDInsightCluster
	{
		"Deleting HDInsight cluster..." | Trace

		$clusterSettings = $global:AzureProvisionSettings.HDInsight
		$clusterName = Concat-AzurePrefix -Text $clusterSettings.ClusterName

		if((Get-AzureHDInsightCluster -Name $clusterName) -eq $null)
		{
			"The cluster '{0}' was not found." -f $clusterName | Trace
		}
		else
		{
			"Deleting '{0}'." -f $clusterName | Trace
			Remove-AzureHDInsightCluster -Name $clusterName
		}
	}
}