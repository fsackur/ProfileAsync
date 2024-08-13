# ProfileAsync

Load your powershell profile asynchronously, so you can get to the prompt faster.

This module is not suitable for general-purpose asynchrony. The `ThreadJob` module is likely to be a better solution. See the warnings below.

## Usage

This module exports one command: `Import-ProfileAsync`.

Say you have a profile that looks like this (with example timings):

```powershell
# Detect VS Code terminal
# example code; will not work in every case!
$IsVSCode = $env:TERM_PROGRAM -eq 'vscode'  # 1ms
if (-not $IsVSCode) {Set-Location ~/git/}  # 2ms
Import-Module -Global SomeMonsterAzureModule  # 1000ms
```

If we consistently run commands from `SomeMonsterAzureModule` immediately when we get to the prompt, then there is no shortcut: we must wait while it loads. But, if that is not the most common case, then we can get to the prompt without waiting for the module to load:

```powershell
# Detect VS Code terminal
# example code; will not work in every case!
$IsVSCode = $env:TERM_PROGRAM -eq 'vscode'  # 1ms
if (-not $IsVSCode) {Set-Location ~/git/}  # 2ms

$AsyncScriptblock = {Import-Module -Global SomeMonsterAzureModule}  # 1ms

Import-ProfileAsync $AsyncScriptblock  # 10ms
# End of profile code; control is turned to the user
# Async scriptblock starts running
```

This change shaves a second off the time to the prompt. The downside is that it increases the time until the profile is fully loaded, due to asynchrony overhead. This is usually a good trade-off.

Here's a more realistic example:

```powershell
$OutputEncoding = [console]::InputEncoding = [console]::OutputEncoding = [Text.Encoding]::UTF8

if ($PSVersionTable.PSEdition -ne 'Core') { <# omitted for brevity #> }

if ($IsLinux -or $IsMacOS) { <# omitted for brevity #> }

function Test-VSCode { <# omitted for brevity #> }

$env:GITROOT = if (Test-Path /git) {"/git"} elseif (Test-Path ~/git) {"~/git"}
if ($env:GITROOT -and -not (Test-VSCode)) {Set-Location $env:GITROOT}

# Starship is a cross-platform prompt customisation tool - https://starship.rs
if (Get-Command starship -ErrorAction Ignore)
{
    $env:STARSHIP_CONFIG = $PSScriptRoot | Split-Path | Join-Path -ChildPath starship.toml
    starship init powershell --print-full-init | Out-String | Invoke-Expression
}

# a thousand lines of code moved out of main profile into dot-sourced scripts:
. /home/freddie/.local/share/chezmoi/PSHelpers/Console.ps1
. /home/freddie/.local/share/chezmoi/PSHelpers/git_helpers.ps1
. /home/freddie/.local/share/chezmoi/PSHelpers/pipe_operators.ps1
. /home/freddie/.local/share/chezmoi/PSHelpers/Utils.ps1
. /home/freddie/.local/share/chezmoi/PSHelpers/LinuxNetworking.ps1
. /home/freddie/.local/share/chezmoi/PSHelpers/ModuleLoad.ps1
```

This profile, including the dot-source script files, was taking nearly two seconds to load:

```powershell
Measure-Command {pwsh -c ""} | % TotalMilliseconds
1912.2259
```

200ms is from the powershell engine itself:

```powershell
Measure-Command {pwsh -NoProfile -c ""} | % TotalMilliseconds
199.9063
```

So, the profile adds 1700ms to the start-up time.

The slow part is the dot-sourced scripts, which import modules and register argument completers. By moving the slow code into `Import-ProfileAsync`, we can get that time right down:

```powershell
# ...other code...

$AsyncScriptblock = {
    . /home/freddie/.local/share/chezmoi/PSHelpers/Console.ps1
    . /home/freddie/.local/share/chezmoi/PSHelpers/git_helpers.ps1
    . /home/freddie/.local/share/chezmoi/PSHelpers/pipe_operators.ps1
    . /home/freddie/.local/share/chezmoi/PSHelpers/Utils.ps1
    . /home/freddie/.local/share/chezmoi/PSHelpers/LinuxNetworking.ps1
    . /home/freddie/.local/share/chezmoi/PSHelpers/ModuleLoad.ps1
}
Import-ProfileAsync $AsyncScriptblock
```

```powershell
Measure-Command {pwsh -c ""} | % TotalMilliseconds
525.1334
```

Since 200ms is powershell itself, we have got our profile load time down from ~1700ms to ~325ms - that's five times faster!

The downside is that, due to overhead, the profile takes longer to fully load.

You need to decide what profile code you want immediately, and what you are willing to wait an extra ~500ms for.

Put all the fast code at the top of your profile, and the slow code at the bottom. Wrap the slow code in a scriptblock and pass it to `Import-ProfileAsync`, in a single call, at the bottom of your profile. It doesn't have to be the last line, but avoid importing modules or defining functions or registering argument completers after the call to `Import-ProfileAsync`.

## Risk

This code works by forcing a second thread to run the initialisation code. Parts of the PowerShell engine are not thread-safe by design.

> We are hacking. Your session may crash. Errors may be misleading. Do not use in server scripts.

The risk is minimised in the designed use case:

- use only in your powershell profile
- only call this command once
- call this command at the bottom

## Troubleshooting

If you get unexpected errors, particularly intermittent errors, then increase the value of the Delay parameter. (The default value can be checked with `Get-Help Import-ProfileAsync -Parameter Delay`). This gives the engine more time to complete initialisation, which may be needed on slow machines or when security software is scanning code execution.

If your profile won't load at all, you can temporarily disable the async feature by setting the env var `PWSH_PROFILE_ASYNC_DISABLE` to `1`, or by passing the `-PWSH_PROFILE_ASYNC_DISABLE` switch. This should get you to the prompt, but your profile may not work as expected.

## Contributing

Bug reports are welcome! Submit a new issue [here](https://github.com/fsackur/ProfileAsync/issues/new).

Code contributions are welcome - please fork the repo and PR to the `main` branch from your fork.
