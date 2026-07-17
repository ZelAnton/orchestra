@{
    Severity = @('Error', 'Warning', 'ParseError')

    ExcludeRules = @(
        # These are command-line tools and test harnesses; host output is their intentional user interface.
        'PSAvoidUsingWriteHost'

        # Internal helpers use domain nouns such as Events and Paths; they are not exported PowerShell commands.
        'PSUseSingularNouns'

        # Internal command dispatchers mirror CLI verbs such as Cmd/Require/Parse and are never exported as cmdlets.
        'PSUseApprovedVerbs'

        # State changes are guarded by the repository policy/transaction layer, not by PowerShell ShouldProcess.
        'PSUseShouldProcessForStateChangingFunctions'

        # Best-effort cleanup and platform capability probes deliberately ignore failures after bounded attempts.
        'PSAvoidUsingEmptyCatchBlock'

        # Repository scripts are cross-platform UTF-8 without BOM; adding a BOM only for Windows PowerShell is unwanted drift.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
