BeforeAll {
    $TestRoot = $PSScriptRoot
    $ModuleBase = $PSScriptRoot | Split-Path
    $PesterBase = (Get-Module Pester).ModuleBase
    $Containers = @{}

    function Test
    {
        param
        (
            [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
            [string]$TestProfile
        )

        begin
        {
            $Image = "mcr.microsoft.com/powershell"
            $Listing = docker image ls --format json $Image | ConvertFrom-Json
            if (-not $Listing) {docker pull $Image}

            $FactScript = {
                "waiting async marker" | Write-Verbose
                while (-not (Test-Path $Marker)) {Start-Sleep -Milliseconds 100}
                "marker found" | Write-Verbose
                Get-Module | % Name
            }
        }

        process
        {
            $RunArgs = @(
                "--detach",
                "--label", "test",
                "--name", $TestProfile,
                "-v", "$TestRoot/$TestProfile`:/opt/microsoft/powershell/7/profile.ps1",
                "-v", "$ModuleBase/:/opt/microsoft/powershell/7/Modules/ProfileAsync/",
                "-v", "$PesterBase/:/opt/microsoft/powershell/7/Modules/Pester/",
                $Image,
                "pwsh", "-c", "$FactScript"
            )

            $Id = docker run @RunArgs
            if (-not $?) {throw}
            $Containers[$TestProfile] = $Id
        }
    }

    function Wait-Container
    {
        param
        (
            [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
            [string]$Id
        )

        process
        {
            while ($true)
            {
                $Container = docker inspect $Id | ConvertFrom-Json
                if (-not $Container.State.Running) {break}
                Start-Sleep -Milliseconds 500
            }
            $Id
        }
    }

    function Receive-Container
    {
        param
        (
            [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
            [string]$Id
        )

        process
        {
            docker logs $Id
            docker rm -f $Id | Out-Null
        }
    }
}

Describe "Import-ProfileAsync" {

    BeforeAll {
        $TestProfile = "profile1.ps1"
        "Testing $TestProfile" | Write-Verbose
        Test $TestProfile
    }

    BeforeEach {
        $Output = $Containers[$TestProfile] | Wait-Container | Receive-Container
        $StdOut = $Output -notmatch "^\e\[33;1mVERBOSE:"
    }

    It "Imports Pester" {
        "Pester" | Should -BeIn $StdOut
    }
}
