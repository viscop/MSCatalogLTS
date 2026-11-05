function Get-UpdateSupersedenceBatch {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Guids
    )

    if (-not (Get-Variable -Name MSCatalogSupersedenceCache -Scope Script -ErrorAction SilentlyContinue)) {
        $script:MSCatalogSupersedenceCache = @{}
    }
    $cache = $script:MSCatalogSupersedenceCache
    $now = [DateTime]::UtcNow
    foreach ($guid in @($cache.Keys)) {
        if (($now - $cache[$guid].FetchedAt).TotalMinutes -ge 5) {
            $cache.Remove($guid)
        }
    }

    $results = @{}
    $missing = @()
    $seen = @{}
    foreach ($guid in $Guids) {
        if ($seen.ContainsKey($guid)) { continue }
        $seen[$guid] = $true
        if ($cache.ContainsKey($guid)) {
            $results[$guid] = $cache[$guid].Metadata
        } else {
            $missing += $guid
        }
    }
    if ($missing.Count -gt 0) {
        Write-Verbose "Fetching supersedence for $($missing.Count) updates (up to four concurrent requests, 20-second timeout)."
        $responses = Invoke-CatalogDetailRequests -Guids $missing
        foreach ($guid in $missing) {
            $metadata = Get-UpdateSupersedence -Guid $guid -Response $responses[$guid]
            $results[$guid] = $metadata
            # Failed lookups must be retried on the next command invocation.
            if ($metadata.Status -in @('Retrieved', 'Partial')) {
                $cache[$guid] = @{ FetchedAt = [DateTime]::UtcNow; Metadata = $metadata }
            }
        }
        # Keep the session cache bounded when many different searches are made.
        while ($cache.Count -gt 256) {
            $oldest = $cache.Keys | Sort-Object { $cache[$_].FetchedAt } | Select-Object -First 1
            $cache.Remove($oldest)
        }
    }
    return $results
}
