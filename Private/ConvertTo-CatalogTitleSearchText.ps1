function ConvertTo-CatalogTitleSearchText {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Text
    )

    # Catalog product labels can use '-24H2' where titles use 'version 24H2'.
    # Normalize numeric version separators without mapping any product or OS name.
    $decoded = [HtmlAgilityPack.HtmlEntity]::DeEntitize($Text)
    ($decoded -replace '-(?=[0-9])', ' ' -replace '\bversion\s+(?=[0-9])', '' -replace '\s+', ' ').Trim()
}
