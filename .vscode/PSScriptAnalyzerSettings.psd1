@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        'PSUseApprovedVerbs'
        'PSUseSingularNouns'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSReviewUnusedParameter'
    )

    Rules = @{
        PSUseApprovedVerbs = @{
            Enable = $false
        }

        PSUseSingularNouns = @{
            Enable = $false
        }

        PSUseShouldProcessForStateChangingFunctions = @{
            Enable = $false
        }

        PSReviewUnusedParameter = @{
            Enable = $false
        }
    }
}
