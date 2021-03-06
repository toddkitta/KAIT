<#
	.SYNOPSIS
		Deletes Azure Storage Accounts, Containers, ServiceBus Namespace, Event Hubs, Stream Analytics, and Data Factory Services.
		This script is driven by the configuration file located at .\conf\Azureprovisionsettings.json
		
	.Created
		6/29/2015 - Todd Kitta
#>

Param(
	[switch]$DeleteStorageAccounts,
	[switch]$DeleteHDInsightCluster,
	[switch]$DeleteEventHubs,
	[switch]$DeleteASA,
	[switch]$DeleteDataFactory
)

#Region References & Param Validation

	cls
	
	#Change the directory to the location we're running the script from so we can use relative paths
	Set-Location -LiteralPath ([System.IO.Directory]::GetParent($MyInvocation.MyCommand.Path))

	. .\utils\Constants.ps1
	. .\utils\Utils_Shared.ps1
	. .\utils\Utils_Storage.ps1 # Azure Storage
	. .\utils\Utils_HDI.ps1	# HDInsight
	. .\utils\Utils_EH.ps1	# Event Hub and Service Bus
	. .\utils\Utils_ASA.ps1	# Stream Analytics
	. .\utils\Utils_DF.ps1 	# Data Factory
	
	# If no switch parameters are specified, we'll delete everything. Otherwise, only delete the services specified
	if(($DeleteStorageAccounts.ToBool() -bor $DeleteHDInsightCluster.ToBool() -bor $DeleteEventHubs.ToBool() -bor $DeleteASA.ToBool() -bor $DeleteDataFactory.ToBool()) -eq 0)
	{
		"No parameters were specified. Deleting all available services" | Trace
		
		$DeleteStorageAccounts = $true
		$DeleteHDInsightCluster = $true
		$DeleteEventHubs = $true
		$DeleteASA = $true
		$DeleteDataFactory = $true
	}
	
	"Delete Storage Accounts: {0}" -f $DeleteStorageAccounts | Trace
	"Delete HDInsight Cluster: {0}" -f $DeleteHDInsightCluster | Trace
	"Delete Event Hubs: {0}" -f $DeleteEventHubs | Trace
	"Delete Stream Analytics: {0}" -f $DeleteASA | Trace
	"Delete Data Factory: {0}" -f $DeleteDataFactory | Trace
	
#EndRegion References & Param Validation

if(!(Import-AzurePSModules))
{
	"Unable to import Azure PowerShell Modules. Have you installed the Azure SDK with Microsoft Azure PowerShell?" | Trace -Severity:Error
}
else
{
	#Get all of the settings for storage accounts, event hubs, etc. If we can't get them, stop the script
	if(!(Load-AzureProvisionSettings))
	{
		"There was an issue loading the settings file."  | Trace -Severity:Error
	}
	else
	{
		# The Remove-AzureAccount cmdlet deletes an Azure account and its subscriptions from the subscription data file in your roaming user profile. It does not delete the account from Microsoft Azure, or change 
		# the actual account in any way.
	    #
		#Using this cmdlet is a lot like logging out of your Azure account. And, if you want to log into the account again, use the Add-AzureAccount or Import-AzurePublishSettingsFile to add the account to 
		#Windows PowerShell again.
		#
		#We are doing this to reset the authentication to Azure before running the script in case something is still cached.
		Get-AzureAccount | %{Remove-AzureAccount -Name $_.Id -Force | Out-Null}	
		Add-AzureAccount -ErrorAction:Stop		
		Select-AzureSubscription -SubscriptionId $global:AzureProvisionSettings.AzureSubscriptionId -ErrorAction:Stop
		
		if($DeleteASA)
		{
			#Deletes the Stream Analytics jobs
			Delete-AzureStreamAnalyticsJobs
		}
		
		if($DeleteDataFactory)
		{
			#Deletes the inception data factory
			Delete-AzureDataFactory
		}
		
		if($DeleteHDInsightCluster)
		{
			#Deletes the Hadoop cluster as defined in the settings
			Delete-AzureHDInsightCluster
		}
		
		if($DeleteEventHubs)
		{
			#Deletes the Service bus namespace and event hubs
			Delete-SBNamespaceAndEventHubs
		}
		
		if($DeleteStorageAccounts)
		{
			#Deletes all storage accounts defined in the configuration settings.
			Delete-AzureStorageAccounts
		}
	}
}

Read-Host "The script has completed. Press any button to continue" -ErrorAction:SilentlyContinue

