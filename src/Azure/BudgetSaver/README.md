# Costs saver for Azure

This module is designed to save on costs of resources in Azure. Usually, one is not using Test and Acceptance resources during nights and weekends, but not everybody can afford themselves to destroy those resources and recreate them (complex configurations, too much manual interventions, whateverYouNameIt).
So, I created this small script, which requires your connection to Azure RM and wants your resource group name to proceed.

If you select to downscale your resources (suggestion: run it at evening) - it will find all SQL databases, all web apps and all VMs belonging to given resource group and will downscale web apps and sql databases to lowest possible size, vm's will be deprovisioned. If you select to upscale resources - script will read tags on them and upscale resources (web app and sql databases), vm's will be started.

SQL databases sizes tags are stored on SQL server resource, as they tend to dissappear on SQL database resource.

## Word of advise

Be extra careful when modifying this module, as it consumed by Teamcity metarunner and VSTS extension. While VSTS extension itself will be OK with changes (it needs nuget to be installed and package will be pushed with preinstalled nuget), Teamcity metarunner will install nuget package on runtime.

## Issues

1. Script will silently fail if you try to run upscaling before downscaling

1. Script will fail if Tags are missing

## Use case

Downscale Azure resources for Testing and Acceptance environments during nights and weekends to save on costs.

## Distribution

Module could be used as is, installed as [Nuget package](), could be installed at [Teamcity with metarunner]() or as [extension at VSTS](https://github.com/akuryan/vsts.extensions/tree/master/AzureCostsSaver).

## Usage

### As is

```powershell
Import-Module .\azure-costs-saver.psm1
Set-ResourceSizesForCostsSaving -ResourceGroupName $rgName -Downscale ($true|$false) -executionEnv manual
```

Do not forget to login :) to Azure 

### VSTS extension

See [VSTS marketplace](https://marketplace.visualstudio.com/items?itemName=anton-kuryan.AzureCostsSaver) or [blog post](https://colours.nl/azure-costs-saver)

### Teamcity metarunner

To be written
