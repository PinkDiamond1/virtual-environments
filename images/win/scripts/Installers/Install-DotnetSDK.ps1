################################################################################
##  File:  Install-DotnetSDK.ps1
##  Desc:  Install all released versions of the dotnet sdk and populate package
##         cache.  Should run after VS and Node
################################################################################

# ensure temp
New-Item -Path C:\Temp -Force -ItemType Directory

# Set environment variables
Set-SystemVariable -SystemVariable DOTNET_MULTILEVEL_LOOKUP -Value "0"

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor "Tls12"

function Get-SDKVersionsToInstall (
    $DotnetVersion
) {
    $releaseJson = "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/${DotnetVersion}/releases.json"
    $releasesJsonPath = Start-DownloadWithRetry -Url $releaseJson -Name "releases-${DotnetVersion}.json"
    $currentReleases = Get-Content -Path $releasesJsonPath | ConvertFrom-Json
    # filtering out the preview/rc releases
    $currentReleases = $currentReleases.'releases' | Where-Object { !$_.'release-version'.Contains('-') }

    $sdks = @()
    ForEach ($release in $currentReleases)
    {
        $sdks += $release.'sdk'
        $sdks += $release.'sdks'
    }

    $sdkVersions = @()
    $sdks | ForEach-Object { $sdkVersions += $_.'version' }
    $sortedSdkVersions = $sdkVersions | Sort-Object { [Version] $_ } -Unique

    # return the latest patch version for every feature version
    return $sortedSdkVersions | Where-Object {
        $nextItemIndex = [array]::IndexOf($sortedSdkVersions, $_) + 1

        if ($sortedSdkVersions.Length -eq $nextItemIndex) {
            $true
        } else {
            $_.substring(0, 5) -ne ($sortedSdkVersions[$nextItemIndex]).substring(0, 5)
        }
    }
}

function Invoke-Warmup (
    $SdkVersion
) {
    # warm up dotnet for first time experience
    $projectTypes = @('console', 'mstest', 'web', 'mvc', 'webapi')
    $projectTypes | ForEach-Object {
        $template = $_
        $projectPath = Join-Path -Path C:\temp -ChildPath $template
        New-Item -Path $projectPath -Force -ItemType Directory
        Push-Location -Path $projectPath
        & $env:ProgramFiles\dotnet\dotnet.exe new globaljson --sdk-version "$sdkVersion"
        & $env:ProgramFiles\dotnet\dotnet.exe new $template
        Pop-Location
        Remove-Item $projectPath -Force -Recurse
    }
}

function Fix-ImportPublishProfile (
    $SdkVersion
) {
    if ((Test-IsWin16) -or (Test-IsWin19)) {
        # Fix for issue https://github.com/dotnet/sdk/issues/1276.  This will be fixed in 3.1.
        $sdkTargetsName = "Microsoft.NET.Sdk.ImportPublishProfile.targets"
        $sdkTargetsUrl = "https://raw.githubusercontent.com/dotnet/sdk/82bc30c99f1325dfaa7ad450be96857a4fca2845/src/Tasks/Microsoft.NET.Build.Tasks/targets/${sdkTargetsName}"
        $sdkTargetsPath = "C:\Program Files\dotnet\sdk\$sdkVersion\Sdks\Microsoft.NET.Sdk\targets"
        Start-DownloadWithRetry -Url $sdkTargetsUrl -DownloadPath $sdkTargetsPath -Name $sdkTargetsName
    }
}

function InstallSDKVersion (
    $SdkVersion,
    $Warmup
)
{
    if (!(Test-Path -Path "C:\Program Files\dotnet\sdk\$sdkVersion"))
    {
        Write-Host "Installing dotnet $sdkVersion"
        .\dotnet-install.ps1 -Architecture x64 -Version $sdkVersion -InstallDir $(Join-Path -Path $env:ProgramFiles -ChildPath 'dotnet')
    }
    else
    {
        Write-Host "Sdk version $sdkVersion already installed"
    }

    Fix-ImportPublishProfile -SdkVersion $SdkVersion

    if ($Warmup) {
        Invoke-Warmup -SdkVersion $SdkVersion
    }
}

function InstallAllValidSdks()
{
    # Consider all channels except preview/eol channels.
    # Sort the channels in ascending order
    $dotnetToolset = (Get-ToolsetContent).dotnet
    $dotnetVersions = $dotnetToolset.versions
    $warmup = $dotnetToolset.warmup

    # Download installation script.
    $installationName = "dotnet-install.ps1"
    $installationUrl = "https://dot.net/v1/${installationName}"
    Start-DownloadWithRetry -Url $installationUrl -Name $installationName -DownloadPath ".\"

    ForEach ($dotnetVersion in $dotnetVersions)
    {
        $sdkVersionsToInstall = Get-SDKVersionsToInstall -DotnetVersion $dotnetVersion
        
        ForEach ($sdkVersion in $sdkVersionsToInstall)
        {
            InstallSDKVersion -SdkVersion $sdkVersion -Warmup $warmup
        }
    }
}

function RunPostInstallationSteps()
{
    Add-MachinePathItem "C:\Program Files\dotnet"
    # Run script at startup for all users
    $cmdDotNet = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -Command "[System.Environment]::SetEnvironmentVariable(''PATH'',"""$env:USERPROFILE\.dotnet\tools;$env:PATH""", ''USER'')"'

    # Update Run key to run a script at logon
    Set-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "DOTNETUSERPATH" -Value $cmdDotNet
}

InstallAllValidSdks
RunPostInstallationSteps

Invoke-PesterTests -TestFile "DotnetSDK"