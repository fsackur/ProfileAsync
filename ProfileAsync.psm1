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

function Import-ProfileAsync
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory, Position = 0)]
        [scriptblock]$ScriptBlock
    )

    if ($env:PWSH_DEFERRED_LOAD -imatch '^(0|false|no)$')
    {
        . $ScriptBlock
        return
    }


    "=== Starting deferred load ===" | Write-ProfileAsyncLog


    # https://seeminglyscience.github.io/powershell/2017/09/30/invocation-operators-states-and-scopes
    $GlobalState = [psmoduleinfo]::new($false)
    $GlobalState.SessionState = $ExecutionContext.SessionState

    # A runspace to run our code asynchronously; pass in $Host to support Write-Host
    $Runspace = [runspacefactory]::CreateRunspace($Host)
    $Powershell = [powershell]::Create($Runspace)
    $Runspace.Open()
    $Runspace.SessionStateProxy.PSVariable.Set('GlobalState', $GlobalState)

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

    Remove-Variable -ErrorAction Ignore (
        'Private',
        'GlobalContext',
        'ContextField',
        'ContextCACProperty',
        'ContextNACProperty',
        'CAC',
        'NAC',
        'RSEngineField',
        'RSEngine',
        'EngineContextField',
        'RSContext',
        'Runspace'
    )

    $Wrapper = {
        # Without a sleep, you get issues:
        #   - occasional crashes
        #   - prompt not rendered
        #   - no highlighting
        # Assumption: this is related to PSReadLine.
        # 20ms seems to be enough on my machine, but let's be generous - this is non-blocking
        Start-Sleep -Milliseconds 200

        . $GlobalState {. $ScriptBlock; Remove-Variable ScriptBlock}
    }

    $AsyncResult = $Powershell.AddScript($Wrapper.ToString()).BeginInvoke()

    $SourceIdentifier = "__ProfileAsyncCleanup__" + [guid]::NewGuid()
    $null = Register-ObjectEvent -MessageData $AsyncResult -InputObject $Powershell -EventName InvocationStateChanged -SourceIdentifier $SourceIdentifier -Action {
        $AsyncResult = $Event.MessageData
        $Powershell = $Event.Sender
        $SourceIdentifier = $EventSubscriber.SourceIdentifier
        if ($Powershell.InvocationStateInfo.State -ge 2)
        {
            if ($Powershell.Streams.Error)
            {
                $Powershell.Streams.Error | Out-String | Write-Host -ForegroundColor Red
            }

            try
            {
                # Profiles swallow output; it would be weird to output anything here
                $null = $Powershell.EndInvoke($AsyncResult)
            }
            catch
            {
                $_ | Out-String | Write-Host -ForegroundColor Red
            }

            $h1 = Get-History -Id 1 -ErrorAction Ignore
            if ($h1.CommandLine -match '\bcode\b.*shellIntegration\.ps1')
            {
                $Msg = 'VS Code Shell Integration is enabled. This may cause issues with deferred load. To disable it, set "terminal.integrated.shellIntegration.enabled" to "false" in your settings.'
                Write-Host $Msg -ForegroundColor Yellow
            }

            $PowerShell.Dispose()
            $Runspace.Dispose()
            Unregister-Event $SourceIdentifier
            Get-Job $SourceIdentifier | Remove-Job
        }
    }

    Remove-Variable Wrapper, Powershell, AsyncResult, GlobalState

    "synchronous load complete" | Write-ProfileAsyncLog
}
