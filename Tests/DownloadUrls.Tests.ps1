# Run in a fresh PowerShell process after changes to PowerShell classes.
BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../MSCatalogLTS.psd1') -Force
}

Describe 'Download metadata validation' {
    InModuleScope MSCatalogLTS {
        BeforeAll {
            $fixtureRoot = Join-Path (Split-Path (Get-Module MSCatalogLTS).Path) 'Tests/Fixtures'
            $updateGuid = '00000000-0000-0000-0000-000000000001'
            $singleHtml = Get-Content (Join-Path $fixtureRoot 'DownloadDialog.Single.html') -Raw
        }

        BeforeEach {
            $dialogHtml = $singleHtml
            Mock Invoke-WebRequest { [PSCustomObject]@{ Content = $dialogHtml } }
        }

        It 'returns a complete original filename and converts Base64 SHA1 to uppercase hex' {
            $downloads = @(Get-UpdateDownloads -Guid $updateGuid)
            $downloads.Count | Should -Be 1
            $downloads[0].Url | Should -Be 'https://download.windowsupdate.com/content/Windows11.0-KB5078127-x64_Full_Original_Name.msu'
            $downloads[0].FileName | Should -BeExactly 'Windows11.0-KB5078127-x64_Full_Original_Name.msu'
            $downloads[0].KB | Should -Be 'KB5078127'
            $downloads[0].SHA1 | Should -BeExactly '000102030405060708090A0B0C0D0E0F10111213'
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -and
                $Body.UpdateIDs -like "*$updateGuid*" -and -not $OutFile -and $ErrorAction -eq 'Stop'
            }
        }

        It 'deduplicates multiple arrays and orders files by numeric Catalog indexes' {
            $dialogHtml = Get-Content (Join-Path $fixtureRoot 'DownloadDialog.Multiple.html') -Raw
            $downloads = @(Get-UpdateDownloads -Guid $updateGuid)
            $downloads.Count | Should -Be 3
            $downloads[0].KB | Should -Be 'KB5078127'
            $downloads[1].KB | Should -Be 'KB5078128'
            $downloads[1].SHA1 | Should -BeExactly '0123456789ABCDEF0123456789ABCDEF01234567'
            $downloads[2].FileName | Should -BeExactly 'driver Original_Name.cab'
            $downloads[2].SHA1 | Should -BeNullOrEmpty
            ($null -eq $downloads[2].SHA1) | Should -BeTrue
            ($null -eq $downloads[2].KB) | Should -BeTrue
        }

        It 'returns null when optional checksum metadata is absent' {
            $dialogHtml = $singleHtml -replace "downloadInformation\[0\]\.files\[0\]\.digest[^;]+;", ''
            $downloads = @(Get-UpdateDownloads -Guid $updateGuid)
            ($null -eq $downloads[0].SHA1) | Should -BeTrue
        }

        It 'rejects invalid checksum metadata: <Label>' -ForEach @(
            @{ Label = 'non-Base64'; Value = 'not-a-digest!' }
            @{ Label = 'wrong byte count'; Value = 'AQID' }
            @{ Label = 'empty but supplied'; Value = '' }
            @{ Label = 'wrong hex length'; Value = '0123456789abcdef0123456789abcdef0123456' }
        ) {
            $dialogHtml = $singleHtml.Replace('AAECAwQFBgcICQoLDA0ODxAREhM=', $Value)
            { Get-UpdateDownloads -Guid $updateGuid } | Should -Throw "*$updateGuid*Invalid SHA-1*"
        }

        It 'rejects malformed URL <Value>' -ForEach @(
            @{ Value = 'relative/file.msu' }
            @{ Value = 'ftp://example.com/file.msu' }
            @{ Value = 'https://example.com/a file.msu' }
            @{ Value = 'https://example.com/file%ZZ.msu' }
            @{ Value = '' }
        ) {
            $dialogHtml = $singleHtml.Replace('https://download.windowsupdate.com/content/Windows11.0-KB5078127-x64_Full_Original_Name.msu', $Value)
            { Get-UpdateDownloads -Guid $updateGuid } | Should -Throw "*$updateGuid*Malformed download URL*"
        }

        It 'rejects URLs with no filename' {
            $dialogHtml = $singleHtml.Replace('Windows11.0-KB5078127-x64_Full_Original_Name.msu', '')
            { Get-UpdateDownloads -Guid $updateGuid } | Should -Throw "*$updateGuid*no filename*"
        }

        It 'propagates HTTP failure with the update GUID' {
            Mock Invoke-WebRequest { throw 'HTTP 503 Service Unavailable' }
            { Get-UpdateDownloads -Guid $updateGuid } | Should -Throw "*$updateGuid*HTTP 503*"
        }

        It 'accepts a recognized empty response' {
            $dialogHtml = Get-Content (Join-Path $fixtureRoot 'DownloadDialog.Empty.html') -Raw
            @(Get-UpdateDownloads -Guid $updateGuid).Count | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        }

        It 'rejects an unrecognized response instead of reporting an empty success' {
            $dialogHtml = '<html>Service unavailable</html>'
            { Get-UpdateDownloads -Guid $updateGuid } | Should -Throw "*$updateGuid*Unrecognized DownloadDialog*"
        }

        It 'rejects a Catalog error page even when it initializes the download array' {
            $dialogHtml += '<div id="errorPageDisplayedError">Catalog error</div>'
            { Get-UpdateDownloads -Guid $updateGuid } | Should -Throw "*$updateGuid*Unrecognized DownloadDialog*"
        }

        It 'rejects <Label> without emitting partial download data' -ForEach @(
            @{ Label = 'a file without a URL'; Extra = 'downloadInformation[0].files[1] = new Object();' }
            @{ Label = 'an incomplete URL'; Extra = "downloadInformation[0].files[1].url = 'https://example.com/incomplete" }
            @{ Label = 'an incomplete checksum'; Extra = "downloadInformation[0].files[0].digest = 'incomplete" }
            @{ Label = 'a duplicate checksum assignment'; Extra = "downloadInformation[0].files[0].digest = 'AQID';" }
            @{ Label = 'a duplicate URL assignment'; Extra = "downloadInformation[0].files[0].url = 'https://example.com/file.msu';" }
            @{ Label = 'an invalid duplicate URL checksum'; Extra = "downloadInformation[0].files[1].url = 'https://download.windowsupdate.com/content/Windows11.0-KB5078127-x64_Full_Original_Name.msu'; downloadInformation[0].files[1].digest = 'AQID';" }
        ) {
            $dialogHtml += $Extra
            $emitted = [System.Collections.Generic.List[object]]::new()
            { Get-UpdateDownloads -Guid $updateGuid | ForEach-Object { $emitted.Add($_) } } | Should -Throw "*$updateGuid*"
            $emitted.Count | Should -Be 0
        }

        It 'does not change global preferences or security protocol on success or failure' {
            $protocol = [Net.ServicePointManager]::SecurityProtocol
            $preference = $global:ErrorActionPreference
            Get-UpdateDownloads -Guid $updateGuid | Out-Null
            Mock Invoke-WebRequest { throw 'HTTP failure' }
            { Get-UpdateDownloads -Guid $updateGuid } | Should -Throw
            [Net.ServicePointManager]::SecurityProtocol | Should -Be $protocol
            $global:ErrorActionPreference | Should -Be $preference
        }

        It 'preserves legacy Get-UpdateLinks metadata and ordering for existing consumers' {
            $dialogHtml = Get-Content (Join-Path $fixtureRoot 'DownloadDialog.Multiple.html') -Raw
            $links = @(Get-UpdateLinks -Guid $updateGuid)
            $links.Count | Should -Be 3
            $links[0].KB | Should -Be 5078128
            $links[0].SHA1 | Should -Be '0123456789abcdef0123456789abcdef01234567'
            $links[1].SHA1 | Should -Be 'AAECAwQFBgcICQoLDA0ODxAREhM='
            $links[2].KB | Should -Be 0
            $links[2].SHA1 | Should -BeExactly ''
        }

        It 'preserves legacy empty and unrecognized response behavior' {
            $dialogHtml = Get-Content (Join-Path $fixtureRoot 'DownloadDialog.Empty.html') -Raw
            ($null -eq (Get-UpdateLinks -Guid $updateGuid)) | Should -BeTrue
            $dialogHtml = '<html>Unrecognized response</html>'
            ($null -eq (Get-UpdateLinks -Guid $updateGuid)) | Should -BeTrue
        }
    }
}

Describe 'Get-MSCatalogUpdate download URLs' {
    InModuleScope MSCatalogLTS {
        BeforeAll {
            $fixtureRoot = Join-Path (Split-Path (Get-Module MSCatalogLTS).Path) 'Tests/Fixtures'
            $productName = 'Microsoft Server Operating System-24H2'
            $firstGuid = '00000000-0000-0000-0000-000000000001'
            $secondGuid = '00000000-0000-0000-0000-000000000002'
        }

        BeforeEach {
            $searchHtml = Get-Content (Join-Path $fixtureRoot 'Search.Products.html') -Raw
            $dialogHtml = Get-Content (Join-Path $fixtureRoot 'DownloadDialog.Single.html') -Raw
            Mock Write-Host {}
            Mock Write-Warning {}
            Mock Set-TempSecurityProtocol {}
            Mock Invoke-WebRequest {
                if ($Uri -like '*DownloadDialog.aspx') { [PSCustomObject]@{ Content = $dialogHtml } }
                elseif ($Uri -like '*Search.aspx*') { [PSCustomObject]@{ RawContent = $searchHtml; Content = $searchHtml } }
                else { throw "Unexpected request: $Uri" }
            }
            Mock Get-UpdateSupersedenceBatch {
                $metadata = @{}
                foreach ($guid in $Guids) {
                    $metadata[$guid] = [PSCustomObject]@{
                        Supersedes = @()
                        SupersededBy = @(if ($guid -eq $firstGuid) { [PSCustomObject]@{ Guid = $secondGuid; Title = 'Replacement' } })
                        Status = 'Retrieved'
                        Error = $null
                    }
                }
                $metadata
            }
        }

        It 'preserves existing search results with null Downloads and no download requests when omitted or false' {
            foreach ($arguments in @(@{}, @{ IncludeDownloadUrls = $false })) {
                $updates = @(Get-MSCatalogUpdate -Search 'Cumulative Update' @arguments)
                $updates.Count | Should -Be 6
                foreach ($update in $updates) {
                    ($null -eq $update.Downloads) | Should -BeTrue
                    $update.SHA1 | Should -BeNullOrEmpty
                }
            }
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -like '*DownloadDialog.aspx' }
        }

        It 'returns a single download as a collection without requesting supersedence' {
            $updates = @(Get-MSCatalogUpdate -Product $productName -FromDate '2026-10-01' -IncludeDownloadUrls)
            $updates.Count | Should -Be 1
            ($updates[0].Downloads -is [object[]]) | Should -BeTrue
            $updates[0].Downloads.Count | Should -Be 1
            $updates[0].SHA1 | Should -BeExactly '000102030405060708090A0B0C0D0E0F10111213'
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*DownloadDialog.aspx' }
            Should -Invoke Get-UpdateSupersedenceBatch -Times 0 -Exactly
        }

        It 'populates update SHA1 from the first download and keeps every file digest' {
            $dialogHtml = Get-Content (Join-Path $fixtureRoot 'DownloadDialog.Multiple.html') -Raw
            $updates = @(Get-MSCatalogUpdate -Product $productName -FromDate '2026-10-01' -IncludeDownloadUrls)
            $updates[0].Downloads.Count | Should -Be 3
            $updates[0].SHA1 | Should -BeExactly $updates[0].Downloads[0].SHA1
            $updates[0].Downloads[1].SHA1 | Should -BeExactly '0123456789ABCDEF0123456789ABCDEF01234567'
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*DownloadDialog.aspx' }
        }

        It 'leaves update SHA1 blank when the first download has no digest' {
            $dialogHtml = Get-Content (Join-Path $fixtureRoot 'DownloadDialog.Multiple.html') -Raw
            $dialogHtml = $dialogHtml.Replace("downloadInformation[0].files[0].digest = 'AAECAwQFBgcICQoLDA0ODxAREhM=';", '')
            $updates = @(Get-MSCatalogUpdate -Product $productName -FromDate '2026-10-01' -IncludeDownloadUrls)
            $updates[0].SHA1 | Should -BeNullOrEmpty
            ($null -eq $updates[0].Downloads[0].SHA1) | Should -BeTrue
            $updates[0].Downloads[1].SHA1 | Should -BeExactly '0123456789ABCDEF0123456789ABCDEF01234567'
        }

        It 'retrieves links only after product, date, architecture, preview, dynamic and Framework filters' {
            $updates = @(Get-MSCatalogUpdate -Search 'Cumulative Update' -Product $productName -Architecture x64 -Date '2026-09' -FromDate '2026-09-10' -ToDate '2026-09-30' -ExcludeFramework -IncludeDownloadUrls)
            $updates.Count | Should -Be 1
            $updates[0].Guid | Should -Be $secondGuid
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -like '*DownloadDialog.aspx' -and $Body.UpdateIDs -like "*$secondGuid*"
            }
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        }

        It 'retrieves links only after relative date and size filtering' {
            Mock Get-Date {
                if ($Year -and $Month -and $Day) { [datetime]::new($Year, $Month, $Day) }
                else { [datetime] '2026-09-15' }
            }
            $updates = @(Get-MSCatalogUpdate -Product $productName -LastDays 7 -ToDate '2026-09-30' -MinSize 101 -MaxSize 101 -IncludeDownloadUrls)
            $updates.Count | Should -Be 1
            $updates[0].Guid | Should -Be $secondGuid
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*DownloadDialog.aspx' }
        }

        It 'resolves URLs after supersedence exclusion and supports the exclusion alias' {
            $updates = @(Get-MSCatalogUpdate -Product $productName -Architecture x64 -ExcludeSupersedence -IncludeDownloadUrls)
            $updates.Count | Should -Be 1
            $updates[0].Guid | Should -Be $secondGuid
            $updates[0].Downloads.Count | Should -Be 1
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -like '*DownloadDialog.aspx' -and $Body.UpdateIDs -like "*$secondGuid*"
            }
        }

        It 'can include supersedence and download metadata independently' {
            $updates = @(Get-MSCatalogUpdate -Product $productName -Architecture x64 -IncludeSupersedence -IncludeDownloadUrls)
            $updates.Count | Should -Be 2
            ($updates | Where-Object Guid -eq $firstGuid).SupersededBy[0].Guid | Should -Be $secondGuid
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly -ParameterFilter { $Uri -like '*DownloadDialog.aspx' }
        }

        It 'supports Framework-only, dynamic and preview inclusion switches' {
            $updates = @(Get-MSCatalogUpdate -Product $productName -GetFramework -IncludeDownloadUrls)
            $updates.Count | Should -Be 1
            $updates[0].Guid | Should -Be '00000000-0000-0000-0000-000000000006'
            $included = @(Get-MSCatalogUpdate -Product $productName -IncludeDynamic -IncludePreview -IncludeDownloadUrls)
            $included.Count | Should -Be 6
            Should -Invoke Invoke-WebRequest -Times 7 -Exactly -ParameterFilter { $Uri -like '*DownloadDialog.aspx' }
        }

        It 'supports the OS parameter set' {
            $searchHtml = Get-Content (Join-Path $fixtureRoot 'Search.Month.html') -Raw
            $updates = @(Get-MSCatalogUpdate -OperatingSystem 'Windows Server' -Version '2025' -Architecture x64 -Product $productName -IncludeDownloadUrls)
            $updates.Count | Should -Be 4
            Should -Invoke Invoke-WebRequest -Times 4 -Exactly -ParameterFilter { $Uri -like '*DownloadDialog.aspx' }
        }

        It 'shares requests with IncludeFileNames after date and supersedence filtering' {
            $updates = @(Get-MSCatalogUpdate -Product $productName -FromDate '2026-09-01' -ToDate '2026-09-30' -Architecture x64 -ExcludeSuperseded -IncludeDownloadUrls -IncludeFileNames)
            $updates.Count | Should -Be 1
            $updates[0].FileNames[0] | Should -BeExactly $updates[0].Downloads[0].FileName
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*DownloadDialog.aspx' }
        }

        It 'retains an empty collection after a successful no-files response' {
            $dialogHtml = Get-Content (Join-Path $fixtureRoot 'DownloadDialog.Empty.html') -Raw
            $updates = @(Get-MSCatalogUpdate -Product $productName -FromDate '2026-10-01' -IncludeDownloadUrls)
            $updates.Count | Should -Be 1
            ($updates[0].Downloads -is [object[]]) | Should -BeTrue
            $updates[0].Downloads.Count | Should -Be 0
            $updates[0].SHA1 | Should -BeNullOrEmpty
        }

        It 'does not request downloads when no updates match' {
            @(Get-MSCatalogUpdate -Product 'Unknown product' -IncludeDownloadUrls).Count | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -like '*DownloadDialog.aspx' }
        }

        It 'preserves pagination and resolves a duplicate GUID once per call' {
            $firstPage = $searchHtml + '<span id="ctl00_catalogBody_nextPageLink">Next</span>'
            Mock Invoke-WebRequest {
                if ($Uri -like '*DownloadDialog.aspx') { [PSCustomObject]@{ Content = $dialogHtml } }
                else {
                    $html = if ($Uri -like '*&p=1') { $searchHtml } else { $firstPage }
                    [PSCustomObject]@{ RawContent = $html; Content = $html }
                }
            }
            $updates = @(Get-MSCatalogUpdate -Product $productName -Architecture x64 -AllPages -IncludeDownloadUrls)
            $updates.Count | Should -Be 4
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*&p=1' }
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly -ParameterFilter { $Uri -like '*DownloadDialog.aspx' }
        }

        It 'does not cache download metadata across calls' {
            Get-MSCatalogUpdate -Product $productName -FromDate '2026-10-01' -IncludeDownloadUrls | Out-Null
            Get-MSCatalogUpdate -Product $productName -FromDate '2026-10-01' -IncludeDownloadUrls | Out-Null
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly -ParameterFilter { $Uri -like '*DownloadDialog.aspx' }
        }

        It 'propagates a later update failure without emitting incomplete search results' {
            Mock Invoke-WebRequest { throw 'HTTP 503' } -ParameterFilter {
                $Uri -like '*DownloadDialog.aspx' -and $Body.UpdateIDs -like "*$secondGuid*"
            }
            $emitted = [System.Collections.Generic.List[object]]::new()
            { Get-MSCatalogUpdate -Product $productName -Architecture x64 -IncludeDownloadUrls | ForEach-Object { $emitted.Add($_) } } | Should -Throw "*$secondGuid*HTTP 503*"
            $emitted.Count | Should -Be 0
        }

        It 'preserves nested metadata in JSON output and export' {
            $arguments = @{ Product = $productName; FromDate = '2026-10-01'; IncludeDownloadUrls = $true }
            $result = Get-MSCatalogUpdate @arguments -Format JSON | ConvertFrom-Json
            $result.Downloads[0].FileName | Should -BeExactly 'Windows11.0-KB5078127-x64_Full_Original_Name.msu'
            $result.SHA1 | Should -BeExactly $result.Downloads[0].SHA1
            $path = Join-Path $TestDrive 'updates.json'
            Get-MSCatalogUpdate @arguments -ExportJson $path
            (Get-Content $path -Raw | ConvertFrom-Json).Downloads[0].SHA1 | Should -Be '000102030405060708090A0B0C0D0E0F10111213'
        }

        It 'preserves nested metadata in XML output' {
            [xml] $xml = Get-MSCatalogUpdate -Product $productName -FromDate '2026-10-01' -IncludeDownloadUrls -Format XML
            $xml.OuterXml | Should -Match 'Windows11.0-KB5078127-x64_Full_Original_Name.msu'
            $xml.OuterXml | Should -Match '000102030405060708090A0B0C0D0E0F10111213'
        }
    }
}
