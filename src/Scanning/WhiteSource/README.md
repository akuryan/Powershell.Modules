# Module

This module is used to ease whitesource scanning integration in different scanning scenarios, executed on machine with installed powershell. Also, it allows to define several mostly used parameters (by my use-cases) in configuration file, so - for big variety of projects there is no need to store WhiteSource configuration file repository.

## Caution

Script expects that you have Java installed on your system already.

## Usage

### Module parameters

#### Mandatory

```ProjectName``` - defines project name, as will be seen in WhiteSource Dashboard

#### Set by default

```ForceDownload``` - defines, if we need to redownload scanner file, even if it present and not stale (less than 15 days). Default value is ```$false```.

```AgentPath``` - defines, where whitesource agent shall be downloaded for further execution. Default value is temporary folder.

```WssConfigurationExists``` - boolean value which defines, if WSS configuration is stored within repository. Default valus is ```$false```. If set to ```$true``` - need to define path WSS configuration

### As is

```powershell
Import-Module .\whitesource-scanner.psm1
Scan-Sources 
```