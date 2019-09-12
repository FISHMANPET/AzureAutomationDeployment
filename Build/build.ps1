param ($Task = 'Default')
#$VerbosePreference = 'Continue'

# Grab nuget bits, install modules, set build variables, start build.
Get-PackageProvider -Name NuGet -ForceBootstrap | Out-Null


#I've made a number of PRs against the BuildHelpers project and some have been accepted but some are being ignored
#I have a branch in my fork, called umnmaster
#https://github.com/FISHMANPET/BuildHelpers/tree/umnmaster
#This branch contains my pull requests, and is the version deployed in Azure Artifacts that will be downloaded
#If my changes get merged and pushed to the PSGallery that step can be disabled, and this will default to using the gallery version
if (Test-Path "$ENV:System_ArtifactsDirectory\BuildHelpers.psd1") {
    #If we have downloaded a version of BuildHelpers locally we'll use that
    Import-Module "$ENV:System_ArtifactsDirectory\BuildHelpers.psd1"
} else {
    #We didn't download a copy locally so let's get it from the gallery
    Install-Module BuildHelpers -Force
}

Install-Module Psake, Pester -Force -WarningAction SilentlyContinue
Import-Module Psake

#az 2.3.2 has been tested to work so if that exists lets use that
if (Test-Path "C:\Modules\az_2.3.2") {
    $azpath = "C:\Modules\az_2.3.2"
} else {
    #If not, let's find the lowest version after 2.3.2 and use that
    Write-Warning "C:\Modules\az_2.3.2 not found, looking for other versions like C:\Modules\az_*"
    if ($allAz = Get-ChildItem "C:\Modules\az_*") {
        $allAzVersions = [version[]]$allAz.Name.Trim("az_")
        foreach ($azversion in ($allAzVersions | Sort-Object)) {
            if ($azversion -gt [version]"2.3.2") {
                Write-Warning "Found az version $azversion, using that"
                $azpath = "C:\Modules\az_$($azversion)"
                break
            }
        }
    }
}
if (-not $azpath) {
    #We didn't find any version, maybe the az module moved?
    #This will fail the task and require some manual investigation
    throw "No acceptable version of az module found"
}
$env:PSModulePath = $azpath + ";" + $env:PSModulePath
Import-Module Az.Accounts, Az.Automation -WarningAction SilentlyContinue

Set-BuildEnvironment

Invoke-psake -buildFile .\Build\psake.ps1 -taskList $Task -nologo
exit ( [int]( -not $psake.build_success ) )
