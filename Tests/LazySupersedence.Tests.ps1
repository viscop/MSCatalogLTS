BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../MSCatalogLTS.psd1') -Force
}

Describe 'Lazy supersedence through Get-MSCatalogUpdate and the existing cache and parser' {
    InModuleScope MSCatalogLTS {
        BeforeAll {
            $fixtureRoot = Join-Path (Split-Path (Get-Module MSCatalogLTS).Path) 'Tests/Fixtures'
            $latestGuid = '00000000-0000-0000-0000-000000000006'
            $octoberGuid = '1abba66b-03c6-467e-9819-96844606cb15'
            $oldGuid = '20df3c75-cba4-4606-8af0-41ad89675e98'
            $septemberGuid = '797fec39-6d79-43b7-8585-8d95c6017cc3'
            $netGuid = '00000000-0000-0000-0000-000000000007'
            $oldNetGuid = '2bcb5934-1515-44d3-898f-fcfe55ce3824'
        }

        BeforeEach {
            $script:MSCatalogSupersedenceCache = @{}
            $fixture = [HtmlAgilityPack.HtmlDocument]::new()
            $fixture.LoadHtml((Get-Content (Join-Path $fixtureRoot 'Search.Supersedence.html') -Raw))
            $historic = $fixture.DocumentNode.SelectSingleNode("//tr[.//input[@id='00000000-0000-0000-0000-000000000008']]")
            $null = $historic.ParentNode.RemoveChild($historic)
            $supersedes = @{}
            $supersedes[$latestGuid] = @($octoberGuid, $septemberGuid, $oldGuid)
            $supersedes[$netGuid] = @($oldNetGuid)
            $supersededBy = @{}
            $failedGuid = $null
            $requestOrder = [System.Collections.Generic.List[string]]::new()
            Mock Write-Host {}
            Mock Write-Warning {}
            Mock Set-TempSecurityProtocol {}
            Mock Invoke-WebRequest {
                $html = $fixture.DocumentNode.OuterHtml
                [PSCustomObject]@{ Content = $html; RawContent = $html }
            }
            Mock Invoke-CatalogDetailRequests {
                $responses = @{}
                foreach ($guid in $Guids) {
                    $requestOrder.Add($guid)
                    if ($guid -eq $failedGuid) {
                        $responses[$guid] = [PSCustomObject]@{ Content = $null; Error = 'Timeout' }
                        continue
                    }
                    $lists = @{}
                    foreach ($direction in @('supersedesInfo', 'supersededbyInfo')) {
                        $targets = if ($direction -eq 'supersedesInfo') { $supersedes[$guid] } else { $supersededBy[$guid] }
                        $items = @(foreach ($target in $targets) {
                            '<div><a href="ScopedViewInline.aspx?updateid={0}">Related update</a></div>' -f $target
                        })
                        $lists[$direction] = if ($items.Count) { $items -join '' } else { 'n/a' }
                    }
                    $html = '<span id="ScopedViewHandler_UpdateID">{0}</span><div id="supersedesInfo">{1}</div><div id="supersededbyInfo">{2}</div>' -f $guid, $lists.supersedesInfo, $lists.supersededbyInfo
                    $responses[$guid] = [PSCustomObject]@{ Content = $html; Error = $null }
                }
                $responses
            }
        }

        It 'delegates exclusion directly to the lazy selector without an eager metadata batch' {
            Mock Select-NonSupersededUpdate { $Updates }
            Mock Get-UpdateSupersedenceBatch { throw 'Unexpected eager metadata retrieval' }
            @(Get-MSCatalogUpdate -Search 'Example Product' -ExcludeSuperseded).Count | Should -Be 6
            Should -Invoke Select-NonSupersededUpdate -Times 1 -Exactly -ParameterFilter {
                $ResolveSupersedence -and $Updates.Count -eq 6
            }
            Should -Invoke Get-UpdateSupersedenceBatch -Times 0 -Exactly
        }

        It 'reduces six detail requests to two and skips every eliminated candidate' {
            $updates = @(Get-MSCatalogUpdate -Search 'Example Product' -ExcludeSuperseded)
            $updates.Guid | Should -Be @($latestGuid, $netGuid)
            @($requestOrder) | Should -Be @($latestGuid, $netGuid)
            $updates.SupersedenceStatus | Should -Be @('Retrieved', 'Retrieved')
            Should -Invoke Invoke-CatalogDetailRequests -Times 2 -Exactly -ParameterFilter { $Guids.Count -eq 1 }
        }

        It 'retrieves complete metadata for retained candidates with both switches explicitly supplied' {
            $updates = @(Get-MSCatalogUpdate -Search 'Example Product' -ExcludeSuperseded -IncludeSupersedence)
            $updates.Count | Should -Be 2
            ($updates | Where-Object Guid -eq $latestGuid).Supersedes.Count | Should -Be 3
            ($updates | Where-Object Guid -eq $netGuid).Supersedes[0].Guid | Should -Be $oldNetGuid
            @($requestOrder) | Should -Be @($latestGuid, $netGuid)
        }

        It 'still loads every unique candidate in a batch for IncludeSupersedence alone' {
            $updates = @(Get-MSCatalogUpdate -Search 'Example Product' -IncludeSupersedence)
            $updates.Count | Should -Be 6
            @($updates | Where-Object SupersedenceStatus -ne 'Retrieved').Count | Should -Be 0
            $requestOrder.Count | Should -Be 6
            Should -Invoke Invoke-CatalogDetailRequests -Times 1 -Exactly -ParameterFilter { $Guids.Count -eq 6 }
        }

        It 'keeps implicit metadata with an explicitly false IncludeSupersedence switch' {
            $updates = @(Get-MSCatalogUpdate -Search 'Example Product' -ExcludeSuperseded -IncludeSupersedence:$false)
            $updates.SupersedenceStatus | Should -Be @('Retrieved', 'Retrieved')
            $requestOrder.Count | Should -Be 2
        }

        It 'reuses successful cached metadata and reports cache hits and duration' {
            Get-MSCatalogUpdate -Search 'Example Product' -ExcludeSuperseded | Out-Null
            $records = @(Get-MSCatalogUpdate -Search 'Example Product' -ExcludeSuperseded -Verbose 4>&1)
            $updates = @($records | Where-Object { $_ -is [MSCatalogUpdate] })
            $messages = @($records | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }) -join "`n"
            $updates.Count | Should -Be 2
            $requestOrder.Count | Should -Be 2
            $messages | Should -Match '6 candidates'
            $messages | Should -Match 'Reusing cached supersedence'
            $messages | Should -Match '4 candidates eliminated, 2 candidates remaining; duration'
        }

        It 'refreshes expired cache entries without loading eliminated candidates' {
            Get-MSCatalogUpdate -Search 'Example Product' -ExcludeSuperseded | Out-Null
            foreach ($entry in $script:MSCatalogSupersedenceCache.Values) { $entry.FetchedAt = [datetime]::UtcNow.AddMinutes(-6) }
            Get-MSCatalogUpdate -Search 'Example Product' -ExcludeSuperseded | Out-Null
            @($requestOrder) | Should -Be @($latestGuid, $netGuid, $latestGuid, $netGuid)
        }

        It 'preserves a failed lookup and retries it on the next invocation' {
            $failedGuid = $latestGuid
            $updates = @(Get-MSCatalogUpdate -Search 'Example Product' -ExcludeSuperseded)
            $updates.Count | Should -Be 5
            $failed = $updates | Where-Object Guid -eq $latestGuid
            $failed.SupersedenceStatus | Should -Be 'Failed'
            $failed.SupersedenceError | Should -Be 'Timeout'
            $script:MSCatalogSupersedenceCache.ContainsKey($latestGuid) | Should -BeFalse
            @($requestOrder) | Should -Be @($latestGuid, $netGuid, $octoberGuid, $septemberGuid, $oldGuid)
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*Timeout*' }
            $failedGuid = $null
            $updates = @(Get-MSCatalogUpdate -Search 'Example Product' -ExcludeSuperseded)
            $updates.Count | Should -Be 2
            $requestOrder.Count | Should -Be 6
            $requestOrder[5] | Should -Be $latestGuid
        }

        It 'looks up duplicate GUID rows once and populates each retained object' {
            $row = $fixture.DocumentNode.SelectSingleNode("//tr[.//input[@id='$latestGuid']]")
            $null = $row.ParentNode.AppendChild($row.CloneNode($true))
            $updates = @(Get-MSCatalogUpdate -Search 'Example Product' -ExcludeSuperseded)
            $updates.Count | Should -Be 3
            @($updates | Where-Object SupersedenceStatus -eq 'Retrieved').Count | Should -Be 3
            @($requestOrder) | Should -Be @($latestGuid, $netGuid)
        }

        It 'keeps internal lookup order independent from the final ascending date sort' {
            $updates = @(Get-MSCatalogUpdate -Search 'Example Product' -ExcludeSuperseded -SortBy Date -Descending:$false)
            $updates.Guid | Should -Be @($netGuid, $latestGuid)
            @($requestOrder) | Should -Be @($latestGuid, $netGuid)
        }

        It 'does not resolve metadata for an empty filtered selection' {
            @(Get-MSCatalogUpdate -Search 'Example Product' -TitleContains 'Nonexistent' -ExcludeSuperseded).Count | Should -Be 0
            Should -Invoke Invoke-CatalogDetailRequests -Times 0 -Exactly
        }

        It 'runs the title filter before resolution and keeps excluded replacements out of evidence' {
            $supersededBy[$netGuid] = @($latestGuid)
            $supersededBy[$oldNetGuid] = @($latestGuid)
            $updates = @(Get-MSCatalogUpdate -Search 'Example Product' -TitleContains '.NET Framework' -ExcludeSuperseded)
            $updates.Guid | Should -Be @($netGuid)
            @($requestOrder) | Should -Be @($netGuid)
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        }
    }
}
