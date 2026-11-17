function Select-NonSupersededUpdate {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Updates,

        [switch] $ResolveSupersedence
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $candidates = @($Updates)
    $byGuid = @{}
    $byTitle = @{}
    $active = @{}
    $resolved = @{}
    $replacedBy = @{}
    $lookups = 0
    $reused = 0

    # Keep every original row for output and metadata propagation. Duplicate GUIDs
    # share one resolution and are one identity when checking title uniqueness.
    foreach ($update in $candidates) {
        if (-not $update.Guid) { continue }
        $guid = [string] $update.Guid
        if (-not $byGuid.ContainsKey($guid)) {
            $byGuid[$guid] = [System.Collections.Generic.List[object]]::new()
            $active[$guid] = $true
        }
        $byGuid[$guid].Add($update)
        $titleKey = ([HtmlAgilityPack.HtmlEntity]::DeEntitize([string] $update.Title) -replace '\s+', ' ').Trim()
        if ($titleKey) {
            if (-not $byTitle.ContainsKey($titleKey)) { $byTitle[$titleKey] = @{} }
            $byTitle[$titleKey][$guid] = $true
        }
    }

    Write-Verbose "Starting supersedence resolution for $($candidates.Count) candidates ($($byGuid.Count) unique GUIDs)."

    # Match against the ORIGINAL eligible set, never a progressively smaller title
    # index. Otherwise eliminating one duplicate title could make an ambiguity
    # appear to be a valid identity. An explicit external GUID always takes priority.
    $resolveIdentity = {
        param ($Relationship)
        if ($Relationship.Guid) {
            if ($byGuid.ContainsKey([string] $Relationship.Guid)) { [string] $Relationship.Guid }
        } else {
            $key = ([HtmlAgilityPack.HtmlEntity]::DeEntitize([string] $Relationship.Title) -replace '\s+', ' ').Trim()
            if ($key -and $byTitle.ContainsKey($key) -and $byTitle[$key].Count -eq 1) {
                foreach ($id in $byTitle[$key].Keys) { $id }
            }
        }
    }

    $ordered = @($candidates | Sort-Object @{ Expression = 'LastUpdated'; Descending = $true }, Guid)
    foreach ($candidate in $ordered) {
        $guid = [string] $candidate.Guid
        if (-not $guid -or -not $active.ContainsKey($guid) -or $resolved.ContainsKey($guid)) { continue }
        $resolved[$guid] = $true

        $update = $byGuid[$guid] | Where-Object { $_.SupersedenceStatus -in @('Retrieved', 'Partial') } | Select-Object -First 1
        if ($null -ne $update) {
            $reused++
        } elseif ($ResolveSupersedence) {
            $lookups++
            $batch = Get-UpdateSupersedenceBatch -Guids @($guid)
            $metadata = if ($null -ne $batch) { $batch[$guid] } else { $null }
            if ($null -eq $metadata) {
                $metadata = [PSCustomObject]@{
                    Supersedes = $null; SupersededBy = $null; Status = 'Failed'
                    Error = "No supersedence metadata was returned for $guid."
                }
                Write-Warning $metadata.Error
            }
            $update = $candidate
            $update.Supersedes = if ($metadata.Supersedes.Count -gt 0) { $metadata.Supersedes } else { $null }
            $update.SupersededBy = if ($metadata.SupersededBy.Count -gt 0) { $metadata.SupersededBy } else { $null }
            $update.SupersedenceStatus = $metadata.Status
            $update.SupersedenceError = $metadata.Error
        } else {
            continue
        }

        foreach ($row in $byGuid[$guid]) {
            $row.Supersedes = $update.Supersedes
            $row.SupersededBy = $update.SupersededBy
            $row.SupersedenceStatus = $update.SupersedenceStatus
            $row.SupersedenceError = $update.SupersedenceError
        }
        # Failed lookups provide no evidence. Other successful candidates may
        # still prove that this candidate is superseded later in the traversal.
        if ($update.SupersedenceStatus -notin @('Retrieved', 'Partial')) { continue }

        foreach ($relationship in $update.Supersedes) {
            $target = & $resolveIdentity $relationship
            if ($target -and $target -ne $guid -and $active.ContainsKey($target)) {
                $active.Remove($target)
                $replacedBy[$target] = $guid
                Write-Verbose "Excluded $target : replaced by $guid within the selected results."
            }
        }

        foreach ($relationship in $update.SupersededBy) {
            $replacement = & $resolveIdentity $relationship
            if (-not $replacement) { continue }
            # A replacement may itself have been replaced. Follow only confirmed
            # in-set exclusions to a retained candidate; never fetch related pages.
            while ($replacedBy.ContainsKey($replacement)) {
                $replacement = $replacedBy[$replacement]
            }
            # Ignoring a path back to this update prevents contradictory cycles
            # from removing every candidate. Dates alone never justify removal.
            if ($replacement -ne $guid -and $active.ContainsKey($replacement)) {
                $active.Remove($guid)
                $replacedBy[$guid] = $replacement
                Write-Verbose "Excluded $guid : replaced by $replacement within the selected results."
                break
            }
        }
    }

    # Internal evaluation order must not change the caller's final output order.
    $remaining = @($candidates | Where-Object { -not $_.Guid -or $active.ContainsKey([string] $_.Guid) })
    $timer.Stop()
    Write-Verbose "Supersedence resolution completed: $lookups metadata lookups through the cache, $reused supplied metadata snapshots reused, $($candidates.Count - $remaining.Count) candidates eliminated, $($remaining.Count) candidates remaining; duration $($timer.Elapsed.TotalSeconds.ToString('F3', [cultureinfo]::InvariantCulture)) seconds."
    $remaining
}
