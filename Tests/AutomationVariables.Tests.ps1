param(
    $scriptvariables,
    $aavariables,
    $aaenv
)

Describe "Automation Variables - $aaenv" {

    It "$aaenv has variable <value> for <command>" -TestCases $scriptvariables {
        param (
            $command,
            $value
        )
        $aavariables.$($command) | Should -Contain $value
    }
}
