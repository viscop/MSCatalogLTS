BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../MSCatalogLTS.psd1') -Force
}

Describe 'Save-MSCatalogUpdate pipeline downloads' {
    InModuleScope MSCatalogLTS {
        BeforeEach {
            $windows = [MSCatalogUpdate]::new()
            $windows.Guid = '4fa68173-6861-438a-abb3-a01d9da15038'
            $windows.Title = '2026-10 Cumulative Update for Microsoft server operating system version 24H2 (KB5134137)'
            $net = [MSCatalogUpdate]::new()
            $net.Guid = '3f8cc115-713d-4622-8ad4-50b3419b8356'
            $net.Title = '2026-10 Cumulative Update for .NET Framework 3.5 and 4.8.1 (KB5127690)'
            $destination = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            $linksByGuid = @{}
            $linksByGuid[$windows.Guid] = @(
                [PSCustomObject]@{ URL = 'https://example.invalid/windows-kb5134137-x64_hash.msu' }
                [PSCustomObject]@{ URL = 'https://example.invalid/windows-kb5134137-prerequisite-x64_hash.msu' }
            )
            $linksByGuid[$net.Guid] = @(
                [PSCustomObject]@{ URL = 'https://example.invalid/dotnet-kb5127690-x64_hash.msu' }
            )
            Mock Set-TempSecurityProtocol {}
            Mock Write-Warning {}
            Mock Get-UpdateLinks { $linksByGuid[$Guid] }
            Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value 'Mock download' }
        }

        It 'downloads all files for both Windows and .NET updates from the pipeline' {
            @($windows, $net) | Save-MSCatalogUpdate -Destination $destination -DownloadAll | Out-Null
            Should -Invoke Get-UpdateLinks -Times 1 -Exactly -ParameterFilter { $Guid -eq $windows.Guid }
            Should -Invoke Get-UpdateLinks -Times 1 -Exactly -ParameterFilter { $Guid -eq $net.Guid }
            Should -Invoke Invoke-WebRequest -Times 3 -Exactly
            (Join-Path $destination 'windows-kb5134137-x64.msu') | Should -Exist
            (Join-Path $destination 'windows-kb5134137-prerequisite-x64.msu') | Should -Exist
            (Join-Path $destination 'dotnet-kb5127690-x64.msu') | Should -Exist
        }

        It 'downloads the first file of each pipeline update without DownloadAll' {
            @($windows, $net) | Save-MSCatalogUpdate -Destination $destination | Out-Null
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly
            (Join-Path $destination 'windows-kb5134137-x64.msu') | Should -Exist
            (Join-Path $destination 'dotnet-kb5127690-x64.msu') | Should -Exist
            (Join-Path $destination 'windows-kb5134137-prerequisite-x64.msu') | Should -Not -Exist
        }

        It 'preserves downloading a single explicitly supplied update' {
            Save-MSCatalogUpdate -Update $windows -Destination $destination -DownloadAll | Out-Null
            Should -Invoke Get-UpdateLinks -Times 1 -Exactly
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        }

        It 'preserves downloading multiple explicitly supplied GUIDs' {
            Save-MSCatalogUpdate -Guid @($windows.Guid, $net.Guid) -Destination $destination -DownloadAll | Out-Null
            Should -Invoke Get-UpdateLinks -Times 2 -Exactly
            Should -Invoke Invoke-WebRequest -Times 3 -Exactly
        }

        It 'looks up each unique pipeline GUID once' {
            @($windows, $net, $windows) | Save-MSCatalogUpdate -Destination $destination -DownloadAll | Out-Null
            Should -Invoke Get-UpdateLinks -Times 2 -Exactly
            Should -Invoke Invoke-WebRequest -Times 3 -Exactly
        }

        It 'continues with the next update when one update has no download links' {
            $linksByGuid[$windows.Guid] = @()
            @($windows, $net) | Save-MSCatalogUpdate -Destination $destination -DownloadAll | Out-Null
            Should -Invoke Get-UpdateLinks -Times 2 -Exactly
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
            (Join-Path $destination 'dotnet-kb5127690-x64.msu') | Should -Exist
        }
    }
}
