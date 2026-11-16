BeforeAll {
    $sourceFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'ObjectHandling/Import-TestToolkitToNavContainer.ps1'
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($sourceFile, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) {
        throw ($parseErrors | Out-String)
    }
    # Load the shipped function without importing the module or requiring Docker.
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Import-TestToolkitToBcContainer' }, $false)
    . ([scriptblock]::Create($definition.Extent.Text))

    function InitTelemetryScope { param($name, $parameterValues, $includeParameters) }
    function TrackException { param($telemetryScope, $errorRecord) }
    function TrackTrace { param($telemetryScope) }
    function docker { param($command, $containerName) }
    function Get-BcContainerServerConfiguration { param($containerName) }
    function GetTestToolkitApps { param($containerName, $compilerFolder, [switch]$includeTestRunnerOnly, [switch]$includeTestFrameworkOnly, [switch]$includeTestLibrariesOnly, [switch]$includePerformanceToolkit) }
    function Invoke-ScriptInBcContainer { param($containerName, [scriptblock]$scriptblock, [object[]]$argumentList) }
    function Get-NAVAppInfo { [CmdletBinding()] param($Path, $ServerInstance, $Name, $Publisher, $Version, $Tenant, [switch]$TenantSpecificProperties) }
    function Sync-BcContainerApp { param($containerName, $tenant, $appName, $appPublisher, $appVersion, [switch]$Force) }
    function Install-BcContainerApp { param($containerName, $tenant, $appName, $appPublisher, $appVersion, [switch]$Force) }
    function Publish-BcContainerApp { param($containerName, $appFile, [switch]$skipVerification, [switch]$sync, [switch]$install, $scope, [switch]$useDevEndpoint, $replaceDependencies, $credential, $tenant, $internalsVisibleTo, [switch]$replacePackageId) }
    function Get-BcContainerAppInfo { param($containerName) }
    function UnPublish-BcContainerApp { param($containerName, $publisher, $name, $version, [switch]$unInstall, [switch]$force) }
    function Get-BcContainerPath { param($containerName, $path, [switch]$throw) }
    function Get-NavAppRuntimePackage { param($ServerInstance, $Publisher, $Name, $Version, $Path, $Tenant) }

    function Add-ToolkitPackage {
        param([string]$Name, [string]$FileName, [string]$Version = '28.0.0.0', [string]$Publisher = 'Microsoft', [guid]$Id = [guid]::NewGuid())
        if (!$FileName) {
            $FileName = "Microsoft_$Name.app"
        }
        $path = Join-Path $TestDrive $FileName
        $script:toolkitFiles += $path
        $script:packages[$path] = [pscustomobject]@{ AppId = $Id; Name = $Name; Publisher = $Publisher; Version = [version]$Version }
        $path
    }

    function Add-PublishedPackage {
        param([string]$Path, [bool]$Installed = $true)
        $app = $script:packages[$Path]
        $script:publishedApps += [pscustomobject]@{ AppId = $app.AppId; Name = $app.Name; Publisher = $app.Publisher; Version = $app.Version; IsInstalled = $Installed }
    }

    function Get-TestRuntimePath {
        param([string]$Path)
        $folder = Join-Path $script:bcContainerHelperConfig.hostHelperFolder "Extensions\onprem-Applications-$($script:containerVersion)-w1"
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
        "$folder\$([System.IO.Path]::GetFileName($Path).Replace('.app', '.runtime.app'))"
    }
}

Describe 'Import-TestToolkitToBcContainer batched container lookups' {
    BeforeEach {
        $script:serverInstance = 'BC'
        $script:containerVersion = '28.0.0.0'
        $script:bcContainerHelperConfig = @{ defaultContainerName = 'test'; hostHelperFolder = (Join-Path $TestDrive 'helper') }
        $script:toolkitFiles = @()
        $script:packages = @{}
        $script:publishedApps = @()
        $script:operations = @()

        Mock InitTelemetryScope { @{} }
        Mock TrackException {}
        Mock TrackTrace {}
        Mock Write-Host {}
        Mock docker { @{ Config = @{ Labels = @{ maintainer = 'Dynamics SMB'; version = $script:containerVersion; country = 'w1' }; Env = @() } } | ConvertTo-Json -Depth 4 }
        Mock Get-BcContainerServerConfiguration { [pscustomobject]@{ EnableSymbolLoadingAtServerStartup = 'False' } }
        Mock Test-Path { $false } -ParameterFilter { $Path -eq 'C:\Test Assemblies\Mock Assemblies' }
        Mock GetTestToolkitApps { $script:toolkitFiles }
        Mock Invoke-ScriptInBcContainer { & $scriptblock @argumentList }
        Mock Get-NAVAppInfo {
            if ($Path) {
                if (!$script:packages.ContainsKey($Path)) {
                    throw "Unexpected package path: $Path"
                }
                $script:operations += "Read:$Path"
                $script:packages[$Path]
            }
            else {
                $script:operations += 'Query tenant'
                $script:publishedApps
            }
        }
        Mock Sync-BcContainerApp { $script:operations += "Sync:$appName" }
        Mock Install-BcContainerApp { $script:operations += "Install:$appName" }
        Mock Publish-BcContainerApp { $script:operations += "Publish:$appFile" }
        Mock Get-BcContainerAppInfo {}
        Mock UnPublish-BcContainerApp { $script:operations += "Unpublish:$name" }
        Mock Get-BcContainerPath { $path }
        Mock Get-NavAppRuntimePackage {}
    }

    It 'uses one tenant query and one metadata invocation when all apps are installed' {
        foreach ($name in @('Permissions Mock', 'Test Runner', 'Library Assert')) {
            $path = Add-ToolkitPackage -Name $name
            Add-PublishedPackage -Path $path
        }

        Import-TestToolkitToBcContainer -containerName 'test'

        Should -Invoke Get-NAVAppInfo -Times 1 -Exactly -ParameterFilter { $ServerInstance -eq 'BC' -and $Tenant -eq 'default' -and $TenantSpecificProperties -and !$Name -and !$Publisher -and !$Version }
        Should -Invoke Get-NAVAppInfo -Times 3 -Exactly -ParameterFilter { $Path }
        # One existing mock-assembly preparation call plus one batched lookup.
        Should -Invoke Invoke-ScriptInBcContainer -Times 2 -Exactly
        Should -Invoke Sync-BcContainerApp -Times 0 -Exactly
        Should -Invoke Install-BcContainerApp -Times 0 -Exactly
        Should -Invoke Publish-BcContainerApp -Times 0 -Exactly
        Should -Invoke Write-Host -Times 3 -Exactly -ParameterFilter { $Object -like "Skipping app '*' as it is already installed" }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq 'TestToolkit successfully imported' }
    }

    It 'preserves installed, published-only, and missing app behavior' {
        $installed = Add-ToolkitPackage -Name 'Installed'
        $published = Add-ToolkitPackage -Name 'Published'
        $missing = Add-ToolkitPackage -Name 'Missing'
        Add-PublishedPackage -Path $installed
        Add-PublishedPackage -Path $published -Installed $false

        Import-TestToolkitToBcContainer -containerName 'test' -tenant 'test-tenant'

        Should -Invoke Get-NAVAppInfo -Times 1 -Exactly -ParameterFilter { $ServerInstance -eq 'BC' -and $Tenant -eq 'test-tenant' -and $TenantSpecificProperties }
        Should -Invoke Sync-BcContainerApp -Times 1 -Exactly -ParameterFilter { $appName -eq 'Published' -and $appPublisher -eq 'Microsoft' -and $appVersion -eq '28.0.0.0' -and $tenant -eq 'test-tenant' -and $Force }
        Should -Invoke Install-BcContainerApp -Times 1 -Exactly -ParameterFilter { $appName -eq 'Published' -and $tenant -eq 'test-tenant' -and $Force }
        Should -Invoke Publish-BcContainerApp -Times 1 -Exactly -ParameterFilter { $appFile -eq ":$missing" -and $tenant -eq 'test-tenant' -and $skipVerification -and $sync -and $install -and $scope -eq 'global' }
        ($script:operations -join '|') | Should -Be (@('Query tenant', "Read:$installed", "Read:$published", "Read:$missing", 'Sync:Published', 'Install:Published', "Publish::$missing") -join '|')
    }

    It 'reads and publishes a repeated file only once without sorting dependencies' {
        $dependency = Add-ToolkitPackage -Name 'Z Dependency'
        $consumer = Add-ToolkitPackage -Name 'A Consumer'
        $script:toolkitFiles += $dependency

        Import-TestToolkitToBcContainer -containerName 'test'

        Should -Invoke Get-NAVAppInfo -Times 1 -Exactly -ParameterFilter { $Path -eq $dependency }
        Should -Invoke Publish-BcContainerApp -Times 2 -Exactly
        ($script:operations | Where-Object { $_ -like 'Publish:*' }) -join '|' | Should -Be "Publish::$dependency|Publish::$consumer"
    }

    It 'imports the same app ID and version from different files only once' {
        $id = [guid]::NewGuid()
        $first = Add-ToolkitPackage -Name 'Permissions Mock' -FileName 'first.app' -Id $id
        $second = Add-ToolkitPackage -Name 'Permissions Mock' -FileName 'second.app' -Id $id

        Import-TestToolkitToBcContainer -containerName 'test'

        Should -Invoke Get-NAVAppInfo -Times 2 -Exactly -ParameterFilter { $Path }
        Should -Invoke Publish-BcContainerApp -Times 1 -Exactly -ParameterFilter { $appFile -eq ":$first" }
        Should -Invoke Publish-BcContainerApp -Times 0 -Exactly -ParameterFilter { $appFile -eq ":$second" }
    }

    It 'does not conflate different versions of the same app' {
        $id = [guid]::NewGuid()
        $old = Add-ToolkitPackage -Name 'Library Assert' -FileName 'old.app' -Id $id -Version '27.0.0.0'
        $current = Add-ToolkitPackage -Name 'Library Assert' -FileName 'current.app' -Id $id -Version '28.0.0.0'
        Add-PublishedPackage -Path $old

        Import-TestToolkitToBcContainer -containerName 'test'

        Should -Invoke Publish-BcContainerApp -Times 1 -Exactly -ParameterFilter { $appFile -eq ":$current" }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq "Skipping app '$old' as it is already installed" }
    }

    It 'matches the publisher as well as the name and version' {
        $path = Add-ToolkitPackage -Name 'Library Assert'
        Add-PublishedPackage -Path $path
        $script:publishedApps[0].Publisher = 'Other Publisher'

        Import-TestToolkitToBcContainer -containerName 'test'

        Should -Invoke Publish-BcContainerApp -Times 1 -Exactly -ParameterFilter { $appFile -eq ":$path" }
    }

    It 'preserves installed status after argument and result serialization' {
        $path = Add-ToolkitPackage -Name 'Library Assert'
        Add-PublishedPackage -Path $path
        Mock Invoke-ScriptInBcContainer {
            $decodedArguments = [System.Management.Automation.PSSerializer]::Deserialize([System.Management.Automation.PSSerializer]::Serialize($argumentList, 10))
            $result = @(& $scriptblock @decodedArguments)
            [System.Management.Automation.PSSerializer]::Deserialize([System.Management.Automation.PSSerializer]::Serialize($result, 10))
        }

        Import-TestToolkitToBcContainer -containerName 'test'

        Should -Invoke Publish-BcContainerApp -Times 0 -Exactly
        Should -Invoke Install-BcContainerApp -Times 0 -Exactly
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq "Skipping app '$path' as it is already installed" }
    }

    It 'uses an existing runtime package and does not regenerate it' {
        $path = Add-ToolkitPackage -Name 'Library Assert'
        $runtimePath = Get-TestRuntimePath -Path $path
        Set-Content -Path $runtimePath -Value 'runtime package fixture'
        $script:packages[$runtimePath] = $script:packages[$path]

        Import-TestToolkitToBcContainer -containerName 'test' -doNotUseRuntimePackages:$false

        Should -Invoke Get-NAVAppInfo -Times 1 -Exactly -ParameterFilter { $Path -eq $runtimePath }
        Should -Invoke Get-NAVAppInfo -Times 0 -Exactly -ParameterFilter { $Path -eq $path }
        Should -Invoke Publish-BcContainerApp -Times 1 -Exactly -ParameterFilter { $appFile -eq ":$runtimePath" }
        Should -Invoke Get-NavAppRuntimePackage -Times 0 -Exactly
    }

    It 'replaces an empty runtime package and reuses metadata when exporting' {
        $path = Add-ToolkitPackage -Name 'Library Assert'
        $runtimePath = Get-TestRuntimePath -Path $path
        [System.IO.File]::WriteAllBytes($runtimePath, [byte[]]@())

        Import-TestToolkitToBcContainer -containerName 'test' -doNotUseRuntimePackages:$false

        Should -Invoke Get-NAVAppInfo -Times 1 -Exactly -ParameterFilter { $Path -eq $path }
        Should -Invoke Publish-BcContainerApp -Times 1 -Exactly -ParameterFilter { $appFile -eq ":$path" }
        Should -Invoke Get-NavAppRuntimePackage -Times 1 -Exactly -ParameterFilter { $Name -eq 'Library Assert' -and $Publisher -eq 'Microsoft' -and $Version -eq '28.0.0.0' -and $Tenant -eq 'default' -and $Path -eq $runtimePath }
        $runtimePath | Should -Not -Exist
    }

    It 'preserves dependency replacement and the development endpoint scope' {
        $path = Add-ToolkitPackage -Name 'Library Assert'
        $runtimePath = Get-TestRuntimePath -Path $path
        Set-Content -Path $runtimePath -Value 'runtime package fixture'
        $replacements = @{ '437dbf0e-84ff-417a-965d-ed2bb9650972' = @{ id = '88b7902e-1655-4e7b-812e-ee9f0667b01b'; name = 'Replacement'; publisher = 'Test'; minversion = '1.0.0.0' } }

        Import-TestToolkitToBcContainer -containerName 'test' -doNotUseRuntimePackages:$false -replaceDependencies $replacements -useDevEndpoint

        Should -Invoke Get-NAVAppInfo -Times 1 -Exactly -ParameterFilter { $Path -eq $path }
        Should -Invoke Publish-BcContainerApp -Times 1 -Exactly -ParameterFilter { $appFile -eq ":$path" -and $useDevEndpoint -and $scope -eq 'tenant' -and $replaceDependencies.ContainsKey('437dbf0e-84ff-417a-965d-ed2bb9650972') }
        Should -Invoke Get-NavAppRuntimePackage -Times 0 -Exactly
    }

    It 'queries tenant state after performance toolkit cleanup and preserves publish parameters' {
        $script:containerVersion = '19.0.0.0'
        $path = Add-ToolkitPackage -Name 'Performance Toolkit' -Version '19.0.0.0'
        Add-PublishedPackage -Path $path
        $script:bcptFixture = Join-Path $TestDrive 'bcpt'
        New-Item -Path $script:bcptFixture -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $script:bcptFixture 'app.json') -Value '{"id":"7027efad-e349-4b2f-a33e-0d15c746d213","name":"BCPT API","publisher":"Test"}'
        Mock Join-Path { $script:bcptFixture } -ParameterFilter { $ChildPath -eq '..\AppHandling\BCPTLogEntryAPI' }
        Mock UnPublish-BcContainerApp {
            $script:operations += "Unpublish:$name"
            $script:publishedApps = @()
        }

        Import-TestToolkitToBcContainer -containerName 'test' -includePerformanceToolkit

        ($script:operations | Select-Object -First 2) -join '|' | Should -Be 'Unpublish:Performance Toolkit|Query tenant'
        Should -Invoke Publish-BcContainerApp -Times 1 -Exactly -ParameterFilter { $appFile -eq ":$path" -and $replacePackageId -and $internalsVisibleTo.id -eq '7027efad-e349-4b2f-a33e-0d15c746d213' }
    }

    It 'does not query tenant state when no packages are selected' {
        Import-TestToolkitToBcContainer -containerName 'test'

        Should -Invoke Get-NAVAppInfo -Times 0 -Exactly
        Should -Invoke Invoke-ScriptInBcContainer -Times 1 -Exactly
        Should -Invoke Publish-BcContainerApp -Times 0 -Exactly
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq 'TestToolkit successfully imported' }
    }

    It 'does not interpret a failed tenant query as an empty app list' {
        Add-ToolkitPackage -Name 'Library Assert' | Out-Null
        Mock Get-NAVAppInfo { throw 'Tenant lookup failed' } -ParameterFilter { $ServerInstance }

        { Import-TestToolkitToBcContainer -containerName 'test' } | Should -Throw '*Tenant lookup failed*'

        Should -Invoke Publish-BcContainerApp -Times 0 -Exactly
        Should -Invoke Sync-BcContainerApp -Times 0 -Exactly
        Should -Invoke Install-BcContainerApp -Times 0 -Exactly
        Should -Invoke TrackException -Times 1 -Exactly
        Should -Invoke TrackTrace -Times 1 -Exactly
        Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -eq 'TestToolkit successfully imported' }
    }

    It 'does not start imports when reading a later package fails' {
        Add-ToolkitPackage -Name 'Valid' | Out-Null
        $bad = Add-ToolkitPackage -Name 'Invalid'
        Mock Get-NAVAppInfo { throw 'Invalid package' } -ParameterFilter { $Path -eq $bad }

        { Import-TestToolkitToBcContainer -containerName 'test' } | Should -Throw '*Invalid package*'

        Should -Invoke Publish-BcContainerApp -Times 0 -Exactly
        Should -Invoke Sync-BcContainerApp -Times 0 -Exactly
        Should -Invoke Install-BcContainerApp -Times 0 -Exactly
        Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -eq 'TestToolkit successfully imported' }
    }

    It 'propagates a <operation> failure without reporting successful completion' -TestCases @(
        @{ operation = 'sync' }
        @{ operation = 'install' }
        @{ operation = 'publish' }
    ) {
        param($operation)
        $path = Add-ToolkitPackage -Name 'Library Assert'
        if ($operation -ne 'publish') {
            Add-PublishedPackage -Path $path -Installed $false
        }
        switch ($operation) {
            'sync' { Mock Sync-BcContainerApp { throw 'Import action failed' } }
            'install' { Mock Install-BcContainerApp { throw 'Import action failed' } }
            'publish' { Mock Publish-BcContainerApp { throw 'Import action failed' } }
        }

        { Import-TestToolkitToBcContainer -containerName 'test' } | Should -Throw '*Import action failed*'

        Should -Invoke TrackException -Times 1 -Exactly
        Should -Invoke TrackTrace -Times 1 -Exactly
        Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -eq 'TestToolkit successfully imported' }
    }
}
