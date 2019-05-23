function DownloadDataWithCheckForStaleness {
    param (
        [bool]$forceDownload,
        [string]$filePath,
        [string]$urlToDownload
    )
    
    $downloadRequired = $forceDownload;
    if (!$forceDownload) {
        #check, if file exists
        if (Test-Path $filePath) {
            $timeLimit = (Get-Date).AddDays(-15);
            $downloadRequired = (Get-ChildItem $filePath -Force | Where-Object CreationTime -lt $timeLimit).Length -gt 0;
        } else {
            #if file does not exist - we shall download
            $downloadRequired = $true;
        }
    }

    if ($downloadRequired) {
        if (Test-Path $filePath) {
            Remove-Item -Path $filePath -Force;
        }
        $webClient = New-Object System.Net.WebClient;
        $webClient.DownloadFile($urlToDownload, $filePath);
    }
}

function ReplaceVariables {
    param (
        [string]$config,
        [string]$variableName,
        [string]$variableValue
    )
    
    if ([string]::IsNullOrWhiteSpace($variableValue)) {
        return $config;
    }

    $regExp = [regex]"(#)?$variableName=(.*)";    
    $replacement = $variableName + "=" + $variableValue;
    return $regExp.Replace($config, $replacement, 1);
}


function Scan-Sources {
    param (
        [bool]$ForceDownload = $false,
        [string]$AgentPath,
        [string]$ProjectName,
        [string]$WssConfigurationPath,
        [Parameter(Mandatory=$true)]
        [string]$Version,
        [string]$FileScanPattern,
        [Parameter(Mandatory=$true)]
        [string]$WssApiKey,
        [Parameter(Mandatory=$true)]
        [string]$ScanPath
    )

    #To display version during execution - I will output it in host and replace at build time
    Write-Host "NuGet version is #{placeHolderForVersion}#";

    [Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls";

    if ([string]::IsNullOrWhiteSpace($AgentPath)) {
        $AgentPath = "$env:temp/wss-unified-agent.jar";
    } else {
        if (!(Test-Path -PathType Container -Path "$AgentPath")) {
            New-Item -ItemType Directory -Force -Path $AgentPath;
        }
        $AgentPath = "$AgentPath/wss-unified-agent.jar";
    }

    DownloadDataWithCheckForStaleness -forceDownload $ForceDownload -filePath $AgentPath -urlToDownload "https://github.com/whitesource/unified-agent-distribution/raw/master/standAlone/wss-unified-agent.jar";

    $WssConfigurationExists = $true;
    if (![string]::IsNullOrWhiteSpace($WssConfigurationPath)) {
        $WssConfigurationExists = Test-Path $WssConfigurationPath -PathType Leaf;
    } else {
        $WssConfigurationExists = $false;
    }
    
    if (!$WssConfigurationExists) {
        $wssConfigDirectory = "$env:temp/$ProjectName";
        $WssConfigurationPath = "$wssConfigDirectory/wss-unified-agent.config";
        if (!(Test-Path -PathType Container -Path "$wssConfigDirectory")) {
            New-Item -ItemType Directory -Force -Path $wssConfigDirectory;
        }

        DownloadDataWithCheckForStaleness -forceDownload $false -filePath $WssConfigurationPath -urlToDownload "https://github.com/whitesource/unified-agent-distribution/raw/master/standAlone/wss-unified-agent.config";
    }

    $config = Get-Content -Path $WssConfigurationPath -Raw;

    Write-Verbose "Config before modification:";
    Write-Verbose $config;

    if (!$WssConfigurationExists) {
        $config = ReplaceVariables -config $config -variableName "includes" -variableValue $FileScanPattern;
        $config = ReplaceVariables -config $config -variableName "projectName" -variableValue $ProjectName;
        $config = ReplaceVariables -config $config -variableName "productName" -variableValue $ProjectName;
    }

    $config = ReplaceVariables -config $config -variableName "projectVersion" -variableValue $Version;
    $config = ReplaceVariables -config $config -variableName "productVersion" -variableValue $Version;

    Write-Verbose "Config after modification:";
    Write-Verbose $config;
    Set-Content -Path $WssConfigurationPath -Value $config;

    java -jar $AgentPath -apiKey $WssApiKey -c $WssConfigurationPath -d $ScanPath
}
