BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../MSCatalogLTS.psd1') -Force
}

Describe 'Explicit title phrases combined with Catalog searches' {
    InModuleScope MSCatalogLTS {
        BeforeAll {
            $fixtureRoot = Join-Path (Split-Path (Get-Module MSCatalogLTS).Path) 'Tests/Fixtures'
            $productName = 'Microsoft Server Operating System-24H2'
            $searchText = "Cumulative Update for $productName"
            $titlePhrase = 'Cumulative Update for Microsoft server operating system version 24H2'
            $octoberGuid = '1abba66b-03c6-467e-9819-96844606cb15'
            $replacementGuid = '00000000-0000-0000-0000-000000000006'
            $netGuid = '2bcb5934-1515-44d3-898f-fcfe55ce3824'
            $octoberNetGuid = '00000000-0000-0000-0000-000000000007'
        }

        BeforeEach {
            $searchHtml = (Get-Content (Join-Path $fixtureRoot 'Search.Supersedence.html') -Raw).
                Replace('Example Product', 'Microsoft server operating system version 24H2').
                Replace('<td>Microsoft server operating system version 24H2</td>', "<td>$productName</td>")
            Mock Write-Host {}
            Mock Write-Warning {}
            Mock Set-TempSecurityProtocol {}
            Mock Invoke-WebRequest { [PSCustomObject]@{ Content = $searchHtml; RawContent = $searchHtml } }
            Mock Get-UpdateSupersedenceBatch {
                $metadata = @{}
                foreach ($guid in $Guids) {
                    $metadata[$guid] = [PSCustomObject]@{
                        Supersedes = $null; SupersededBy = $null; Status = 'Retrieved'; Error = $null
                    }
                }
                $metadata
            }
        }

        It 'matches OS cumulative titles and rejects interposed .NET Framework titles for <Label>' -ForEach @(
            @{ Label = 'a product label'; Query = 'Cumulative Update for Microsoft Server Operating System-24H2' }
            @{ Label = 'a title version phrase'; Query = 'Cumulative Update for Microsoft Server Operating System version 24H2' }
            @{ Label = 'case and whitespace variants'; Query = "  cumulative`tUPDATE for MICROSOFT Server Operating System-24h2  " }
        ) {
            $updates = @(Get-MSCatalogUpdate -Search $Query -TitleContains $titlePhrase -Product $productName -Architecture x64 -ToDate '2026-10-31' -AllPages)
            $updates.Count | Should -Be 5
            $updates.Guid | Should -Contain $octoberGuid
            $updates.Guid | Should -Contain $replacementGuid
            $updates.Guid | Should -Not -Contain $netGuid
            $updates.Guid | Should -Not -Contain $octoberNetGuid
            foreach ($update in $updates) { $update.Title | Should -Not -Match '\.NET' }
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
            Should -Invoke Get-UpdateSupersedenceBatch -Times 0 -Exactly
        }

        It 'keeps the existing Catalog query and performs title filtering without Product' {
            @(Get-MSCatalogUpdate -Search $searchText -TitleContains $titlePhrase).Count | Should -Be 5
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://www.catalog.update.microsoft.com/Search.aspx?q=for%20Microsoft%20Server%20Operating%20System-24H2'
            }
        }

        It 'filters complete <UpdateKind> phrases using the same generic comparison' -ForEach @(
            @{ UpdateKind = 'Security Update' }
            @{ UpdateKind = 'Feature Update' }
            @{ UpdateKind = 'Dynamic Update' }
            @{ UpdateKind = 'Servicing Stack' }
            @{ UpdateKind = 'Servicing Stack Update' }
        ) {
            $searchHtml = $searchHtml.Replace('Cumulative Update', $UpdateKind)
            @(Get-MSCatalogUpdate -Search "$UpdateKind for $productName" -TitleContains "$UpdateKind for Microsoft server operating system version 24H2" -IncludeDynamic).Count | Should -Be 5
        }

        It 'checks the complete target rather than only the update type or Products column' {
            $searchHtml = $searchHtml.Replace('operating system version 24H2 for x64', 'operating system version 25H2 for x64')
            @(Get-MSCatalogUpdate -Search $searchText -TitleContains $titlePhrase -Product $productName).Count | Should -Be 0
        }

        It 'distinguishes releases when the title phrase includes the following text' {
            $searchHtml = $searchHtml.Replace('version 24H2 for x64', 'version 24H20 for x64')
            @(Get-MSCatalogUpdate -Search $searchText -TitleContains "$titlePhrase for x64").Count | Should -Be 0
        }

        It 'matches the hyphenated spelling in a title too' {
            $searchHtml = $searchHtml.Replace('operating system version 24H2', 'operating system-24H2')
            @(Get-MSCatalogUpdate -Search $searchText -TitleContains $searchText).Count | Should -Be 5
        }

        It 'preserves explicitly requested .NET title phrases' {
            $query = 'Cumulative Update for .NET Framework for Microsoft Server Operating System-24H2'
            $updates = @(Get-MSCatalogUpdate -Search $query -TitleContains 'Cumulative Update for .NET Framework for Microsoft server operating system version 24H2')
            $updates.Count | Should -Be 2
            $updates.Guid | Should -Contain $netGuid
            $updates.Guid | Should -Contain $octoberNetGuid
        }

        It 'retains generic product names, literal metacharacters and decoded HTML entities' {
            $searchHtml = $searchHtml.Replace('Microsoft server operating system version 24H2', 'Contoso A&amp;B (Tools)+-2026')
            $query = 'Cumulative Update for Contoso A&B (Tools)+-2026'
            @(Get-MSCatalogUpdate -Search $query -TitleContains $query).Count | Should -Be 5
            # Regex-like punctuation in a search must not match a different name.
            @(Get-MSCatalogUpdate -Search 'Contoso' -TitleContains 'Cumulative Update for Contoso A&B (Tools).*-2026').Count | Should -Be 0
        }

        It 'applies title and explicit date filters before metadata retrieval' {
            # Explicit date bounds select October; the title phrase excludes NET.
            $searchHtml = $searchHtml.Replace('2026-10 Cumulative Update for .NET', '2026-11 Cumulative Update for .NET')
            $updates = @(Get-MSCatalogUpdate -Search $searchText -TitleContains $titlePhrase -FromDate '2026-10-01' -ToDate '2026-10-31' -IncludeSupersedence)
            $updates.Count | Should -Be 2
            $updates.Guid | Should -Contain $octoberGuid
            $updates.Guid | Should -Contain $replacementGuid
            Should -Invoke Get-UpdateSupersedenceBatch -Times 1 -Exactly -ParameterFilter {
                $Guids.Count -eq 2 -and $Guids -contains $octoberGuid -and $Guids -contains $replacementGuid
            }
        }

        It 'passes only title-matching candidates into supersedence exclusion' {
            $updates = @(Get-MSCatalogUpdate -Search $searchText -TitleContains $titlePhrase -ExcludeSuperseded)
            $updates.Count | Should -Be 5
            Should -Invoke Get-UpdateSupersedenceBatch -Times 5 -Exactly -ParameterFilter {
                $Guids.Count -eq 1 -and $Guids -notcontains $netGuid -and $Guids -notcontains $octoberNetGuid
            }
        }

        It 'intersects title matching with Date and LastUpdated filters' {
            $updates = @(Get-MSCatalogUpdate -Search $searchText -TitleContains $titlePhrase -Date '2026-10' -ToDate '2026-10-20')
            $updates.Count | Should -Be 1
            $updates[0].Guid | Should -Be $octoberGuid
        }

        It 'retains a date token supplied in the original full search phrase' {
            $updates = @(Get-MSCatalogUpdate -Search "2026-10 $searchText" -TitleContains $titlePhrase)
            $updates.Count | Should -Be 2
            $updates.Guid | Should -Not -Contain $octoberNetGuid
        }

        It 'preserves the existing behavior for <Label>' -ForEach @(
            @{ Label = 'a broad update search'; Arguments = @{ Search = 'Cumulative Update' } }
            @{ Label = 'a KB lookup'; Arguments = @{ Search = 'KB5134137' } }
            @{ Label = 'a hardware-ID lookup'; Arguments = @{ Search = 'ff82ca0d-ea57-4a85-8f7c-ff12c5be941e' } }
            @{ Label = 'an abbreviated OS query'; Arguments = @{ Search = 'Server 24H2' } }
            @{ Label = 'a product-only search'; Arguments = @{ Product = 'Microsoft Server Operating System-24H2' } }
        ) {
            # The mocked index returns all candidates, even when the title lacks the query.
            @(Get-MSCatalogUpdate @Arguments).Count | Should -Be 7
        }

        It 'does not retain a preceding invocation title filter in a later broad search' {
            @(Get-MSCatalogUpdate -Search $searchText -TitleContains $titlePhrase).Count | Should -Be 5
            @(Get-MSCatalogUpdate -Search 'Cumulative Update').Count | Should -Be 7
        }

        It 'filters each retrieved page without another Catalog search' {
            $firstPage = $searchHtml.Replace('Cumulative Update for Microsoft', 'Cumulative Update for Other') +
                '<span id="ctl00_catalogBody_nextPageLink">Next</span>'
            $secondPage = $searchHtml
            Mock Invoke-WebRequest {
                $html = if ($Uri -like '*&p=1') { $secondPage } else { $firstPage }
                [PSCustomObject]@{ Content = $html; RawContent = $html }
            }
            @(Get-MSCatalogUpdate -Search $searchText -TitleContains $titlePhrase).Count | Should -Be 0
            @(Get-MSCatalogUpdate -Search $searchText -TitleContains $titlePhrase -AllPages).Count | Should -Be 5
            Should -Invoke Invoke-WebRequest -Times 3 -Exactly
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*&p=1' }
        }

        It 'preserves candidate-limit warnings when title filtering removes every row' {
            $searchHtml += '<span id="ctl00_catalogBody_textMoreResults">Only the first 1000 are returned.</span>'
            @(Get-MSCatalogUpdate -Search 'Cumulative Update for Unrelated Product' -TitleContains 'Cumulative Update for Unrelated Product' -Product $productName).Count | Should -Be 0
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*candidate search reached its 1000-result limit*' }
        }

        It 'preserves an empty Catalog response without metadata retrieval' {
            $searchHtml = '<span id="ctl00_catalogBody_noResultText">No results</span>'
            @(Get-MSCatalogUpdate -Search $searchText -IncludeSupersedence).Count | Should -Be 0
            Should -Invoke Get-UpdateSupersedenceBatch -Times 1 -Exactly -ParameterFilter { $Guids.Count -eq 0 }
        }
    }
}
