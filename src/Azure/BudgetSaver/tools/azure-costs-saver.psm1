function WriteLogToHost {
    param (
        [string]$logMessage,
        [string]$logFormat
    )
    $message = $logFormat -f $logMessage;
    Write-Host $message;
}

function ProcessWebApps {
    param (
        $webApps,
        $logStringFormat,
        $ResourceGroupName
        )

    $whatsProcessing = "Web app farms"
    Write-Host "Processing $whatsProcessing"
    $amount = ($webApps | Measure-Object).Count
    if ($amount -le 0) {
        $messageToLog = "No {0} was retrieved for {1}" -f $whatsProcessing, $ResourceGroupName;
        WriteLogToHost -logMessage $messageToLog -logFormat $logStringFormat
        return;
    }

    #hash is needed to get correct worker size
    $webAppHashSizes = @{}
    $webAppHashSizes['1'] = "Small"
    $webAppHashSizes['2'] = "Medium"
    $webAppHashSizes['3'] = "Large"
    $webAppHashSizes['4'] = "Extra Large"

    Write-Host "There is $amount $whatsProcessing to be processed."

    foreach ($farm in $webApps) {
        $resourceId = $farm.ResourceId
        $webFarmResource = Get-AzureRmResource -ResourceId $resourceId -ExpandProperties
        $resourceName = $webFarmResource.Name
        Write-Host "Performing requested operation on $resourceName"
        #get existing tags
        $tags = $webFarmResource.Tags
        if ($tags.Count -eq 0)
        {
            #there is no tags defined
            $tags = @{}
        }

        #we do not want to upscale those slots to Standard :)
        $excludedTiers = "Free","Shared","Basic"
        #if installed AzureRm is v.2 - we shall exclude PremiumV2 as well (it is not supported there)
        $azureRMModules = Get-Module -Name AzureRM -ListAvailable | Select-Object Version | Format-Table | Out-String
        Write-Verbose "Azure RM Modules: $azureRMModules";
        if($azureRMModules -match "2") {
            #we have azureRMModules version 2 - PremiumV2 is not supported here
            $excludedTiers += "PremiumV2"
        }
        Write-Verbose "Excluded tiers: $excludedTiers"

        if ($Downscale) {
            #we need to store current web app sizes in tags
            $tags.costsSaverTier = $webFarmResource.Sku.tier
            $tags.costsSaverNumberofWorkers = $webFarmResource.Sku.capacity
            #from time to time - workerSize returns as Default
            $tags.costsSaverWorkerSize = $webAppHashSizes[$webFarmResource.Sku.size.Substring(1,1)]
            #write tags to web app
            Set-AzureRmResource -ResourceId $resourceId -Tag $tags -Force
            (Get-AzureRmResource -ResourceId $resourceId).Tags

            #we shall proceed only if we are in more expensive tiers
            if ($excludedTiers -notcontains $webFarmResource.Sku.tier) {
				#If web app have slots - it could not be downscaled to Basic :(
                Write-Host "Downscaling $resourceName to tier: Standard, workerSize: Small and 1 worker"
                Set-AzureRmAppServicePlan -Tier Standard -NumberofWorkers 1 -WorkerSize Small -ResourceGroupName $webFarmResource.ResourceGroupName -Name $webFarmResource.Name
            }
        }
        else {
            if ($excludedTiers -notcontains $tags.costsSaverTier) {
                #we shall not try to set resource
                $targetTier = $tags.costsSaverTier
                $targetWorkerSize = $tags.costsSaverWorkerSize
                $targetAmountOfWorkers = $tags.costsSaverNumberofWorkers
                Write-Host "Upscaling $resourceName to tier: $targetTier, workerSize: $targetWorkerSize with $targetAmountOfWorkers workers"
                Set-AzureRmAppServicePlan -Tier $tags.costsSaverTier -NumberofWorkers $tags.costsSaverNumberofWorkers -WorkerSize $tags.costsSaverWorkerSize -ResourceGroupName $webFarmResource.ResourceGroupName -Name $webFarmResource.Name
            }
        }
    }
}

function ProcessVirtualMachines {
    param (
        $vms,
        $logStringFormat,
        $ResourceGroupName
        )

    $whatsProcessing = "Virtual machines"
    Write-Host "Processing $whatsProcessing"
    $amount = ($vms | Measure-Object).Count
    if ($amount -le 0) {
        $messageToLog = "No {0} was retrieved for {1}" -f $whatsProcessing, $ResourceGroupName;
        WriteLogToHost -logMessage $messageToLog -logFormat $logStringFormat
        return;
    }

    Write-Host "There is $amount $whatsProcessing to be processed."

    foreach ($vm in $vms) {
        $resourceName = $vm.Name
        if ($Downscale) {
            #Deprovision VMs
            Write-Host "Stopping and deprovisioning $resourceName"
            Stop-AzureRmVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Force
        }
        else {
            #Start them up
            Write-Host "Starting $resourceName"
            Start-AzureRmVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name
        }
    }
}

function ProcessSqlDatabases {
    param (
        $sqlServers,
        $logStringFormat,
        $ResourceGroupName
        )

    $whatsProcessing = "SQL servers"
    Write-Host "Processing $whatsProcessing"
    $amount = ($sqlServers | Measure-Object).Count
    if ($amount -le 0) {
        $messageToLog = "No {0} was retrieved for {1}" -f $whatsProcessing, $ResourceGroupName;
        WriteLogToHost -logMessage $messageToLog -logFormat $logStringFormat
        return;
    }

    Write-Host "There is $amount $whatsProcessing to be processed."

    foreach ($sqlServer in $sqlServers) {
        $sqlServerResourceId = $sqlServer.ResourceId
        $sqlServerResource = Get-AzureRmResource -ResourceId $sqlServerResourceId -ExpandProperties

		$sqlServerName =  $sqlServerResource.Name

        $sqlDatabases = Get-AzureRmSqlDatabase -ResourceGroupName $sqlServerResource.ResourceGroupName -ServerName $sqlServerName
        #Get existing tags for SQL server
        $sqlServerTags = $sqlServerResource.Tags
        if ($sqlServerTags.Count -eq 0)
        {
            #there is no tags defined
            $sqlServerTags = @{}
        }

        #we will store all data in one string and then we will try to save it as tags to be parsed later
        $dbNameSkuEditionInfoString = "";
        $keySkuEdition = "skuEdition";
        if (!$Downscale) {
            #count keys
            $keyCounter = 0;
            foreach($key in $sqlServerTags.keys) {
                #get all keys starting with with skuEdition
                if ($key.Contains($keySkuEdition)){
                    $keyCounter = $keyCounter+1;
                }
            }
            Write-Verbose "We've found $keyCounter keys with database sizes"
            for ($counter=0; $counter -lt $keyCounter; $counter++){
                $key = $keySkuEdition + $counter;
                Write-Verbose "Retrieving $key from tags"
                $dbNameSkuEditionInfoString = $dbNameSkuEditionInfoString + $sqlServerTags[$key];
                Write-Verbose "Retrieved so far: $dbNameSkuEditionInfoString";
            }

            $databaseSizesSkuEditions = $dbNameSkuEditionInfoString.Split(';');
        }

        foreach ($sqlDb in $sqlDatabases.where( {$_.DatabaseName -ne "master"}))
        {
            $resourceName = $sqlDb.DatabaseName

            Write-Host "Performing requested operation on $resourceName"
            $resourceId = $sqlDb.ResourceId

            $keySku = ("{0}-{1}" -f $resourceName, "sku");
            $keyEdition = ("{0}-{1}" -f $resourceName, "edition");
            #removing possibly existing old tags
            $sqlServerTags.Remove($keySku);
            $sqlServerTags.Remove($keyEdition);

            if ($Downscale) {
                #proceed only in case we are not on Basic
                if ($sqlDb.Edition -ne "Basic")
                {
                    #proceed only in case we are not at S0
                    if ($sqlDb.CurrentServiceObjectiveName -ne "S0") {
                        #store it as dbName:sku-edition
                        Write-Verbose "dbNameSkuEditionInfoString now is $dbNameSkuEditionInfoString";
                        $dbNameSkuEditionInfoString = $dbNameSkuEditionInfoString + ("{0}:{1}-{2};" -f $resourceName, $sqlDb.CurrentServiceObjectiveName, $sqlDb.Edition );
                        Write-Verbose "dbNameSkuEditionInfoString became now $dbNameSkuEditionInfoString";
                        Write-Host "Downscaling $resourceName at server $sqlServerName to S0 size";
                        Set-AzureRmSqlDatabase -DatabaseName $resourceName -ResourceGroupName $sqlDb.ResourceGroupName -ServerName $sqlServerName -RequestedServiceObjectiveName S0 -Edition Standard;
                    } else {
                        Write-Verbose "We do not need to downscale db $resourceName at server $sqlServerName to S0 size";
                    }
                }
            } else {
                $filterOn = ("{0}:*" -f $resourceName);
                Write-Verbose "We are going to filter $dbNameSkuEditionInfoString with filter $filterOn";
                $replaceString = ("{0}:" -f $resourceName);
                #get DB size and edition
                $skuEdition = ($databaseSizesSkuEditions -like $filterOn);
                Write-Verbose "We've found sku and edition for $resourceName - it is $skuEdition";
                #ugly, a lot of branching, but could not think of any way
                if (![string]::IsNullOrWhiteSpace($skuEdition)) {
                    $skuEdition = $skuEdition.Replace($replaceString, "");
                    Write-Verbose "We've replaced and final sku and edition is $skuEdition";
                    #we have SkuEdition defined for database, which means that it was not Basic or Standard S0 prior to downscaling
                    if ($skuEdition.Split('-').Count -eq 2)
                    {
                        #we have exactly 2 values in our tag and could proceed further
                        $edition = $skuEdition.Split('-')[1];
                        $targetSize = $skuEdition.Split('-')[0];
                        #since we could not have tags about Basic and Standard S0 databases - we are going to proceed from here
                        Write-Host "Upscaling $resourceName at server $sqlServerName to $targetSize size"
                        Set-AzureRmSqlDatabase -DatabaseName $resourceName -ResourceGroupName $sqlDb.ResourceGroupName -ServerName $sqlServerName -RequestedServiceObjectiveName $targetSize -Edition $edition
                    }
                }
            }
        }
        if ($Downscale) {
            #now we need to form up tags (tag have a limit of 256 chars per tag)
            $stringLength = $dbNameSkuEditionInfoString.Length;
            Write-Verbose "dbNameSkuEditionInfoString have lenght of $stringLength"
            #how much tags we need to record our databases sizes
            $tagsLimitCount = [Math]::ceiling( $stringLength/256)
            Write-Verbose "We need $tagsLimitCount tags to write our db sizes"

            #count how much tags we will have in the end
            $resultingTagsCount = $sqlServerTags.Count + $tagsLimitCount

            if ($resultingTagsCount -le 15) {
                #we could not have more than 15 tags per resource but this is OK and we can proceed
                for ($counter=0; $counter -lt $tagsLimitCount; $counter++){
                    $key = $keySkuEdition + $counter;
                    $value = ($dbNameSkuEditionInfoString.ToCharArray() | select -first 256) -join "";
                    #remove extracted data
                    $dbNameSkuEditionInfoString = $dbNameSkuEditionInfoString.Replace($value, "");
                    $sqlServerTags[$key] = $value
                }
            } else {
                $messageToLog = "We could not save database sizes as tags, as we are over limit of 15 tags per resource on current sql server {0}. We need to write {1} in addition to existing tags" -f $sqlServerName, $resultingTagsCount;
                WriteLogToHost -logMessage $messageToLog -logFormat $logStringFormat;
                $messageToLog = "Databases sizes as string: {0}" -f $dbNameSkuEditionInfoString;
                WriteLogToHost -logMessage $messageToLog -logFormat $logStringFormat;
            }
            #Store tags on SQL server
            Set-AzureRmResource -ResourceId $sqlServerResourceId -Tag $sqlServerTags -Force
            (Get-AzureRmResource -ResourceId $sqlServerResourceId).Tags
        }
    }
}

function Set-ResourceSizesForCostsSaving {
    param (
        [Parameter(Mandatory=$True)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory=$True)]
        [bool]$Downscale,
        #execution environment defines logging patterns
        [Parameter(Mandatory=$True)]
        [ValidateSet("manual", "teamcity", "vsts")]
        [string]$executionEnv
        )

    $logStringFormat = "{0}";
    if ($executionEnv -eq "teamcity")
    {
        $logStringFormat = "##teamcity[message text='{0}' status='WARNING']";
    }
    if ($executionEnv -eq "vsts")
    {
        $logStringFormat = "##vso[task.logissue type=warning;] {0}";
    }

    Write-Host "We are going to downscale? $Downscale"
    Write-Host "Resources will be selected from $ResourceGroupName resource group"

    #Get all resources, which are in resource groups, which contains our name
    $resources = Find-AzureRmResource -ResourceGroupNameContains $ResourceGroupName

    if (($resources | Measure-Object).Count -le 0)
    {
        $messageToLog = "No resources was retrieved for resource group {0}" -f $ResourceGroupName;
        WriteLogToHost -logMessage $messageToLog -logFormat $logStringFormat
        Exit $false
    }

    ProcessWebApps -webApps $resources.where( {$_.ResourceType -eq "Microsoft.Web/serverFarms" -And $_.ResourceGroupName -eq "$ResourceGroupName"}) -logStringFormat $logStringFormat -ResourceGroupName $ResourceGroupName;
    ProcessSqlDatabases -sqlServers $resources.where( {$_.ResourceType -eq "Microsoft.Sql/servers" -And $_.ResourceGroupName -eq "$ResourceGroupName"}) -logStringFormat $logStringFormat -ResourceGroupName $ResourceGroupName;
    ProcessVirtualMachines -vms $resources.where( {$_.ResourceType -eq "Microsoft.Compute/virtualMachines" -And $_.ResourceGroupName -eq "$ResourceGroupName"}) -logStringFormat $logStringFormat -ResourceGroupName $ResourceGroupName;
}
