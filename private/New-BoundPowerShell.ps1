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
