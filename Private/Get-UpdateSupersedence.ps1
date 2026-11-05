function Get-UpdateSupersedence {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Guid,

        # Allows the batch loader to reuse this parser without another request.
        [Parameter(Mandatory = $false)]
        [object] $Response
    )

    $result = [PSCustomObject]@{
        Supersedes = $null
        SupersededBy = $null
        Status = 'Failed'
        Error = $null
    }

    try {
        Set-TempSecurityProtocol
        $uri = "https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=$([uri]::EscapeDataString($Guid))"
        if (-not $PSBoundParameters.ContainsKey('Response')) {
            $Response = Invoke-WebRequest -Uri $uri -UseBasicParsing -ErrorAction Stop -TimeoutSec 20
        } elseif ($Response.Error) {
            throw $Response.Error
        }
        $doc = [HtmlAgilityPack.HtmlDocument]::new()
        $doc.LoadHtml($response.Content)

        $identity = $doc.GetElementbyId('ScopedViewHandler_UpdateID')
        if ($null -eq $identity -or $identity.InnerText.Trim() -ne $Guid) {
            throw 'The detail page is missing the requested update identity.'
        }

        $relationships = @{}
        $hasTitleOnly = $false
        foreach ($property in @('Supersedes', 'SupersededBy')) {
            $id = if ($property -eq 'Supersedes') { 'supersedesInfo' } else { 'supersededbyInfo' }
            $container = $doc.GetElementbyId($id)
            if ($null -eq $container) {
                throw "The detail page is missing $id."
            }

            $entries = @()
            $seen = @{}
            $text = [HtmlAgilityPack.HtmlEntity]::DeEntitize($container.InnerText).Trim()
            if ($text -eq 'n/a') {
                if ($null -ne $container.SelectSingleNode('./*')) {
                    throw "Unrecognized empty-list metadata in $id."
                }
            } else {
                # Catalog renders each relationship in a direct child div. Some have
                # only a title; do not guess a GUID from a title or KB number.
                foreach ($child in $container.ChildNodes) {
                    if (($child.NodeType -eq 'Element' -and $child.Name -ne 'div') -or
                        ($child.NodeType -eq 'Text' -and -not [string]::IsNullOrWhiteSpace([HtmlAgilityPack.HtmlEntity]::DeEntitize($child.InnerText)))) {
                        throw "Unrecognized relationship content in $id."
                    }
                }
                $items = $container.SelectNodes('./div')
                if ($null -eq $items -or $items.Count -eq 0) {
                    throw "Unrecognized or empty relationship metadata in $id."
                }
                foreach ($item in $items) {
                    $title = ([HtmlAgilityPack.HtmlEntity]::DeEntitize($item.InnerText) -replace '\s+', ' ').Trim()
                    if ([string]::IsNullOrWhiteSpace($title)) {
                        throw "An empty relationship was found in $id."
                    }
                    $relatedGuid = $null
                    $links = $item.SelectNodes('.//a')
                    if ($null -ne $links) {
                        $href = [HtmlAgilityPack.HtmlEntity]::DeEntitize($links[0].GetAttributeValue('href', ''))
                        $guidPattern = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
                        if ($links.Count -ne 1 -or $href -notmatch "^(?:https://www\.catalog\.update\.microsoft\.com/|/)?ScopedViewInline\.aspx\?updateid=($guidPattern)$") {
                            throw "An invalid relationship link was found in $id."
                        }
                        $relatedGuid = ([guid] $Matches[1]).ToString()
                    } else {
                        if ($null -ne $item.SelectSingleNode('.//*')) {
                            throw "Unrecognized title-only relationship markup in $id."
                        }
                        $hasTitleOnly = $true
                    }
                    $key = if ($relatedGuid) { $relatedGuid } else { $title }
                    if (-not $seen.ContainsKey($key)) {
                        $seen[$key] = $true
                        $entries += [PSCustomObject]@{ Guid = $relatedGuid; Title = $title }
                    }
                }
            }
            $relationships[$property] = $entries
        }

        # Publish both lists only after the entire response has been validated.
        $result.Supersedes = $relationships.Supersedes
        $result.SupersededBy = $relationships.SupersededBy
        $result.Status = if ($hasTitleOnly) { 'Partial' } else { 'Retrieved' }
        if ($hasTitleOnly) {
            $result.Error = 'The Catalog exposes some relationships as titles only; their GUIDs are unavailable.'
        }
    } catch {
        $result.Error = $_.Exception.Message
        Write-Warning "Unable to retrieve supersedence for $Guid : $($result.Error)"
    } finally {
        Set-TempSecurityProtocol -ResetToDefault
    }

    return $result
}
