@{
  Severity     = @('Error', 'Warning', 'Information')
  ExcludeRules = @(
    'PSUseShouldProcessForStateChangingFunctions',
    'PSUseSingularNouns',
    'PSReviewUnusedParameter',
    'PSUseDeclaredVarsMoreThanAssignments'
  )
}
