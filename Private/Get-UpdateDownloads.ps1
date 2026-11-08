function Get-UpdateDownloads {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Guid
    )

    try {
        $links = @(Get-UpdateLinks -Guid $Guid -ValidateResponse -ErrorAction Stop)
        $downloads = @()
        $seenUrls = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($link in $links) {
            $url = [string] $link.URL
            $uri = $null
            if (-not [uri]::TryCreate($url, [UriKind]::Absolute, [ref] $uri) -or
                $uri.Scheme -notin @('http', 'https') -or -not $uri.Host -or
                -not $uri.IsWellFormedOriginalString() -or $url -match '%(?![0-9a-fA-F]{2})') {
                throw "Malformed download URL: '$url'."
            }
            $fileName = [uri]::UnescapeDataString(($uri.AbsolutePath -split '/')[-1])
            if ([string]::IsNullOrWhiteSpace($fileName)) {
                throw "Download URL has no filename: '$url'."
            }

            $sha1 = $null
            if ($null -ne $link.SHA1) {
                $digest = [string] $link.SHA1
                if ($digest -cmatch '^[0-9a-fA-F]{40}$') {
                    $sha1 = $digest.ToUpperInvariant()
                } else {
                    try { $bytes = [Convert]::FromBase64String($digest) }
                    catch { throw "Invalid SHA-1 metadata for '$url': expected a hexadecimal or Base64 SHA-1 digest." }
                    if ($bytes.Length -ne 20) {
                        throw "Invalid SHA-1 metadata for '$url': expected 20 bytes, received $($bytes.Length)."
                    }
                    $sha1 = [BitConverter]::ToString($bytes).Replace('-', '')
                }
            }

            # Validate every entry before deduplication so an invalid duplicate
            # cannot hide a technical error. Retain the first entry for each URL.
            if ($seenUrls.Add($url)) {
                $kb = $null
                if ($link.KB) { $kb = "KB$($link.KB)" }
                $downloads += [PSCustomObject]@{
                    Url = $url
                    FileName = $fileName
                    KB = $kb
                    SHA1 = $sha1
                }
            }
        }
        # Emit only once every entry has passed validation.
        $downloads
    } catch {
        throw "Failed to retrieve downloads for update GUID '$Guid': $($_.Exception.Message)"
    }
}
