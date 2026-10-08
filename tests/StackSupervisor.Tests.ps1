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
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        # Lets Pester mock the cmdlet on hosts that do not ship the CIM module; the tests never query real WMI.
        function Get-CimInstance { [CmdletBinding()] param([string]$ClassName, [string]$Filter) }
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
            probe = [pscustomobject]@{ localPort = 1080; timeoutSec = 2; targets = @([pscustomobject]@{ url = 'https://a.example/x'; expect = 'ok'; plain = $false }) }
            candidateTest = [pscustomobject]@{ instanceTemplate = '{"port":{port},"outbound":{outbound}}'; basePort = 19001; probeExecutable = 'gateway'; probeArguments = '{config}'; rounds = 1; wantHealthy = 1; probeTimeoutSec = 1 }
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
        $livePath = [System.IO.Path]::GetFullPath((Join-Path $TestDrive 'gateway.json'))
        $otherPath = [System.IO.Path]::GetFullPath((Join-Path $TestDrive 'other/gateway.json'))
        $config.service.configPath = $livePath
        $script:processFixtures = @(
            [pscustomobject]@{ ProcessId = 11; CommandLine = ('edge-gateway.exe --config "{0}"' -f $livePath) },
            [pscustomobject]@{ ProcessId = 22; CommandLine = ('edge-gateway.exe --config "{0}"' -f $otherPath) }
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

Describe 'A failed failover attempt must not end the supervisor' {
    It 'reports failure instead of throwing when the failover raises an unexpected error' {
        $config = New-TestConfig
        Mock Invoke-Failover { throw 'simulated failure inside the failover' }
        Mock Write-Log {}

        { Invoke-FailoverGuarded -Config $config -Reason 'test' -CurrentScore 0 } | Should -Not -Throw
        Invoke-FailoverGuarded -Config $config -Reason 'test' -CurrentScore 0 | Should -BeFalse
        Should -Invoke Write-Log -ParameterFilter { $Message -like '*simulated failure inside the failover*' }
    }

    It 'passes the failover outcome and its switches through unchanged' {
        $config = New-TestConfig
        Mock Invoke-Failover { return $true }

        Invoke-FailoverGuarded -Config $config -Reason 'forced' -CurrentScore 2 -Force -DryRun | Should -BeTrue
        Should -Invoke Invoke-Failover -Times 1 -Exactly -ParameterFilter {
            $Force.IsPresent -and $DryRun.IsPresent -and $CurrentScore -eq 2 -and $Reason -eq 'forced'
        }
    }

    It 'skips a candidate whose probe instance cannot be built, logs why, and starts nothing' {
        $live = Join-Path $TestDrive 'probe-live.json'
        $json = '{"outbounds":[{"tag":"primary","kind":"proxy","target":{"host":"old.example","port":443}}]}'
        [System.IO.File]::WriteAllText($live, $json, (New-Object System.Text.UTF8Encoding($false)))
        $rules = @(
            (New-TestPatchRule -Path 'target.host' -Value '{host}'),
            (New-TestPatchRule -Path 'tls.serverName' -Value '{attr:sni}')
        )
        $config = New-TestConfig -PatchRules $rules
        $config.service.configPath = $live
        $candidate = [pscustomobject]@{ Label = 'c1'; Host = 'new.example'; Port = 8443; Fields = @{ host = 'new.example'; port = 8443; sni = 'new.example' } }
        Mock Start-Process {}
        Mock Write-Log {}

        $result = @(Invoke-CandidateMeasurement -Config $config -Candidates @($candidate))

        $result.Count | Should -Be 0
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Write-Log -ParameterFilter { $Message -like '*cannot build a probe instance*tls.serverName*' }
    }
}

Describe 'Optional attribute patch rules' {
    BeforeAll {
        $script:optionalRules = @(
            (New-TestPatchRule -Path 'target.host' -Value '{host}'),
            (New-TestPatchRule -Path 'target.port' -Value '{port}'),
            (New-TestPatchRule -Path 'tls.serverName' -Value '{attr:sni}')
        )
        $script:plainEndpoint = [pscustomobject]@{ Host = 'new.example'; Port = 8443; Fields = @{ host = 'new.example'; port = 8443 } }
    }

    It 'skips a rule whose attribute the candidate lacks, even when its path is absent from the live endpoint' {
        $config = New-TestConfig -PatchRules $script:optionalRules
        $blockText = '{"tag":"primary","kind":"proxy","target":{"host":"old.example","port":443}}'

        $parsed = ConvertFrom-Json -InputObject (Update-EndpointBlock -Config $config -BlockText $blockText -Endpoint $script:plainEndpoint)

        $parsed.target.host | Should -Be 'new.example'
        $parsed.target.port | Should -Be 8443
        $parsed.PSObject.Properties.Name | Should -Not -Contain 'tls'
    }

    It 'leaves an existing optional field untouched when the candidate lacks the attribute' {
        $config = New-TestConfig -PatchRules $script:optionalRules
        $blockText = '{"tag":"primary","kind":"proxy","target":{"host":"old.example","port":443},"tls":{"serverName":"keep.example"}}'

        $parsed = ConvertFrom-Json -InputObject (Update-EndpointBlock -Config $config -BlockText $blockText -Endpoint $script:plainEndpoint)

        $parsed.tls.serverName | Should -Be 'keep.example'
    }

    It 'still refuses a missing path when the candidate does carry the attribute' {
        $config = New-TestConfig -PatchRules $script:optionalRules
        $blockText = '{"tag":"primary","kind":"proxy","target":{"host":"old.example","port":443}}'
        $endpoint = [pscustomobject]@{ Host = 'new.example'; Port = 8443; Fields = @{ host = 'new.example'; port = 8443; sni = 'sni.example' } }

        { Update-EndpointBlock -Config $config -BlockText $blockText -Endpoint $endpoint } | Should -Throw '*patch path does not exist: tls.serverName*'
    }

    It 'still reports a duplicated patch path when the rule would be skipped' {
        $rules = @(
            (New-TestPatchRule -Path 'tls.serverName' -Value '{attr:sni}'),
            (New-TestPatchRule -Path 'tls.serverName' -Value '{attr:sni}')
        )
        $config = New-TestConfig -PatchRules $rules
        $blockText = '{"tag":"primary","kind":"proxy","tls":{"serverName":"keep.example"}}'

        { Update-EndpointBlock -Config $config -BlockText $blockText -Endpoint $script:plainEndpoint } | Should -Throw '*duplicate patch path*'
    }
}

Describe 'Failover when the service restart does not complete' {
    BeforeAll {
        function Initialize-FailoverScenario {
            param([string]$Name, [object[]]$Candidates)
            $script:failoverPath = Join-Path $TestDrive ($Name + '.json')
            $script:failoverOriginal = [byte[]](0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes("{`"original`":true}`r`n")
            [System.IO.File]::WriteAllBytes($script:failoverPath, $script:failoverOriginal)
            $script:failoverCandidates = $Candidates
            $script:failoverConfig = New-TestConfig
            $script:failoverConfig.service.configPath = $script:failoverPath
            $script:restartCalls = 0
            $script:scoreCalls = 0
            Mock Get-ActiveEndpoint { return [pscustomobject]@{ Host = 'active.example'; Port = 443 } }
            Mock Test-UpstreamReachability { return $true }
            Mock Get-CatalogEndpoints { return $script:failoverCandidates }
            Mock Invoke-CandidateMeasurement {
                return @($script:failoverCandidates | ForEach-Object { [pscustomobject]@{ Endpoint = $_; Score = 2; Ms = 10 } })
            }
            Mock Set-ActiveEndpoint {
                [System.IO.File]::WriteAllText($script:failoverPath, ('{"patched":"' + $Endpoint.Host + '"}'))
                return $true
            }
            Mock Write-Log {}
        }

        function New-TestCandidate {
            param([string]$Name)
            return [pscustomobject]@{ Label = $Name; Host = ($Name + '.example'); Port = 8443; Fields = @{ host = ($Name + '.example'); port = 8443 } }
        }
    }

    It 'puts the previous configuration back and reports failure instead of scoring the old process' {
        Initialize-FailoverScenario -Name 'refused' -Candidates @((New-TestCandidate 'c1'))
        Mock Restart-ServiceProcess { return $false }
        Mock Get-GatewayScore { return 1 }

        Invoke-Failover -Config $script:failoverConfig -Reason 'test' -CurrentScore 1 | Should -BeFalse

        [System.BitConverter]::ToString([System.IO.File]::ReadAllBytes($script:failoverPath)) | Should -BeExactly ([System.BitConverter]::ToString($script:failoverOriginal))
        Should -Invoke Get-GatewayScore -Times 0 -Exactly
        Should -Invoke Write-Log -ParameterFilter { $Message -like '*did not restart*restoring the previous configuration*' }
    }

    It 'restores the configuration from before the first write when a later candidate is the one that fails to restart' {
        Initialize-FailoverScenario -Name 'second' -Candidates @((New-TestCandidate 'c1'), (New-TestCandidate 'c2'))
        Mock Restart-ServiceProcess { $script:restartCalls++; return ($script:restartCalls -eq 1) }
        Mock Get-GatewayScore { return 0 }

        Invoke-Failover -Config $script:failoverConfig -Reason 'test' -CurrentScore 0 | Should -BeFalse

        Should -Invoke Set-ActiveEndpoint -Times 2 -Exactly
        [System.BitConverter]::ToString([System.IO.File]::ReadAllBytes($script:failoverPath)) | Should -BeExactly ([System.BitConverter]::ToString($script:failoverOriginal))
    }

    It 'keeps the new configuration and reports success when the restart completes and the data path answers' {
        Initialize-FailoverScenario -Name 'success' -Candidates @((New-TestCandidate 'c1'))
        Mock Restart-ServiceProcess { return $true }
        Mock Get-GatewayScore { return 2 }

        Invoke-Failover -Config $script:failoverConfig -Reason 'test' -CurrentScore 1 | Should -BeTrue

        [System.IO.File]::ReadAllText($script:failoverPath) | Should -BeExactly '{"patched":"c1.example"}'
        Should -Invoke Restart-ServiceProcess -Times 1 -Exactly
        Should -Invoke Get-GatewayScore -Times 1 -Exactly
    }

    It 'moves on to the next candidate when a completed restart is not followed by a working data path' {
        Initialize-FailoverScenario -Name 'verify' -Candidates @((New-TestCandidate 'c1'), (New-TestCandidate 'c2'))
        Mock Restart-ServiceProcess { return $true }
        Mock Get-GatewayScore { $script:scoreCalls++; if ($script:scoreCalls -eq 1) { return 0 } return 2 }

        Invoke-Failover -Config $script:failoverConfig -Reason 'test' -CurrentScore 0 | Should -BeTrue

        [System.IO.File]::ReadAllText($script:failoverPath) | Should -BeExactly '{"patched":"c2.example"}'
        Should -Invoke Restart-ServiceProcess -Times 2 -Exactly
    }
}

Describe 'JSON selection edge cases' {
    It 'accepts an empty property name' {
        $json = '{"":1,"outbounds":[{"tag":"primary","kind":"proxy"}]}'

        $block = Get-JsonObjectBlock -Text $json -Tag 'primary' -RequireProperty @('kind')

        $block.Path | Should -Be '/outbounds/0'
    }

    It 'resolves the root pointer, so an endpoint object that is the whole document can be read back' {
        $json = '{"tag":"primary","kind":"proxy"}'
        $tree = Get-JsonDocumentTree -Text $json

        (Get-JsonNodeByPointer -Root $tree -Pointer '').Kind | Should -Be 'Object'
        (Get-JsonObjectBlock -Text $json -Tag 'primary' -RequireProperty @('kind')).Path | Should -Be ''
    }

    It 'round-trips pointers for property names that contain a slash or a tilde' {
        $tree = Get-JsonDocumentTree -Text '{"a/b":{"tag":"primary","kind":"x"},"c~d":[{"tag":"primary","kind":"y"}]}'

        foreach ($node in @(Get-JsonObjectNodes -Node $tree)) {
            $back = Get-JsonNodeByPointer -Root $tree -Pointer $node.Path
            $back.Start | Should -Be $node.Start
            $back.End | Should -Be $node.End
        }
    }

    It 'returns strings without escape sequences verbatim, even when they look like dates' {
        $tree = Get-JsonDocumentTree -Text '{"d":"2024-01-02T03:04:05Z","s":"plain"}'

        $tree.Members[0].Node.Value | Should -BeExactly '2024-01-02T03:04:05Z'
        $tree.Members[1].Node.Value | Should -BeExactly 'plain'
    }

    It 'still decodes escape sequences' {
        $tree = Get-JsonDocumentTree -Text '{"k":"a\"b\\c\u00e9\n"}'

        $tree.Members[0].Node.Value | Should -BeExactly ("a`"b\c" + [char]0xE9 + "`n")
    }
}

Describe 'JSON selection diagnostics' {
    It 'explains a syntax error with its line and column' {
        $why = ''
        $json = "{`n  `"outbounds`": [`n    { /* note */ `"tag`": `"primary`" }`n  ]`n}"

        Get-JsonObjectBlock -Text $json -Tag 'primary' -Reason ([ref]$why) | Should -BeNullOrEmpty

        $why | Should -BeExactly 'JSON syntax error at line 3, column 7: expected a JSON string'
    }

    It 'reports an empty document as a syntax error instead of failing to bind' {
        $why = ''

        Get-JsonObjectBlock -Text '' -Tag 'primary' -Reason ([ref]$why) | Should -BeNullOrEmpty

        $why | Should -BeLike 'JSON syntax error at line 1, column 1: *'
    }

    It 'explains that no object matches' {
        $why = ''
        $json = '{"outbounds":[{"tag":"other","kind":"proxy"},{"tag":"primary"}]}'

        Get-JsonObjectBlock -Text $json -Tag 'primary' -RequireProperty @('kind') -Reason ([ref]$why) | Should -BeNullOrEmpty

        $why | Should -BeExactly "no JSON object has tag 'primary' with the properties kind"
    }

    It 'explains an ambiguous match by listing the paths' {
        $why = ''
        $json = '{"a":{"tag":"primary","kind":"x"},"b":{"tag":"primary","kind":"y"}}'

        Get-JsonObjectBlock -Text $json -Tag 'primary' -RequireProperty @('kind') -Reason ([ref]$why) | Should -BeNullOrEmpty

        $why | Should -BeExactly "2 JSON objects have tag 'primary' with the properties kind (paths /a, /b); refusing to choose one"
    }

    It 'still works when the caller does not ask for a reason' {
        Get-JsonObjectBlock -Text '{"tag":"primary"}' -Tag 'primary' | Should -Not -BeNullOrEmpty
        Get-JsonObjectBlock -Text '{' -Tag 'primary' | Should -BeNullOrEmpty
    }

    It 'logs why the active endpoint cannot be read' {
        $path = Join-Path $TestDrive 'unreadable.json'
        [System.IO.File]::WriteAllText($path, '{"outbounds":[{"tag":"primary","kind":"proxy",}]}', (New-Object System.Text.UTF8Encoding($false)))
        $config = New-TestConfig
        $config.service.configPath = $path
        Mock Write-Log {}

        Get-ActiveEndpoint -Config $config | Should -BeNullOrEmpty

        Should -Invoke Write-Log -ParameterFilter { $Message -like 'active endpoint not found: JSON syntax error at line 1, column *' }
    }

    It 'logs when the configured read fields do not resolve in the endpoint object' {
        $path = Join-Path $TestDrive 'nofields.json'
        [System.IO.File]::WriteAllText($path, '{"outbounds":[{"tag":"primary","kind":"proxy","target":{"address":"old.example"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        $config = New-TestConfig
        $config.service.configPath = $path
        Mock Write-Log {}

        Get-ActiveEndpoint -Config $config | Should -BeNullOrEmpty

        Should -Invoke Write-Log -ParameterFilter { $Message -like '*readFields*did not resolve*/outbounds/0*' }
    }

    It 'logs the reason when a configuration write is refused' {
        $path = Join-Path $TestDrive 'refused.json'
        $json = '{"a":{"tag":"primary","kind":"x"},"b":{"tag":"primary","kind":"y"}}'
        [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
        $config = New-TestConfig
        $config.service.configPath = $path
        $endpoint = [pscustomobject]@{ Host = 'new.example'; Port = 8443; Fields = @{ host = 'new.example'; port = 8443 } }
        Mock Write-Log {}

        Set-ActiveEndpoint -Config $config -Endpoint $endpoint | Should -BeFalse

        Should -Invoke Write-Log -ParameterFilter { $Message -like 'endpoint block not found; refusing to write: 2 JSON objects have tag*' }
        [System.IO.File]::ReadAllText($path) | Should -BeExactly $json
    }

    It 'logs the reason when probe instances cannot be built' {
        $path = Join-Path $TestDrive 'noprobe.json'
        [System.IO.File]::WriteAllText($path, '{"outbounds":[{"tag":"other","kind":"proxy"}]}', (New-Object System.Text.UTF8Encoding($false)))
        $config = New-TestConfig
        $config.service.configPath = $path
        $candidate = [pscustomobject]@{ Label = 'c1'; Host = 'new.example'; Port = 8443; Fields = @{ host = 'new.example'; port = 8443 } }
        Mock Start-Process {}
        Mock Write-Log {}

        @(Invoke-CandidateMeasurement -Config $config -Candidates @($candidate)).Count | Should -Be 0

        Should -Invoke Write-Log -ParameterFilter { $Message -like "cannot build probe instances: endpoint block not found: no JSON object has tag 'primary'*" }
    }
}

Describe 'JSON syntax accepted and rejected by the tokenizer' {
    It 'accepts <Name>' -TestCases @(
        @{ Name = 'an empty object'; Json = '{}' },
        @{ Name = 'an empty array'; Json = '[]' },
        @{ Name = 'a bare string'; Json = '"x"' },
        @{ Name = 'zero'; Json = '0' },
        @{ Name = 'negative zero'; Json = '-0' },
        @{ Name = 'exponents and fractions'; Json = '[1E5,-2.5e-3,0.0,1e+2]' },
        @{ Name = 'the three literals'; Json = '[true,false,null]' },
        @{ Name = 'nesting'; Json = '{"a":[{"b":[[]]}]}' },
        @{ Name = 'every simple escape'; Json = '"\"\\\/\b\f\n\r\t"' },
        @{ Name = 'a unicode escape'; Json = '"\u00e9"' },
        @{ Name = 'a surrogate pair written as escapes'; Json = '"\ud83d\ude00"' },
        @{ Name = 'whitespace around the value'; Json = " `t`r`n{ } `n" },
        @{ Name = 'an empty property name'; Json = '{"":0}' }
    ) {
        { Get-JsonDocumentTree -Text $Json } | Should -Not -Throw
    }

    It 'rejects <Name>' -TestCases @(
        @{ Name = 'empty text'; Json = '' },
        @{ Name = 'whitespace only'; Json = '  ' },
        @{ Name = 'a line comment'; Json = '{} // c' },
        @{ Name = 'a block comment'; Json = '/* c */ {}' },
        @{ Name = 'a trailing comma in an object'; Json = '{"a":1,}' },
        @{ Name = 'a trailing comma in an array'; Json = '[1,]' },
        @{ Name = 'a leading comma'; Json = '[,1]' },
        @{ Name = 'single quotes'; Json = "{'a':1}" },
        @{ Name = 'an unquoted key'; Json = '{a:1}' },
        @{ Name = 'a missing colon'; Json = '{"a" 1}' },
        @{ Name = 'a leading zero'; Json = '01' },
        @{ Name = 'a plus sign'; Json = '+1' },
        @{ Name = 'a trailing dot'; Json = '1.' },
        @{ Name = 'a leading dot'; Json = '.5' },
        @{ Name = 'a lone minus'; Json = '-' },
        @{ Name = 'an exponent without digits'; Json = '1e' },
        @{ Name = 'a literal in the wrong case'; Json = 'trUE' },
        @{ Name = 'a truncated literal'; Json = 'nul' },
        @{ Name = 'NaN'; Json = 'NaN' },
        @{ Name = 'content after the value'; Json = '{} {}' },
        @{ Name = 'an unterminated string'; Json = '"abc' },
        @{ Name = 'an unterminated object'; Json = '{"a":1' },
        @{ Name = 'an unterminated array'; Json = '[1' },
        @{ Name = 'a raw tab inside a string'; Json = ('"a' + [char]9 + 'b"') },
        @{ Name = 'an unknown escape'; Json = '"\x"' },
        @{ Name = 'a short unicode escape'; Json = '"\u12"' },
        @{ Name = 'a non-hex unicode escape'; Json = '"\u12G4"' },
        @{ Name = 'an upper-case unicode escape'; Json = '"\U0041"' },
        @{ Name = 'a duplicated property name'; Json = '{"a":1,"a":2}' }
    ) {
        { Get-JsonDocumentTree -Text $Json } | Should -Throw
    }
}

Describe 'Service process identity: the reason is spelled out' {
    BeforeAll {
        $script:identityPath = [System.IO.Path]::GetFullPath((Join-Path $TestDrive 'gateway.json'))
        $script:identityOther = [System.IO.Path]::GetFullPath((Join-Path $TestDrive 'other/gateway.json'))
        function New-IdentityConfig {
            $config = New-TestConfig
            $config.service.configPath = $script:identityPath
            return $config
        }
    }

    It 'says that no process of the executable is running' {
        $script:processFixtures = @()
        Mock Get-CimInstance { return $script:processFixtures }

        $snapshot = Get-ServiceProcessSnapshot -Config (New-IdentityConfig)

        $snapshot.Processes.Count | Should -Be 0
        $snapshot.Matching.Count | Should -Be 0
        $snapshot.Reason | Should -BeExactly 'no process named edge-gateway.exe is running'
    }

    It 'identifies the one process that carries the config path' {
        $script:processFixtures = @(
            [pscustomobject]@{ ProcessId = 11; CommandLine = ('edge-gateway.exe --config "{0}"' -f $script:identityPath) },
            [pscustomobject]@{ ProcessId = 22; CommandLine = ('edge-gateway.exe --config "{0}"' -f $script:identityOther) }
        )
        Mock Get-CimInstance { return $script:processFixtures }

        $snapshot = Get-ServiceProcessSnapshot -Config (New-IdentityConfig)

        $snapshot.Processes.Count | Should -Be 2
        @($snapshot.Matching).Count | Should -Be 1
        $snapshot.Matching[0].ProcessId | Should -Be 11
        $snapshot.Reason | Should -BeLike 'exactly one edge-gateway.exe process carries *'
    }

    It 'compares paths regardless of the slash direction used on the command line' {
        $script:processFixtures = @(
            [pscustomobject]@{ ProcessId = 11; CommandLine = ('edge-gateway.exe --config "{0}"' -f $script:identityPath.Replace('\', '/')) }
        )
        Mock Get-CimInstance { return $script:processFixtures }

        @((Get-ServiceProcessSnapshot -Config (New-IdentityConfig)).Matching).Count | Should -Be 1
    }

    It 'reports several matching processes' {
        $script:processFixtures = @(
            [pscustomobject]@{ ProcessId = 11; CommandLine = ('edge-gateway.exe --config "{0}"' -f $script:identityPath) },
            [pscustomobject]@{ ProcessId = 22; CommandLine = ('edge-gateway.exe -c {0}' -f $script:identityPath) }
        )
        Mock Get-CimInstance { return $script:processFixtures }

        $snapshot = Get-ServiceProcessSnapshot -Config (New-IdentityConfig)

        @($snapshot.Matching).Count | Should -Be 2
        $snapshot.Reason | Should -BeLike '2 edge-gateway.exe processes carry *'
    }

    It 'explains that none of the running processes carries the config path' {
        $script:processFixtures = @(
            [pscustomobject]@{ ProcessId = 11; CommandLine = 'edge-gateway.exe --config gateway.json' }
        )
        Mock Get-CimInstance { return $script:processFixtures }

        $snapshot = Get-ServiceProcessSnapshot -Config (New-IdentityConfig)

        @($snapshot.Matching).Count | Should -Be 0
        $snapshot.Reason | Should -BeLike '1 edge-gateway.exe process(es) are running but none carries *in its command line*absolute configPath*'
        $snapshot.Reason | Should -Not -BeLike '*could not be read*'
    }

    It 'points at unreadable command lines when a running process hides its own' {
        $script:processFixtures = @(
            [pscustomobject]@{ ProcessId = 11; CommandLine = $null }
        )
        Mock Get-CimInstance { return $script:processFixtures }

        $snapshot = Get-ServiceProcessSnapshot -Config (New-IdentityConfig)

        @($snapshot.Matching).Count | Should -Be 0
        $snapshot.Reason | Should -BeLike '*1 command line(s) could not be read*'
    }
}
