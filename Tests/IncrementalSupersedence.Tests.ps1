BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../MSCatalogLTS.psd1') -Force
}

Describe 'Incremental supersedence resolution from newest to oldest' {
    InModuleScope MSCatalogLTS {
        BeforeAll {
            $oldGuid = '00000000-0000-0000-0000-000000000001'
            $newGuid = '00000000-0000-0000-0000-000000000002'
            $independentGuid = '00000000-0000-0000-0000-000000000003'
            $externalGuid = '00000000-0000-0000-0000-000000000004'

            function New-IncrementalCandidate {
                param ([string] $Guid, [datetime] $LastUpdated)
                [PSCustomObject]@{
                    Guid = $Guid; LastUpdated = $LastUpdated; Title = 'Update (KB1234567)'
                    Supersedes = $null; SupersededBy = $null
                    SupersedenceStatus = 'NotRequested'; SupersedenceError = $null
                }
            }
        }

        BeforeEach {
            $old = New-IncrementalCandidate $oldGuid '2026-09-01'
            $new = New-IncrementalCandidate $newGuid '2026-10-27'
            $independent = New-IncrementalCandidate $independentGuid '2026-10-13'
            $candidates = @($old, $new, $independent)
            $requestOrder = [System.Collections.Generic.List[string]]::new()
            $metadataById = @{}
            foreach ($guid in $candidates.Guid) {
                $metadataById[$guid] = [PSCustomObject]@{
                    Supersedes = $null; SupersededBy = $null; Status = 'Retrieved'; Error = $null
                }
            }
            Mock Get-UpdateSupersedenceBatch {
                $requestOrder.Add($Guids[0])
                $response = @{}
                foreach ($guid in $Guids) { $response[$guid] = $metadataById[$guid] }
                $response
            }
        }

        It 'starts with the youngest candidate and skips details for its confirmed superseded candidate' {
            $metadataById[$newGuid].Supersedes = @([PSCustomObject]@{ Guid = $oldGuid; Title = 'Old update' })
            $results = @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence)
            $results.Guid | Should -Be @($newGuid, $independentGuid)
            @($requestOrder) | Should -Be @($newGuid, $independentGuid)
            Should -Invoke Get-UpdateSupersedenceBatch -Times 0 -Exactly -ParameterFilter { $Guids -contains $oldGuid }
        }

        It 'continues through the list if none of the superseded GUIDs match' {
            $metadataById[$newGuid].Supersedes = @([PSCustomObject]@{ Guid = $externalGuid; Title = 'External update' })
            $results = @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence)
            $results.Count | Should -Be 3
            @($requestOrder) | Should -Be @($newGuid, $independentGuid, $oldGuid)
            Should -Invoke Get-UpdateSupersedenceBatch -Times 0 -Exactly -ParameterFilter { $Guids -contains $externalGuid }
        }

        It 'removes all confirmed older candidates with a single detail request' {
            $metadataById[$newGuid].Supersedes = @($oldGuid, $independentGuid | ForEach-Object {
                [PSCustomObject]@{ Guid = $_; Title = 'Old update' }
            })
            $results = @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence)
            $results.Count | Should -Be 1
            $results[0].Guid | Should -Be $newGuid
            Should -Invoke Get-UpdateSupersedenceBatch -Times 1 -Exactly -ParameterFilter { $Guids.Count -eq 1 -and $Guids[0] -eq $newGuid }
        }

        It 'uses reverse GUID evidence if the replacement does not list the older candidate' {
            $metadataById[$oldGuid].SupersededBy = @([PSCustomObject]@{ Guid = $newGuid; Title = 'Replacement' })
            $results = @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence)
            $results.Guid | Should -Not -Contain $oldGuid
            @($requestOrder) | Should -Be @($newGuid, $independentGuid, $oldGuid)
        }

        It 'does not use reverse relationships to updates outside the filtered set' {
            $metadataById[$newGuid].SupersededBy = @([PSCustomObject]@{ Guid = $externalGuid; Title = 'External replacement' })
            @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence).Count | Should -Be 3
            Should -Invoke Get-UpdateSupersedenceBatch -Times 0 -Exactly -ParameterFilter { $Guids -contains $externalGuid }
        }

        It 'keeps ambiguous title-only relationships even when all candidate titles and KBs match' {
            $metadataById[$newGuid].Status = 'Partial'
            $metadataById[$newGuid].Supersedes = @([PSCustomObject]@{ Guid = $null; Title = $old.Title })
            $results = @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence)
            $results.Count | Should -Be 3
            $new.SupersedenceStatus | Should -Be 'Partial'
            $requestOrder.Count | Should -Be 3
        }

        It 'uses valid GUIDs from partial metadata to skip confirmed candidates' {
            $metadataById[$newGuid].Status = 'Partial'
            $metadataById[$newGuid].Supersedes = @(
                [PSCustomObject]@{ Guid = $oldGuid; Title = 'Old update' }
                [PSCustomObject]@{ Guid = $null; Title = 'Unidentified update' }
            )
            $results = @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence)
            $results.Count | Should -Be 2
            $requestOrder.Count | Should -Be 2
        }

        It 'continues after a failed lookup and preserves its status' {
            $metadataById[$newGuid].Status = 'Failed'
            $metadataById[$newGuid].Error = 'Timeout'
            $results = @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence)
            $results.Count | Should -Be 3
            $new.SupersedenceStatus | Should -Be 'Failed'
            $new.SupersedenceError | Should -Be 'Timeout'
            @($requestOrder) | Should -Be @($newGuid, $independentGuid, $oldGuid)
        }

        It 'can remove an already inspected candidate when LastUpdated differs from supersedence order' {
            $metadataById[$oldGuid].Supersedes = @([PSCustomObject]@{ Guid = $newGuid; Title = 'Revised old update' })
            $results = @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence)
            $results.Guid | Should -Be @($oldGuid, $independentGuid)
            @($requestOrder) | Should -Be @($newGuid, $independentGuid, $oldGuid)
        }

        It 'uses GUID ordering for ties and keeps every independent candidate' {
            $old.LastUpdated = $new.LastUpdated
            $independent.LastUpdated = $new.LastUpdated
            @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence).Count | Should -Be 3
            @($requestOrder) | Should -Be @($oldGuid, $newGuid, $independentGuid)
        }

        It 'looks up duplicate GUIDs once and populates metadata on each returned object' {
            $duplicate = New-IncrementalCandidate $newGuid '2026-10-27'
            $results = @(Select-NonSupersededUpdate -Updates @($new, $duplicate) -ResolveSupersedence)
            $results.Count | Should -Be 2
            $results.SupersedenceStatus | Should -Be @('Retrieved', 'Retrieved')
            Should -Invoke Get-UpdateSupersedenceBatch -Times 1 -Exactly
        }

        It 'ignores self-relationships' {
            $metadataById[$newGuid].Supersedes = @([PSCustomObject]@{ Guid = $newGuid; Title = 'Self' })
            $metadataById[$newGuid].SupersededBy = $metadataById[$newGuid].Supersedes
            @(Select-NonSupersededUpdate -Updates @($new) -ResolveSupersedence).Count | Should -Be 1
        }

        It 'does not request metadata for an empty selection' {
            @(Select-NonSupersededUpdate -Updates @() -ResolveSupersedence).Count | Should -Be 0
            Should -Invoke Get-UpdateSupersedenceBatch -Times 0 -Exactly
        }

        It 'can also filter already populated metadata without requesting details' {
            $new.SupersedenceStatus = 'Retrieved'
            $new.Supersedes = @([PSCustomObject]@{ Guid = $oldGuid; Title = 'Old update' })
            $results = @(Select-NonSupersededUpdate -Updates $candidates)
            $results.Guid | Should -Be @($newGuid, $independentGuid)
            Should -Invoke Get-UpdateSupersedenceBatch -Times 0 -Exactly
        }

        It 'resolves an exact unique title to a candidate GUID and skips its lookup' {
            $old.Title = '2026-09 Cumulative Update for Example Product for x64 (KB1234567)'
            $metadataById[$newGuid].Status = 'Partial'
            $relationship = [PSCustomObject]@{ Guid = $null; Title = $old.Title }
            $metadataById[$newGuid].Supersedes = @($relationship)
            $results = @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence)
            $results.Guid | Should -Be @($newGuid, $independentGuid)
            @($requestOrder) | Should -Be @($newGuid, $independentGuid)
            # Preserve the actual Catalog metadata and its partial status.
            $new.Supersedes[0].Guid | Should -BeNullOrEmpty
            $new.SupersedenceStatus | Should -Be 'Partial'
        }

        It 'normalizes only case, whitespace and HTML entities for exact title identity' {
            $old.Title = '2026-09 Update for A&B x64 (KB1234567)'
            $metadataById[$newGuid].Status = 'Partial'
            $metadataById[$newGuid].Supersedes = @([PSCustomObject]@{
                Guid = $null; Title = "  2026-09`tUPDATE for A&amp;B x64 (KB1234567) "
            })
            $results = @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence)
            $results.Guid | Should -Not -Contain $oldGuid
            $requestOrder.Count | Should -Be 2
        }

        It 'does not identify a candidate from <Case>' -ForEach @(
            @{ Case = 'a KB alone'; Title = 'KB1234567' }
            @{ Case = 'an abbreviated title'; Title = '2026-09 Cumulative Update (KB1234567)' }
            @{ Case = 'a different architecture'; Title = '2026-09 Cumulative Update for Example Product x86 (KB1234567)' }
            @{ Case = 'a different build'; Title = '2026-09 Cumulative Update for Example Product x64 (KB1234567) (2.0)' }
            @{ Case = 'a hyphenated alias'; Title = '2026-09 Cumulative Update for Example-Product x64 (KB1234567)' }
            @{ Case = 'a wildcard'; Title = '2026-09 Cumulative Update*' }
            @{ Case = 'an empty title'; Title = '' }
        ) {
            $old.Title = '2026-09 Cumulative Update for Example Product x64 (KB1234567)'
            $metadataById[$newGuid].Status = 'Partial'
            $metadataById[$newGuid].Supersedes = @([PSCustomObject]@{ Guid = $null; Title = $Title })
            @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence).Count | Should -Be 3
            $requestOrder.Count | Should -Be 3
        }

        It 'does not override an external Catalog GUID with a matching local title' {
            $old.Title = 'Unique local update'
            $metadataById[$newGuid].Supersedes = @([PSCustomObject]@{ Guid = $externalGuid; Title = $old.Title })
            @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence).Count | Should -Be 3
            $requestOrder.Count | Should -Be 3
        }

        It 'does not reuse the looser search version normalization for relationship identity' {
            $old.Title = '2026-09 Update for Product version 24H2 x64 (KB1234567)'
            $metadataById[$newGuid].Status = 'Partial'
            $metadataById[$newGuid].Supersedes = @([PSCustomObject]@{
                Guid = $null; Title = '2026-09 Update for Product-24H2 x64 (KB1234567)'
            })
            @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence).Count | Should -Be 3
            $requestOrder.Count | Should -Be 3
        }

        It 'resolves exact title-only reverse relationships within the candidate set' {
            $new.Title = 'Unique replacement title'
            $metadataById[$oldGuid].Status = 'Partial'
            $metadataById[$oldGuid].SupersededBy = @([PSCustomObject]@{ Guid = $null; Title = $new.Title })
            $results = @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence)
            $results.Guid | Should -Not -Contain $oldGuid
        }

        It 'does not let a later duplicate row undo a title ambiguity' {
            $duplicate = New-IncrementalCandidate $oldGuid '2026-09-01'
            $metadataById[$newGuid].Status = 'Partial'
            $metadataById[$newGuid].Supersedes = @([PSCustomObject]@{ Guid = $null; Title = $old.Title })
            @(Select-NonSupersededUpdate -Updates @($old, $independent, $new, $duplicate) -ResolveSupersedence).Count | Should -Be 4
            $requestOrder.Count | Should -Be 3
        }

        It 'accepts duplicate rows with the same GUID as a unique title identity' {
            $old.Title = 'Unique replaced update'
            $duplicate = New-IncrementalCandidate $oldGuid '2026-09-01'
            $duplicate.Title = $old.Title
            $metadataById[$newGuid].Status = 'Partial'
            $metadataById[$newGuid].Supersedes = @([PSCustomObject]@{ Guid = $null; Title = $old.Title })
            $results = @(Select-NonSupersededUpdate -Updates @($old, $new, $duplicate) -ResolveSupersedence)
            $results.Count | Should -Be 1
            $results[0].Guid | Should -Be $newGuid
            $requestOrder.Count | Should -Be 1
        }

        It 'reuses supplied successful metadata even when resolving missing metadata is enabled' {
            foreach ($candidate in $candidates) { $candidate.SupersedenceStatus = 'Retrieved' }
            $old.Title = 'Unique replaced update'
            $new.SupersedenceStatus = 'Partial'
            $new.Supersedes = @([PSCustomObject]@{ Guid = $null; Title = $old.Title })
            $results = @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence)
            $results.Guid | Should -Be @($newGuid, $independentGuid)
            Should -Invoke Get-UpdateSupersedenceBatch -Times 0 -Exactly
        }

        It 'loads metadata only for candidates whose supplied metadata is missing' {
            $new.SupersedenceStatus = 'Retrieved'
            $old.SupersedenceStatus = 'Retrieved'
            @(Select-NonSupersededUpdate -Updates $candidates -ResolveSupersedence).Count | Should -Be 3
            Should -Invoke Get-UpdateSupersedenceBatch -Times 1 -Exactly -ParameterFilter { $Guids[0] -eq $independentGuid }
        }

        It 'retries supplied failed metadata rather than treating failure as a successful snapshot' {
            $new.SupersedenceStatus = 'Failed'
            $new.SupersedenceError = 'Previous timeout'
            @(Select-NonSupersededUpdate -Updates @($new) -ResolveSupersedence).Count | Should -Be 1
            $new.SupersedenceStatus | Should -Be 'Retrieved'
            Should -Invoke Get-UpdateSupersedenceBatch -Times 1 -Exactly
        }
    }
}
