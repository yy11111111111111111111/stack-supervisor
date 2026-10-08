#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:CRLF = [string][char]13 + [char]10
    $repoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($sourcePath in @(
        (Join-Path $repoRoot 'src/StackSupervisor.ps1'),
        (Join-Path $repoRoot 'src/StackKeeper.ps1')
    )) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
        $functions = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $false)
        foreach ($functionAst in $functions) {
            . ([scriptblock]::Create($functionAst.Extent.Text))
        }
    }
    function New-TestPatchRule {
        param([string]$Path, [string]$Value)
        return [pscustomobject]@{ path = $Path; value = $Value }
    }

    function New-TestConfig {
        param([object[]]$PatchRules)
        if (-not $PatchRules) {
            $PatchRules = @(
                (New-TestPatchRule -Path 'target.host' -Value '{host}'),
                (New-TestPatchRule -Path 'target.port' -Value '{port}')
            )
        }
        $selector = [pscustomobject]@{
            tag = 'primary'
            requireProperties = @('kind')
            readFields = [pscustomobject]@{ host = 'target.host'; port = 'target.port' }
            patchRules = $PatchRules
        }
        $service = [pscustomobject]@{
            endpointSelector = $selector
            configPath = ''
            backupDir = ''
            processName = 'edge-gateway'
            startCommand = 'C:\edge\edge-gateway.exe --config "{config}"'
            catalog = [pscustomobject]@{ maxCandidates = 8 }
        }
        return [pscustomobject]@{ service = $service; log = '' }
    }
}

Describe 'JSON source-span selection and patching' {
    It 'selects the endpoint object rather than an earlier nested tag reference' {
        $json = '{"routes":[{"forward":{"tag":"primary"}}],"outbounds":[{"tag":"primary","kind":"proxy","note":"braces { } and escaped quote \" are text","target":{"host":"old.example","port":443}}]}'
        $block = Get-JsonObjectBlock -Text $json -Tag 'primary' -RequireProperty @('kind')

        $block.Path | Should -Be '/outbounds/0'
        (ConvertFrom-Json -InputObject $block.Text).kind | Should -Be 'proxy'
    }

    It 'refuses duplicate JSON keys and ambiguous endpoint objects' {
        Get-JsonObjectBlock -Text '{"outbounds":[{"tag":"primary","kind":"proxy","kind":"other"}]}' -Tag 'primary' -RequireProperty @('kind') | Should -BeNullOrEmpty
        Get-JsonObjectBlock -Text '{"outbounds":[{"tag":"primary","kind":"proxy"},{"tag":"primary","kind":"proxy"}]}' -Tag 'primary' -RequireProperty @('kind') | Should -BeNullOrEmpty
    }

    It 'patches the configured path while preserving a nested field with the same name' {
        $config = New-TestConfig
        $blockText = '{"tag":"primary","kind":"proxy","target":{"host":"old.example","port":443},"fallback":{"host":"keep.example"}}'
        $endpoint = [pscustomobject]@{ Host = 'new.example'; Port = 8443; Fields = @{ host = 'new.example'; port = 8443 } }

        $patched = Update-EndpointBlock -Config $config -BlockText $blockText -Endpoint $endpoint
        $parsed = ConvertFrom-Json -InputObject $patched

        $parsed.target.host | Should -Be 'new.example'
        $parsed.target.port | Should -Be 8443
        $parsed.fallback.host | Should -Be 'keep.example'
    }

    It 'refuses a legacy regex that matches more than one occurrence' {
        $rules = @([pscustomobject]@{
            pattern = '"host"\s*:\s*"[^"]*"'
            replacement = '"host": "{host}"'
        })
        $config = New-TestConfig -PatchRules $rules
        $endpoint = [pscustomobject]@{ Host = 'new.example'; Port = 443; Fields = @{ host = 'new.example'; port = 443 } }

        { Update-EndpointBlock -Config $config -BlockText '{"target":{"host":"old"},"fallback":{"host":"keep"}}' -Endpoint $endpoint } | Should -Throw '*must match exactly once*'
    }

    It 'validates the exact selected object path before writing and backs up the original' {
        $path = Join-Path $TestDrive 'gateway.json'
        $backupDir = Join-Path $TestDrive 'backups'
        $json = '{"routes":[{"target":{"tag":"primary"}}],"outbounds":[{"tag":"primary","kind":"proxy","target":{"host":"old.example","port":443}}]}'
        [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
        $config = New-TestConfig
        $config.service.configPath = $path
        $config.service.backupDir = $backupDir
        $endpoint = [pscustomobject]@{ Host = 'new.example'; Port = 8443; Fields = @{ host = 'new.example'; port = 8443 } }

        Set-ActiveEndpoint -Config $config -Endpoint $endpoint | Should -BeTrue
        $updated = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8))

        $updated.outbounds[0].target.host | Should -Be 'new.example'
        $updated.outbounds[0].target.port | Should -Be 8443
        $updated.routes[0].target.tag | Should -Be 'primary'
        @(Get-ChildItem -LiteralPath $backupDir -Filter 'config-*.json').Count | Should -Be 1
    }

    It 'leaves the live file untouched when a legacy patch is ambiguous' {
        $path = Join-Path $TestDrive 'ambiguous.json'
        $backupDir = Join-Path $TestDrive 'ambiguous-backups'
        $json = '{"outbounds":[{"tag":"primary","kind":"proxy","target":{"host":"old.example","port":443},"fallback":{"host":"keep.example"}}]}'
        [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
        $rules = @([pscustomobject]@{ pattern = '"host"\s*:\s*"[^"]*"'; replacement = '"host": "{host}"' })
        $config = New-TestConfig -PatchRules $rules
        $config.service.configPath = $path
        $config.service.backupDir = $backupDir
        $endpoint = [pscustomobject]@{ Host = 'new.example'; Port = 8443; Fields = @{ host = 'new.example'; port = 8443 } }
        Mock Write-Log {}

        Set-ActiveEndpoint -Config $config -Endpoint $endpoint | Should -BeFalse
        [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | Should -BeExactly $json
        Test-Path -LiteralPath $backupDir | Should -BeFalse
    }
}

Describe 'HTTP probe protocol' {
    It 'leaves bytes after the CONNECT header available on the same loopback stream' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $client = New-Object System.Net.Sockets.TcpClient
        $server = $null
        try {
            $client.Connect('127.0.0.1', $listener.LocalEndpoint.Port)
            $server = $listener.AcceptTcpClient()
            $header = "HTTP/1.1 200 Connection Established`r`nProxy-Agent: fixture`r`n`r`n"
            $body = 'x' * 4096
            $payload = [System.Text.Encoding]::ASCII.GetBytes($header + $body)
            $server.GetStream().Write($payload, 0, $payload.Length)
            $server.Close()

            $stream = $client.GetStream()
            $stream.ReadTimeout = 3000
            (Read-HttpHeaderBlock -Stream $stream) | Should -BeExactly $header
            $remaining = New-Object System.IO.MemoryStream
            $buffer = New-Object byte[] 8192
            while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $remaining.Write($buffer, 0, $count)
            }
            [System.Text.Encoding]::ASCII.GetString($remaining.ToArray()) | Should -BeExactly $body
            $remaining.Dispose()
        } finally {
            if ($server) { $server.Close() }
            $client.Close()
            $listener.Stop()
        }
    }
}

Describe 'Health scoring and failover decisions' {
    It 'maps full, partial, and failed probe rounds to scores 2, 1, and 0' {
        $config = [pscustomobject]@{ service = [pscustomobject]@{ probe = [pscustomobject]@{ localPort = 1080 } } }
        $script:healthTargets = @()
        Mock Get-HealthTargets { return $script:healthTargets }
        Mock Test-HealthTarget { return [bool]$Target.Pass }

        foreach ($outcomes in @(@($true, $true), @($true, $false), @($false, $false))) {
            $script:healthTargets = @(
                [pscustomobject]@{ Pass = $outcomes[0] },
                [pscustomobject]@{ Pass = $outcomes[1] }
            )
            $score = Get-GatewayScore -Config $config
            if ($outcomes[0] -and $outcomes[1]) { $score | Should -Be 2 }
            elseif ($outcomes[0] -or $outcomes[1]) { $score | Should -Be 1 }
            else { $score | Should -Be 0 }
        }
    }

    It 'does not write when no measured candidate beats the active score' {
        $active = [pscustomobject]@{ Host = 'active.example'; Port = 443 }
        $candidate = [pscustomobject]@{ Host = 'candidate.example'; Port = 8443; Label = 'candidate' }
        $measured = [pscustomobject]@{ Endpoint = $candidate; Score = 2; Ms = 10 }
        $config = New-TestConfig
        $script:catalogCandidates = @($candidate)
        $script:measurements = @($measured)
        Mock Get-ActiveEndpoint { return $active }
        Mock Test-UpstreamReachability { return $true }
        Mock Get-CatalogEndpoints { return $script:catalogCandidates }
        Mock Invoke-CandidateMeasurement { return $script:measurements }
        Mock Set-ActiveEndpoint { throw 'configuration write should not occur' }
        Mock Write-Log {}

        Invoke-Failover -Config $config -Reason 'test' -CurrentScore 2 | Should -BeFalse
        Should -Invoke Set-ActiveEndpoint -Times 0 -Exactly
    }
}

Describe 'Service process identity' {
    It 'matches the config path so another process with the same executable is ignored' {
        $config = New-TestConfig
        $config.service.configPath = 'C:\ProgramData\edge-gateway\gateway.json'
        $script:processFixtures = @(
            [pscustomobject]@{ ProcessId = 11; CommandLine = 'edge-gateway.exe --config "C:\ProgramData\edge-gateway\gateway.json"' },
            [pscustomobject]@{ ProcessId = 22; CommandLine = 'edge-gateway.exe --config "C:\Other\gateway.json"' }
        )
        Mock Get-CimInstance { return $script:processFixtures }

        $found = @(Get-ServiceProcessCandidates -Config $config)

        $found.Count | Should -Be 1
        $found[0].ProcessId | Should -Be 11
        Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter {
            $ClassName -eq 'Win32_Process' -and $Filter -eq "Name='edge-gateway.exe'"
        }
    }

    It 'stops only the unique configured process and accepts its replacement' {
        $config = New-TestConfig
        $original = [pscustomobject]@{ ProcessId = 101; CommandLine = 'edge-gateway.exe --config gateway.json' }
        $replacement = [pscustomobject]@{ ProcessId = 202; CommandLine = 'edge-gateway.exe --config gateway.json' }
        $script:processReads = 0
        $script:originalProcess = $original
        $script:replacementProcess = $replacement
        Mock Get-ServiceProcessCandidates {
            $script:processReads++
            if ($script:processReads -eq 1) { return @($script:originalProcess) }
            return @($script:replacementProcess)
        }
        Mock Stop-Process {}
        Mock Start-ServiceProcess {}
        Mock Start-Sleep {}

        Restart-ServiceProcess -Config $config -WaitSec 10 | Should -BeTrue
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 101 }
        Should -Invoke Start-ServiceProcess -Times 0 -Exactly
    }

    It 'starts the configured service only after the original PID has exited' {
        $config = New-TestConfig
        $original = [pscustomobject]@{ ProcessId = 101; CommandLine = 'edge-gateway.exe --config gateway.json' }
        $replacement = [pscustomobject]@{ ProcessId = 202; CommandLine = 'edge-gateway.exe --config gateway.json' }
        $script:processReads = 0
        $script:originalProcess = $original
        $script:replacementProcess = $replacement
        Mock Get-ServiceProcessCandidates {
            $script:processReads++
            if ($script:processReads -eq 1) { return @($script:originalProcess) }
            if ($script:processReads -eq 2) { return @() }
            return @($script:replacementProcess)
        }
        Mock Stop-Process {}
        Mock Start-ServiceProcess {}

        Restart-ServiceProcess -Config $config -WaitSec 0 | Should -BeTrue
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 101 }
        Should -Invoke Start-ServiceProcess -Times 1 -Exactly
    }

    It 'refuses to stop when more than one process matches the configured instance' {
        $config = New-TestConfig
        $script:multipleProcesses = @(
            [pscustomobject]@{ ProcessId = 101 },
            [pscustomobject]@{ ProcessId = 202 }
        )
        Mock Get-ServiceProcessCandidates { return $script:multipleProcesses }
        Mock Stop-Process {}
        Mock Write-Log {}

        Restart-ServiceProcess -Config $config -WaitSec 0 | Should -BeFalse
        Should -Invoke Stop-Process -Times 0 -Exactly
    }

    It 'refuses to restart when process inspection fails' {
        $config = New-TestConfig
        Mock Get-ServiceProcessCandidates { throw 'process query failed' }
        Mock Stop-Process {}
        Mock Write-Log {}

        Restart-ServiceProcess -Config $config -WaitSec 0 | Should -BeFalse
        Should -Invoke Stop-Process -Times 0 -Exactly
    }
}

Describe 'Keeper command-line detection' {
    It 'does not let the keeper match its own command line' {
        $processes = @(
            [pscustomobject]@{ ProcessId = 10; CommandLine = 'powershell.exe -File C:\ops\StackKeeper.ps1 -Pattern StackKeeper' },
            [pscustomobject]@{ ProcessId = 11; CommandLine = 'powershell.exe -NoProfile' }
        )
        Test-KeeperCommandLineMatch -Processes $processes -SelfProcessId 10 -Pattern 'StackKeeper\.ps1' | Should -BeFalse

        $processes += [pscustomobject]@{ ProcessId = 12; CommandLine = 'powershell.exe -File C:\ops\StackKeeper.ps1' }
        Test-KeeperCommandLineMatch -Processes $processes -SelfProcessId 10 -Pattern 'StackKeeper\.ps1' | Should -BeTrue
    }
}
