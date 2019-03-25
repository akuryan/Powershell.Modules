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
    
    $regExp = "(#)?" + $variableName + "=(.*)";
    $replacement = $variableName + "=" + $variableValue;
    $configAltered = $config -replace $regExp, $replacement;
    return $configAltered;
}


function Scan-Sources {
    param (
        [bool]$ForceDownload = $false,
        [string]$AgentPath = "$env:temp/wss-unified-agent.jar",
        [Parameter(Mandatory=$true)]
        [string]$ProjectName,
        [string]$WssConfigurationPath,
        [string]$ExcludeFoldersFromScan,
        [Parameter(Mandatory=$true)]
        [string]$Version,
        [string]$FileScanPattern,
        [Parameter(Mandatory=$true)]
        [string]$WssApiKey,
        [Parameter(Mandatory=$true)]
        [string]$ScanPath
    )

    DownloadDataWithCheckForStaleness -forceDownload $ForceDownload -filePath $AgentPath -urlToDownload "https://github.com/whitesource/unified-agent-distribution/raw/master/standAlone/wss-unified-agent.jar";

    $WssConfigurationExists = $true;
    if (![string]::IsNullOrWhiteSpace($WssConfigurationPath)) {
        $WssConfigurationExists = Test-Path $WssConfigurationPath;
    } else {
        $WssConfigurationExists = $false;
    }
    
    if (!$WssConfigurationExists) {
        $WssConfigurationPath = "$env:temp/$ProjectName/wss-unified-agent.config";
        DownloadDataWithCheckForStaleness -forceDownload $false -filePath $WssConfigurationPath -urlToDownload "https://github.com/whitesource/unified-agent-distribution/raw/master/standAlone/wss-unified-agent.config";

        $config = Get-Content -Path $WssConfigurationPath;

        if (![string]::IsNullOrWhiteSpace($ExcludeFoldersFromScan)) {
            $config = ReplaceVariables -config $config -variableName "projectPerFolderExcludes" -variableValue $ExcludeFoldersFromScan;
        }
        if (![string]::IsNullOrWhiteSpace($FileScanPattern)) {
            ReplaceVariables -config $config -variableName "includes" -variableValue $FileScanPattern;
        }
        ReplaceVariables -config $config -variableName "projectVersion" -variableValue $Version;
        ReplaceVariables -config $config -variableName "productVersion" -variableValue $Version;

        ReplaceVariables -config $config -variableName "projectName" -variableValue $ProjectName;
        ReplaceVariables -config $config -variableName "productName" -variableValue $ProjectName;

        Set-Content -Path $WssConfigurationPath -Value $config;
    }

    java -jar whitesource-fs-agent.jar -apiKey $WssApiKey -c $WssConfigurationPath -d $ScanPath
}