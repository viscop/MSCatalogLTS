function Select-NonSupersededUpdate {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Updates
    )

    $candidates = @($Updates)
    $byGuid = @{}
    foreach ($update in $candidates) {
        if ($update.Guid) { $byGuid[$update.Guid] = $update }
    }

    foreach ($update in $candidates) {
        $isSuperseded = $false
        if ($update.SupersedenceStatus -in @('Retrieved', 'Partial')) {
            foreach ($replacement in $update.SupersededBy) {
                # Only a GUID match to another eligible result is proof that the
                # update is replaced within this selection. Never infer from KBs.
                if ($replacement.Guid -and $replacement.Guid -ne $update.Guid -and
                    $byGuid.ContainsKey($replacement.Guid)) {
                    $isSuperseded = $true
                    Write-Verbose "Excluded $($update.Guid): replaced by $($replacement.Guid) within the selected results."
                    break
                }
            }
        }
        if (-not $isSuperseded) { $update }
    }
}
