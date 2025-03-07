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

        [switch]$PWSH_PROFILE_ASYNC_DISABLE
    )

    if ($PWSH_PROFILE_ASYNC_DISABLE -or $env:PWSH_PROFILE_ASYNC_DISABLE -imatch '^(1|true|yes)$')
    {
        . $ScriptBlock
        return
    }

    $Silent = (Get-Command tty -CommandType Application -ErrorAction Ignore) -and (tty) -match "not a tty"
    if ($Silent)
    {
        $VerbosePreference = 'SilentlyContinue'
    }


    $Powershell = New-BoundPowerShell

    # https://seeminglyscience.github.io/powershell/2017/09/30/invocation-operators-states-and-scopes
    $GlobalState = [psmoduleinfo]::new($false)
    $GlobalState.SessionState = $ExecutionContext.SessionState

    $Powershell.Runspace.SessionStateProxy.PSVariable.Set('GlobalState', $GlobalState)
    $Powershell.Runspace.SessionStateProxy.PSVariable.Set('ScriptBlock', $ScriptBlock)
    $Powershell.Runspace.SessionStateProxy.PSVariable.Set('Delay', $Delay)


    "Starting asynchronous execution" | Write-Verbose

    $Wrapper = {
        [System.Diagnostics.DebuggerHidden()]
        param()

        # Runspace init is unsafe. Stack traces point to PSReadLine; not sure
        Start-Sleep -Milliseconds $Delay

        . $GlobalState {. $args[0]} $ScriptBlock
    }
    $AsyncResult = $Powershell.AddScript($Wrapper).BeginInvoke()


    $SourceIdentifier = "__ProfileAsyncCleanup__" + [guid]::NewGuid()
    $HandlerParams = @{
        MessageData = $AsyncResult, $Silent, $VerbosePreference
        InputObject = $Powershell
        EventName = "InvocationStateChanged"
        SourceIdentifier = $SourceIdentifier
    }
    $null = Register-ObjectEvent @HandlerParams -Action {
        $AsyncResult, $Silent, $VerbosePreference = $Event.MessageData
        $Powershell = $Event.Sender
        $SourceIdentifier = $EventSubscriber.SourceIdentifier

        if ($Powershell.Streams.Error)
        {
            $Powershell.Streams.Error | Out-String | Write-Host -ForegroundColor Red
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
                $_ | Out-String | Write-Host -ForegroundColor Red
            }

            $Formats = $Powershell.Runspace.InitialSessionState.Formats
            $FormatFiles = $Formats.FileName | Where-Object {$_ -and (Test-Path $_)}
            if ($FormatFiles)
            {
                Update-FormatData -PrependPath $FormatFiles
            }

            $Types = $Powershell.Runspace.InitialSessionState.Types
            $TypeFiles = $Types.FileName | Where-Object {$_ -and (Test-Path $_)}
            if ($TypeFiles)
            {
                Update-TypeData -PrependPath $TypeFiles
            }

            Unregister-Event $SourceIdentifier
            Get-Job $SourceIdentifier | Remove-Job

            if ($VerbosePreference -eq 'Continue' -and -not $Silent)
            {
                $State = [string]$Powershell.InvocationStateInfo.State
                $Msg = "VERBOSE: Asynchronous execution $($State.ToLower())"
                $Msg | Write-Host -ForegroundColor Yellow
            }
        }
    }
}
