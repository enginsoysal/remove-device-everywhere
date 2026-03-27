@{
    Severity = @('Error', 'Warning')

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
