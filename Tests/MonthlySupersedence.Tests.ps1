BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../MSCatalogLTS.psd1') -Force
}

Describe 'Supersedence filtering within selected dates' {
    InModuleScope MSCatalogLTS {
        BeforeAll {
            $fixtureRoot = Join-Path (Split-Path (Get-Module MSCatalogLTS).Path) 'Tests/Fixtures'
            $olderGuid = '20df3c75-cba4-4606-8af0-41ad89675e98'
            $newerGuid = '797fec39-6d79-43b7-8585-8d95c6017cc3'
            $netGuid = '2bcb5934-1515-44d3-898f-fcfe55ce3824'
            $octoberGuid = '1abba66b-03c6-467e-9819-96844606cb15'
            $previewGuid = '00000000-0000-0000-0000-000000000005'
        }

        BeforeEach {
            $script:MSCatalogSupersedenceCache = @{}
            $searchHtml = Get-Content (Join-Path $fixtureRoot 'Search.Month.html') -Raw
            $targetsByGuid = @{}
            $targetsByGuid[$olderGuid] = @($newerGuid, $octoberGuid)
            $targetsByGuid[$newerGuid] = @($octoberGuid)
            $titlesByGuid = @{}
            $titlesByGuid[$newerGuid] = '2026-09 Cumulative Update (KB5129235)'
            $titlesByGuid[$octoberGuid] = '2026-10 Cumulative Update (KB5126646)'
            $titlesByGuid[$previewGuid] = '2026-09 Cumulative Update Preview (KB9999999)'
            $failedGuid = $null
            $titleOnlyGuid = $null
            Mock Write-Host {}
            Mock Write-Warning {}
            Mock Invoke-WebRequest { [PSCustomObject]@{ Content = $searchHtml; RawContent = $searchHtml } }
            Mock Invoke-CatalogDetailRequests {
                $responses = @{}
                foreach ($guid in $Guids) {
                    if ($guid -eq $failedGuid) {
                        $responses[$guid] = [PSCustomObject]@{ Content = $null; Error = 'Timeout' }
                        continue
                    }
                    $items = foreach ($target in $targetsByGuid[$guid]) {
                        if ($guid -eq $titleOnlyGuid) {
                            '<div>{0}</div>' -f $titlesByGuid[$target]
                        } else {
                            '<div><a href="ScopedViewInline.aspx?updateid={0}">{1}</a></div>' -f $target, $titlesByGuid[$target]
                        }
                    }
                    $replacements = if ($items) { $items -join '' } else { 'n/a' }
                    $html = '<span id="ScopedViewHandler_UpdateID">{0}</span><div id="supersedesInfo">n/a</div><div id="supersededbyInfo">{1}</div>' -f $guid, $replacements
                    $responses[$guid] = [PSCustomObject]@{ Content = $html; Error = $null }
                }
                $responses
            }
        }

        It 'removes an older September update, keeps its September replacement and independent .NET update' {
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -Architecture x64 -Date '2026-09' -AllPages -ExcludeSuperseded)
            $updates.Count | Should -Be 2
            $updates.Guid | Should -Contain $newerGuid
            $updates.Guid | Should -Contain $netGuid
            $updates.Guid | Should -Not -Contain $olderGuid
            $updates.Guid | Should -Not -Contain $octoberGuid
            $rendered = $updates | Out-String -Width 250
            $rendered | Should -Match 'Title\s+Products\s+Classification\s+LastUpdated\s+Size'
            $rendered | Should -Not -Match 'Supersedes|SupersededBy|SupersedenceStatus|KB5122871'
            Should -Invoke Invoke-CatalogDetailRequests -Times 1 -Exactly -ParameterFilter { $Guids.Count -eq 3 -and $Guids -notcontains $octoberGuid }
        }

        It 'does not exclude September updates because of October replacements' {
            $targetsByGuid[$olderGuid] = @($octoberGuid)
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -Date '2026-09' -ExcludeSuperseded)
            $updates.Count | Should -Be 3
            $updates.Guid | Should -Contain $olderGuid
            ($updates | Where-Object Guid -eq $newerGuid).SupersededBy[0].Guid | Should -Be $octoberGuid
        }

        It 'passes every remaining update to the downstream pipeline command' {
            # Verify the search output independently of the downloader implementation.
            Mock Save-MSCatalogUpdate {}
            Get-MSCatalogUpdate -Search 'Server 24H2' -Date '2026-09' -ExcludeSuperseded |
                Save-MSCatalogUpdate -DownloadAll | Out-Null
            Should -Invoke Save-MSCatalogUpdate -Times 2 -Exactly
            Should -Invoke Save-MSCatalogUpdate -Times 1 -Exactly -ParameterFilter { $Update.Guid -eq $newerGuid }
            Should -Invoke Save-MSCatalogUpdate -Times 1 -Exactly -ParameterFilter { $Update.Guid -eq $netGuid }
            Should -Invoke Save-MSCatalogUpdate -Times 0 -Exactly -ParameterFilter { $Update.Guid -eq $olderGuid }
        }

        It 'keeps all monthly results when only metadata is requested' {
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -Date '2026-09' -IncludeSupersedence)
            $updates.Count | Should -Be 3
            $updates.Guid | Should -Contain $olderGuid
        }

        It 'accepts the original FromDate and ToDate command without Date' {
            $updates = @(Get-MSCatalogUpdate -Architecture x64 -Search 'Server 24H2' -FromDate '2026-09-01' -ToDate '2026-10-01' -ExcludeSuperseded)
            $updates.Count | Should -Be 2
            $updates.Guid | Should -Contain $newerGuid
            $updates.Guid | Should -Contain $netGuid
            $updates.Guid | Should -Not -Contain $olderGuid
            Should -Invoke Invoke-CatalogDetailRequests -Times 1 -Exactly -ParameterFilter { $Guids.Count -eq 3 -and $Guids -notcontains $octoberGuid }
        }

        It 'ignores a replacement outside a narrower date interval' {
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -FromDate '2026-09-01' -ToDate '2026-09-10' -ExcludeSuperseded)
            $updates.Count | Should -Be 2
            $updates.Guid | Should -Contain $olderGuid
            $updates.Guid | Should -Contain $netGuid
            $updates.Guid | Should -Not -Contain $newerGuid
        }

        It 'compares all returned candidates when the interval spans multiple months' {
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -FromDate '2026-09-01' -ToDate '2026-10-31' -ExcludeSuperseded)
            $updates.Count | Should -Be 2
            $updates.Guid | Should -Contain $octoberGuid
            $updates.Guid | Should -Contain $netGuid
            $updates.Guid | Should -Not -Contain $newerGuid
            $updates.Guid | Should -Not -Contain $olderGuid
        }

        It 'includes updates on both date boundaries without inheriting the current time' {
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -FromDate '2026-09-08' -ToDate '2026-09-08' -ExcludeSuperseded)
            $updates.Count | Should -Be 2
            $updates.Guid | Should -Contain $olderGuid
            $updates.Guid | Should -Contain $netGuid
            $updates[0].LastUpdated.TimeOfDay | Should -Be ([TimeSpan]::Zero)
        }

        It 'uses LastUpdated for a range even when the update title specifies September' {
            $searchHtml = $searchHtml.Replace('9/14/2026', '10/20/2026')
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -FromDate '2026-09-01' -ToDate '2026-09-30' -ExcludeSuperseded)
            $updates.Count | Should -Be 2
            $updates.Guid | Should -Contain $olderGuid
            $updates.Guid | Should -Not -Contain $newerGuid
        }

        It 'intersects a title month and LastUpdated range when both are specified' {
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -Date '2026-09' -FromDate '2026-09-01' -ToDate '2026-09-10' -ExcludeSuperseded)
            $updates.Count | Should -Be 2
            $updates.Guid | Should -Contain $olderGuid
            $updates.Guid | Should -Contain $netGuid
        }

        It 'retains a result on lookup failure with a date interval' {
            $failedGuid = $olderGuid
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -FromDate '2026-09-01' -ToDate '2026-09-30' -ExcludeSuperseded)
            $updates.Count | Should -Be 3
            ($updates | Where-Object Guid -eq $olderGuid).SupersedenceStatus | Should -Be 'Failed'
        }

        It 'accepts <Selection> and only compares the remaining results' -ForEach @(
            @{ Selection = 'no date filter'; Bounds = @{}; ExpectedGuid = '1abba66b-03c6-467e-9819-96844606cb15'; ExpectedCount = 2 }
            @{ Selection = 'FromDate alone'; Bounds = @{ FromDate = '2026-09-01' }; ExpectedGuid = '1abba66b-03c6-467e-9819-96844606cb15'; ExpectedCount = 2 }
            @{ Selection = 'ToDate alone'; Bounds = @{ ToDate = '2026-09-30' }; ExpectedGuid = '797fec39-6d79-43b7-8585-8d95c6017cc3'; ExpectedCount = 2 }
        ) {
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' @Bounds -ExcludeSuperseded)
            $updates.Count | Should -Be $ExpectedCount
            $updates.Guid | Should -Contain $ExpectedGuid
            $updates.Guid | Should -Contain $netGuid
        }

        It 'supports LastDays <Days> with deterministic date boundaries' -ForEach @(
            @{ Days = 7; ExpectedCount = 2 }
            @{ Days = 3; ExpectedCount = 1 }
        ) {
            # Keep the October update outside the simulated relative interval.
            $searchHtml = $searchHtml.Replace('10/13/2026', '8/1/2026')
            Mock Get-Date {
                if ($Year -and $Month -and $Day) { [datetime]::new($Year, $Month, $Day) }
                else { [datetime] '2026-09-15' }
            }
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -LastDays $Days -ExcludeSuperseded)
            $updates.Count | Should -Be $ExpectedCount
            $updates.Guid | Should -Contain $newerGuid
            $updates.Guid | Should -Not -Contain $octoberGuid
            $updates.Guid | Should -Not -Contain $olderGuid
        }

        It 'intersects LastDays and an upper date bound' {
            Mock Get-Date {
                if ($Year -and $Month -and $Day) { [datetime]::new($Year, $Month, $Day) }
                else { [datetime] '2026-09-15' }
            }
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -LastDays 7 -ToDate '2026-09-10' -ExcludeSuperseded)
            $updates.Count | Should -Be 2
            $updates.Guid | Should -Contain $olderGuid
            $updates.Guid | Should -Contain $netGuid
        }

        It 'supports a month token supplied only in the search text' {
            $updates = @(Get-MSCatalogUpdate -Search '2026-09 Server 24H2' -ExcludeSuperseded)
            $updates.Count | Should -Be 2
            $updates.Guid | Should -Contain $newerGuid
            $updates.Guid | Should -Contain $netGuid
            Should -Invoke Invoke-CatalogDetailRequests -Times 1 -Exactly -ParameterFilter { $Guids.Count -eq 3 }
        }

        It 'applies Date in the OS parameter set' {
            $updates = @(Get-MSCatalogUpdate -OperatingSystem 'Windows Server' -Version '2025' -Date '2026-09' -ExcludeSuperseded)
            $updates.Guid | Should -Contain $newerGuid
            $updates.Guid | Should -Not -Contain $octoberGuid
        }

        It 'does not reuse the month token from a preceding call in the OS parameter set' {
            $first = @(Get-MSCatalogUpdate -Search '2026-09 Server 24H2' -ExcludeSuperseded)
            $second = @(Get-MSCatalogUpdate -OperatingSystem 'Windows Server' -Version '2025' -FromDate '2026-10-01' -ExcludeSuperseded)
            $first.Guid | Should -Contain $newerGuid
            $second.Count | Should -Be 1
            $second.Guid | Should -Contain $octoberGuid
        }

        It 'rejects a reversed date interval before requesting metadata' {
            { Get-MSCatalogUpdate -Search 'Server 24H2' -FromDate '2026-10-01' -ToDate '2026-09-01' -ExcludeSuperseded } | Should -Throw '*earlier than or equal*'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Invoke-CatalogDetailRequests -Times 0 -Exactly
        }

        It 'keeps a result whose supersedence lookup failed' {
            $failedGuid = $olderGuid
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -Date '2026-09' -ExcludeSuperseded)
            $updates.Count | Should -Be 3
            ($updates | Where-Object Guid -eq $olderGuid).SupersedenceStatus | Should -Be 'Failed'
        }

        It 'does not infer exclusions from title-only relationships' {
            $titleOnlyGuid = $olderGuid
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -Date '2026-09' -ExcludeSuperseded)
            $updates.Count | Should -Be 3
            ($updates | Where-Object Guid -eq $olderGuid).SupersedenceStatus | Should -Be 'Partial'
        }

        It 'does not use an excluded preview to remove a result' {
            $targetsByGuid[$newerGuid] = @($previewGuid)
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -Date '2026-09' -ExcludeSuperseded)
            $updates.Guid | Should -Contain $newerGuid
            $updates.Guid | Should -Not -Contain $previewGuid
        }

        It 'follows a replacement chain within the month when previews are explicitly included' {
            $targetsByGuid[$newerGuid] = @($previewGuid)
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -Date '2026-09' -IncludePreview -ExcludeSuperseded)
            $updates.Count | Should -Be 2
            $updates.Guid | Should -Contain $previewGuid
            $updates.Guid | Should -Contain $netGuid
            $updates.Guid | Should -Not -Contain $olderGuid
            $updates.Guid | Should -Not -Contain $newerGuid
        }

        It 'uses title month even when LastUpdated has changed in October' {
            $searchHtml = $searchHtml.Replace('9/14/2026', '10/20/2026')
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -Date '2026-09' -ExcludeSuperseded)
            $updates.Count | Should -Be 2
            $updates.Guid | Should -Contain $newerGuid
        }

        It 'preserves relationship objects in JSON after filtering' {
            $updates = Get-MSCatalogUpdate -Search 'Server 24H2' -Date '2026-09' -ExcludeSuperseded -Format JSON | ConvertFrom-Json
            $updates.Count | Should -Be 2
            ($updates | Where-Object Guid -eq $newerGuid).SupersededBy[0].Guid | Should -Be $octoberGuid
        }

        It 'accepts the existing title token <Token> without imposing a month-only format' -ForEach @(
            @{ Token = '2026' }
            @{ Token = '2026-09-08' }
        ) {
            $searchHtml = $searchHtml.Replace('2026-09 ', "$Token ")
            # A year token also includes October, so restrict LastUpdated to September.
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -Date $Token -ToDate '2026-09-30' -ExcludeSuperseded)
            $updates.Count | Should -Be 2
            $updates.Guid | Should -Contain $newerGuid
            $updates.Guid | Should -Contain $netGuid
        }

        It 'handles an empty monthly selection without detail requests' {
            $updates = @(Get-MSCatalogUpdate -Search 'Server 24H2' -Date '2026-08' -ExcludeSuperseded)
            $updates.Count | Should -Be 0
            Should -Invoke Invoke-CatalogDetailRequests -Times 0 -Exactly
        }
    }
}
