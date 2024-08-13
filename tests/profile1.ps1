# $VerbosePreference = 'Continue'

"starting sync" | Write-Verbose
Import-Module ProfileAsync -ea Stop -Verbose:$false
$Marker = Join-Path ([IO.Path]::GetTempPath()) "test.marker"
Import-ProfileAsync -Delay 1000 {
    "starting async" | Write-Verbose
    Import-Module Pester -Verbose:$false
    "" > $Marker
    "async return" | Write-Verbose
}
"sync return" | Write-Verbose
