. $PSScriptRoot\..\Example-Runbook-Functions.ps1

Describe "Test-Function" {
    It "returns output" {
        Test-Function | Should -Be "This is a test"
    }
}
