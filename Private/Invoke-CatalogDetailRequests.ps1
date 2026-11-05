function Invoke-CatalogDetailRequests {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[]] $Guids
    )

    # Async HTTP works on both Windows PowerShell 5.1 and PowerShell 7, without
    # starting jobs or importing the module into additional PowerShell processes.
    $responses = @{}
    $handler = $null
    $client = $null
    try {
        Set-TempSecurityProtocol
        Add-Type -AssemblyName System.Net.Http
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(20)
        for ($offset = 0; $offset -lt $Guids.Count; $offset += 4) {
            $pending = @{}
            $last = [Math]::Min($offset + 4, $Guids.Count)
            for ($index = $offset; $index -lt $last; $index++) {
                $guid = $Guids[$index]
                $uri = "https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=$([uri]::EscapeDataString($guid))"
                $pending[$guid] = $client.GetStringAsync($uri)
            }
            foreach ($guid in $pending.Keys) {
                try {
                    $responses[$guid] = [PSCustomObject]@{
                        Content = $pending[$guid].GetAwaiter().GetResult()
                        Error = $null
                    }
                } catch {
                    $responses[$guid] = [PSCustomObject]@{ Content = $null; Error = $_.Exception.Message }
                }
            }
        }
    } catch {
        foreach ($guid in $Guids) {
            if (-not $responses.ContainsKey($guid)) {
                $responses[$guid] = [PSCustomObject]@{ Content = $null; Error = $_.Exception.Message }
            }
        }
    } finally {
        if ($null -ne $client) { $client.Dispose() }
        if ($null -ne $handler) { $handler.Dispose() }
        Set-TempSecurityProtocol -ResetToDefault
    }
    return $responses
}
