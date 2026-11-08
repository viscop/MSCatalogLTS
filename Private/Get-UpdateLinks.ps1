function Get-UpdateLinks {
    [CmdletBinding()]
    param (
        [Parameter(
            Mandatory = $true,
            Position = 0
        )]
        [String] $Guid,

        # Opt-in validation for metadata consumers; legacy callers retain their
        # existing return values, deduplication and ordering.
        [switch] $ValidateResponse
    )

    $Post = @{size = 0; UpdateID = $Guid; UpdateIDInfo = $Guid} | ConvertTo-Json -Compress
    $Body = @{UpdateIDs = "[$Post]"}
    
    $Params = @{
        Uri = "https://www.catalog.update.microsoft.com/DownloadDialog.aspx"
        Body = $Body
        ContentType = "application/x-www-form-urlencoded"
        UseBasicParsing = $true
    }

    if ($ValidateResponse) { $Params.ErrorAction = 'Stop' }
    $DownloadDialog = Invoke-WebRequest @Params
    $Links = $DownloadDialog.Content -replace "www.download.windowsupdate", "download.windowsupdate"

    # NEW: Capture ALL downloadInformation arrays (not just [0])
    # This regex matches downloadInformation[ANY_INDEX].files[ANY_INDEX].url
    $Regex = "downloadInformation\[(\d+)\]\.files\[(\d+)\]\.url\s*=\s*'([^']*)'"
    $DownloadMatches = [regex]::Matches($Links, $Regex)

    if ($ValidateResponse) {
        # An initialized array with no file records is a successful empty result.
        # Missing markup or incomplete assignments are parsing failures instead.
        if ($Links -notmatch 'downloadInformation\s*=\s*(?:new\s+Array\s*\(\s*\)|\[\s*\])\s*;' -or
            $Links -match 'id\s*=\s*["'']errorPageDisplayedError["'']') {
            throw "Unrecognized DownloadDialog response for update GUID '$Guid'."
        }
        $filePattern = 'downloadInformation\[(\d+)\]\.files\[(\d+)\]'
        $fileKeys = @([regex]::Matches($Links, $filePattern) | ForEach-Object {
            "$($_.Groups[1].Value)_$($_.Groups[2].Value)"
        } | Select-Object -Unique)
        foreach ($field in @('url', 'digest')) {
            $assignments = [regex]::Matches($Links, "$filePattern\.$field\s*=")
            $complete = [regex]::Matches($Links, "$filePattern\.$field\s*=\s*'([^']*)'\s*;")
            if ($assignments.Count -ne $complete.Count) {
                throw "Malformed $field assignment in DownloadDialog for update GUID '$Guid'."
            }
            $keys = @($complete | ForEach-Object { "$($_.Groups[1].Value)_$($_.Groups[2].Value)" })
            if (@($keys | Select-Object -Unique).Count -ne $keys.Count) {
                throw "Duplicate $field assignment in DownloadDialog for update GUID '$Guid'."
            }
        }
        if ($fileKeys.Count -ne $DownloadMatches.Count) {
            throw "Incomplete download file records for update GUID '$Guid'."
        }
    }

    if ($DownloadMatches.Count -eq 0) {
        Write-Verbose "No download links found in response."
        if ($ValidateResponse) { return }
        return $null
    }

    Write-Verbose "Found $($DownloadMatches.Count) download link(s) in response."

    # Build a lookup of SHA1 digests (base64) keyed by "downloadInfoIndex_fileIndex"
    $DigestRegex = "downloadInformation\[(\d+)\]\.files\[(\d+)\]\.digest\s*=\s*'([^']*)'"
    $DigestMatches = [regex]::Matches($Links, $DigestRegex)
    $DigestMap = @{}
    foreach ($DigestMatch in $DigestMatches) {
        $DigestKey = "$($DigestMatch.Groups[1].Value)_$($DigestMatch.Groups[2].Value)"
        $DigestMap[$DigestKey] = $DigestMatch.Groups[3].Value
    }

    $KbLinks = foreach ($Match in $DownloadMatches) {
        $InfoIdx = $Match.Groups[1].Value
        $FileIdx = $Match.Groups[2].Value
        $Url = $Match.Groups[3].Value

        # Try to extract KB number from the URL (if present)
        $KbNumber = 0
        if ($Url -match 'kb(\d+)') {
            $KbNumber = [int]$Matches[1]
        }

        $Sha1Base64 = if ($ValidateResponse) { $null } else { "" }
        $DigestKey = "${InfoIdx}_${FileIdx}"
        if ($DigestMap.ContainsKey($DigestKey)) {
            $Sha1Base64 = $DigestMap[$DigestKey]
        }

        [PSCustomObject]@{
            URL = $Url
            KB  = $KbNumber
            DownloadInfoIndex = [int]$InfoIdx
            FileIndex = [int]$FileIdx
            SHA1 = $Sha1Base64
        }
    }
    
    if ($ValidateResponse) {
        # Preserve every record for validation, including duplicate URLs. Numeric
        # file indexes give deterministic order independent of script line order.
        return $KbLinks | Sort-Object DownloadInfoIndex, FileIndex
    }

    # Remove duplicates based on URL
    $UniqueLinks = $KbLinks | Group-Object -Property URL | ForEach-Object { $_.Group[0] }
    
    return $UniqueLinks | Sort-Object KB -Descending
}
