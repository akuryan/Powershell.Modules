# Module

This module is used to ease whitesource scanning integration in different scanning scenarios, executed on machine with installed powershell. Also, it allows to define several mostly used parameters (by my use-cases) in configuration file, so - for big variety of projects there is no need to store WhiteSource configuration file repository.

## Caution

Script expects that you have Java installed on your system already.

## Usage

### Module parameters

#### Mandatory

```Version``` - version to be sent to WhiteSource. Marked as mandatory, as you shall bump it up every scan.

```WssApiKey``` - API key for WhiteSource

```ScanPath``` - Root path to start scanning for

#### Set by default

```ForceDownload``` - defines, if we need to redownload scanner file, even if it present and not stale (less than 15 days). Default value is ```$false```.

```AgentPath``` - defines, where whitesource agent shall be downloaded for further execution. Default value is temporary folder.

#### Optional

```FileScanPattern``` - Comma, space or line separated list of Ant-style GLOB patterns specifying which files to include in the scan. 

```WssConfigurationPath``` - Specify path to config file for WhiteSource analyzer. If not specified - it will be downloaded

```ProjectName``` - defines project name, as will be seen in WhiteSource Dashboard (works only if config is not defined)

### As is

Without predefined configuration:

```powershell
Import-Module .\whitesource-scanner.psm1
Scan-Sources -ProjectName "youProjectName" -Version "x.x.x.x" -FileScanPattern "**/*.cs **/*.js **/*.scss **/*.jsx" -WssApiKey "youWhiteSourceApiKey" -ScanPath "youProjectRootFolder"
```

With predefined configuration:

```powershell
Import-Module .\whitesource-scanner.psm1
Scan-Sources -WssApiKey "youWhiteSourceApiKey" -ScanPath "youProjectRootFolder" -Version "x.x.x.x"  -WssConfigurationPath "youWhiteSourceConfigFile"
```