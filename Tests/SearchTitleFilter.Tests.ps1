BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../MSCatalogLTS.psd1') -Force
}

Describe 'Optional literal case-insensitive TitleContains filtering' {
    InModuleScope MSCatalogLTS {
        BeforeAll {
            $fixtureRoot = Join-Path (Split-Path (Get-Module MSCatalogLTS).Path) 'Tests/Fixtures'
            $phrase = 'Cumulative Update for microsoft server operating system version 24H2'
            $productName = 'Microsoft Server Operating System-24H2'
        }

        BeforeEach {
            $searchHtml = (Get-Content (Join-Path $fixtureRoot 'Search.Products.html') -Raw).
                Replace('Cumulative Update for x64-based Systems', "$phrase for x64-based Systems").
                Replace('Cumulative Update for arm64', "$phrase for arm64").
                Replace('Cumulative Update for .NET Framework x86', 'Cumulative Update for .NET Framework for microsoft server operating system version 24H2 x86')
            Mock Write-Host {}
            Mock Write-Warning {}
            Mock Set-TempSecurityProtocol {}
            Mock Invoke-WebRequest { [PSCustomObject]@{ Content = $searchHtml; RawContent = $searchHtml } }
            Mock Get-UpdateDownloads { throw 'Unexpected download metadata request' }
        }

        It 'matches an independent phrase without adding it to the Catalog query' {
            $updates = @(Get-MSCatalogUpdate -Search 'server 24H2' -TitleContains $phrase.ToUpperInvariant())
            $updates.Count | Should -Be 4
            $updates.Title | Should -Not -Match '\.NET'
            foreach ($update in $updates) {
                $update.Title.IndexOf($phrase, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeGreaterOrEqual 0
            }
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://www.catalog.update.microsoft.com/Search.aspx?q=server%2024H2'
            }
            Should -Invoke Get-UpdateDownloads -Times 0 -Exactly
        }

        It 'combines title, product, architecture and separate date filters' {
            $updates = @(Get-MSCatalogUpdate -Search 'server 24H2' -TitleContains $phrase -Product $productName -Architecture x64 -Date '2026-09')
            $updates.Count | Should -Be 2
        }

        It 'matches short phrases too and retains explicitly requested NET titles' {
            @(Get-MSCatalogUpdate -Search 'server 24H2' -TitleContains '.NET Framework').Count | Should -Be 1
            @(Get-MSCatalogUpdate -Search 'server 24H2' -TitleContains 'KB0000002').Count | Should -Be 1
            @(Get-MSCatalogUpdate -Search 'server 24H2' -TitleContains 'nonexistent title').Count | Should -Be 0
        }

        It 'supports the abbreviated NET query with and without a separate title phrase' {
            $searchHtml = Get-Content (Join-Path $fixtureRoot 'Search.Month.html') -Raw
            $arguments = @{
                Product = $productName
                Architecture = 'x64'
                ToDate = [datetime] '2026-11-16'
                ExcludeSuperseded = $true
                AllPages = $true
            }
            Mock Get-UpdateSupersedenceBatch { @{} }
            $query = 'Cumulative Update for .NET Framework 3.5 and 4.8.1 server 24H2 x64'
            # The mocked Catalog returns four candidates. Search alone must not
            # reject them for lacking the abbreviated query as one exact phrase.
            @(Get-MSCatalogUpdate -Search $query @arguments).Count | Should -Be 4
            @(Get-MSCatalogUpdate -Search $query -TitleContains 'Cumulative Update for .NET Framework 3.5 and 4.8.1' @arguments).Count | Should -Be 1
            @(Get-MSCatalogUpdate -Search $query -TitleContains 'operating system 24H2' @arguments).Count | Should -Be 0
            Should -Invoke Write-Warning -Times 0 -Exactly
        }

        It 'does not retain a title filter for product-only calls' {
            @(Get-MSCatalogUpdate -Search 'server 24H2' -TitleContains 'nonexistent title').Count | Should -Be 0
            @(Get-MSCatalogUpdate -Product $productName).Count | Should -Be 4
            @(Get-MSCatalogUpdate -Search 'server 24H2').Count | Should -Be 6
        }

        It 'compares punctuation literally and decodes HTML title entities' {
            $searchHtml = $searchHtml.Replace($phrase, 'Contoso A&amp;B [Tools]+ (24H2)')
            @(Get-MSCatalogUpdate -Search 'Contoso' -TitleContains 'Contoso A&B [Tools]+ (24H2)').Count | Should -Be 4
            @(Get-MSCatalogUpdate -Search 'Contoso' -TitleContains 'Contoso A&B *').Count | Should -Be 0
            @(Get-MSCatalogUpdate -Search 'Contoso' -TitleContains 'Contoso A&B .*').Count | Should -Be 0
        }

        It 'requires the supplied spelling and word order' {
            @(Get-MSCatalogUpdate -Search 'server 24H2' -TitleContains 'Cumulative Update for Microsoft Server Operating System-24H2').Count | Should -Be 1
            @(Get-MSCatalogUpdate -Search 'server 24H2' -TitleContains 'Update Cumulative').Count | Should -Be 0
        }

        It 'filters candidates from every retrieved page' {
            $firstPage = $searchHtml.Replace($phrase, 'Unrelated Update') +
                '<span id="ctl00_catalogBody_nextPageLink">Next</span>'
            $secondPage = $searchHtml
            Mock Invoke-WebRequest {
                $html = if ($Uri -like '*&p=1') { $secondPage } else { $firstPage }
                [PSCustomObject]@{ Content = $html; RawContent = $html }
            }
            @(Get-MSCatalogUpdate -Search 'server 24H2' -TitleContains $phrase).Count | Should -Be 0
            @(Get-MSCatalogUpdate -Search 'server 24H2' -TitleContains $phrase -AllPages).Count | Should -Be 4
            Should -Invoke Invoke-WebRequest -Times 3 -Exactly
        }

        It 'supports the German parameter alias' {
            @(Get-MSCatalogUpdate -Search 'server 24H2' -TitelContains $phrase).Count | Should -Be 4
        }

        It 'supports a title phrase with product-only and structured OS searches' {
            @(Get-MSCatalogUpdate -Product $productName -TitleContains '.NET Framework').Count | Should -Be 1
            @(Get-MSCatalogUpdate -OperatingSystem 'Windows Server' -Version '2025' -TitleContains '.NET Framework').Count | Should -Be 1
        }

        It 'rejects <Label> title phrases before requesting the Catalog' -ForEach @(
            @{ Label = 'empty'; Value = '' }
            @{ Label = 'whitespace-only'; Value = " `t`r`n" }
            @{ Label = 'null'; Value = $null }
        ) {
            { Get-MSCatalogUpdate -Search 'server 24H2' -TitleContains $Value } | Should -Throw
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'requires a Catalog search source in addition to the title phrase' {
            { Get-MSCatalogUpdate -TitleContains $phrase } | Should -Throw '*at least one non-empty -Search or -Product*'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'filters titles before supersedence and download metadata retrieval' {
            $searchHtml = Get-Content (Join-Path $fixtureRoot 'Search.Month.html') -Raw
            $netGuid = '2bcb5934-1515-44d3-898f-fcfe55ce3824'
            Mock Get-UpdateSupersedenceBatch {
                $metadata = @{}
                foreach ($guid in $Guids) {
                    $metadata[$guid] = [PSCustomObject]@{
                        Supersedes = $null; SupersededBy = $null; Status = 'Retrieved'; Error = $null
                    }
                }
                $metadata
            }
            Mock Get-UpdateDownloads { @() }
            $updates = @(Get-MSCatalogUpdate -Search 'server 24H2' -TitleContains '.NET Framework' -ExcludeSuperseded -IncludeDownloadUrls)
            $updates.Count | Should -Be 1
            $updates[0].Guid | Should -Be $netGuid
            Should -Invoke Get-UpdateSupersedenceBatch -Times 1 -Exactly -ParameterFilter {
                $Guids.Count -eq 1 -and $Guids[0] -eq $netGuid
            }
            Should -Invoke Get-UpdateDownloads -Times 1 -Exactly -ParameterFilter { $Guid -eq $netGuid }
        }
    }
}
