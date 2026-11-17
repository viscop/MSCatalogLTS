BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../MSCatalogLTS.psd1') -Force
}

Describe 'Catalog response validation' {
    InModuleScope MSCatalogLTS {
        BeforeAll {
            $fixtureRoot = Join-Path (Split-Path (Get-Module MSCatalogLTS).Path) 'Tests/Fixtures'
            $uri = 'https://www.catalog.update.microsoft.com/Search.aspx?q=test'
        }

        BeforeEach {
            $html = Get-Content (Join-Path $fixtureRoot 'Search.html') -Raw
            Mock Write-Warning {}
            Mock Set-TempSecurityProtocol {}
            Mock Invoke-WebRequest { [PSCustomObject]@{ Content = $html; RawContent = $html } }
        }

        It 'reads results and all form fields' {
            $response = Invoke-CatalogRequest -Uri $uri
            $response.Rows.Count | Should -Be 3
            $response.EventArgument | Should -Be ''
            $response.EventValidation | Should -Be 'validation'
            $response.ViewState | Should -Be 'viewstate'
            $response.ViewStateGenerator | Should -Be 'generator'
            Should -Invoke Write-Warning -Times 0 -Exactly
        }

        It 'handles missing form fields and value attributes' {
            $html = $html -replace '<input id="__(?:EVENTARGUMENT|EVENTVALIDATION|VIEWSTATE|VIEWSTATEGENERATOR)"[^>]*>', ''
            $html += '<input id="__VIEWSTATE" />'
            $response = Invoke-CatalogRequest -Uri $uri
            $response.Rows.Count | Should -Be 3
            $response.ViewState | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 0 -Exactly
        }

        It 'handles an empty results table' {
            $html = '<table id="ctl00_catalogBody_updateMatches"></table>'
            $response = Invoke-CatalogRequest -Uri $uri
            $response.Rows.Count | Should -Be 0
            Should -Invoke Write-Warning -Times 0 -Exactly
        }

        It 'reports a missing results table clearly' {
            $html = '<html><body>Unexpected Catalog response</body></html>'
            Invoke-CatalogRequest -Uri $uri | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*no results table*' }
        }

        It 'handles a recognized no-results response' {
            $html = '<span id="ctl00_catalogBody_noResultText">No results</span>'
            Invoke-CatalogRequest -Uri $uri | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*We did not find any results*' }
        }

        It 'reports an empty HTTP response clearly' {
            $html = $null
            Invoke-CatalogRequest -Uri $uri | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*empty response*' }
        }

        It 'reads Content without requiring RawContent' {
            Mock Invoke-WebRequest { [PSCustomObject]@{ Content = $html } }
            (Invoke-CatalogRequest -Uri $uri).Rows.Count | Should -Be 3
            Should -Invoke Write-Warning -Times 0 -Exactly
        }

        It 'retains support for RawContent-only responses' {
            Mock Invoke-WebRequest { [PSCustomObject]@{ RawContent = $html } }
            (Invoke-CatalogRequest -Uri $uri).Rows.Count | Should -Be 3
            Should -Invoke Write-Warning -Times 0 -Exactly
        }

        It 'retains the Catalog error message' {
            $html = '<div id="errorPageDisplayedError">Test Catalog error</div>'
            Invoke-CatalogRequest -Uri $uri | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*Test Catalog error*' }
        }
    }
}
