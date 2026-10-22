@{
    # Only checks that catch real breakage or unsafe behaviour. Style rules such as
    # PSAvoidUsingWriteHost are intentionally not enabled: this is a console installer.
    Severity     = @('Error', 'Warning')
    IncludeRules = @(
        'PSAvoidUsingInvokeExpression',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSPossibleIncorrectComparisonWithNull',
        'PSPossibleIncorrectUsageOfAssignmentOperator',
        'PSUseCompatibleSyntax'
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
    }
}
