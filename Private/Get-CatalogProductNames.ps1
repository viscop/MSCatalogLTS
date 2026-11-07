function Get-CatalogProductNames {
    param (
        [AllowEmptyString()]
        [string] $Products
    )

    # In search result cells, associations are joined by comma + one space.
    # Commas inside a product name are followed by two spaces, e.g.
    # "Windows 10,  version 1903 and later". Split before normalizing whitespace
    # so "Windows 10" cannot accidentally match that individual product.
    foreach ($name in [regex]::Split($Products, ', (?! )')) {
        $decoded = [System.Net.WebUtility]::HtmlDecode($name)
        $normalized = ($decoded -replace '\s+', ' ').Trim()
        if ($normalized) {
            $normalized
        }
    }
}
