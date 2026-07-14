@{
    # Loki lint rules (CI gate, identical locally via build/Invoke-Checks.ps1).
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # Loki is an interactive terminal CLI: Write-Host is the deliberate console channel
        # (colour, immediate output). Machine-readable output runs separately via --json/stdout.
        'PSAvoidUsingWriteHost',

        # Command/stub handlers have 'param($Context)' by contract, even when a given
        # handler doesn't use the context. The rule would only produce noise here.
        'PSReviewUnusedParameter'
    )

    # Deliberately NOT excluded (real 5.1 / API gates):
    #   PSUseBOMForUnicodeEncodedFile  -> otherwise 5.1 reads non-ASCII as the ANSI codepage (mojibake).
    #   PSUseSingularNouns, PSUseApprovedVerbs, PSAvoidUsingCmdletAliases, ...
}
