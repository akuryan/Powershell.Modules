function WriteLogToHost {
    param (
        [string]$logMessage,
        [string]$logFormat
    )
    $message = $logFormat -f $logMessage;
    Write-Host $message;
}

function ShallDownScaleDbBasedOnSkuEdition {
    param (
        [string]$currentDbSku,
        [string]$currentDbEdition
    )
    #we should not downscale Basic databases
    if ($currentDbEdition.ToLower() -eq "Basic".ToLower()) {
        return $false;
    }

    #we should not downscale databases from Standard S0 or from ElasticPool
    if ($currentDbSku.ToLower() -ne "S0".ToLower() -and $currentDbSku.ToLower() -ne "ElasticPool".ToLower()) {
        return $true;
    } else {
        return $false;
    }
}

function ShallDownscalePool {
    param (
        [string]$poolEdition,
        [int]$poolDtu
    )
    if ($poolEdition.ToLower() -eq "Basic".ToLower()) {
        #will not work with Basic pools now
        return $false;
    }

    if ($poolEdition.ToLower() -eq "Free".ToLower()) {
        #will not work with Free pools now
        return $false;
    }

    if ($poolDtu -le 50) {
        #pool is at minimum dtu already
        return $false;
    }

    return $true;
}

function ParseTagsToSizesString {
	param (
		[string]$name,
		[string]$tagsStringified
	)
	
	$filterOn = ("{0}:*" -f $name);
	Write-Verbose "We are going to filter $tagsStringified with filter $filterOn";
	$replaceString = ("{0}:" -f $name);
	#get DB size and edition
	$tagsCollection = $tagsStringified.Split(';');
	$tagsData = ($tagsCollection -like $filterOn);
	Write-Verbose "We've found sku and edition for $name - it is $tagsData";
	if (![string]::IsNullOrWhiteSpace($tagsData)) {
		$tagsData = $tagsData.Replace($replaceString, "");
		Write-Verbose "We've replaced and final sku and edition is $tagsData";
		return $tagsData;
	}
	
	return "";	
}

function RetryCommand {
    [CmdletBinding()]
    Param(
        [Parameter(Position=0, Mandatory=$true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Position=1, Mandatory=$false)]
        [int]$Maximum = 5,

        [Parameter(Position=2, Mandatory=$false)]
        [int]$sleepInSeconds = 5
    )

    Begin {
        $cnt = 0
    }

    Process {
        do {
            $cnt++
            try {
                $ScriptBlock.Invoke();
                return;
            } catch {
                Write-Verbose $_.Exception.InnerException.Message;
                Start-Sleep $sleepInSeconds;
            }
        } while ($cnt -lt $Maximum)

        # Throw an error after $Maximum unsuccessful invocations. Doesn't need
        # a condition, since the function returns upon successful invocation.
        throw 'Execution failed.'
    }
}

function ProcessWebApps {
    param (
        $webAppFarms,
        $logStringFormat,
        $ResourceGroupName
        )

    $whatsProcessing = "Web app farms"
    Write-Host "Processing $whatsProcessing"
    $amount = ($webAppFarms | Measure-Object).Count
    if ($amount -le 0) {
        $messageToLog = "No {0} was retrieved for {1}" -f $whatsProcessing, $ResourceGroupName;
        WriteLogToHost -logMessage $messageToLog -logFormat $logStringFormat
        return;
    }

    #hash is needed to get correct worker size
    $webAppHashSizes = @{};
    $webAppHashSizes['1'] = "Small";
    $webAppHashSizes['2'] = "Medium";
    $webAppHashSizes['3'] = "Large";
    $webAppHashSizes['4'] = "Extra Large";
    Write-Host "There is $amount $whatsProcessing to be processed."

    foreach ($farm in $webAppFarms) {
        $resourceId = $farm.ResourceId
        $webFarmResource = Get-AzureRmResource -ResourceId $resourceId -ExpandProperties
        $resourceName = $webFarmResource.Name
        Write-Host "Performing requested operation on $resourceName"
        #get existing tags
        $tags = $webFarmResource.Tags
        if ($tags.Count -eq 0) {
            #there is no tags defined
            $tags = @{}
        } else {
            if ($tags.ContainsKey('costsSaverTier')) {
                #do a cleanup of previous cost saver tags
                $tags.Remove('costsSaverTier');
                $tags.Remove('costsSaverWorkerSize');
                $tags.Remove('costsSaverNumberofWorkers');
            }
        }

        #we do not want to upscale those slots to Standard :)
        $excludedTiers = "Free","Shared";
        #if installed AzureRm is v.2 - we shall exclude PremiumV2 as well (it is not supported there)
        $azureRMModules = Get-Module -Name AzureRM | Select-Object Version | Format-Table | Out-String;
        Write-Verbose "Azure RM Modules: $azureRMModules";
        if($azureRMModules -match "2") {
            #we have azureRMModules version 2 - PremiumV2 is not supported here
            $excludedTiers += "PremiumV2";
        }
        Write-Verbose "Excluded tiers: $excludedTiers";

        #get app service plan rich data
        $aspEnriched = Get-AzureRmAppServicePlan -ResourceGroupName $webFarmResource.ResourceGroupName -Name $webFarmResource.Name;
        #get all apps assigned to ASP
        $apps = Get-AzureRmWebApp -AppServicePlan $aspEnriched;

        if ($Downscale) {
            #we need to store current web app sizes in tag
            #tag stores Sku Name, Tier, Size, Family and Capacity splitted by colon
            $tags.costsSaver = ("{0}:{1}:{2}:{3}:{4}:{5}" -f $webFarmResource.Sku.name, $webFarmResource.Sku.tier, $webFarmResource.Sku.size, $webFarmResource.Sku.family, $webFarmResource.Sku.capacity, $webAppHashSizes[$webFarmResource.Sku.size.Substring(1,1)]);
            #write tags to web app
            Set-AzureRmResource -ResourceId $resourceId -Tag $tags -Force
            (Get-AzureRmResource -ResourceId $resourceId).Tags

            #we shall proceed only if we are in more expensive tiers
            if ($excludedTiers -notcontains $webFarmResource.Sku.tier) {
                $slots = @();
                #traverse each app to check, if it actually have a slot assigned
                foreach ($app in $apps) {
                    $appName = $app.Name;
                    $appRg = $app.ResourceGroup;
                    
                    #https://github.com/Azure/azure-powershell/issues/5760
                    # use the resource group parameter if the webapp resource group is null
                    if ([string]::IsNullOrWhiteSpace($appRg))
                    {
                        $appRg = $ResourceGroupName
                    }

                    Write-Verbose "Trying to get slot for $appName in resource group $appRg";
                    #If web app have slots - it could not be downscaled to Basic :(
                    #test for presence of slot
                    $slot = Get-AzureRmWebAppSlot -ResourceGroupName $appRg -name $appName;
                    #not very mem-effective; but list will always create additional element, even if it is empty :(
                    $slots += $slot;
                }

                #if in $slots array we have something - that one of web apps, assigned to web farm have deployment slot
                $slotIsPresent = ($slots.Count -ne 0);
                Write-Verbose "Do app service plan $resourceName have slot assigned: $slotIsPresent";

                if ($slotIsPresent) {
                    Write-Host "Downscaling $resourceName to tier: Standard, workerSize: Small and 1 worker"
                    Set-AzureRmAppServicePlan -Tier Standard -NumberofWorkers 1 -WorkerSize Small -ResourceGroupName $webFarmResource.ResourceGroupName -Name $webFarmResource.Name
                } else {
                    Write-Host "Downscaling $resourceName to tier: Basic, workerSize: Small and 1 worker"
                    Set-AzureRmAppServicePlan -Tier Basic -NumberofWorkers 1 -WorkerSize Small -ResourceGroupName $webFarmResource.ResourceGroupName -Name $webFarmResource.Name
                }

                #write tags to web app after scaling (sometimes tags disappear)
                Set-AzureRmResource -ResourceId $resourceId -Tag $tags -Force
                (Get-AzureRmResource -ResourceId $resourceId).Tags
            }
        }
        else {
            #parse resuls
            if (-not $tags.ContainsKey("costsSaver")) {
                $messageToLog = "Tags does not have any costs saver related values. Returning...";
                WriteLogToHost -logMessage $messageToLog -logFormat $logStringFormat
                continue;
            }
            $collection = $tags.costsSaver.Split(":");
            if (-not $collection.Length -eq 6) {
                $messageToLog = "Tag costsSaver does not contains all required data to restore web farm {0} to previous state" -f $resourceName;
                WriteLogToHost -logMessage $messageToLog -logFormat $logStringFormat
                continue;
            }
            $skuName = $collection[0];
            $targetTier = $collection[1];
            $targetWorkerSize = $collection[2];
            $skuFamily = $collection[3];
            $targetAmountOfWorkers = $collection[4];
            $verbSize = $collection[5];

            if ($excludedTiers -notcontains $targetTier) {
                Write-Host "Upscaling $resourceName to tier: $targetTier, workerSize: $targetWorkerSize with $targetAmountOfWorkers workers";
                Set-AzureRmAppServicePlan -Tier $targetTier -NumberofWorkers $targetAmountOfWorkers -WorkerSize $verbSize -ResourceGroupName $webFarmResource.ResourceGroupName -Name $webFarmResource.Name;
                
                #write tags to web app after scaling (sometimes tags disappear)
                Set-AzureRmResource -ResourceId $resourceId -Tag $tags -Force
                (Get-AzureRmResource -ResourceId $resourceId).Tags

                foreach ($app in $apps) {
                    #sometimes during upscale - app will stall in disabled state (though it is running), so I will restart it here one more time (this fixes problem)
                    Restart-AzureRmWebApp $app;
                }
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
        $sqlServerResourceId = $sqlServer.ResourceId;
        $sqlServerResource = Get-AzureRmResource -ResourceId $sqlServerResourceId -ExpandProperties;

        $sqlServerName =  $sqlServerResource.Name;
        #variable $couldDownscale holds if we could proceed with downscaling
        $couldDownscale = $false;

        $sqlDatabases = Get-AzureRmSqlDatabase -ResourceGroupName $sqlServerResource.ResourceGroupName -ServerName $sqlServerName;
        $elasticPools = Get-AzureRmSqlElasticPool -ServerName $sqlServerName -ResourceGroupName $sqlServerResource.ResourceGroupName;
        #Get existing tags for SQL server
        $sqlServerTags = $sqlServerResource.Tags;
        if ($sqlServerTags.Count -eq 0)
        {
            #there is no tags defined
            $sqlServerTags = @{};
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
            for ($counter=0; $counter -lt $keyCounter; $counter++) {
                $key = $keySkuEdition + $counter;
                Write-Verbose "Retrieving $key from tags"
                $dbNameSkuEditionInfoString = $dbNameSkuEditionInfoString + $sqlServerTags[$key];
                Write-Verbose "Retrieved so far: $dbNameSkuEditionInfoString";
            }
        } else {
            #collect sizes and save tags
            foreach ($sqlDb in $sqlDatabases.where( {$_.DatabaseName -ne "master"})) {
                $resourceName = $sqlDb.DatabaseName;
                #removing possibly existing old tags, maybe get rid of it by version 2 of nuget :)
                $keySku = ("{0}-{1}" -f $resourceName, "sku");
                $keyEdition = ("{0}-{1}" -f $resourceName, "edition");
                if ($sqlServerTags.ContainsKey($keySku)) {
                    $sqlServerTags.Remove($keySku);
                }
                if ($sqlServerTags.ContainsKey($keyEdition)) {
                    $sqlServerTags.Remove($keyEdition);
                }

                if (ShallDownScaleDbBasedOnSkuEdition -currentDbSku $sqlDb.CurrentServiceObjectiveName -currentDbEdition $sqlDb.Edition) {
                    #store it as dbName:sku-edition
                    Write-Verbose "dbNameSkuEditionInfoString now is $dbNameSkuEditionInfoString";
                    $dbNameSkuEditionInfoString = $dbNameSkuEditionInfoString + ("{0}:{1}-{2};" -f $resourceName, $sqlDb.CurrentServiceObjectiveName, $sqlDb.Edition );
                    Write-Verbose "dbNameSkuEditionInfoString became now $dbNameSkuEditionInfoString";
                }
            }

            foreach ($pool in $elasticPools) {
                if (ShallDownscalePool -poolEdition $pool.Edition -poolDtu $pool.Dtu) {
                    #store pool data in tags as well
                    Write-Verbose "dbNameSkuEditionInfoString now is $dbNameSkuEditionInfoString";
                    $dbNameSkuEditionInfoString = $dbNameSkuEditionInfoString + ("{0}:{1}-{2}-{3}-{4};" -f $pool.ElasticPoolName, $pool.Edition, $pool.Dtu, $pool.DatabaseDtuMax, $pool.DatabaseDtuMin);
                    Write-Verbose "dbNameSkuEditionInfoString became now $dbNameSkuEditionInfoString";
                }
            }

            #now we need to form up tags (tag have a limit of 256 chars per tag)
            $stringLength = $dbNameSkuEditionInfoString.Length;
            Write-Verbose "dbNameSkuEditionInfoString have lenght of $stringLength";
            #how much tags we need to record our databases sizes
            $tagsLimitCount = [Math]::ceiling($stringLength/256);
            Write-Verbose "We need $tagsLimitCount tags to write our db sizes";
            
            for ($counter=0; $counter -lt $tagsLimitCount; $counter++){
                $key = $keySkuEdition + $counter;
                $value = ($dbNameSkuEditionInfoString.ToCharArray() | select -first 256) -join "";
                #remove extracted data
                $dbNameSkuEditionInfoString = $dbNameSkuEditionInfoString.Replace($value, "");
                $sqlServerTags[$key] = $value;
            }
            #we could downscale if we could save data in tags for SQL Server, which shall be no more than 15
            $couldDownscale = $sqlServerTags.Count -le 15;

            if ($couldDownscale) {
                #we could not have more than 15 tags per resource but this is OK and we can proceed
                #Store tags on SQL server
                Set-AzureRmResource -ResourceId $sqlServerResourceId -Tag $sqlServerTags -Force;
                (Get-AzureRmResource -ResourceId $sqlServerResourceId).Tags;
            } else {
                #count how much tags we will have in the end
                $resultingTagsCount = $sqlServerTags.Count;
                $messageToLog = "We could not save database sizes as tags, as we are over limit of 15 tags per resource on current sql server {0}. We need to write {1} in addition to existing tags" -f $sqlServerName, $resultingTagsCount;
                WriteLogToHost -logMessage $messageToLog -logFormat $logStringFormat;
                $messageToLog = "Databases sizes as string: {0}" -f $dbNameSkuEditionInfoString;
                WriteLogToHost -logMessage $messageToLog -logFormat $logStringFormat;
            }
        }

        foreach ($sqlDb in $sqlDatabases.where( {$_.DatabaseName -ne "master"}))
        {
            $resourceName = $sqlDb.DatabaseName;

            Write-Host "Performing requested operation on database $resourceName";

            if ($Downscale) {
                if ($couldDownscale) {
                    #proceed if we written tags on SQL server level
                    if (ShallDownScaleDbBasedOnSkuEdition -currentDbSku $sqlDb.CurrentServiceObjectiveName -currentDbEdition $sqlDb.Edition) {
                        Write-Host "Downscaling database $resourceName at server $sqlServerName to S0 size";
                        RetryCommand -ScriptBlock {
                            Set-AzureRmSqlDatabase -DatabaseName $resourceName -ResourceGroupName $sqlDb.ResourceGroupName -ServerName $sqlServerName -RequestedServiceObjectiveName S0 -Edition Standard;
                        }
                    } else {
                        Write-Verbose "We do not need to downscale db $resourceName at server $sqlServerName to S0 size (it is either S0 already or belongs to elastic pool or belongs to Basic edition)";
                    }
                }
            } else {
                $skuEdition = ParseTagsToSizesString -name $resourceName -tagsStringified $dbNameSkuEditionInfoString;
                Write-Verbose "We've found sku and edition for $resourceName - it is $skuEdition";
                if (![string]::IsNullOrWhiteSpace($skuEdition)) {
                    if ($skuEdition.Split('-').Count -eq 2)
                    {
                        #we have exactly 2 values in our tag and could proceed further
                        $edition = $skuEdition.Split('-')[1];
                        $targetSize = $skuEdition.Split('-')[0];
                        #since we could not have tags about Basic and Standard S0 databases - we are going to proceed from here
                        Write-Host "Upscaling $resourceName at server $sqlServerName to $targetSize size"
                        RetryCommand -ScriptBlock {
                            Set-AzureRmSqlDatabase -DatabaseName $resourceName -ResourceGroupName $sqlDb.ResourceGroupName -ServerName $sqlServerName -RequestedServiceObjectiveName $targetSize -Edition $edition
                        }
                    }
                }
            }
        }

        foreach ($pool in $elasticPools) {
            $resourceName = $pool.ElasticPoolName;
            Write-Host "Performing requested operation on pool $resourceName";

            if ($Downscale) {
                if ($couldDownscale) {
                    #proceed if we written tags on SQL server level
                    if (ShallDownscalePool -poolEdition $pool.Edition -poolDtu $pool.Dtu) {
                        Write-Host "Downscaling pool $resourceName at server $sqlServerName";
                        RetryCommand -ScriptBlock {
                            Set-AzureRmSqlElasticPool -ResourceGroupName $pool.ResourceGroupName -ServerName $sqlServerName -ElasticPoolName $resourceName -Edition Standard -Dtu 50 -DatabaseDtuMin 0 -DatabaseDtuMax 50;
                        }
                    } else {
                        Write-Verbose "We do not need to downscale pool $resourceName at server $sqlServerName ";
                    }
                }
            } else {
                $poolData = ParseTagsToSizesString -name $resourceName -tagsStringified $dbNameSkuEditionInfoString;
                Write-Verbose "We've found sku and edition for $resourceName - it is $poolData";
                if (![string]::IsNullOrWhiteSpace($poolData)) {
                    if ($poolData.Split('-').Count -eq 4)
                    {
                        #we have exactly 4 values in our tag and could proceed further
                        $edition = $poolData.Split('-')[0];
                        $dtu = [int]$poolData.Split('-')[1];
                        $maxDbDtu = [int]$poolData.Split('-')[2];
                        $minDbDtu = [int]$poolData.Split('-')[3];
                        Write-Host "Upscaling $resourceName at server $sqlServerName";
                        RetryCommand -ScriptBlock {
                            Set-AzureRmSqlElasticPool -ResourceGroupName $pool.ResourceGroupName -ServerName $sqlServerName -ElasticPoolName $resourceName -Edition $edition -Dtu $dtu -DatabaseDtuMin $minDbDtu -DatabaseDtuMax $maxDbDtu;
                        }
                    }
                }
            }
        }
    }
}

function ProcessVirtualMachinesScaleSets {
    param (
        $vmScaleSets,
        $logStringFormat,
        $ResourceGroupName
        )

    $whatsProcessing = "Virtual machines scale sets"
    Write-Host "Processing $whatsProcessing"
    $amount = ($vmScaleSets | Measure-Object).Count
    if ($amount -le 0) {
        $messageToLog = "No {0} was retrieved for {1}" -f $whatsProcessing, $ResourceGroupName;
        WriteLogToHost -logMessage $messageToLog -logFormat $logStringFormat
        return;
    }

    Write-Host "There is $amount $whatsProcessing to be processed."

    foreach ($vmss in $vmScaleSets) {
        $resourceName = $vmss.Name
        if ($Downscale) {
            #Deprovision VMs
            Write-Host "Stopping and deprovisioning $resourceName"
            Stop-AzureRmVmss -ResourceGroupName $ResourceGroupName -VMScaleSetName $vmss.Name -Force
        }
        else {
            #Start them up
            Write-Host "Starting $resourceName"
            Start-AzureRmVmss -ResourceGroupName $ResourceGroupName -VMScaleSetName $vmss.Name
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
    $resources = Get-AzureRmResource | Where-Object {$_.ResourceGroupName -eq $ResourceGroupName};

    if (($resources | Measure-Object).Count -le 0)
    {
        $messageToLog = "No resources was retrieved for resource group {0}" -f $ResourceGroupName;
        WriteLogToHost -logMessage $messageToLog -logFormat $logStringFormat;
        Exit $false;
    }

    ProcessWebApps -webAppFarms $resources.where( {$_.ResourceType -eq "Microsoft.Web/serverFarms" -And $_.ResourceGroupName -eq "$ResourceGroupName"}) -logStringFormat $logStringFormat -ResourceGroupName $ResourceGroupName;
    ProcessSqlDatabases -sqlServers $resources.where( {$_.ResourceType -eq "Microsoft.Sql/servers" -And $_.ResourceGroupName -eq "$ResourceGroupName"}) -logStringFormat $logStringFormat -ResourceGroupName $ResourceGroupName;
    ProcessVirtualMachines -vms $resources.where( {$_.ResourceType -eq "Microsoft.Compute/virtualMachines" -And $_.ResourceGroupName -eq "$ResourceGroupName"}) -logStringFormat $logStringFormat -ResourceGroupName $ResourceGroupName;
    ProcessVirtualMachinesScaleSets -vmScaleSets $resources.where( {$_.ResourceType -eq "Microsoft.Compute/virtualMachineScaleSets" -And $_.ResourceGroupName -eq "$ResourceGroupName"}) -logStringFormat $logStringFormat -ResourceGroupName $ResourceGroupName;
}
