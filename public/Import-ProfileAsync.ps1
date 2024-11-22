function Import-ProfileAsync
{
    <#
        .SYNOPSIS
        Load your powershell profile asynchronously, so you can get to the prompt faster.

        .LINK
        https://github.com/fsackur/ProfileAsync

        .DESCRIPTION
        This command executes a scriptblock asynchronously using the current session's
        execution context. In simple terms, this runs code asynchronously in the caller's
        scope.

        This command is not the best tool if you do not need that specific behaviour.

        When used in a powershell profile, it effectively runs in the global scope. Things in the
        scriptblock will be available in the session when the scriptblock completes.

        This includes modules, functions, aliases, variables and argument completers.

        Warning:

        This command uses reflection hacks. PowerShell is designed to avoid async bugs in areas
        that we jam async code into. Your session may crash. Errors may be misleading. Do not use
        in server scripts.

        The risk is minimised in the designed use case:

        - use only in your powershell profile
        - only call this command once
        - call this command at the bottom
        - increase delay if you get errors
        - don't do other async stuff before the async code completes

        .PARAMETER ScriptBlock
        The code to be executed asynchronously.

        .PARAMETER Delay
        Interval, in milliseconds, to wait within the asynchronous runspace before executing the
        scriptblock.

        This is necessary because this command subverts normal runspace initialisation. Without
        this delay, command availability may be unreliable when the command is run at startup.

        This delay can be set to 0 when the command is run in a fully-initialised powershell
        session.

        10ms may be sufficient on a fast machine. 100-200ms should cover most recent machines.

        .PARAMETER LogPath
        File for logging. If not supplied, no log is written.

        .PARAMETER PWSH_PROFILE_ASYNC_DISABLE
        Disables the async and scope features. Also accepted as an env var; parameter takes
        precedence.

        Use this to recover a crashing profile. Code will not be run in the global scope.
    #>

    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory, Position = 0)]
        [scriptblock]$ScriptBlock,

        [ValidateRange(0, 5000)]
        [PSDefaultValue(Help = "500ms")]
        [int]$Delay = 500,

        [string]$LogPath,

        [switch]$PWSH_PROFILE_ASYNC_DISABLE
    )

    if ($PWSH_PROFILE_ASYNC_DISABLE -or $env:PWSH_PROFILE_ASYNC_DISABLE -imatch '^(1|true|yes)$')
    {
        . $ScriptBlock
        return
    }

    if ($LogPath)
    {
        $LogDir = $LogPath | Split-Path
        if (-not (Test-Path $LogDir -PathType Container))
        {
            $null = New-Item -ItemType Directory $LogDir -Force
            if (!$?)
            {
                Write-Warning "$($MyCommand.InvocationName): Could not create $LogDir. Logging is disabled."
                Remove-Variable LogPath
            }
        }
    }
    $env:PWSH_PROFILE_ASYNC_LOG_PATH = $LogPath
    "Warning", "Verbose", "Debug", "Information" | ForEach-Object {Set-Alias "Write-$_" Write-Log}


    $PowerShell = New-BoundPowerShell

    # https://seeminglyscience.github.io/powershell/2017/09/30/invocation-operators-states-and-scopes
    $GlobalState = [psmoduleinfo]::new($true)
    $GlobalState.SessionState = $ExecutionContext.SessionState

    $PowerShell.Runspace.SessionStateProxy.PSVariable.Set('GlobalState', $GlobalState)
    $PowerShell.Runspace.SessionStateProxy.PSVariable.Set('ScriptBlock', $ScriptBlock)
    $PowerShell.Runspace.SessionStateProxy.PSVariable.Set('Delay', $Delay)
    $PowerShell.Runspace.SessionStateProxy.PSVariable.Set('LogPath', $LogPath)


    "Starting asynchronous execution" | Write-Verbose
    $Wrapper = {
        [System.Diagnostics.DebuggerHidden()]
        param()

        # Runspace init is unsafe. Stack traces point to PSReadLine; not sure.
        # Comment in PSRL source says:
        #     This is a workaround to ensure the command analysis cache
        #     has been created before we enter into ReadLine.
        Start-Sleep -Milliseconds $Delay

        Write-Log "In ProfileAsync wrapper"

        # Execute in the scope of GlobalState
        . $GlobalState {
            $ScriptBlock = $args[0]
            $LogBlock = $args[1]

            Set-Content Function:\Global:Write-Log $LogBlock
            "Warning", "Verbose", "Debug", "Information" | ForEach-Object {
                Set-Alias -Scope Global "Write-$_" Write-Log
            }

            . $ScriptBlock

            "Warning", "Verbose", "Debug", "Information" | ForEach-Object {
                Remove-Alias -Scope Global "Write-$_"
            }
            Remove-Item Function:\Global:Write-Log

        } $ScriptBlock (Get-Command Write-Log).ScriptBlock
    }


    $Provider = $PowerShell.Runspace.SessionStateProxy.InvokeProvider
    $LogBlock = (Get-Command Write-Log).Definition
    $null = $Provider.Item.Set("function:Global:Write-Log", [scriptblock]::Create($LogBlock))

    $AsyncResult = $Powershell.AddScript($Wrapper).BeginInvoke()


    $SourceIdentifier = "__ProfileAsyncCleanup__" + [guid]::NewGuid()
    $HandlerParams = @{
        MessageData = $AsyncResult
        InputObject = $Powershell
        EventName = "InvocationStateChanged"
        SourceIdentifier = $SourceIdentifier
    }
    $null = Register-ObjectEvent @HandlerParams -Action {
        $AsyncResult = $Event.MessageData
        $Powershell = $Event.Sender
        $SourceIdentifier = $EventSubscriber.SourceIdentifier

        if ($Powershell.Streams.Error)
        {
            $Powershell.Streams.Error | Out-String | Write-Log -Stream Error
            $Powershell.Streams.Error.Clear()
        }

        if ($Powershell.InvocationStateInfo.State -ge 2)
        {
            try
            {
                $Powershell.EndInvoke($AsyncResult)
            }
            catch
            {
                $_ | Out-String | Write-Log -Stream Error
            }

            Unregister-Event $SourceIdentifier
            Get-Job $SourceIdentifier | Remove-Job

            "Asynchronous execution complete", "State: $($Powershell.InvocationStateInfo.State)" | Write-Log
        }
    }

    # Remove-Alias Write-Verbose -Scope Global
}
