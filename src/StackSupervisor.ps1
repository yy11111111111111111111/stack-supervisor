#Requires -Version 5.1
<#
.SYNOPSIS
    Layered supervisor for a local gateway service whose upstream endpoints are unreliable.

.DESCRIPTION
    Three-stage health model, automatic endpoint failover, and a self-healing keeper.

    Stage 1 - Score the live data path (not process liveness) by asking the running service
              to fetch each configured health target and asserting on the response body:
                  2 = every target answered correctly   (healthy)
                  1 = some targets answered correctly   (degraded)
                  0 = nothing answered correctly        (down)
    Stage 2 - When the score stays below full for enough consecutive rounds, fetch the
              endpoint catalog, build one isolated probe instance per candidate, measure
              every candidate, and rank them.
    Stage 3 - Patch the live configuration to the best candidate that is *strictly better*
              than the current one, restart the service, and verify. Every write is
              preceded by a timestamped backup and validated by re-parsing the result.

    Nothing about a particular service or configuration schema is hardcoded: the tag to
    look for, the fields to read, the text patterns to rewrite and the shape of a probe
    instance all come from the configuration file.

.PARAMETER ConfigPath
    Path to the supervisor configuration file (see config/supervisor.example.json).

.PARAMETER Once
    Run a single check and exit. An unhealthy or degraded result triggers failover
    immediately instead of waiting for the consecutive-round threshold.

.PARAMETER ForceSwitch
    Ignore the "strictly better" rule and the cooldown, and switch to the best candidate
    that passes the probe. Useful for manual re-selection.

.PARAMETER DryRun
    Measure candidates and report, but never write the live configuration.

.EXAMPLE
    .\StackSupervisor.ps1 -ConfigPath .\config\supervisor.json

.EXAMPLE
    .\StackSupervisor.ps1 -ConfigPath .\config\supervisor.json -Once -ForceSwitch -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [switch]$Once,
    [switch]$ForceSwitch,
    [switch]$DryRun,
    [int]$CheckIntervalSec  = 60,
    [int]$FailThreshold     = 3,
    [int]$DegradedThreshold = 5,
    [int]$CooldownMin       = 10,
    [int]$MissingThreshold  = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$script:CRLF = [string][char]13 + [char]10

#region ---------------------------------------------------------------- logging

function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [string]$Path)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    if ($Path) {
        try {
            [System.IO.File]::AppendAllText($Path, $line + $script:CRLF, (New-Object System.Text.UTF8Encoding($true)))
        } catch { }
    }
    Write-Host $line
}

function Read-TextFile {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-TextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    # Written without a BOM: configuration files are consumed by external tools that may
    # not skip one. Scripts, by contrast, must carry a BOM on Windows PowerShell 5.1.
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

#endregion

#region ------------------------------------------------------------------- json

function Get-JsonPathValue {
    <# Resolves a dotted path such as 'target.host' or 'upstreams[0].target.port'. #>
    param($Object, [Parameter(Mandatory)][string]$Path)
    $current = $Object
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        $name = $segment; $index = -1
        $match = [regex]::Match($segment, '^([^\[]+)\[(\d+)\]$')
        if ($match.Success) { $name = $match.Groups[1].Value; $index = [int]$match.Groups[2].Value }
        if ($name) {
            if (-not $current.PSObject.Properties.Name.Contains($name)) { return $null }
            $current = $current.$name
        }
        if ($index -ge 0) {
            if ($null -eq $current -or $current.Count -le $index) { return $null }
            $current = $current[$index]
        }
    }
    return $current
}

function Get-JsonObjectBlock {
    <#
        Extracts the raw text of the JSON object that carries a given tag, together with its
        offsets, so a single object can be patched without reformatting the whole file.

        Only objects that declare the tag *and* every property listed in -RequireProperty are
        accepted. Without that guard a nested reference to the same tag - for example a route
        that points at the endpoint by name - matches first and the wrong object is rewritten.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Tag,
        [string[]]$RequireProperty = @()
    )
    $needle = '"tag"' + ': "' + $Tag + '"'
    $from = 0
    while ($true) {
        $idx = $Text.IndexOf($needle, $from, [System.StringComparison]::Ordinal)
        if ($idx -lt 0) { return $null }
        $from = $idx + 1
        $start = $Text.LastIndexOf('{', $idx)
        if ($start -lt 0) { continue }
        $depth = 0; $inString = $false; $escaped = $false
        for ($i = $start; $i -lt $Text.Length; $i++) {
            $ch = $Text[$i]
            if ($inString) {
                if ($escaped) { $escaped = $false }
                elseif ($ch -eq [char]92) { $escaped = $true }
                elseif ($ch -eq '"') { $inString = $false }
            } else {
                if ($ch -eq '"') { $inString = $true }
                elseif ($ch -eq '{') { $depth++ }
                elseif ($ch -eq '}') {
                    $depth--
                    if ($depth -eq 0) {
                        $candidate = $Text.Substring($start, $i - $start + 1)
                        $accepted = $false
                        try {
                            $parsed = $candidate | ConvertFrom-Json
                            if ($parsed.tag -eq $Tag) {
                                $accepted = $true
                                foreach ($property in $RequireProperty) {
                                    if (-not $parsed.PSObject.Properties.Name.Contains($property)) { $accepted = $false }
                                }
                            }
                        } catch { }
                        if ($accepted) { return [pscustomobject]@{ Start = $start; End = $i; Text = $candidate } }
                        break
                    }
                }
            }
        }
    }
    return $null
}

function Set-RegexFirst {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Pattern, [Parameter(Mandatory)][string]$Replacement)
    return ([regex]::new($Pattern)).Replace($Text, $Replacement, 1)
}

function Expand-Template {
    <# Replaces {token} placeholders. Unknown tokens are left untouched. #>
    param([Parameter(Mandatory)][string]$Template, [Parameter(Mandatory)][hashtable]$Tokens)
    $result = $Template
    foreach ($key in $Tokens.Keys) {
        $result = $result.Replace('{' + $key + '}', [string]$Tokens[$key])
    }
    return $result
}

#endregion

#region ------------------------------------------------------------- configuration

function Get-SupervisorConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "configuration file not found: $Path" }
    $cfg = (Read-TextFile -Path $Path) | ConvertFrom-Json
    foreach ($section in 'service', 'log') {
        if (-not $cfg.PSObject.Properties.Name.Contains($section)) { throw "configuration is missing the '$section' section" }
    }
    foreach ($key in 'name', 'processName', 'configPath', 'startCommand', 'endpointSelector', 'probe', 'catalog', 'candidateTest') {
        if (-not $cfg.service.PSObject.Properties.Name.Contains($key)) { throw "service section is missing '$key'" }
    }
    return $cfg
}

function Get-Selector {
    param([Parameter(Mandatory)]$Config)
    $selector = $Config.service.endpointSelector
    $required = @()
    if ($selector.PSObject.Properties.Name.Contains('requireProperties')) { $required = @($selector.requireProperties) }
    return [pscustomobject]@{
        Tag      = [string]$selector.tag
        Required = $required
        Read     = $selector.readFields
        Patch    = @($selector.patchRules)
    }
}

#endregion

#region ------------------------------------------------------------------- probe

function Invoke-GatewayProbe {
    <#
        Sends one request through the local service endpoint and returns the raw response.
        A plain TCP socket plus an HTTP CONNECT preamble keeps this usable with any
        forwarding service that speaks the standard verb, with no extra dependencies.
    #>
    param(
        [Parameter(Mandatory)][int]$LocalPort,
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSec = 12,
        [switch]$NoTls
    )
    $uri = [System.Uri]$Url
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $LocalPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutSec * 1000)) { throw 'connect timeout' }
        $client.EndConnect($iar)
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutSec * 1000
        $stream.WriteTimeout = $TimeoutSec * 1000

        $connect = 'CONNECT ' + $uri.Host + ':' + $uri.Port + ' HTTP/1.1' + $script:CRLF +
                   'Host: ' + $uri.Host + ':' + $uri.Port + $script:CRLF + $script:CRLF
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($connect)
        $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()

        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
        $status = $reader.ReadLine()
        if (-not $status -or $status -notmatch ' 200') { throw "endpoint refused CONNECT: $status" }
        while ($true) { $line = $reader.ReadLine(); if ([string]::IsNullOrEmpty($line)) { break } }

        $active = $stream
        if (-not $NoTls) {
            $ssl = New-Object System.Net.Security.SslStream($stream, $false,
                ([System.Net.Security.RemoteCertificateValidationCallback] { $true }))
            $ssl.AuthenticateAsClient($uri.Host, $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
            $active = $ssl
        }
        $request = 'GET ' + $uri.PathAndQuery + ' HTTP/1.1' + $script:CRLF +
                   'Host: ' + $uri.Host + $script:CRLF +
                   'User-Agent: stack-supervisor/1.0' + $script:CRLF +
                   'Accept: */*' + $script:CRLF + 'Connection: close' + $script:CRLF + $script:CRLF
        $rb = [System.Text.Encoding]::ASCII.GetBytes($request)
        $active.Write($rb, 0, $rb.Length); $active.Flush()

        $buffer = New-Object byte[] 8192
        $memory = New-Object System.IO.MemoryStream
        while ($true) {
            $read = $active.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $memory.Write($buffer, 0, $read)
        }
        return [System.Text.Encoding]::UTF8.GetString($memory.ToArray())
    } finally { $client.Close() }
}

function Get-HealthTargets {
    param([Parameter(Mandatory)]$Config)
    $targets = @()
    foreach ($entry in $Config.service.probe.targets) {
        $targets += [pscustomobject]@{
            Url        = [string]$entry.url
            Expect     = [string]$entry.expect
            Plain      = [bool]$entry.plain
            TimeoutSec = [int]$Config.service.probe.timeoutSec
        }
    }
    return $targets
}

function Test-HealthTarget {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)][int]$LocalPort, [int]$TimeoutSec = 0)
    if ($TimeoutSec -le 0) { $TimeoutSec = $Target.TimeoutSec }
    try {
        $response = Invoke-GatewayProbe -LocalPort $LocalPort -Url $Target.Url -TimeoutSec $TimeoutSec -NoTls:$Target.Plain
        if ($response -match $Target.Expect) { return $true }
    } catch { }
    return $false
}

function Get-GatewayScore {
    param([Parameter(Mandatory)]$Config, [int]$LocalPort = 0)
    if ($LocalPort -le 0) { $LocalPort = [int]$Config.service.probe.localPort }
    $targets = Get-HealthTargets -Config $Config
    if ($targets.Count -eq 0) { return 0 }
    $passed = 0
    foreach ($target in $targets) { if (Test-HealthTarget -Target $target -LocalPort $LocalPort) { $passed++ } }
    if ($passed -ge $targets.Count) { return 2 }
    if ($passed -ge 1) { return 1 }
    return 0
}

#endregion

#region ---------------------------------------------------------- endpoint access

function Get-ActiveEndpoint {
    param([Parameter(Mandatory)]$Config)
    $selector = Get-Selector -Config $Config
    $text = Read-TextFile -Path $Config.service.configPath
    $block = Get-JsonObjectBlock -Text $text -Tag $selector.Tag -RequireProperty $selector.Required
    if (-not $block) { return $null }
    $object = $block.Text | ConvertFrom-Json
    $fields = @{}
    foreach ($property in $selector.Read.PSObject.Properties) {
        $fields[$property.Name] = Get-JsonPathValue -Object $object -Path ([string]$property.Value)
    }
    if (-not $fields.ContainsKey('host') -or -not $fields.ContainsKey('port')) { return $null }
    return [pscustomobject]@{ Host = [string]$fields['host']; Port = [int]$fields['port']; Fields = $fields }
}

function Update-EndpointBlock {
    <# Applies the configured patch rules to one endpoint block and returns the new text. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$BlockText, [Parameter(Mandatory)]$Endpoint)
    $selector = Get-Selector -Config $Config
    $tokens = @{ host = $Endpoint.Host; port = $Endpoint.Port }
    foreach ($key in $Endpoint.Fields.Keys) {
        if ($key -ne 'host' -and $key -ne 'port' -and $Endpoint.Fields[$key]) { $tokens['attr:' + $key] = [string]$Endpoint.Fields[$key] }
    }
    $patched = $BlockText
    foreach ($rule in $selector.Patch) {
        $replacement = [string]$rule.replacement
        $skip = $false
        foreach ($match in [regex]::Matches($replacement, '\{attr:([^\}]+)\}')) {
            $name = $match.Groups[1].Value
            if (-not $tokens.ContainsKey('attr:' + $name)) { $skip = $true; break }
        }
        if ($skip) { continue }
        $patched = Set-RegexFirst -Text $patched -Pattern ([string]$rule.pattern) -Replacement (Expand-Template -Template $replacement -Tokens $tokens)
    }
    return $patched
}

function Set-ActiveEndpoint {
    <# Backs up the configuration, patches the endpoint in place, validates, then writes. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Endpoint)
    $path = $Config.service.configPath
    $selector = Get-Selector -Config $Config
    $text = Read-TextFile -Path $path
    $block = Get-JsonObjectBlock -Text $text -Tag $selector.Tag -RequireProperty $selector.Required
    if (-not $block) { Write-Log -Message 'endpoint block not found; refusing to write' -Path $Config.log; return $false }

    $updated = $text.Substring(0, $block.Start) + (Update-EndpointBlock -Config $Config -BlockText $block.Text -Endpoint $Endpoint) + $text.Substring($block.End + 1)

    try {
        $parsed = $updated | ConvertFrom-Json
        $object = $null
        foreach ($candidate in $parsed.PSObject.Properties) {
            if ($candidate.Value -isnot [System.Array]) { continue }
            foreach ($item in $candidate.Value) {
                if ($item.PSObject.Properties.Name.Contains('tag') -and $item.tag -eq $selector.Tag) { $object = $item }
            }
        }
        if (-not $object) { Write-Log -Message 'read-back could not locate the endpoint block' -Path $Config.log; return $false }
        $host = Get-JsonPathValue -Object $object -Path ([string]$selector.Read.host)
        $port = Get-JsonPathValue -Object $object -Path ([string]$selector.Read.port)
        if ([string]$host -ne [string]$Endpoint.Host -or [int]$port -ne [int]$Endpoint.Port) {
            Write-Log -Message 'read-back validation failed; refusing to write' -Path $Config.log
            return $false
        }
    } catch {
        Write-Log -Message ('updated configuration does not parse: ' + $_.Exception.Message) -Path $Config.log
        return $false
    }

    $backupDir = [string]$Config.service.backupDir
    if ($backupDir) {
        if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
        $stamp = Get-Date -Format 'yyyyMMddHHmmss'
        Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir ('config-' + $stamp + '.json')) -Force
        Get-ChildItem -LiteralPath $backupDir -Filter 'config-*.json' | Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 10 | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Write-TextFile -Path $path -Text $updated
    return $true
}

#endregion

#region ------------------------------------------------------------ catalog input

function Get-CatalogEndpoints {
    <#
        Reads the endpoint catalog.

        Formats:
          uri-lines   one endpoint URI per line
          base64-uri  a single base64 blob that decodes to URI lines (typical for hosted feeds)
        URI shape:  <scheme>://<id>@<host>:<port>?key=value&...#<label>
        Every query parameter becomes an attribute that patch rules can reference as {attr:<name>}.
    #>
    param([Parameter(Mandatory)]$Config)
    $feed = $Config.service.catalog
    if ($feed.PSObject.Properties.Name.Contains('file') -and $feed.file) {
        $raw = Read-TextFile -Path ([string]$feed.file)
    } else {
        $response = Invoke-WebRequest -Uri ([string]$feed.url) -UseBasicParsing -TimeoutSec 25 -UserAgent 'stack-supervisor/1.0'
        $raw = $response.Content
    }
    $raw = $raw.Trim()
    $scheme = [string]$feed.uriPrefix
    if ($feed.format -eq 'base64-uri' -and $raw -notmatch [regex]::Escape($scheme)) {
        $raw = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($raw))
    }

    $endpoints = @()
    $pattern = '^' + [regex]::Escape($scheme) + '://[^@]+@([^:]+):(\d+)\?(.+)$'
    foreach ($line in ($raw -split '\s+')) {
        if (-not $line.StartsWith($scheme)) { continue }
        if ($line -notmatch $pattern) { continue }
        $hostName = $Matches[1]; $port = [int]$Matches[2]; $rest = $Matches[3]
        $label = ''
        if ($rest -match '#(.+)$') { $label = [System.Uri]::UnescapeDataString($Matches[1]) }
        $query = ($rest -split '#')[0]
        $attributes = @{}
        foreach ($pair in ($query -split '&')) {
            $eq = $pair.IndexOf('=')
            if ($eq -gt 0) { $attributes[$pair.Substring(0, $eq)] = $pair.Substring($eq + 1) }
        }
        $fields = @{ host = $hostName; port = $port }
        foreach ($key in $attributes.Keys) { $fields[$key] = $attributes[$key] }
        $endpoints += [pscustomobject]@{ Label = $label.Trim(); Host = $hostName; Port = $port; Fields = $fields }
    }
    return $endpoints
}

function Get-EndpointRank {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Endpoint)
    $rank = 90
    $table = $Config.service.catalog.PSObject.Properties['regionRank']
    if ($table) {
        foreach ($property in $table.Value.PSObject.Properties) {
            if ($Endpoint.Label -match [regex]::Escape($property.Name)) { $rank = [int]$property.Value; break }
        }
    }
    return $rank
}

#endregion

#region -------------------------------------------------- isolated candidate test

function Invoke-CandidateMeasurement {
    <#
        Measures candidates without touching the live service.

        Each candidate gets its own isolated instance: its own generated configuration file,
        its own local probe port and its own process, all started side by side and torn down
        afterwards. The instance shape comes from candidateTest.instanceTemplate, so the
        supervisor never needs to know the service's own schema - and because the live
        configuration is not touched until a winner has been chosen, probing candidates can
        never take production traffic down.

        Ranking uses the sum of both rounds. A single sample is dominated by noise: one such
        sample once promoted the endpoint with the worst true latency in the candidate set.
    #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][object[]]$Candidates)

    $test = $Config.service.candidateTest
    $selector = Get-Selector -Config $Config
    $template = [string]$test.instanceTemplate
    if (-not $template -and $test.PSObject.Properties.Name.Contains('instanceTemplateFile') -and $test.instanceTemplateFile) {
        $templatePath = [string]$test.instanceTemplateFile
        if (-not [System.IO.Path]::IsPathRooted($templatePath)) {
            $templatePath = Join-Path ([System.IO.Path]::GetDirectoryName($ConfigPath)) $templatePath
        }
        if (Test-Path -LiteralPath $templatePath) { $template = Read-TextFile -Path $templatePath }
    }
    if (-not $template) { Write-Log -Message 'candidateTest.instanceTemplate or instanceTemplateFile is required' -Path $Config.log; return @() }

    $liveText = Read-TextFile -Path $Config.service.configPath
    $liveBlock = Get-JsonObjectBlock -Text $liveText -Tag $selector.Tag -RequireProperty $selector.Required
    if (-not $liveBlock) { Write-Log -Message 'cannot build probe instances: endpoint block not found' -Path $Config.log; return @() }

    $workDir = [System.IO.Path]::GetDirectoryName($Config.service.configPath)
    $targets = Get-HealthTargets -Config $Config
    $instances = @()

    try {
        for ($i = 0; $i -lt $Candidates.Count; $i++) {
            $port = [int]$test.basePort + $i
            $tagPattern = '"tag"\s*:\s*"' + [regex]::Escape($selector.Tag) + '"'
            $tagValue = '"tag": "probe-out-' + $i + '"'
            $blockText = Set-RegexFirst -Text $liveBlock.Text -Pattern $tagPattern -Replacement $tagValue
            $blockText = Update-EndpointBlock -Config $Config -BlockText $blockText -Endpoint $Candidates[$i]
            $document = Expand-Template -Template $template -Tokens @{ index = $i; port = $port; outbound = $blockText }
            $configFile = Join-Path $workDir ('_probe-' + $PID + '-' + $i + '.json')
            Write-TextFile -Path $configFile -Text $document
            $arguments = ([string]$test.probeArguments).Replace('{config}', $configFile)
            $process = Start-Process -FilePath ([string]$test.probeExecutable) -ArgumentList $arguments -WindowStyle Hidden -PassThru
            $instances += [pscustomobject]@{
                Index = $i; Port = $port; Process = $process; ConfigFile = $configFile
                Candidate = $Candidates[$i]; Ready = $false
            }
        }

        foreach ($instance in $instances) {
            for ($attempt = 0; $attempt -lt 24; $attempt++) {
                if ($instance.Process.HasExited) { break }
                Start-Sleep -Milliseconds 500
                try {
                    $client = New-Object System.Net.Sockets.TcpClient
                    $iar = $client.BeginConnect('127.0.0.1', $instance.Port, $null, $null)
                    $ok = $iar.AsyncWaitHandle.WaitOne(500)
                    if ($ok) { $client.EndConnect($iar) }
                    $client.Close()
                    if ($ok) { $instance.Ready = $true; break }
                } catch { }
            }
        }
        if (-not ($instances | Where-Object { $_.Ready })) {
            Write-Log -Message 'no probe instance came up; skipping this failover round' -Path $Config.log
            return @()
        }

        $healthy = @()
        foreach ($instance in $instances) {
            if (-not $instance.Ready) {
                Write-Log -Message ('  candidate unreachable: {0} {1}:{2}' -f $instance.Candidate.Label, $instance.Candidate.Host, $instance.Candidate.Port) -Path $Config.log
                continue
            }
            if (@($healthy | Where-Object { $_.Score -ge $targets.Count }).Count -ge [int]$test.wantHealthy) { break }
            $score = 0; $totalMs = 0
            for ($round = 1; $round -le [int]$test.rounds; $round++) {
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                $roundScore = 0
                foreach ($target in $targets) {
                    if (Test-HealthTarget -Target $target -LocalPort $instance.Port -TimeoutSec ([int]$test.probeTimeoutSec)) { $roundScore++ }
                }
                $watch.Stop(); $totalMs += $watch.ElapsedMilliseconds
                if ($roundScore -gt $score) { $score = $roundScore }
            }
            if ($score -gt 0) {
                Write-Log -Message ('  candidate usable: {0} {1}:{2} probe {3}/{4}, two rounds {5}ms' -f $instance.Candidate.Label, $instance.Candidate.Host, $instance.Candidate.Port, $score, $targets.Count, $totalMs) -Path $Config.log
                $healthy += [pscustomobject]@{ Endpoint = $instance.Candidate; Ms = $totalMs; Score = $score }
            } else {
                Write-Log -Message ('  candidate unusable: {0} {1}:{2}' -f $instance.Candidate.Label, $instance.Candidate.Host, $instance.Candidate.Port) -Path $Config.log
            }
        }
        return ($healthy | Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Ms } })
    } finally {
        foreach ($instance in $instances) {
            if ($instance.Process -and -not $instance.Process.HasExited) { Stop-Process -Id $instance.Process.Id -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $instance.ConfigFile -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion

#region ------------------------------------------------------------------ service

function Start-ServiceProcess {
    param([Parameter(Mandatory)]$Config)
    $command = ([string]$Config.service.startCommand).Replace('{config}', [string]$Config.service.configPath)
    $parts = [regex]::Match($command, '^\s*"?([^"]+?)"?\s+(.+)$')
    if ($parts.Success) {
        Start-Process -FilePath $parts.Groups[1].Value -ArgumentList $parts.Groups[2].Value -WindowStyle Hidden
    } else {
        Start-Process -FilePath $command -WindowStyle Hidden
    }
}

function Restart-ServiceProcess {
    param([Parameter(Mandatory)]$Config, [int]$WaitSec = 40)
    $name = [string]$Config.service.processName
    Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { return $true }
    }
    Write-Log -Message 'external keeper did not restart the service in time; starting it here' -Path $Config.log
    Start-ServiceProcess -Config $Config
    Start-Sleep -Seconds 4
    return [bool](Get-Process -Name $name -ErrorAction SilentlyContinue)
}

function Test-UpstreamReachability {
    <# Separates "the dependency is down" from "this machine has no network at all". #>
    param([Parameter(Mandatory)]$Config)
    $targets = @()
    if ($Config.service.catalog.PSObject.Properties.Name.Contains('url') -and $Config.service.catalog.url) {
        $targets += ([string]$Config.service.catalog.url -replace '^https?://([^/:]+).*$', '$1')
    }
    $targets += '1.1.1.1'
    foreach ($target in $targets) {
        if (-not $target) { continue }
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($target, 443, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(5000)
            if ($ok) { $client.EndConnect($iar); $client.Close(); return $true }
            $client.Close()
        } catch { }
    }
    return $false
}

function Invoke-Failover {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Reason, [int]$CurrentScore = 0, [switch]$Force)
    $active = Get-ActiveEndpoint -Config $Config
    if (-not $active) { Write-Log -Message 'cannot read the active endpoint; aborting failover' -Path $Config.log; return $false }
    Write-Log -Message ('failover started ({0}); active endpoint {1}:{2}' -f $Reason, $active.Host, $active.Port) -Path $Config.log

    if (-not (Test-UpstreamReachability -Config $Config)) {
        Write-Log -Message 'local network looks unavailable; leaving everything alone' -Path $Config.log
        return $false
    }

    try { $all = Get-CatalogEndpoints -Config $Config }
    catch { Write-Log -Message ('catalog fetch failed: ' + $_.Exception.Message) -Path $Config.log; return $false }
    if (-not $all -or @($all).Count -eq 0) { Write-Log -Message 'catalog returned no usable endpoints' -Path $Config.log; return $false }

    $candidates = @($all |
        Where-Object { -not ($_.Host -eq $active.Host -and [int]$_.Port -eq $active.Port) } |
        Sort-Object @{ Expression = { Get-EndpointRank -Config $Config -Endpoint $_ } } |
        Select-Object -First ([int]$Config.service.catalog.maxCandidates))
    if ($candidates.Count -eq 0) { Write-Log -Message 'no candidates other than the active endpoint' -Path $Config.log; return $false }

    $healthy = @(Invoke-CandidateMeasurement -Config $Config -Candidates $candidates)
    if ($healthy.Count -eq 0) { Write-Log -Message 'no candidate passed the probe; keeping the current configuration' -Path $Config.log; return $false }

    if (-not $Force) {
        $better = @($healthy | Where-Object { $_.Score -gt $CurrentScore })
        if ($better.Count -eq 0) {
            Write-Log -Message ('no candidate beats the active score ({0}); standing pat' -f $CurrentScore) -Path $Config.log
            return $false
        }
        $healthy = $better
    }

    foreach ($entry in $healthy) {
        $endpoint = $entry.Endpoint
        Write-Log -Message ('trying {0} {1}:{2} (probe score {3})' -f $endpoint.Label, $endpoint.Host, $endpoint.Port, $entry.Score) -Path $Config.log
        if ($DryRun) { Write-Log -Message 'dry run: configuration left untouched' -Path $Config.log; return $true }
        if (-not (Set-ActiveEndpoint -Config $Config -Endpoint $endpoint)) { continue }
        Restart-ServiceProcess -Config $Config | Out-Null
        $score = Get-GatewayScore -Config $Config
        if ($score -ge 1) {
            Write-Log -Message ('switch complete: {0} {1}:{2} is serving (score {3})' -f $endpoint.Label, $endpoint.Host, $endpoint.Port, $score) -Path $Config.log
            return $true
        }
        Write-Log -Message ('{0} failed verification; trying the next candidate' -f $endpoint.Host) -Path $Config.log
    }
    Write-Log -Message 'every candidate failed verification; keeping the last written configuration' -Path $Config.log
    return $false
}

#endregion

#region --------------------------------------------------------------------- main

$config = Get-SupervisorConfig -Path $ConfigPath

# Thresholds come from the configuration file unless the caller passed them explicitly.
$policy = $config.PSObject.Properties['policy']
if ($policy -and $policy.Value) {
    $bound = $PSBoundParameters
    if (-not $bound.ContainsKey('CheckIntervalSec')  -and $policy.Value.PSObject.Properties.Name.Contains('checkIntervalSec'))  { $CheckIntervalSec  = [int]$policy.Value.checkIntervalSec }
    if (-not $bound.ContainsKey('FailThreshold')     -and $policy.Value.PSObject.Properties.Name.Contains('failThreshold'))     { $FailThreshold     = [int]$policy.Value.failThreshold }
    if (-not $bound.ContainsKey('DegradedThreshold') -and $policy.Value.PSObject.Properties.Name.Contains('degradedThreshold')) { $DegradedThreshold = [int]$policy.Value.degradedThreshold }
    if (-not $bound.ContainsKey('CooldownMin')       -and $policy.Value.PSObject.Properties.Name.Contains('cooldownMin'))       { $CooldownMin       = [int]$policy.Value.cooldownMin }
    if (-not $bound.ContainsKey('MissingThreshold')  -and $policy.Value.PSObject.Properties.Name.Contains('missingThreshold'))  { $MissingThreshold  = [int]$policy.Value.missingThreshold }
}

$logPath = [string]$config.log
$mutex = New-Object System.Threading.Mutex($false, ('Local\' + [string]$config.service.name + '-supervisor'))
if (-not $mutex.WaitOne(0)) { Write-Log -Message 'another supervisor instance is already running; exiting' -Path $logPath; exit 0 }

$active = Get-ActiveEndpoint -Config $config
$activeText = 'unknown'
if ($active) { $activeText = $active.Host + ':' + $active.Port }
Write-Log -Message ('supervisor started (interval {0}s, fail threshold {1}, degraded threshold {2}, cooldown {3}m, active {4})' -f $CheckIntervalSec, $FailThreshold, $DegradedThreshold, $CooldownMin, $activeText) -Path $logPath

$failures = 0; $degraded = 0; $missing = 0
$lastSwitch = [datetime]::MinValue
$serviceName = [string]$config.service.processName

while ($true) {
    if (-not (Get-Process -Name $serviceName -ErrorAction SilentlyContinue)) {
        $missing++
        if ($missing -eq 1) { Write-Log -Message 'service process is not running; deferring to the process keeper' -Path $logPath }
        if ($missing -ge $MissingThreshold) {
            Write-Log -Message ('service missing for {0} rounds and the process keeper has not acted; starting it here' -f $missing) -Path $logPath
            Start-ServiceProcess -Config $config
            Start-Sleep -Seconds 5
            if (Get-Process -Name $serviceName -ErrorAction SilentlyContinue) {
                Write-Log -Message 'service started by the supervisor' -Path $logPath
                $missing = 0
            }
        }
        $failures = 0; $degraded = 0
    }
    else {
        $missing = 0
        $score = Get-GatewayScore -Config $config
        if ($score -ge 2) {
            if ($failures -gt 0 -or $degraded -gt 0) { Write-Log -Message 'health restored' -Path $logPath }
            $failures = 0; $degraded = 0
            if ($ForceSwitch) {
                Invoke-Failover -Config $config -Reason 'forced re-selection' -CurrentScore $score -Force | Out-Null
                break
            }
        }
        elseif ($score -eq 1) {
            $failures = 0; $degraded++
            if ($degraded -eq 1) { Write-Log -Message 'degraded: not every health target answered' -Path $logPath }
            $shouldSwitch = ($degraded -ge $DegradedThreshold) -or $ForceSwitch -or $Once
            if ($shouldSwitch -and -not $ForceSwitch -and -not $Once -and ((Get-Date) - $lastSwitch).TotalMinutes -lt $CooldownMin) {
                Write-Log -Message ('degraded, but the cooldown window ({0}m) has not elapsed' -f $CooldownMin) -Path $logPath
                $shouldSwitch = $false
            }
            if ($shouldSwitch) {
                $reason = 'degraded for ' + $degraded + ' rounds'
                if ($ForceSwitch) { $reason = 'forced re-selection' }
                if (Invoke-Failover -Config $config -Reason $reason -CurrentScore $score -Force:$ForceSwitch) { $lastSwitch = Get-Date }
                $degraded = 0
                if ($ForceSwitch) { break }
            }
        }
        else {
            $degraded = 0; $failures++
            if ($failures -eq 1) { Write-Log -Message 'health check failed (round 1)' -Path $logPath }
            if ($ForceSwitch -or $failures -ge $FailThreshold -or $Once) {
                if (-not $ForceSwitch -and -not $Once -and ((Get-Date) - $lastSwitch).TotalMinutes -lt $CooldownMin) {
                    Write-Log -Message ('still unhealthy, but the cooldown window ({0}m) has not elapsed' -f $CooldownMin) -Path $logPath
                } else {
                    $reason = 'failed ' + $failures + ' consecutive rounds'
                    if ($ForceSwitch) { $reason = 'forced re-selection' }
                    if (Invoke-Failover -Config $config -Reason $reason -CurrentScore $score -Force:$ForceSwitch) { $lastSwitch = Get-Date }
                    $failures = 0
                    if ($ForceSwitch) { break }
                }
            }
        }
    }
    if ($Once) { break }
    Start-Sleep -Seconds $CheckIntervalSec
}

if ($Once) {
    $final = Get-GatewayScore -Config $config
    if ($final -ge 2) { Write-Log -Message 'check finished: healthy' -Path $logPath; exit 0 }
    if ($final -eq 1) { Write-Log -Message 'check finished: degraded, no better candidate available' -Path $logPath; exit 0 }
    Write-Log -Message 'check finished: unhealthy' -Path $logPath
    exit 1
}
exit 0

#endregion
