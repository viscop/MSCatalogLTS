class MSCatalogResponse {
    [HtmlAgilityPack.HtmlNode[]] $Rows
    [string] $EventArgument
    [string] $EventValidation
    [string] $ViewState
    [string] $ViewStateGenerator
    [string] $NextPage
    [bool] $ResultLimitExceeded

    MSCatalogResponse($HtmlDoc) {
        $Table = $HtmlDoc.GetElementbyId("ctl00_catalogBody_updateMatches")
        if ($null -eq $Table) {
            throw 'The Catalog response contains no results table and no recognized no-results message. The response may be an error page or the Catalog HTML may have changed.'
        }
        $this.Rows = @($Table.SelectNodes("tr") | Where-Object { $null -ne $_ -and $_.Id -ne "headerRow" })
        # Some responses omit optional form fields; GET pagination does not need them.
        foreach ($fieldName in @('EventArgument', 'EventValidation', 'ViewState', 'ViewStateGenerator')) {
            $field = $HtmlDoc.GetElementbyId("__$($fieldName.ToUpperInvariant())")
            if ($null -ne $field -and $null -ne $field.Attributes["value"]) {
                $this.$fieldName = $field.Attributes["value"].Value
            }
        }
        $NextPageNode = $HtmlDoc.GetElementbyId("ctl00_catalogBody_nextPageLink")
        $this.NextPage = if ($null -ne $NextPageNode) { $NextPageNode.InnerText.Trim() } else { $null }
        $this.ResultLimitExceeded = $null -ne $HtmlDoc.GetElementbyId("ctl00_catalogBody_textMoreResults")
    }
}
