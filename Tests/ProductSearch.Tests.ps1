BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../MSCatalogLTS.psd1') -Force
}

Describe 'Catalog product search' {
    InModuleScope MSCatalogLTS {
        BeforeAll {
            $fixtureRoot = Join-Path (Split-Path (Get-Module MSCatalogLTS).Path) 'Tests/Fixtures'
            $productName = 'Microsoft Server Operating System-24H2'
            $firstGuid = '00000000-0000-0000-0000-000000000001'
            $secondGuid = '00000000-0000-0000-0000-000000000002'
            $octoberGuid = '00000000-0000-0000-0000-000000000003'
            $wrongProductGuid = '00000000-0000-0000-0000-000000000005'
            $frameworkGuid = '00000000-0000-0000-0000-000000000006'
        }

        BeforeEach {
            $searchHtml = Get-Content (Join-Path $fixtureRoot 'Search.Products.html') -Raw
            Mock Write-Host {}
            Mock Write-Warning {}
            Mock Set-TempSecurityProtocol {}
            Mock Invoke-WebRequest { [PSCustomObject]@{ RawContent = $searchHtml; Content = $searchHtml } }
            Mock Get-UpdateSupersedenceBatch {
                $metadata = @{}
                foreach ($guid in $Guids) {
                    $targets = if ($guid -eq $firstGuid) { @($secondGuid) } else { @() }
                    $metadata[$guid] = [PSCustomObject]@{
                        Supersedes = @()
                        SupersededBy = @($targets | ForEach-Object { [PSCustomObject]@{ Guid = $_; Title = 'Replacement' } })
                        Status = 'Retrieved'
                        Error = $null
                    }
                }
                $metadata
            }
        }

        It 'preserves free-text search and its default exclusions without Product' {
            $updates = @(Get-MSCatalogUpdate -Search 'Cumulative Update')
            $updates.Count | Should -Be 6
            $updates.Guid | Should -Contain $wrongProductGuid
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://www.catalog.update.microsoft.com/Search.aspx?q=Cumulative%20Update'
            }
            Should -Invoke Write-Warning -Times 0 -Exactly
            Should -Invoke Get-UpdateSupersedenceBatch -Times 0 -Exactly
        }

        It 'supports product-only discovery without a title match or OS name mapping' {
            $updates = @(Get-MSCatalogUpdate -Product $productName)
            $updates.Count | Should -Be 4
            $updates.Guid | Should -Contain $firstGuid
            $updates.Guid | Should -Contain $secondGuid
            $updates.Guid | Should -Contain $octoberGuid
            $updates.Guid | Should -Contain $frameworkGuid
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://www.catalog.update.microsoft.com/Search.aspx?q=Microsoft%20Server%20Operating%20System-24H2'
            }
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*Complete product enumeration is not guaranteed*' }
            Should -Invoke Get-UpdateSupersedenceBatch -Times 0 -Exactly
        }

        It 'combines the existing text query AND the exact Products column filter' {
            $updates = @(Get-MSCatalogUpdate -Search 'Cumulative Update' -Product $productName)
            $updates.Count | Should -Be 4
            $updates.Guid | Should -Not -Contain $wrongProductGuid
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://www.catalog.update.microsoft.com/Search.aspx?q=Cumulative%20Update'
            }
            Should -Invoke Write-Warning -Times 0 -Exactly
        }

        It 'requires a search source before making requests' {
            { Get-MSCatalogUpdate } | Should -Throw '*at least one non-empty -Search or -Product*'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'rejects <Parameter> with <Label>, even when the other source is valid' -ForEach @(
            @{ Parameter = 'Search'; Label = 'an empty value'; Value = '' }
            @{ Parameter = 'Search'; Label = 'whitespace'; Value = " `t`r`n" }
            @{ Parameter = 'Search'; Label = 'null'; Value = $null }
            @{ Parameter = 'Product'; Label = 'an empty value'; Value = '' }
            @{ Parameter = 'Product'; Label = 'whitespace'; Value = " `t`r`n" }
            @{ Parameter = 'Product'; Label = 'null'; Value = $null }
        ) {
            $arguments = @{ Search = 'Cumulative Update'; Product = $productName }
            $arguments[$Parameter] = $Value
            { Get-MSCatalogUpdate @arguments } | Should -Throw
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'matches whole product associations case-insensitively' {
            $updates = @(Get-MSCatalogUpdate -Product $productName.ToUpperInvariant())
            $updates.Count | Should -Be 4
            $updates.Guid | Should -Contain $octoberGuid
            $updates.Guid | Should -Not -Contain '00000000-0000-0000-0000-000000000004'
        }

        It 'matches any position in a multiple-product cell and preserves the output string' {
            $updates = @(Get-MSCatalogUpdate -Product 'Other product')
            $updates.Count | Should -Be 2
            ($updates | Where-Object Guid -eq $secondGuid).Products | Should -Be "Other product, $productName"
            $updates.Guid | Should -Contain $wrongProductGuid
        }

        It 'returns no updates for <Product> without substring or wildcard matching' -ForEach @(
            @{ Product = 'Microsoft Server Operating System' }
            @{ Product = 'Microsoft Server Operating System-24H2*' }
            @{ Product = 'Unknown product' }
        ) {
            @(Get-MSCatalogUpdate -Product $Product).Count | Should -Be 0
            Should -Invoke Get-UpdateSupersedenceBatch -Times 0 -Exactly
        }

        It 'preserves commas inside product names and decodes HTML entities' {
            $searchHtml = $searchHtml.Replace('Other product, Microsoft Server Operating System-24H2',
                'Windows 11 Client,  version 24H2 and later,  Servicing Drivers, Windows 11 Client,  version 24H2 and later,  Upgrade &amp; Servicing Drivers')
            $updates = @(Get-MSCatalogUpdate -Product 'Windows 11 Client, version 24H2 and later, Upgrade & Servicing Drivers')
            $updates.Count | Should -Be 1
            $updates[0].Guid | Should -Be $secondGuid
            @(Get-MSCatalogUpdate -Product 'Windows 11 Client').Count | Should -Be 0
            @(Get-MSCatalogUpdate -Product 'Servicing Drivers').Count | Should -Be 0
        }

        It 'intersects Product with <Selection>' -ForEach @(
            @{ Selection = 'Date'; Filters = @{ Date = '2026-09' }; Count = 3 }
            @{ Selection = 'FromDate'; Filters = @{ FromDate = '2026-09-10' }; Count = 2 }
            @{ Selection = 'ToDate'; Filters = @{ ToDate = '2026-09-10' }; Count = 2 }
            @{ Selection = 'both date bounds'; Filters = @{ FromDate = '2026-09-01'; ToDate = '2026-09-30' }; Count = 3 }
        ) {
            $updates = @(Get-MSCatalogUpdate -Product $productName @Filters)
            $updates.Count | Should -Be $Count
            $updates.Guid | Should -Not -Contain $wrongProductGuid
        }

        It 'supports LastDays with Product' {
            Mock Get-Date {
                if ($Year -and $Month -and $Day) { [datetime]::new($Year, $Month, $Day) }
                else { [datetime] '2026-10-15' }
            }
            $updates = @(Get-MSCatalogUpdate -Product $productName -LastDays 7)
            $updates.Count | Should -Be 1
            $updates[0].Guid | Should -Be $octoberGuid
        }

        It 'applies date and product filters before supersedence requests and exclusion' {
            $updates = @(Get-MSCatalogUpdate -Product $productName -Date '2026-09' -ExcludeSupersedence)
            $updates.Count | Should -Be 2
            $updates.Guid | Should -Contain $secondGuid
            $updates.Guid | Should -Contain $frameworkGuid
            $updates.Guid | Should -Not -Contain $firstGuid
            Should -Invoke Get-UpdateSupersedenceBatch -Times 1 -Exactly -ParameterFilter {
                $Guids.Count -eq 3 -and $Guids -notcontains $wrongProductGuid -and $Guids -notcontains $octoberGuid
            }
        }

        It 'does not remove a matching update because of a replacement in another product' {
            # The second update is the first update's replacement in the mocked metadata.
            $searchHtml = $searchHtml.Replace('Other product, Microsoft Server Operating System-24H2', 'Other product')
            $updates = @(Get-MSCatalogUpdate -Product $productName -ExcludeSuperseded)
            $updates.Guid | Should -Contain $firstGuid
            $updates.Guid | Should -Not -Contain $secondGuid
            Should -Invoke Get-UpdateSupersedenceBatch -Times 1 -Exactly -ParameterFilter { $Guids -notcontains $secondGuid }
        }

        It 'can include supersedence metadata without excluding matching results' {
            $updates = @(Get-MSCatalogUpdate -Product $productName -IncludeSupersedence)
            $updates.Count | Should -Be 4
            ($updates | Where-Object Guid -eq $firstGuid).SupersededBy[0].Guid | Should -Be $secondGuid
        }

        It 'retains architecture, classification and Framework filters with Product' {
            $updates = @(Get-MSCatalogUpdate -Product $productName -Architecture x64 -UpdateType 'Security Updates' -ExcludeFramework)
            $updates.Count | Should -Be 2
            $updates.Guid | Should -Contain $firstGuid
            $updates.Guid | Should -Contain $secondGuid
            $framework = @(Get-MSCatalogUpdate -Product $productName -GetFramework)
            $framework.Count | Should -Be 1
            $framework[0].Guid | Should -Be $frameworkGuid
        }

        It 'retains explicit preview and dynamic inclusion' {
            @(Get-MSCatalogUpdate -Product $productName -IncludePreview -IncludeDynamic).Count | Should -Be 6
        }

        It 'retains the OS parameter set, with and without Product' {
            $searchHtml = Get-Content (Join-Path $fixtureRoot 'Search.Month.html') -Raw
            $original = @(Get-MSCatalogUpdate -OperatingSystem 'Windows Server' -Version '2025' -Architecture x64)
            $filtered = @(Get-MSCatalogUpdate -OperatingSystem 'Windows Server' -Version '2025' -Architecture x64 -Product $productName)
            $filtered.Count | Should -Be 4
            ($filtered.Guid -join ',') | Should -Be ($original.Guid -join ',')
        }

        It 'retains positional text search and rejects Search with OperatingSystem' {
            @(Get-MSCatalogUpdate 'Cumulative Update' -Product $productName).Count | Should -Be 4
            { Get-MSCatalogUpdate -Search 'Cumulative Update' -OperatingSystem 'Windows Server' } | Should -Throw
        }

        It 'does not reuse smart-parser date or title filters for a later product-only call' {
            Get-MSCatalogUpdate -Search '2026-09 Security Update for Server 24H2' | Out-Null
            @(Get-MSCatalogUpdate -Product $productName).Count | Should -Be 4
        }

        It 'does not treat a product name as an OS search or infer a title date from it' {
            $searchHtml = $searchHtml.Replace($productName, 'Windows 11 2026-09')
            $searchHtml = $searchHtml.Replace($productName.ToLowerInvariant(), 'Windows 11 2026-09')
            $updates = @(Get-MSCatalogUpdate -Product 'Windows 11 2026-09' -Date '2026-10')
            $updates.Count | Should -Be 1
            $updates[0].Guid | Should -Be $octoberGuid
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://www.catalog.update.microsoft.com/Search.aspx?q=Windows%2011%202026-09'
            }
        }

        It 'uses the existing query-string pagination and warns when pages are omitted' {
            $firstPage = $searchHtml + '<span id="ctl00_catalogBody_nextPageLink">Next</span>'
            $secondPage = $searchHtml.Replace('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000009')
            Mock Invoke-WebRequest {
                $html = if ($Uri -like '*&p=1') { $secondPage } else { $firstPage }
                [PSCustomObject]@{ RawContent = $html; Content = $html }
            }
            @(Get-MSCatalogUpdate -Product $productName).Count | Should -Be 4
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*Not all Catalog candidate pages*' }
            $updates = @(Get-MSCatalogUpdate -Product $productName -AllPages)
            $updates.Count | Should -Be 8
            $updates.Guid | Should -Contain '00000000-0000-0000-0000-000000000009'
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*&p=1' }
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*Not all Catalog candidate pages*' }
        }

        It 'warns about the Catalog result cap before local filters hide it' {
            $searchHtml += '<span id="ctl00_catalogBody_textMoreResults">Only the first 1000 are returned.</span>'
            @(Get-MSCatalogUpdate -Search 'Cumulative Update' -Product 'Unknown product' -AllPages).Count | Should -Be 0
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*candidate search reached its 1000-result limit*' }
        }

        It 'keeps the existing 40-page bound and warns if candidates remain' {
            $searchHtml += '<span id="ctl00_catalogBody_nextPageLink">Next</span>'
            Get-MSCatalogUpdate -Product 'Unknown product' -AllPages | Out-Null
            Should -Invoke Invoke-WebRequest -Times 40 -Exactly
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*Not all Catalog candidate pages*' }
        }

        It 'handles a Catalog no-results response without broadening the query' {
            $searchHtml = '<span id="ctl00_catalogBody_noResultText">No results</span>'
            @(Get-MSCatalogUpdate -Product $productName).Count | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        }
    }
}
