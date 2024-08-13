using namespace System.Management.Automation
using namespace System.Management.Automation.Language
using namespace Microsoft.PowerShell.Commands

<#
    .DESCRIPTION
    Assumes the following layout:

    ├── LICENSE
    ├── <this file>
    ├── Module.psd1
    ├── Classes
    │   └── *.ps1
    ├── Private
    │   └── *.ps1
    ├── Public
    │   └── *.ps1
    └── Tests
        └── *.Tests.ps1
#>

[CmdletBinding()]
param
(
    [version]$NewVersion,

    [string]$PSGalleryApiKey = $env:PSGalleryApiKey,

    [string]$ModuleName = $MyInvocation.MyCommand.Name -replace '\.build\.ps1$',

    [string]$ManifestPath = "$ModuleName.psd1",

    [string[]]$Include = ('*.ps1xml', '*.psrc', 'README*', 'LICENSE*'),

    [string[]]$PSScriptFolders = ('Classes', 'Private', 'Public'),

    [string]$OutputFolder = 'Build'
)

$RequiredModules = [ModuleSpecification[]](
    @{ModuleName = 'Pester'; ModuleVersion = '5.6.1'},
    @{ModuleName = 'PSScriptAnalyzer'; ModuleVersion = '1.22.0'},
    @{ModuleName = 'InvokeBuild'; ModuleVersion = '5.11.3'},
    @{ModuleName = 'Microsoft.PowerShell.PSResourceGet'; ModuleVersion = '1.0.5'}
)

task InstallBuildDependencies {
    $RequiredModules |
      Where-Object {-not (Import-Module $_ -PassThru -ErrorAction Ignore)} |
      Install-Module -Force
}

task ParseManifest {
    $Script:Psd1SourcePath = Join-Path $BuildRoot "$ModuleName.psd1"

    $ManifestAst = [Parser]::ParseFile($Psd1SourcePath, [ref]$null, [ref]$null)
    $Script:ManifestContent = $ManifestAst.Extent.Text

    $Expression = $ManifestAst.EndBlock.Statements[0].PipelineElements[0].Expression
    $KvpAsts = $Expression.KeyValuePairs | Group-Object {$_.Item1.Value} -AsHashTable

    $Script:RootModule = $KvpAsts['RootModule'].Item2.PipelineElements[0].Expression.Value
    $Script:ManifestVersionAst = $KvpAsts['ModuleVersion'].Item2.PipelineElements[0].Expression
    $Script:ManifestVersion = [version]$ManifestVersionAst.Value

    assert($RootModule)
    assert($ManifestVersion)
}

task AppveyorMetadata ParseManifest, {
    $BuildVersion = $env:APPVEYOR_BUILD_VERSION
    assert ($BuildVersion)
    $Script:IsAppveyorTagBuild = $env:APPVEYOR_REPO_TAG -eq 'true'
    if ($IsAppveyorTagBuild)
    {
        Write-Build -Color Green "Building tag: $env:APPVEYOR_REPO_TAG_NAME"
        [version]$Version = $env:APPVEYOR_REPO_TAG_NAME -replace '^\D*' -replace '[^\.\d].*$'
        assert ($Version -eq $ManifestVersion)
        [int]$Build = $env:APPVEYOR_BUILD_NUMBER
        $BuildVersion = $Version, ++$Build -join '-'
        Update-AppveyorBuild -Version $BuildVersion
    }
}

task AppveyorAbortWhenHeadAlreadyTagged AppveyorMetadata, {
    if (-not $IsAppveyorTagBuild)
    {
        $Refs = (git for-each-ref --points-at HEAD) -replace '.* '
        $TagRefs = @($Refs) -match '^refs/tags/'
        if ($TagRefs)
        {
            "Commit $(git rev-parse HEAD) is already tagged in $TagRefs" | Write-Build -Color Yellow
            appveyor exit
        }
    }
}

task Clean {
    remove $OutputFolder
}

task AssertVersion ParseManifest, {
    if ($NewVersion)
    {
        assert ($NewVersion -ge $ManifestVersion)
    }
}

task Version ParseManifest, AssertVersion, {
    if ($NewVersion)
    {
        $Script:Version = $NewVersion
        $Script:Tag = "v$NewVersion"
    }
    else
    {
        $Script:Version = $ManifestVersion
        $Script:Tag = "v$NewVersion"
    }

    if ($NewVersion -gt $ManifestVersion)
    {
        $ManifestContent = (
            $ManifestContent.Substring(0, $ManifestVersionAst.Extent.StartOffset),
            $ManifestContent.Substring($ManifestVersionAst.Extent.EndOffset)
        ) -join "'$NewVersion'"
        $ManifestContent > $Psd1SourcePath
    }
}

task Tag Version, {
    if (git diff -- $Psd1SourcePath)
    {
        git add $Psd1SourcePath
        assert($?)
        git commit -m $Tag
        assert($?)
    }

    $Output = git tag $Tag --no-sign *>&1
    if (-not $?)
    {
        if ($Output -match 'already exists')
        {
            # If tag points to head, we don't care
            $Refs = (git show-ref $Tag --head) -replace ' .*'
            assert($Refs.Count -ge 2)
            assert($Refs[0] -eq $Refs[1])
        }
        else
        {
            $Output = ($Output -join "`n").Trim()
            throw $Output
        }
    }
}

task PushTag Tag, {
    git push --tags
    assert($?)
    git push
    assert($?)
}

task BuildDir Version, {
    $Script:BuildDir = [IO.Path]::Combine($PSScriptRoot, $OutputFolder, $ModuleName, $Version)
    New-Item $BuildDir -ItemType Directory -Force | Out-Null
}

task IncludedFiles BuildDir, {
    Copy-Item $Include $BuildDir
}

task BuildPowershell Clean, Version, BuildDir, IncludedFiles, {
    $Requirements = @()
    $Usings = @()

    # case-insensitive matching
    $Folders = Get-ChildItem -Directory | Where-Object {$_.Name -in $PSScriptFolders}

    $Content = $Folders | ForEach-Object {
        $Label = ($_ | Resolve-Path -Relative) -replace '^\.[\\/]'
        $Files = $_ | Get-ChildItem -File -Recurse -Filter *.ps1

        $FileContents = $Files | ForEach-Object {
            $FileAst = [Parser]::ParseFile($_, [ref]$null, [ref]$null)
            $_Content = $FileAst.Extent.Text

            $Requirements += $FileAst.ScriptRequirements.Extent.Text
            $Usings += $FileAst.UsingStatements.Extent.Text

            # find furthest offset from start
            [int]$SnipOffset = (
                $FileAst.ScriptRequirements.Extent.EndOffset,
                $FileAst.UsingStatements.Extent.EndOffset,
                $FileAst.ParamBlock.Extent.EndOffset  # will only exist to hold PSSA suppressions
            ) |
                Sort-Object |
                Select-Object -Last 1

            $_Content.Substring($SnipOffset).Trim()
        }

        "#region $Label", ($FileContents -join "`n`n"), "#endregion $Label" | Write-Output
    }

    $Requirements = $Requirements | Write-Output | ForEach-Object Trim | Sort-Object -Unique
    $Usings = $Usings | Write-Output | ForEach-Object Trim | Sort-Object -Unique
    $Psm1Content = $Requirements, $Usings, "", ($Content -join "`n`n") | Write-Output

    Copy-Item $Psd1SourcePath $BuildDir
    $Psm1Content > (Join-Path $BuildDir $RootModule)
}

task Build BuildPowershell

task PSSA {
    $Files = $Include, $PSScriptFolders |
        Write-Output |
        Where-Object {Test-Path $_} |
        Get-ChildItem -Recurse

    $Files |
        ForEach-Object {
            Invoke-ScriptAnalyzer -Path $_.FullName -Recurse -Settings .\.vscode\PSScriptAnalyzerSettings.psd1
        } |
        Tee-Object -Variable PSSAOutput

    if ($PSSAOutput | Where-Object Severity -ge ([int][Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity]::Warning))
    {
        throw "PSSA found code violations"
    }
}

task UnitTest {
    Invoke-Pester ./tests/
}

Task Test PSSA, UnitTest

task Package BuildDir, {
    if (-not (Get-PSResourceRepository $ModuleName -ErrorAction Ignore))
    {
        Register-PSResourceRepository $ModuleName -Uri $OutputFolder -Trusted
    }
    try
    {
        Write-Verbose "Packaging to $OutputFolder..."
        Publish-PSResource -Path $BuildDir -Repository $ModuleName
    }
    finally
    {
        Unregister-PSResourceRepository $ModuleName
    }
}

task Publish BuildDir, {
    if (-not $PSGalleryApiKey)
    {
        if (Get-Command rbw -ErrorAction Ignore)  # TODO: sort out SecretManagement wrapper
        {
            $PSGalleryApiKey = rbw get PSGallery
        }
        else
        {
            throw 'PSGalleryApiKey is required'
        }
    }

    Get-ChildItem -File $OutputFolder -Filter *.nupkg | Remove-Item  # PSResourceGet insists on recreating nupkg
    Publish-PSResource -Path $BuildDir -DestinationPath $OutputFolder -Repository PSGallery -ApiKey $PSGalleryApiKey
}

# Default task
task . Build
