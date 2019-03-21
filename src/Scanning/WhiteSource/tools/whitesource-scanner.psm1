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

    return $downloadRequired;
}


function Scan-Sources {
    param (
        [bool]$ForceDownload = $false,
        [string]$AgentPath = "$env:temp/wss-unified-agent.jar",
        [Parameter(Mandatory=$true)]
        [string]$ProjectName,
        [Parameter(ParameterSetName="ConfigExists")]
        [bool]$WssConfigurationExists = $false,
        [Parameter(ParameterSetName="ConfigExists", Mandatory=$true)]
        [string]$WssConfigurationPath
    )

    DownloadDataWithCheckForStaleness -forceDownload $ForceDownload -filePath $AgentPath -urlToDownload "https://github.com/whitesource/unified-agent-distribution/raw/master/standAlone/wss-unified-agent.jar";

    $configWasDownloaded = $true;

    if (!$WssConfigurationExists) {
        $WssConfigurationPath = "$env:temp/$ProjectName/wss-unified-agent.config";
        $configWasDownloaded = DownloadDataWithCheckForStaleness -forceDownload $false -filePath $WssConfigurationPath -urlToDownload "https://github.com/whitesource/unified-agent-distribution/raw/master/standAlone/wss-unified-agent.config"
    }

    
}