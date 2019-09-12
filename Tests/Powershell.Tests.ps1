param(
    $scripts
)

Describe "General project validation" {

    $predicate = {
        param ( $ast )

            if ($ast -is [System.Management.Automation.Language.BinaryExpressionAst] -or
                $ast -is [System.Management.Automation.Language.CommandParameterAst] -or
                $ast -is [System.Management.Automation.Language.AssignmentStatementAst] -or
                $ast -is [System.Management.Automation.Language.UnaryExpressionAst] -or
                $ast -is [System.Management.Automation.Language.ConstantExpressionAst]) {

                if ($ast.Extent.Text[0] -in 0x2013, 0x2014, 0x2015) {
                    return $true
                }
            }

            if (($ast -is [System.Management.Automation.Language.UnaryExpressionAst] -or
                    $ast -is [System.Management.Automation.Language.BinaryExpressionAst]) -and
                $ast.Extent.Text -match '\u2013|\u2014|\u2015') {
                return $true
            }

            if ($ast -is [System.Management.Automation.Language.CommandAst] -and
                $ast.GetCommandName() -match '\u2013|\u2014|\u2015') {
                return $true
            }

            if (($ast -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                    $ast -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
                (($ast.Parent -is [System.Management.Automation.Language.CommandExpressionAst]) -or
                    $ast.Parent -is [System.Management.Automation.Language.BinaryExpressionAst])) {
                if ($ast.Parent -match '^[\u2018-\u201e]|[\u2018-\u201e]$') {
                    return $true
                }
            }
    }

    # TestCases are splatted to the script so we need hashtables
    $testCase = $scripts | Foreach-Object {@{file = $_}}
    It "Script <file> should be valid powershell" -TestCases $testCase {
        param (
            $file
        )
        $script = Get-Content -Raw -Encoding UTF8 -Path $file
        $tokens = $errors = @()
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Script, [Ref]$tokens, [Ref]$errors)
        $elements = $ast.FindAll($predicate, $true)

        $elements | Should -BeNullOrEmpty -Because $elements
        $errors | Should -BeNullOrEmpty -Because $errors
    }
}
