# PSake makes variables declared here available in other scriptblocks
# Init some things
Properties {
    # Find the build folder based on build system
    $ProjectRoot = $ENV:BHProjectPath
    if (-not $ProjectRoot) {
        $ProjectRoot = Resolve-Path "$PSScriptRoot\.."
    }

    $Timestamp = Get-Date -UFormat "%Y%m%d-%H%M%S"
    $PSVersion = $PSVersionTable.PSVersion.Major
    $TestFile = "TestResults_PS$PSVersion`_$TimeStamp.xml"
    $SyntaxTestFile = "SyntaxTestResults_PS$PSVersion`_$TimeStamp.xml"
    $CodeCoverageFile = "CodeCoverage_PS$PSVersion`_$TimeStamp.xml"
    $lines = '----------------------------------------------------------------------'
    $excludes = @("Build\*", "Tests\*", "Deploy\*", ".vscode\*")

    $Verbose = @{ }
    if ($ENV:BHCommitMessage -match "!verbose") {
        $Verbose = @{Verbose = $True }
    }

    $masterRun = [bool]($ENV:BHBranchName -eq 'master' -or $ENV:BHCommitMessage -match '!masterdeploy')
    $testRun = [bool]($env:BHCommitMessage -match '!testdeploy')
    $pullRequestRun = [bool]($ENV:BHIsPullRequest)
    $commitRun = [bool]-not($masterRun -or $testRun -or $pullRequestRun)

    if ($masterRun -or $pullRequestRun -or $testRun) {
        #Azure connection info
        $azpswd = ConvertTo-SecureString -string "$ENV:AzureRunbooksCI_sppswd_test" -AsPlainText -Force
        $azcred = New-Object System.Management.Automation.PSCredential ("$ENV:AzureRunbooksCI_spuser_test", $azpswd)
        $null = Connect-AzAccount -Credential $azcred -ServicePrincipal -Tenant "$ENV:AzureRunbooksCI_TenantID" -WarningAction SilentlyContinue
        $resourceGroup = "$ENV:AzureRunbooksCI_rgname"
        $AutomationAccountTest = "$ENV:AzureRunbooksCI_aaname_test"
        $AutomationAccountProd = "$ENV:AzureRunbooksCI_aaname_prod"
    }
}

Task Default -Depends Init, Test, Build, Deploy

Task Init {
    $lines
    Set-Location $ProjectRoot
    "Build System Details:"
    #Get all the BuildHelper variables (prefixed with BH)
    #Piping to Out-Host to get the formatter to output properly
    Get-Item Env:BH* | Out-Host
    "`n"
}

Task Test {
    $lines
    "`n`tSTATUS: Testing with PowerShell $PSVersion"
    #CodeToSyntaxCheck = all powershell files, we want to verify they're valid powershell and don't have weird unicode characters
    #CodeCouldTest = Runbooks that have changed, we'll check later if they have corresponding Tests
    #CodeForProdVariables = Code where we'll look to extract Prod Azure Automation variable names
    #CodeForTestVariables = Same but only looking in Test runbooks
    #In a master run We only look at test variables for code we're deploying, so that we don't get overwhelmed with creating 150 new variables all at once
    #This way it will only fail as runbooks get deployed to the Test space
    if ($masterRun) {
        $codeToSyntaxCheck = Get-ChildItem $projectRoot -Include *.ps1, *.psm1, *.psd1 -Recurse
        $codeCouldTest = Get-ChildItem $projectRoot -Include *.ps1, *.psm1, *.psd1 -Recurse | Where-Object PSParentPath -NotMatch "Build|Tests|junk|Deploy|.vscode"
        $codeForProdVariables = $codeCouldTest
        $codeForTestVariables = Get-GitChangedFile -Include "*.ps1", "*.psm1", "*.psd1" -Exclude $excludes -DiffFilter "AMRC"
    } elseif ($pullRequestRun) {
        $codeToSyntaxCheck = Get-GitChangedFile -LeftRevision "origin/master" -Include "*.ps1", "*.psm1", "*.psd1" -DiffFilter "AMRC"
        $codeCouldTest = Get-GitChangedFile -LeftRevision "origin/master" -Include "*.ps1", "*.psm1", "*.psd1" -Exclude $excludes -DiffFilter "AMRC"
        $codeForProdVariables = $codeCouldTest
        $codeForTestVariables = $codeCouldTest
    } else {
        $codeToSyntaxCheck = Get-GitChangedFile -Include "*.ps1", "*.psm1", "*.psd1" -DiffFilter "AMRC"
        $codeCouldTest = Get-GitChangedFile -Include "*.ps1", "*.psm1", "*.psd1" -Exclude $excludes -DiffFilter "AMRC"
        $codeForProdVariables = $codeCouldTest
        $codeForTestVariables = $codeCouldTest
    }
    $testsToRun = @()
    $codeToTest = @()
    #Only run tests with Code Coverage on files that have corresponding tests, otherwise it takes 20 minutes to run
    foreach ($code in $codeCouldTest) {
        $name = Split-Path $code -Leaf
        $test = $name -replace ".ps1", ".Tests.ps1"
        $testpath = Join-Path "$projectRoot\Tests" $test
        if (Test-Path $testpath) {
            "found test $testpath for $code"
            $testsToRun += $testpath
            $codeToTest += $code
        }
    }

    #If you didn't include !skipcodecoverage then we'll check code coverage, otherwise not
    if ($ENV:BHCommitMessage -notmatch "!skipcodecoverage") {
        $codeCoverageParams = @{
            CodeCoverageOutputFile = "$ProjectRoot\Build\$CodeCoverageFile"
            CodeCoverage           = $codeToTest
        }
    } else {
        $codeCoverageParams = @{ }
    }

    $syntaxTests = @()

    if ($codeToSyntaxCheck) {
        $syntaxTests += @{Path = '.\Tests\Powershell.Tests.ps1'; Parameters = @{'scripts' = $codeToSyntaxCheck } }
    }

    if ($masterRun -or $pullRequestRun -or $testRun) {

        #The five Automation Resource command that could be in a runbook, and the corresponding AZ cmdlet to get resources of that type
        $sharedResourcesTypes = @(
            [PSCustomObject]@{command = 'Get-AutomationCertificate'; cget = 'Get-AzAutomationCertificate' }
            [PSCustomObject]@{command = 'Get-AutomationConnection'; cget = 'Get-AzAutomationConnection' }
            [PSCustomObject]@{command = 'Get-AutomationPSCredential'; cget = 'Get-AzAutomationCredential' }
            [PSCustomObject]@{command = 'Get-AutomationVariable'; cget = 'Get-AzAutomationVariable' }
            [PSCustomObject]@{command = 'Set-AutomationVariable'; cget = 'Get-AzAutomationVariable' }
        )

        foreach ($deployEnv in "test", "prod") {
            "checking for shared resources in $deployEnv"
            $usedVariables = @{ }
            $aaVars = @{ }
            $codeForVariables = Get-Variable -Name "codeFor$($deployEnv)Variables" -ValueOnly

            #find all instances of the resource command and use Regex to extract the Name of that resource along with it's type
            foreach ($file in $codeForVariables) {
                $filecontent = Get-Content $file -Raw
                foreach ($type in $sharedResourcesTypes) {
                    $uses = $filecontent | Select-String -Pattern "$($type.command)\s*(?:-Name)?\s+['`"]([\w\d-@]+)['`"]" -AllMatches
                    foreach ($use in $uses.Matches) {
                        Write-Verbose "found command $($type.command) with name $($use.Groups[1].Value)" @Verbose
                        $usedVariables.$($type.cget) += @($use.Groups[1].Value)
                    }
                }
            }

            #For every resource command with named resources, get all those resources from Azure with the corresponding AZ cmdlet
            foreach ($command in $usedVariables.Keys) {
                Write-Verbose "getting variables from Azure with command $command" @Verbose
                if ($Variables = Invoke-Expression "$command -ResourceGroupName $resourceGroup -AutomationAccountName $(Get-Variable -Name "AutomationAccount$DeployEnv" -ValueOnly)") {
                    Write-Verbose "found $($Variables.Count) for $command" @Verbose
                    $aaVars.$($command) += $Variables.Name
                }
            }
            #This sets the list of AA resources that are present in this environment
            Set-Variable -Name "$($deployEnv)aavars" -Value $aaVars

            #transform from a hashtable with each AZ command as a key to an array of hashtables containing the AZ command and variable name
            #This transform makes it easier to run the tests
            $usedVariables = foreach ($command in $usedVariables.Keys) {
                foreach ($val in $usedVariables.$($command)) {
                    @{'command' = $command; 'value' = $val }
                }
            }
            #This sets the list of AA resources that are used in the scripts in this environment
            Set-Variable -Name "used$($deployEnv)variables" -Value $usedVariables
        }
        if ($usedtestVariables) {
            $syntaxTests += @{Path = '.\Tests\AutomationVariables.Tests.ps1'; Parameters = @{'scriptvariables' = $usedtestVariables; 'aavariables' = $testAAvars; 'aaenv' = "test" } }
        }
        if ($usedprodVariables -and ($masterRun -or $pullRequestRun)) {
            $syntaxTests += @{Path = '.\Tests\AutomationVariables.Tests.ps1'; Parameters = @{'scriptvariables' = $usedprodVariables; 'aavariables' = $prodAAvars; 'aaenv' = "prod" } }
        }
    }

    # Gather test results. Store them in a variable and file
    $TestResults = Invoke-Pester -Script $testsToRun -PassThru -OutputFormat NUnitXml -OutputFile "$ProjectRoot\Build\$TestFile" @codeCoverageParams @Verbose
    $SyntaxResults = Invoke-Pester -Script $syntaxTests -PassThru -OutputFormat NUnitXml -OutputFile "$ProjectRoot\Build\$SyntaxTestFile" @Verbose

    # Failed tests?
    # Need to tell psake or it will proceed to the deployment. Danger!
    if ($TestResults.FailedCount -gt 0) {
        Write-Error "Failed '$($TestResults.FailedCount)' tests, build failed"
    }
    if ($SyntaxResults.FailedCount -gt 0) {
        Write-Error "Failed '$($TestResults.FailedCount)' syntax tests, build failed"
    }
    "`n"
}

Task Build -Precondition { ($masterRun -or $pullRequestRun -or $testRun) } {
    $lines

    #only build in master, test, or PR run
    if ($masterrun -or $testrun -or $pullRequestRun) {
        if ($masterrun) {
            $fileschanged = Get-GitChangedFile -Include "*.ps1" -Exclude $excludes -DiffFilter "AMRC"
        } elseif ($testrun -or $pullRequestRun) {
            $fileschanged = Get-GitChangedFile -Include "*.ps1" -Exclude $excludes -LeftRevision "origin/master" -DiffFilter "AMRC"
        }
        $filestobuild = @()
        #find all files with a corresponding function file
        foreach ($filepath in $fileschanged) {
            $file = Split-Path $filepath -Leaf
            Write-Host "Found $file"
            if ($file -like "*-Functions.ps1") {
                $filestobuild += $file -replace "-Functions.ps1", ".ps1"
            } else {
                $filestobuild += $file
            }
        }
        $filestobuild = $filestobuild | Select-Object -Unique
        foreach ($filebuild in $filestobuild) {
            Write-Host "Building $filebuild"
            $functionfile = $filebuild -replace ".ps1", "-Functions.ps1"
            $rbfile = Get-Content $filebuild -Raw
            if ($masterrun) {
                #prod errors should generate incidents
                $errormail = "incident@contoso.com"
            } elseif ($pullRequestRun) {
                #these builds will be in test, so failures here will go to the team but not open incidents (closing incidents is a lot of clicking)
                $errormail = "team@contoso.com"
            } elseif ($testrun) {
                if ($ENV:BUILD_REQUESTEDFOREMAIL) {
                    #if we can determine who made this commit, set their email as the error
                    $errormail = $ENV:BUILD_REQUESTEDFOREMAIL
                } else {
                    #if we can't determine fallback to the group list
                    $errormail = "incident@contoso.com"
                }
            }
            #insert the functions into the RB
            if (Test-Path $functionfile) {
                $functions = Get-Content $functionfile -Raw
                $rbfile = $rbfile.Replace("##$functionfile`_goes_here##", $functions)
            }
            if ($errormail) {
                $pattern = '(?:\r|\n|\r\n)\s+(\$errorEmail[ ]?=[ ]?.+)(?:\r|\n|\r\n)'
                if ($result = $rbfile | Select-String -Pattern $pattern -AllMatches) {
                    if ($result.Matches.Count -eq 1) {
                        $rbfile = $rbfile.replace($result.Matches.Groups[1].Value, "`$errorEmail = '$errormail'")
                    } else {
                        Write-Warning "`$errorEmail definition appears multiple times in $filebuild, we won't be doing anything here to be safe"
                    }
                }
            }
            $rbfile | Set-Content ".\Deploy\$filebuild" -Encoding UTF8 -NoNewline -Force
        }
    } else {
        "Not in master, test, or pull request, not building"
    }
    "`n"
}

Task Deploy -Precondition { ($masterRun -or $pullRequestRun -or $testRun) } {
    $lines

    if ($masterrun -or $testrun -or $pullRequestRun) {
        if ($masterrun) {
            "getting runbooks"
            $rbs = Get-AzAutomationRunbook -ResourceGroupName $resourceGroup -AutomationAccountName $AutomationAccountProd | Select-Object Name, LastModifiedTime
        } else {
            $rbs = $null
        }
        $filestodeploy = Get-ChildItem "Deploy\*" -Include "*.ps1", "*.py"
        foreach ($file in $filestodeploy) {
            Write-Host "deploying $($file.name)"
            $ext = $file.Extension
            $name = $file.BaseName
            $type = if ($ext -eq ".ps1") { "PowerShell" }
            elseif ($ext -eq ".py") { "Python2" }
            else { throw "something went wrong, file is not a Python or PowerShell script" }
            Write-Host "test deploy of $($file.name)"
            Import-AzAutomationRunbook -Path $file.FullName -Type $type -Published -ResourceGroupName $resourceGroup -AutomationAccountName $AutomationAccountTest -Force
            if ($masterrun) {
                Write-Host "prod deploy of $($file.name)"
                if ($rbs.Name -notcontains $name) {
                    Write-Warning "$name does not exist, this will create it"
                }
                "deploying $name"
                Import-AzAutomationRunbook -Path $file.FullName -Type $type -Published -ResourceGroupName $resourceGroup -AutomationAccountName $AutomationAccountProd -Force
            }
        }
    }
}
