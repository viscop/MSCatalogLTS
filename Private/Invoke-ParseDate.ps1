function Invoke-ParseDate {
    param (
        [String] $DateString
    )

    $Array = $DateString.Split("/")
    # Catalog dates have no time component. Get-Date otherwise inherits the
    # current clock time, making date-boundary filtering depend on query time.
    (Get-Date -Year $Array[2] -Month $Array[0] -Day $Array[1]).Date
}
