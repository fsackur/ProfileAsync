function Write-Log
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [Alias('Msg', 'MessageData')]
        [AllowEmptyString()]
        [AllowNull()]
        [object]$Message,

        [string]$Stream,

        [Parameter(DontShow)]
        [string[]]$Tags
    )

    $Messages = if ($MyInvocation.ExpectingInput) {$input} else {@($Message)}

    if (-not $Stream)
    {
        $Stream = ($MyInvocation.InvocationName -replace "^Write-" -replace "rmation$")
    }
    $Stream = $Stream.ToUpper()

    $LogPath = $env:PWSH_PROFILE_ASYNC_LOG_PATH
    if ($LogPath)
    {
        $Messages | ForEach-Object {
            $Timestamp = [datetime]::Now.ToString('o').PadRight(33, ' ')
            $Timestamp, "$PID".PadRight(7, ' '), $Stream.PadRight(7, ' '), $_ -join " | " >> $LogPath
        }
    }

    if ($Stream -ne "LOG")
    {
        $Printer = if ($PSStyle)
        {
            $Start = $PSStyle.Formatting.PSObject.Properties[$Stream].Value
            $End = "`e[0m"
            {Write-Host "$Start$Stream`: $_$End"}
        }
        else
        {
            $Fg = $Host.PrivateData.PSObject.Properties["$Stream`ForegroundColor"].Value
            $Bg = $Host.PrivateData.PSObject.Properties["$Stream`BackgroundColor"].Value
            {Write-Host "$Stream`: $_" -ForegroundColor $Fg -BackgroundColor $Bg}
        }

        $Messages | ForEach-Object $Printer
    }
}
