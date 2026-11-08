# Run in a fresh PowerShell process after changing PowerShell class definitions:
# Invoke-Pester ./Tests/Supersedence.Tests.ps1
BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../MSCatalogLTS.psd1') -Force
}

Describe 'Catalog supersedence metadata' {
    InModuleScope MSCatalogLTS {
        BeforeAll {
            $fixtureRoot = Join-Path (Split-Path (Get-Module MSCatalogLTS).Path) 'Tests/Fixtures'
            $updateGuid = 'fe12f49d-f2f0-4de3-a2ed-2946a5bbd7ef'
            $noneHtml = Get-Content (Join-Path $fixtureRoot 'Supersedence.None.html') -Raw
        }

        BeforeEach {
            $detailHtml = $noneHtml
            Mock Invoke-WebRequest { [PSCustomObject]@{ Content = $detailHtml } }
            Mock Write-Warning {}
            Mock Set-TempSecurityProtocol {}
        }

        It 'returns null for explicitly empty lists with a successful status' {
            $result = Get-UpdateSupersedence -Guid $updateGuid
            $result.Status | Should -Be 'Retrieved'
            ($null -eq $result.Supersedes) | Should -BeTrue
            ($null -eq $result.SupersededBy) | Should -BeTrue
            $result.Error | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 0 -Exactly
        }

        It 'retrieves superseded updates, decodes titles, and deduplicates GUIDs' {
            $detailHtml = Get-Content (Join-Path $fixtureRoot 'Supersedence.Replaces.html') -Raw
            $result = Get-UpdateSupersedence -Guid $updateGuid
            $result.Status | Should -Be 'Retrieved'
            $result.Supersedes.Count | Should -Be 1
            ($result.Supersedes -is [object[]]) | Should -BeTrue
            $result.Supersedes[0].Guid | Should -Be '8cea1349-3ff8-4482-af64-9db80cb71ffb'
            $result.Supersedes[0].Title | Should -Be 'Older update & security fix (KB5043080)'
            ($null -eq $result.SupersededBy) | Should -BeTrue
        }

        It 'retrieves superseding updates in the correct direction without following links' {
            $detailHtml = Get-Content (Join-Path $fixtureRoot 'Supersedence.ReplacedBy.html') -Raw
            $result = Get-UpdateSupersedence -Guid $updateGuid
            ($null -eq $result.Supersedes) | Should -BeTrue
            $result.SupersededBy.Count | Should -Be 2
            $result.SupersededBy[0].Guid | Should -Be 'a62b9737-1fe8-4df1-94b4-8ec61855a8d0'
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        }

        It 'preserves title-only relationships without inventing a GUID' {
            $detailHtml = Get-Content (Join-Path $fixtureRoot 'Supersedence.TitleOnly.html') -Raw
            $result = Get-UpdateSupersedence -Guid $updateGuid
            $result.Status | Should -Be 'Partial'
            $result.Supersedes.Count | Should -Be 1
            $result.Supersedes[0].Guid | Should -BeNullOrEmpty
            $result.Supersedes[0].Title | Should -Match 'KB5043080'
            $result.Supersedes[0].Title | Should -Not -Match '\s{2,}'
            $result.Error | Should -Match 'titles only'
        }

        It 'fails visibly for <Case>' -ForEach @(
            @{ Case = 'a missing relationship container'; Fragment = '<div id="supersedesInfo">n/a</div>' }
            @{ Case = 'an empty container'; Fragment = '<div id="supersedesInfo"></div><div id="supersededbyInfo">n/a</div>' }
            @{ Case = 'unrecognized text'; Fragment = '<div id="supersedesInfo">Unavailable</div><div id="supersededbyInfo">n/a</div>' }
            @{ Case = 'an invalid GUID'; Fragment = '<div id="supersedesInfo"><div><a href="ScopedViewInline.aspx?updateid=invalid">Older update</a></div></div><div id="supersededbyInfo">n/a</div>' }
            @{ Case = 'a missing link target'; Fragment = '<div id="supersedesInfo"><div><a>Older update</a></div></div><div id="supersededbyInfo">n/a</div>' }
            @{ Case = 'an empty relationship entry'; Fragment = '<div id="supersedesInfo"><div></div></div><div id="supersededbyInfo">n/a</div>' }
            @{ Case = 'unexpected text beside a relationship'; Fragment = '<div id="supersedesInfo">Incomplete response<div>Older update</div></div><div id="supersededbyInfo">n/a</div>' }
            @{ Case = 'an invalid link disguised as an empty list'; Fragment = '<div id="supersedesInfo"><a href="invalid">n/a</a></div><div id="supersededbyInfo">n/a</div>' }
            @{ Case = 'unexpected markup instead of a title'; Fragment = '<div id="supersedesInfo"><div><span>Unavailable</span></div></div><div id="supersededbyInfo">n/a</div>' }
        ) {
            $detailHtml = '<span id="ScopedViewHandler_UpdateID">' + $updateGuid + '</span>' + $Fragment
            $result = Get-UpdateSupersedence -Guid $updateGuid
            $result.Status | Should -Be 'Failed'
            $result.Supersedes | Should -BeNullOrEmpty
            $result.SupersededBy | Should -BeNullOrEmpty
            $result.Error | Should -Not -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 1 -Exactly
        }

        It 'rejects an unrelated or error page' {
            $detailHtml = '<html>Catalog error</html>'
            $result = Get-UpdateSupersedence -Guid $updateGuid
            $result.Status | Should -Be 'Failed'
            $result.Error | Should -Match 'identity'
        }

        It 'does not publish a valid first list when the second list is malformed' {
            $detailHtml = (Get-Content (Join-Path $fixtureRoot 'Supersedence.Replaces.html') -Raw).Replace('<div id="supersededbyInfo">n/a</div>', '<div id="supersededbyInfo"></div>')
            $result = Get-UpdateSupersedence -Guid $updateGuid
            $result.Status | Should -Be 'Failed'
            ($null -eq $result.Supersedes) | Should -BeTrue
            ($null -eq $result.SupersededBy) | Should -BeTrue
        }

        It 'rejects a different update identity' {
            $detailHtml = $noneHtml.Replace($updateGuid, '8cea1349-3ff8-4482-af64-9db80cb71ffb')
            (Get-UpdateSupersedence -Guid $updateGuid).Status | Should -Be 'Failed'
        }

        It 'handles request failures and restores the security protocol' {
            Mock Invoke-WebRequest { throw 'HTTP request failed' }
            $result = Get-UpdateSupersedence -Guid $updateGuid
            $result.Status | Should -Be 'Failed'
            $result.Supersedes | Should -BeNullOrEmpty
            $result.Error | Should -Be 'HTTP request failed'
            Should -Invoke Set-TempSecurityProtocol -Times 1 -Exactly -ParameterFilter { $ResetToDefault }
            Should -Invoke Write-Warning -Times 1 -Exactly
        }
    }
}

Describe 'Get-MSCatalogUpdate supersedence integration' {
    InModuleScope MSCatalogLTS {
        BeforeAll {
            $fixtureRoot = Join-Path (Split-Path (Get-Module MSCatalogLTS).Path) 'Tests/Fixtures'
            $searchHtml = Get-Content (Join-Path $fixtureRoot 'Search.html') -Raw
            $relatedHtml = Get-Content (Join-Path $fixtureRoot 'Supersedence.ReplacedBy.html') -Raw
        }

        BeforeEach {
            $script:MSCatalogSupersedenceCache = @{}
            Mock Write-Host {}
            Mock Write-Warning {}
            Mock Invoke-WebRequest {
                $html = if ($Uri -like '*Search.aspx*') { $searchHtml } else { $relatedHtml }
                [PSCustomObject]@{ Content = $html; RawContent = $html }
            }
            Mock Invoke-CatalogDetailRequests {
                $responses = @{}
                foreach ($guid in $Guids) {
                    $responses[$guid] = [PSCustomObject]@{ Content = $relatedHtml; Error = $null }
                }
                $responses
            }
        }

        It 'preserves ordinary search fields and makes no detail requests by default' {
            $updates = @(Get-MSCatalogUpdate -Search 'KB5043080')
            $updates.Count | Should -Be 3
            $updates[0].Title | Should -Be 'Security Update (KB5043080)'
            $updates[0].Guid | Should -Be 'fe12f49d-f2f0-4de3-a2ed-2946a5bbd7ef'
            $updates[0].Products | Should -Be 'Test product'
            $updates[0].Size | Should -Be '509.0 MB'
            $updates[0].SupersedenceStatus | Should -Be 'NotRequested'
            $updates[0].Supersedes | Should -BeNullOrEmpty
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
            Should -Invoke Invoke-CatalogDetailRequests -Times 0 -Exactly
        }

        It 'does not fetch metadata for an explicitly false switch' {
            $updates = @(Get-MSCatalogUpdate -Search 'KB5043080' -IncludeSupersedence:$false)
            $updates[0].SupersedenceStatus | Should -Be 'NotRequested'
            Should -Invoke Invoke-CatalogDetailRequests -Times 0 -Exactly
        }

        It 'returns null relationships when the Catalog explicitly reports none' {
            $relatedHtml = Get-Content (Join-Path $fixtureRoot 'Supersedence.None.html') -Raw
            $updates = @(Get-MSCatalogUpdate -Search 'KB5043080' -IncludeSupersedence -FromDate '2024-09-01')
            $updates.Count | Should -Be 2
            foreach ($update in $updates) {
                ($null -eq $update.Supersedes) | Should -BeTrue
                ($null -eq $update.SupersededBy) | Should -BeTrue
                $update.SupersedenceStatus | Should -Be 'Retrieved'
            }
        }

        It 'normalizes previously cached empty arrays to null without another request' {
            $guid = 'fe12f49d-f2f0-4de3-a2ed-2946a5bbd7ef'
            $script:MSCatalogSupersedenceCache[$guid] = @{
                FetchedAt = [DateTime]::UtcNow
                Metadata = [PSCustomObject]@{
                    Supersedes = @()
                    SupersededBy = @()
                    Status = 'Retrieved'
                    Error = $null
                }
            }
            $updates = @(Get-MSCatalogUpdate -Search 'KB5043080' -IncludeSupersedence -FromDate '2024-09-01')
            $updates.Count | Should -Be 2
            foreach ($update in $updates) {
                ($null -eq $update.Supersedes) | Should -BeTrue
                ($null -eq $update.SupersededBy) | Should -BeTrue
                $update.SupersedenceStatus | Should -Be 'Retrieved'
            }
            Should -Invoke Invoke-CatalogDetailRequests -Times 0 -Exactly
        }

        It 'keeps null relationships in JSON output' {
            $relatedHtml = Get-Content (Join-Path $fixtureRoot 'Supersedence.None.html') -Raw
            $updates = Get-MSCatalogUpdate -Search 'KB5043080' -IncludeSupersedence -FromDate '2024-09-01' -Format JSON | ConvertFrom-Json
            foreach ($update in $updates) {
                ($null -eq $update.Supersedes) | Should -BeTrue
                ($null -eq $update.SupersededBy) | Should -BeTrue
                $update.SupersedenceStatus | Should -Be 'Retrieved'
            }
        }

        It 'enriches returned updates, caches duplicate GUIDs, and skips filtered updates' {
            $updates = @(Get-MSCatalogUpdate -Search 'KB5043080' -IncludeSupersedence -FromDate '2024-09-01')
            $updates.Count | Should -Be 2
            foreach ($update in $updates) {
                $update.SupersedenceStatus | Should -Be 'Retrieved'
                $update.SupersededBy.Count | Should -Be 2
            }
            Should -Invoke Invoke-CatalogDetailRequests -Times 1 -Exactly -ParameterFilter { $Guids.Count -eq 1 -and $Guids[0] -eq 'fe12f49d-f2f0-4de3-a2ed-2946a5bbd7ef' }
        }

        It 'retains updates on failure and caches failed lookups within the invocation' {
            Mock Invoke-CatalogDetailRequests {
                $responses = @{}
                foreach ($guid in $Guids) {
                    $responses[$guid] = [PSCustomObject]@{ Content = $null; Error = 'Detail request failed' }
                }
                $responses
            }
            $updates = @(Get-MSCatalogUpdate -Search 'KB5043080' -IncludeSupersedence -FromDate '2024-09-01')
            $updates.Count | Should -Be 2
            foreach ($update in $updates) {
                $update.SupersedenceStatus | Should -Be 'Failed'
                $update.Supersedes | Should -BeNullOrEmpty
                $update.SupersedenceError | Should -Be 'Detail request failed'
            }
            Should -Invoke Invoke-CatalogDetailRequests -Times 1 -Exactly
            Should -Invoke Write-Warning -Times 1 -Exactly
        }

        It 'preserves nested relationship metadata in JSON output for multiple updates' {
            $updates = Get-MSCatalogUpdate -Search 'KB5043080' -IncludeSupersedence -FromDate '2024-09-01' -Format JSON | ConvertFrom-Json
            $updates.Count | Should -Be 2
            $updates[0].SupersededBy[0].Guid | Should -Be 'a62b9737-1fe8-4df1-94b4-8ec61855a8d0'
        }

        It 'preserves nested relationship metadata in XML output' {
            [xml] $xml = Get-MSCatalogUpdate -Search 'KB5043080' -IncludeSupersedence -FromDate '2024-09-01' -Format XML
            $xml.SelectNodes('//Property[@Name="Guid" and text()="a62b9737-1fe8-4df1-94b4-8ec61855a8d0"]').Count | Should -Be 2
        }

        It 'keeps the normal table and retains metadata with -<SwitchName>' -ForEach @(
            @{ SwitchName = 'IncludeSupersedence' }
            @{ SwitchName = 'IncludeSuperseded' }
        ) {
            $options = @{ $SwitchName = $true }
            $updates = @(Get-MSCatalogUpdate -Search 'KB5043080' @options -FromDate '2024-09-01')
            $rendered = $updates | Out-String -Width 200
            $rendered | Should -Match 'Title\s+Products\s+Classification\s+LastUpdated\s+Size'
            $rendered | Should -Not -Match 'Supersedes|SupersededBy|SupersedenceStatus|KB5044284'
            $updates[0].SupersededBy[0].Guid | Should -Be 'a62b9737-1fe8-4df1-94b4-8ec61855a8d0'
            $updates[0].PSObject.TypeNames[0] | Should -Be 'MSCatalogUpdate'
            $updates[0].GetType().Name | Should -Be 'MSCatalogUpdate'
        }

        It 'keeps the original table view without the switch' {
            $updates = @(Get-MSCatalogUpdate -Search 'KB5043080')
            ($updates | Out-String -Width 200) | Should -Not -Match 'SupersededBy'
            $updates[0].PSObject.TypeNames[0] | Should -Be 'MSCatalogUpdate'
        }

        It 'reuses successful lookups for repeated searches in the same session' {
            $first = @(Get-MSCatalogUpdate -Search 'KB5043080' -IncludeSupersedence -FromDate '2024-09-01')
            $second = @(Get-MSCatalogUpdate -Search 'KB5043080' -IncludeSupersedence -FromDate '2024-09-01')
            $second[0].SupersededBy.Count | Should -Be $first[0].SupersededBy.Count
            Should -Invoke Invoke-CatalogDetailRequests -Times 1 -Exactly
        }

        It 'refreshes cache entries after five minutes' {
            $first = @(Get-MSCatalogUpdate -Search 'KB5043080' -IncludeSupersedence -FromDate '2024-09-01')
            $script:MSCatalogSupersedenceCache[$first[0].Guid].FetchedAt = [DateTime]::UtcNow.AddMinutes(-6)
            $second = @(Get-MSCatalogUpdate -Search 'KB5043080' -IncludeSupersedence -FromDate '2024-09-01')
            $second[0].SupersedenceStatus | Should -Be 'Retrieved'
            Should -Invoke Invoke-CatalogDetailRequests -Times 2 -Exactly
        }

        It 'retries failed lookups on the next search' {
            Mock Invoke-CatalogDetailRequests {
                $responses = @{}
                foreach ($guid in $Guids) {
                    $responses[$guid] = [PSCustomObject]@{ Content = $null; Error = 'Timeout' }
                }
                $responses
            }
            $first = @(Get-MSCatalogUpdate -Search 'KB5043080' -IncludeSupersedence -FromDate '2024-09-01')
            $second = @(Get-MSCatalogUpdate -Search 'KB5043080' -IncludeSupersedence -FromDate '2024-09-01')
            $second[0].SupersedenceStatus | Should -Be 'Failed'
            Should -Invoke Invoke-CatalogDetailRequests -Times 2 -Exactly
        }
    }
}
