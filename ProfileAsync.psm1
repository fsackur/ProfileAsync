function Write-ProfileAsyncLog
{
    param
    (
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Message
    )

    if (-not $LogProfileAsync) {return}

    $LogPath = if ($env:XDG_CACHE_HOME)
    {
        Join-Path $env:XDG_CACHE_HOME PowerShellProfileAsync.log
    }
    else
    {
        Join-Path $HOME .cache/PowerShellProfileAsync.log
    }

    $Now = [datetime]::Now
    if (-not $Start)
    {
        $Script:Start = $Now
    }

    $Timestamp = $Now.ToString('o')
    (
        $Timestamp,
        ($Now - $Start).ToString('ss\.fff'),
        [System.Environment]::CurrentManagedThreadId.ToString().PadLeft(3, ' '),
        $Message
    ) -join '  ' | Out-File -FilePath $LogPath -Append
}

function New-BoundPowerShell
{
    <#
        .DESCRIPTION
        Reflection magic!

        Returns an instance of PowerShell with some internal runspace objects set to the objects
        from the current execution context. These objects are not supposed to be shared; race conditions
        may occur.
    #>

    [CmdletBinding()]
    param ()

    # A runspace to run our code asynchronously; pass in $Host to support Write-Host
    $Runspace = [runspacefactory]::CreateRunspace($Host)
    $Powershell = [powershell]::Create($Runspace)
    $Runspace.Open()

    # ArgumentCompleters are set on the ExecutionContext, not the SessionState
    # Note that $ExecutionContext is not an ExecutionContext, it's an EngineIntrinsics
    $Private = [System.Reflection.BindingFlags]'Instance, NonPublic'
    $ContextField = [System.Management.Automation.EngineIntrinsics].GetField('_context', $Private)
    $GlobalContext = $ContextField.GetValue($ExecutionContext)

    # Get the ArgumentCompleters. If null, initialise them.
    $ContextCACProperty = $GlobalContext.GetType().GetProperty('CustomArgumentCompleters', $Private)
    $ContextNACProperty = $GlobalContext.GetType().GetProperty('NativeArgumentCompleters', $Private)
    $CAC = $ContextCACProperty.GetValue($GlobalContext)
    $NAC = $ContextNACProperty.GetValue($GlobalContext)
    if ($null -eq $CAC)
    {
        $CAC = [System.Collections.Generic.Dictionary[string, scriptblock]]::new()
        $ContextCACProperty.SetValue($GlobalContext, $CAC)
    }
    if ($null -eq $NAC)
    {
        $NAC = [System.Collections.Generic.Dictionary[string, scriptblock]]::new()
        $ContextNACProperty.SetValue($GlobalContext, $NAC)
    }

    # Get the AutomationEngine and ExecutionContext of the runspace
    $RSEngineField = $Runspace.GetType().GetField('_engine', $Private)
    $RSEngine = $RSEngineField.GetValue($Runspace)
    $EngineContextField = $RSEngine.GetType().GetFields($Private) | Where-Object {$_.FieldType.Name -eq 'ExecutionContext'}
    $RSContext = $EngineContextField.GetValue($RSEngine)

    # Set the runspace to use the global ArgumentCompleters
    $ContextCACProperty.SetValue($RSContext, $CAC)
    $ContextNACProperty.SetValue($RSContext, $NAC)

    return $Powershell
}

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


    "=== Starting deferred load ===" | Write-ProfileAsyncLog

    $PowerShell = New-BoundPowerShell

    # https://seeminglyscience.github.io/powershell/2017/09/30/invocation-operators-states-and-scopes
    $GlobalState = [psmoduleinfo]::new($false)
    $GlobalState.SessionState = $ExecutionContext.SessionState

    $PowerShell.Runspace.SessionStateProxy.PSVariable.Set('GlobalState', $GlobalState)
    $PowerShell.Runspace.SessionStateProxy.PSVariable.Set('ScriptBlock', $ScriptBlock)
    $PowerShell.Runspace.SessionStateProxy.PSVariable.Set('Delay', $Delay)


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

            $PowerShell.Runspace.Dispose()
            $PowerShell.Dispose()
            Unregister-Event $SourceIdentifier
            Get-Job $SourceIdentifier | Remove-Job
        }
    }

    "synchronous load complete" | Write-ProfileAsyncLog
}
