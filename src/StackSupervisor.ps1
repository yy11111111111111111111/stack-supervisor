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

function Replace-FileBytesAtomically {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [byte[]]$ExpectedBytes
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    $name = [System.IO.Path]::GetFileName($fullPath)
    $temporary = Join-Path $directory ('.' + $name + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $temporaryBackup = $temporary + '.previous'
    try {
        [System.IO.File]::WriteAllBytes($temporary, $Bytes)
        if ($null -ne $ExpectedBytes) {
            $currentBytes = [System.IO.File]::ReadAllBytes($fullPath)
            $same = $currentBytes.Length -eq $ExpectedBytes.Length
            if ($same) {
                for ($i = 0; $i -lt $currentBytes.Length; $i++) {
                    if ($currentBytes[$i] -ne $ExpectedBytes[$i]) { $same = $false; break }
                }
            }
            if (-not $same) { return $false }
        }
        [System.IO.File]::Replace($temporary, $fullPath, $temporaryBackup)
        return $true
    } finally {
        foreach ($temporaryPath in @($temporary, $temporaryBackup)) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Write-TextFileAtomically {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text, [byte[]]$ExpectedBytes)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($Text)
    return Replace-FileBytesAtomically -Path $Path -Bytes $bytes -ExpectedBytes $ExpectedBytes
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

function Skip-JsonWhitespace {
    param([Parameter(Mandatory)]$State)
    while ($State.Index -lt $State.Text.Length -and [int]$State.Text[$State.Index] -in @(9, 10, 13, 32)) {
        $State.Index++
    }
}

function Read-JsonStringToken {
    param([Parameter(Mandatory)]$State)
    if ($State.Index -ge $State.Text.Length -or $State.Text[$State.Index] -ne '"') {
        throw 'expected a JSON string'
    }
    $start = $State.Index
    $State.Index++
    $closed = $false
    $hasEscape = $false
    while ($State.Index -lt $State.Text.Length) {
        $ch = $State.Text[$State.Index]
        if ($ch -eq '"') {
            $State.Index++
            $closed = $true
            break
        }
        if ([int]$ch -lt 32) { throw 'unescaped control character in JSON string' }
        if ($ch -eq [char]92) {
            $hasEscape = $true
            $State.Index++
            if ($State.Index -ge $State.Text.Length) { throw 'incomplete JSON escape' }
            $escaped = $State.Text[$State.Index]
            if ($escaped -eq 'u') {
                if ($State.Index + 4 -ge $State.Text.Length) { throw 'incomplete JSON unicode escape' }
                $hex = $State.Text.Substring($State.Index + 1, 4)
                if ($hex -notmatch '^[0-9a-fA-F]{4}$') { throw 'invalid JSON unicode escape' }
                $State.Index += 5
                continue
            }
            $validEscapes = '"' + [char]92 + '/bfnrt'
            if ($validEscapes.IndexOf([string]$escaped, [System.StringComparison]::Ordinal) -lt 0) {
                throw 'invalid JSON escape'
            }
        }
        $State.Index++
    }
    if (-not $closed) { throw 'unterminated JSON string' }
    if ($hasEscape) {
        $raw = $State.Text.Substring($start, $State.Index - $start)
        $value = [string](ConvertFrom-Json -InputObject $raw -ErrorAction Stop)
    } else {
        # ConvertFrom-Json would turn text such as 2024-01-02T03:04:05Z into a [datetime] on PowerShell 7.
        $value = $State.Text.Substring($start + 1, $State.Index - $start - 2)
    }
    return [pscustomobject]@{ Start = $start; End = $State.Index; Value = $value }
}

function ConvertTo-JsonPointerSegment {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Segment)
    return $Segment.Replace('~', '~0').Replace('/', '~1')
}

function Read-JsonValueToken {
    param([Parameter(Mandatory)]$State, [string]$Path = '')
    Skip-JsonWhitespace -State $State
    if ($State.Index -ge $State.Text.Length) { throw 'unexpected end of JSON document' }
    $start = $State.Index
    $ch = $State.Text[$State.Index]

    if ($ch -eq '{') {
        $State.Index++
        Skip-JsonWhitespace -State $State
        $members = New-Object System.Collections.ArrayList
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        if ($State.Index -lt $State.Text.Length -and $State.Text[$State.Index] -eq '}') {
            $State.Index++
            return [pscustomobject]@{ Kind = 'Object'; Start = $start; End = $State.Index; Path = $Path; Value = $null; Members = @(); Items = @() }
        }
        while ($true) {
            Skip-JsonWhitespace -State $State
            $key = Read-JsonStringToken -State $State
            if (-not $seen.Add($key.Value)) { throw ('duplicate JSON property: ' + $key.Value) }
            Skip-JsonWhitespace -State $State
            if ($State.Index -ge $State.Text.Length -or $State.Text[$State.Index] -ne ':') { throw 'expected colon after JSON property name' }
            $State.Index++
            $childPath = $Path + '/' + (ConvertTo-JsonPointerSegment -Segment $key.Value)
            $child = Read-JsonValueToken -State $State -Path $childPath
            $members.Add([pscustomobject]@{ Name = $key.Value; KeyStart = $key.Start; Node = $child }) | Out-Null
            Skip-JsonWhitespace -State $State
            if ($State.Index -ge $State.Text.Length) { throw 'unterminated JSON object' }
            if ($State.Text[$State.Index] -eq '}') { $State.Index++; break }
            if ($State.Text[$State.Index] -ne ',') { throw 'expected comma or closing brace in JSON object' }
            $State.Index++
        }
        return [pscustomobject]@{ Kind = 'Object'; Start = $start; End = $State.Index; Path = $Path; Value = $null; Members = @($members.ToArray()); Items = @() }
    }

    if ($ch -eq '[') {
        $State.Index++
        Skip-JsonWhitespace -State $State
        $items = New-Object System.Collections.ArrayList
        if ($State.Index -lt $State.Text.Length -and $State.Text[$State.Index] -eq ']') {
            $State.Index++
            return [pscustomobject]@{ Kind = 'Array'; Start = $start; End = $State.Index; Path = $Path; Value = $null; Members = @(); Items = @() }
        }
        $index = 0
        while ($true) {
            $childPath = $Path + '/' + [string]$index
            $child = Read-JsonValueToken -State $State -Path $childPath
            $items.Add($child) | Out-Null
            $index++
            Skip-JsonWhitespace -State $State
            if ($State.Index -ge $State.Text.Length) { throw 'unterminated JSON array' }
            if ($State.Text[$State.Index] -eq ']') { $State.Index++; break }
            if ($State.Text[$State.Index] -ne ',') { throw 'expected comma or closing bracket in JSON array' }
            $State.Index++
        }
        return [pscustomobject]@{ Kind = 'Array'; Start = $start; End = $State.Index; Path = $Path; Value = $null; Members = @(); Items = @($items.ToArray()) }
    }

    if ($ch -eq '"') {
        $string = Read-JsonStringToken -State $State
        return [pscustomobject]@{ Kind = 'String'; Start = $string.Start; End = $string.End; Path = $Path; Value = $string.Value; Members = @(); Items = @() }
    }

    if ($ch -eq 't' -and $State.Index + 4 -le $State.Text.Length -and $State.Text.Substring($State.Index, 4) -ceq 'true') {
        $State.Index += 4
        return [pscustomobject]@{ Kind = 'Boolean'; Start = $start; End = $State.Index; Path = $Path; Value = $true; Members = @(); Items = @() }
    }
    if ($ch -eq 'f' -and $State.Index + 5 -le $State.Text.Length -and $State.Text.Substring($State.Index, 5) -ceq 'false') {
        $State.Index += 5
        return [pscustomobject]@{ Kind = 'Boolean'; Start = $start; End = $State.Index; Path = $Path; Value = $false; Members = @(); Items = @() }
    }
    if ($ch -eq 'n' -and $State.Index + 4 -le $State.Text.Length -and $State.Text.Substring($State.Index, 4) -ceq 'null') {
        $State.Index += 4
        return [pscustomobject]@{ Kind = 'Null'; Start = $start; End = $State.Index; Path = $Path; Value = $null; Members = @(); Items = @() }
    }
    $tokenEnd = $State.Index
    while ($tokenEnd -lt $State.Text.Length) {
        $tokenChar = $State.Text[$tokenEnd]
        $tokenCode = [int]$tokenChar
        if ($tokenCode -eq 9 -or $tokenCode -eq 10 -or $tokenCode -eq 13 -or $tokenCode -eq 32 -or
            $tokenChar -eq ',' -or $tokenChar -eq ']' -or $tokenChar -eq '}') { break }
        $tokenEnd++
    }
    $numberText = $State.Text.Substring($State.Index, $tokenEnd - $State.Index)
    $number = [regex]::Match($numberText, '^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?')
    if ($number.Success) {
        $State.Index += $number.Length
        return [pscustomobject]@{ Kind = 'Number'; Start = $start; End = $State.Index; Path = $Path; Value = $number.Value; Members = @(); Items = @() }
    }
    throw 'invalid JSON value'
}

function Get-JsonErrorLocation {
    <# Turns a character offset into 'line L, column C' for messages. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [int]$Offset)
    if ($Offset -lt 0) { $Offset = 0 }
    if ($Offset -gt $Text.Length) { $Offset = $Text.Length }
    $lines = $Text.Substring(0, $Offset).Split([char]10)
    return ('line {0}, column {1}' -f $lines.Length, ($lines[$lines.Length - 1].Length + 1))
}

function Get-JsonDocumentTree {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $state = @{ Text = $Text; Index = 0 }
    try {
        $root = Read-JsonValueToken -State $state
        Skip-JsonWhitespace -State $state
        if ($state.Index -ne $Text.Length) { throw 'unexpected content after the JSON value' }
    } catch {
        $detail = $_.Exception.Message
        throw ('JSON syntax error at {0}: {1}' -f (Get-JsonErrorLocation -Text $Text -Offset $state.Index), $detail)
    }
    return $root
}

function Get-JsonMemberNode {
    param([Parameter(Mandatory)]$Node, [Parameter(Mandatory)][string]$Name)
    if ($Node.Kind -ne 'Object') { return $null }
    foreach ($member in $Node.Members) {
        if ([string]::Equals([string]$member.Name, $Name, [System.StringComparison]::Ordinal)) { return $member.Node }
    }
    return $null
}

function Get-JsonPathNode {
    param([Parameter(Mandatory)]$Node, [Parameter(Mandatory)][string]$Path)
    $current = $Node
    foreach ($segment in $Path.Split('.')) {
        $match = [regex]::Match($segment, '^([^\[\]]+)(?:\[(\d+)\])?$')
        if (-not $match.Success) { return $null }
        $current = Get-JsonMemberNode -Node $current -Name $match.Groups[1].Value
        if (-not $current) { return $null }
        if ($match.Groups[2].Success) {
            if ($current.Kind -ne 'Array') { return $null }
            $index = [int]$match.Groups[2].Value
            if ($index -ge $current.Items.Count) { return $null }
            $current = $current.Items[$index]
        }
    }
    return $current
}

function Get-JsonNodeByPointer {
    param([Parameter(Mandatory)]$Root, [Parameter(Mandatory)][AllowEmptyString()][string]$Pointer)
    if (-not $Pointer) { return $Root }
    if (-not $Pointer.StartsWith('/')) { return $null }
    $current = $Root
    foreach ($rawSegment in $Pointer.Substring(1).Split('/')) {
        $segment = $rawSegment.Replace('~1', '/').Replace('~0', '~')
        if ($current.Kind -eq 'Object') {
            $current = Get-JsonMemberNode -Node $current -Name $segment
        } elseif ($current.Kind -eq 'Array' -and $segment -match '^\d+$') {
            $index = [int]$segment
            if ($index -ge $current.Items.Count) { return $null }
            $current = $current.Items[$index]
        } else { return $null }
        if (-not $current) { return $null }
    }
    return $current
}

function Get-JsonObjectNodes {
    param([Parameter(Mandatory)]$Node)
    if ($Node.Kind -eq 'Object') {
        Write-Output -NoEnumerate $Node
        foreach ($member in $Node.Members) { Get-JsonObjectNodes -Node $member.Node }
    } elseif ($Node.Kind -eq 'Array') {
        foreach ($item in $Node.Items) { Get-JsonObjectNodes -Node $item }
    }
}

function Get-JsonObjectBlock {
    <#
        Finds exactly one JSON object with a direct tag property and all required siblings, or returns $null.
        -Reason receives the explanation for a $null result (syntax error with its position, no match, or the
        paths of an ambiguous match) so that callers can log why.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Tag,
        [string[]]$RequireProperty = @(),
        [ref]$Reason
    )
    try { $root = Get-JsonDocumentTree -Text $Text }
    catch {
        if ($Reason) { $Reason.Value = $_.Exception.Message }
        return $null
    }
    $found = New-Object System.Collections.ArrayList
    foreach ($candidate in @(Get-JsonObjectNodes -Node $root)) {
        $tagNode = Get-JsonMemberNode -Node $candidate -Name 'tag'
        if (-not $tagNode -or $tagNode.Kind -ne 'String' -or $tagNode.Value -cne $Tag) { continue }
        $accepted = $true
        foreach ($property in $RequireProperty) {
            if (-not (Get-JsonMemberNode -Node $candidate -Name ([string]$property))) { $accepted = $false; break }
        }
        if ($accepted) { $found.Add($candidate) | Out-Null }
    }
    if ($found.Count -ne 1) {
        if ($Reason) {
            $needs = ''
            if (@($RequireProperty).Count -gt 0) { $needs = ' with the properties ' + (@($RequireProperty) -join ', ') }
            if ($found.Count -eq 0) {
                $Reason.Value = "no JSON object has tag '$Tag'$needs"
            } else {
                $paths = @($found | ForEach-Object { $_.Path }) -join ', '
                $Reason.Value = "$($found.Count) JSON objects have tag '$Tag'$needs (paths $paths); refusing to choose one"
            }
        }
        return $null
    }
    $object = $found[0]
    return [pscustomobject]@{
        Start = $object.Start
        End = $object.End
        Path = $object.Path
        Text = $Text.Substring($object.Start, $object.End - $object.Start)
    }
}

function Set-JsonStringPathValue {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Value)
    $tree = Get-JsonDocumentTree -Text $Text
    $node = Get-JsonPathNode -Node $tree -Path $Path
    if (-not $node -or $node.Kind -ne 'String') { throw ('JSON path is not a string value: ' + $Path) }
    $rawValue = [string](ConvertTo-Json -InputObject $Value -Compress -Depth 100)
    return $Text.Substring(0, $node.Start) + $rawValue + $Text.Substring($node.End)
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

function Read-HttpHeaderBlock {
    <# Reads through CRLF CRLF without buffering or consuming bytes from the next protocol layer. #>
    param([Parameter(Mandatory)][System.IO.Stream]$Stream, [int]$MaxBytes = 65536)
    $header = New-Object System.IO.MemoryStream
    $one = New-Object byte[] 1
    $matched = 0
    try {
        while ($header.Length -lt $MaxBytes) {
            $read = $Stream.Read($one, 0, 1)
            if ($read -le 0) { throw 'connection closed before HTTP headers completed' }
            $byte = $one[0]
            $header.WriteByte($byte)
            switch ($matched) {
                0 { if ($byte -eq 13) { $matched = 1 } }
                1 {
                    if ($byte -eq 10) { $matched = 2 }
                    elseif ($byte -eq 13) { $matched = 1 }
                    else { $matched = 0 }
                }
                2 { if ($byte -eq 13) { $matched = 3 } else { $matched = 0 } }
                3 {
                    if ($byte -eq 10) { return [System.Text.Encoding]::ASCII.GetString($header.ToArray()) }
                    elseif ($byte -eq 13) { $matched = 1 }
                    else { $matched = 0 }
                }
            }
        }
        throw ('HTTP headers exceeded the {0}-byte limit' -f $MaxBytes)
    } finally { $header.Dispose() }
}

function Get-ProbeCertificateCallback {
    <#
        Returns the certificate validation callback a probe connection should use.

        $null means "let SslStream apply the platform check", which is the default. Accepting an
        untrusted certificate is opt-in, because a probe that accepts anything reports a
        hijacked endpoint as healthy - a false pass is worse here than a false failure.
    #>
    param([switch]$AllowUntrusted)
    if (-not $AllowUntrusted) { return $null }
    return [System.Net.Security.RemoteCertificateValidationCallback] {
        param($sender, $certificate, $chain, $errors)
        return $true
    }
}

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
        [switch]$NoTls,
        [switch]$AllowUntrustedCertificate
    )
    $uri = [System.Uri]$Url
    $client = New-Object System.Net.Sockets.TcpClient
    $ssl = $null
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

        $connectResponse = Read-HttpHeaderBlock -Stream $stream
        $status = ($connectResponse -split "`r`n", 2)[0]
        if (-not $status -or $status -notmatch '^HTTP/\d(?:\.\d)?\s+200(?:\s|$)') { throw "endpoint refused CONNECT: $status" }

        $active = $stream
        if (-not $NoTls) {
            $callback = Get-ProbeCertificateCallback -AllowUntrusted:$AllowUntrustedCertificate
            if ($callback) {
                $ssl = New-Object System.Net.Security.SslStream($stream, $false, $callback)
            } else {
                $ssl = New-Object System.Net.Security.SslStream($stream, $false)
            }
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
    } finally {
        if ($ssl) { $ssl.Dispose() }
        $client.Close()
    }
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
    if (-not (Test-Path -LiteralPath $Config.service.configPath)) {
        Write-Log -Message ('configuration file not found: ' + $Config.service.configPath) -Path $Config.log
        return $null
    }
    $text = Read-TextFile -Path $Config.service.configPath
    $why = ''
    $block = Get-JsonObjectBlock -Text $text -Tag $selector.Tag -RequireProperty $selector.Required -Reason ([ref]$why)
    if (-not $block) {
        Write-Log -Message ('active endpoint not found: ' + $why) -Path $Config.log
        return $null
    }
    $object = $block.Text | ConvertFrom-Json
    $fields = @{}
    foreach ($property in $selector.Read.PSObject.Properties) {
        $fields[$property.Name] = Get-JsonPathValue -Object $object -Path ([string]$property.Value)
    }
    if (-not $fields.ContainsKey('host') -or -not $fields.ContainsKey('port') -or $null -eq $fields['host'] -or $null -eq $fields['port']) {
        Write-Log -Message ('readFields host/port did not resolve in the endpoint object at ' + $block.Path) -Path $Config.log
        return $null
    }
    return [pscustomobject]@{ Host = [string]$fields['host']; Port = [int]$fields['port']; Fields = $fields }
}

function Update-EndpointBlock {
    <# Applies path-based source-span patches, then compatible unique legacy regex patches. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$BlockText, [Parameter(Mandatory)]$Endpoint)
    $selector = Get-Selector -Config $Config
    $tokens = @{ host = $Endpoint.Host; port = $Endpoint.Port }
    foreach ($key in $Endpoint.Fields.Keys) {
        if ($key -ne 'host' -and $key -ne 'port' -and $null -ne $Endpoint.Fields[$key]) {
            $tokens['attr:' + $key] = [string]$Endpoint.Fields[$key]
        }
    }
    $patched = $BlockText
    $tree = Get-JsonDocumentTree -Text $BlockText
    $edits = New-Object System.Collections.ArrayList
    $legacyRules = New-Object System.Collections.ArrayList
    $usedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($rule in $selector.Patch) {
        $pathProperty = $rule.PSObject.Properties['path']
        $valueProperty = $rule.PSObject.Properties['value']
        if ($pathProperty -and $valueProperty) {
            $path = [string]$pathProperty.Value
            if (-not $usedPaths.Add($path)) { throw ('duplicate patch path: ' + $path) }
            $template = [string]$valueProperty.Value
            $skip = $false
            foreach ($match in [regex]::Matches($template, '\{attr:([^\}]+)\}')) {
                if (-not $tokens.ContainsKey('attr:' + $match.Groups[1].Value)) { $skip = $true; break }
            }
            # An optional attribute the candidate does not carry switches the rule off, exactly as it does for
            # legacy rules. Only a rule that is going to write needs its path to exist.
            if ($skip) { continue }
            $node = Get-JsonPathNode -Node $tree -Path $path
            if (-not $node) { throw ('patch path does not exist: ' + $path) }
            if ($node.Kind -notin @('String', 'Number', 'Boolean')) { throw ('patch path is not a scalar value: ' + $path) }
            $value = Expand-Template -Template $template -Tokens $tokens
            if ($node.Kind -eq 'String') {
                $rawValue = [string](ConvertTo-Json -InputObject ([string]$value) -Compress -Depth 100)
            } elseif ($node.Kind -eq 'Number') {
                if ($value -notmatch '^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$') {
                    throw ('patch value is not a JSON number for path: ' + $path)
                }
                $rawValue = [string]$value
            } else {
                $rawValue = ([string]$value).ToLowerInvariant()
                if ($rawValue -notin @('true', 'false')) { throw ('patch value is not a JSON boolean for path: ' + $path) }
            }
            $edits.Add([pscustomobject]@{ Start = $node.Start; End = $node.End; Text = $rawValue }) | Out-Null
            continue
        }

        # Existing configurations may still use pattern/replacement. Keep them safe by
        # refusing zero or multiple matches instead of silently patching the first one.
        if (-not $rule.PSObject.Properties['pattern'] -or -not $rule.PSObject.Properties['replacement']) {
            throw 'patch rule must define either path/value or pattern/replacement'
        }
        $legacyRules.Add($rule) | Out-Null
    }
    foreach ($edit in @($edits | Sort-Object -Property Start -Descending)) {
        $patched = $patched.Substring(0, $edit.Start) + $edit.Text + $patched.Substring($edit.End)
    }
    foreach ($rule in $legacyRules) {
        $replacement = [string]$rule.replacement
        $skip = $false
        foreach ($match in [regex]::Matches($replacement, '\{attr:([^\}]+)\}')) {
            $name = $match.Groups[1].Value
            if (-not $tokens.ContainsKey('attr:' + $name)) { $skip = $true; break }
        }
        if ($skip) { continue }
        $pattern = [string]$rule.pattern
        $matches = [regex]::Matches($patched, $pattern)
        if ($matches.Count -ne 1) { throw ('legacy patch pattern must match exactly once: ' + $pattern) }
        $match = $matches[0]
        $replacement = Expand-Template -Template $replacement -Tokens $tokens
        $patched = $patched.Substring(0, $match.Index) + $replacement + $patched.Substring($match.Index + $match.Length)
    }
    return $patched
}

function Set-ActiveEndpoint {
    <# Backs up the configuration, patches the endpoint in place, validates, then writes. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Endpoint)
    $path = $Config.service.configPath
    $selector = Get-Selector -Config $Config
    $originalBytes = [System.IO.File]::ReadAllBytes([string]$path)
    $text = Read-TextFile -Path $path
    $why = ''
    $block = Get-JsonObjectBlock -Text $text -Tag $selector.Tag -RequireProperty $selector.Required -Reason ([ref]$why)
    if (-not $block) { Write-Log -Message ('endpoint block not found; refusing to write: ' + $why) -Path $Config.log; return $false }

    try {
        $updated = $text.Substring(0, $block.Start) + (Update-EndpointBlock -Config $Config -BlockText $block.Text -Endpoint $Endpoint) + $text.Substring($block.End)
        $parsed = ConvertFrom-Json -InputObject $updated -ErrorAction Stop
        $tree = Get-JsonDocumentTree -Text $updated
        $object = Get-JsonNodeByPointer -Root $tree -Pointer $block.Path
        if (-not $object -or $object.Kind -ne 'Object') { Write-Log -Message 'read-back could not locate the patched endpoint path' -Path $Config.log; return $false }
        $hostNode = Get-JsonPathNode -Node $object -Path ([string]$selector.Read.host)
        $portNode = Get-JsonPathNode -Node $object -Path ([string]$selector.Read.port)
        if (-not $hostNode -or -not $portNode) { Write-Log -Message 'read-back could not resolve endpoint fields at the selected path' -Path $Config.log; return $false }
        $readBackHost = $hostNode.Value
        $port = $portNode.Value
        if ([string]$readBackHost -ne [string]$Endpoint.Host -or [int]$port -ne [int]$Endpoint.Port) {
            Write-Log -Message 'read-back validation failed; refusing to write' -Path $Config.log
            return $false
        }
    } catch {
        Write-Log -Message ('patch or read-back validation failed; refusing to write: ' + $_.Exception.Message) -Path $Config.log
        return $false
    }

    $backupDir = [string]$Config.service.backupDir
    if ($backupDir) {
        if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
        $stamp = Get-Date -Format 'yyyyMMddHHmmss'
        [System.IO.File]::WriteAllBytes((Join-Path $backupDir ('config-' + $stamp + '.json')), $originalBytes)
        Get-ChildItem -LiteralPath $backupDir -Filter 'config-*.json' | Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 10 | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    try { $written = Write-TextFileAtomically -Path $path -Text $updated -ExpectedBytes $originalBytes }
    catch {
        Write-Log -Message ('could not atomically replace the configuration: ' + $_.Exception.Message) -Path $Config.log
        return $false
    }
    if (-not $written) {
        Write-Log -Message 'configuration changed after it was read; refusing to overwrite it' -Path $Config.log
        return $false
    }
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
    $scheme = ([string]$feed.uriPrefix).Trim()
    if ($scheme.EndsWith('://', [System.StringComparison]::Ordinal)) {
        $scheme = $scheme.Substring(0, $scheme.Length - 3)
    }
    if (-not $scheme) { Write-Log -Message 'catalog uriPrefix must name a URI scheme' -Path $Config.log; return @() }
    $schemePattern = [regex]::Escape($scheme) + '://'
    if ($feed.format -eq 'base64-uri' -and $raw -notmatch $schemePattern) {
        $raw = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($raw))
    }

    $endpoints = @()
    $pattern = '^' + $schemePattern + '[^@]+@([^:]+):(\d+)\?(.+)$'
    foreach ($line in ($raw -split '\s+')) {
        if (-not $line.StartsWith($scheme + '://', [System.StringComparison]::Ordinal)) { continue }
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

function Get-CandidateStableScore {
    param([int[]]$RoundScores = @())
    if (-not $RoundScores -or $RoundScores.Count -eq 0) { return 0 }
    $score = [int]::MaxValue
    foreach ($roundScore in $RoundScores) {
        if ($roundScore -lt $score) { $score = $roundScore }
    }
    return $score
}

function Invoke-CandidateMeasurement {
    <#
        Measures candidates without touching the live service.

        Each candidate gets its own isolated instance: its own generated configuration file,
        its own local probe port and its own process, all started side by side and torn down
        afterwards. The instance shape comes from candidateTest.instanceTemplate, so the
        supervisor never needs to know the service's own schema - and because the live
        configuration is not touched until a winner has been chosen, probing candidates can
        never take production traffic down.

        The availability score is the lowest score across rounds, so a single good sample
        cannot hide an unstable candidate. Ties are ranked by total elapsed milliseconds.
    #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][object[]]$Candidates)

    $test = $Config.service.candidateTest
    $selector = Get-Selector -Config $Config
    # Both spellings are optional, so neither may be read under StrictMode without checking.
    $template = ''
    if ($test.PSObject.Properties.Name.Contains('instanceTemplate')) { $template = [string]$test.instanceTemplate }
    if (-not $template -and $test.PSObject.Properties.Name.Contains('instanceTemplateFile') -and $test.instanceTemplateFile) {
        $templatePath = [string]$test.instanceTemplateFile
        if (-not [System.IO.Path]::IsPathRooted($templatePath)) {
            $templatePath = Join-Path ([System.IO.Path]::GetDirectoryName($Config.service.configPath)) $templatePath
        }
        if (Test-Path -LiteralPath $templatePath) { $template = Read-TextFile -Path $templatePath }
    }
    if (-not $template) { Write-Log -Message 'candidateTest.instanceTemplate or instanceTemplateFile is required' -Path $Config.log; return @() }

    $liveText = Read-TextFile -Path $Config.service.configPath
    $why = ''
    $liveBlock = Get-JsonObjectBlock -Text $liveText -Tag $selector.Tag -RequireProperty $selector.Required -Reason ([ref]$why)
    if (-not $liveBlock) { Write-Log -Message ('cannot build probe instances: endpoint block not found: ' + $why) -Path $Config.log; return @() }

    $workDir = [System.IO.Path]::GetDirectoryName($Config.service.configPath)
    $targets = Get-HealthTargets -Config $Config
    $instances = @()

    try {
        for ($i = 0; $i -lt $Candidates.Count; $i++) {
            $port = [int]$test.basePort + $i
            try {
                $blockText = Set-JsonStringPathValue -Text $liveBlock.Text -Path 'tag' -Value ('probe-out-' + $i)
                $blockText = Update-EndpointBlock -Config $Config -BlockText $blockText -Endpoint $Candidates[$i]
            } catch {
                Write-Log -Message ('  cannot build a probe instance for {0} {1}:{2}: {3}' -f $Candidates[$i].Label, $Candidates[$i].Host, $Candidates[$i].Port, $_.Exception.Message) -Path $Config.log
                continue
            }
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
            $roundScores = @(); $totalMs = 0
            for ($round = 1; $round -le [int]$test.rounds; $round++) {
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                $roundScore = 0
                foreach ($target in $targets) {
                    if (Test-HealthTarget -Target $target -LocalPort $instance.Port -TimeoutSec ([int]$test.probeTimeoutSec)) { $roundScore++ }
                }
                $watch.Stop(); $totalMs += $watch.ElapsedMilliseconds
                $roundScores += $roundScore
            }
            $score = Get-CandidateStableScore -RoundScores $roundScores
            if ($score -gt 0) {
                Write-Log -Message ('  candidate usable: {0} {1}:{2} probe {3}/{4} over {5} rounds, {6}ms total' -f $instance.Candidate.Label, $instance.Candidate.Host, $instance.Candidate.Port, $score, $targets.Count, $test.rounds, $totalMs) -Path $Config.log
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

function ConvertTo-ProcessStartInfo {
    <#
        Splits a configured command line into an executable and an argument string.

        A quoted executable is taken verbatim. An unquoted one may not contain whitespace,
        because guessing where the path ends is exactly how a configured
        "C:\Program Files\App\svc.exe" becomes FilePath "C:\Program" with an argument string
        that starts with "Files\App\...", after which the service never starts and nothing is
        logged. Anything ambiguous throws instead of guessing.
    #>
    param([Parameter(Mandatory)][string]$Command)
    $match = [regex]::Match($Command.Trim(), '^(?:"([^"]+)"|(\S+))(?:\s+([\s\S]+))?$')
    if (-not $match.Success) { throw ('cannot parse the service start command: ' + $Command) }
    if ($match.Groups[1].Success) { $file = $match.Groups[1].Value } else { $file = $match.Groups[2].Value }
    if (-not [System.IO.Path]::IsPathRooted($file)) {
        throw ('the service start command does not begin with an absolute executable path: ' + $Command)
    }
    $arguments = ''
    if ($match.Groups[3].Success) { $arguments = $match.Groups[3].Value }
    return [pscustomobject]@{ FilePath = $file; Arguments = $arguments }
}

function Start-ServiceProcess {
    <#
        Starts the service. Explicit startExecutable/startArguments win; startCommand is still
        accepted but has to survive parsing without ambiguity.
    #>
    param([Parameter(Mandatory)]$Config)
    if ($Config.service.PSObject.Properties.Name.Contains('startExecutable') -and $Config.service.startExecutable) {
        $executable = [string]$Config.service.startExecutable
        $arguments = ''
        if ($Config.service.PSObject.Properties.Name.Contains('startArguments') -and $Config.service.startArguments) {
            $arguments = ([string]$Config.service.startArguments).Replace('{config}', [string]$Config.service.configPath)
        }
    } else {
        $command = ([string]$Config.service.startCommand).Replace('{config}', [string]$Config.service.configPath)
        $startInfo = ConvertTo-ProcessStartInfo -Command $command
        $executable = $startInfo.FilePath
        $arguments = $startInfo.Arguments
    }
    Start-Process -FilePath $executable -ArgumentList $arguments -WindowStyle Hidden
    return $executable
}

function Get-ServiceProcessSnapshot {
    <#
        Separates same-name processes from the unique instance identified by its config path. Reason says in
        words why the answer is what it is: the supervisor runs hidden, and 'ambiguous' alone does not tell an
        operator what to fix.
    #>
    param([Parameter(Mandatory)]$Config)
    $name = [System.IO.Path]::GetFileName([string]$Config.service.processName)
    if ([System.IO.Path]::GetExtension($name) -eq '') { $name += '.exe' }
    $filter = "Name='" + $name.Replace("'", "''") + "'"
    $processes = @(Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction Stop)
    # Both sides use backslashes, so the comparison does not depend on how either path was written.
    $configPath = [System.IO.Path]::GetFullPath([string]$Config.service.configPath).Replace('/', '\')
    $matching = @($processes | Where-Object {
        $_.CommandLine -and ([string]$_.CommandLine).Replace('/', '\').IndexOf($configPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    if ($processes.Count -eq 0) {
        $reason = "no process named $name is running"
    } elseif ($matching.Count -eq 1) {
        $reason = "exactly one $name process carries $configPath in its command line"
    } elseif ($matching.Count -gt 1) {
        $reason = "$($matching.Count) $name processes carry $configPath in their command lines"
    } else {
        $reason = "$($processes.Count) $name process(es) are running but none carries $configPath in its command line; start the service with the absolute configPath"
        $unreadable = @($processes | Where-Object { -not $_.CommandLine }).Count
        if ($unreadable -gt 0) { $reason += " ($unreadable command line(s) could not be read; the supervisor may lack the rights to see them)" }
    }
    return [pscustomobject]@{ Processes = $processes; Matching = $matching; Reason = $reason }
}

function Get-ServiceProcessCandidates {
    param([Parameter(Mandatory)]$Config)
    $snapshot = Get-ServiceProcessSnapshot -Config $Config
    return @($snapshot.Matching)
}

function Restart-ServiceProcess {
    param([Parameter(Mandatory)]$Config, [int]$WaitSec = 40)
    try { $targets = @(Get-ServiceProcessCandidates -Config $Config) }
    catch {
        Write-Log -Message ('cannot inspect service processes; refusing to restart: ' + $_.Exception.Message) -Path $Config.log
        return $false
    }
    if ($targets.Count -ne 1) {
        Write-Log -Message ('cannot safely identify one configured service process (found {0}); refusing to stop processes by name' -f $targets.Count) -Path $Config.log
        return $false
    }
    $targetId = [int]$targets[0].ProcessId
    Stop-Process -Id $targetId -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        try { $running = @(Get-ServiceProcessCandidates -Config $Config) }
        catch {
            Write-Log -Message ('cannot inspect service processes during restart: ' + $_.Exception.Message) -Path $Config.log
            return $false
        }
        if ($running.Count -gt 1) {
            Write-Log -Message 'multiple configured service processes appeared during restart; refusing to choose one' -Path $Config.log
            return $false
        }
        if ($running.Count -eq 1 -and [int]$running[0].ProcessId -ne $targetId) { return $true }
        Start-Sleep -Seconds 2
    }
    try { $remaining = @(Get-ServiceProcessCandidates -Config $Config) }
    catch {
        Write-Log -Message ('cannot verify service stop; refusing to start another instance: ' + $_.Exception.Message) -Path $Config.log
        return $false
    }
    if ($remaining.Count -gt 1) {
        Write-Log -Message 'multiple configured service processes appeared during restart; refusing to start another instance' -Path $Config.log
        return $false
    }
    if ($remaining.Count -eq 1 -and [int]$remaining[0].ProcessId -ne $targetId) { return $true }
    if ($remaining.Count -eq 1) {
        Write-Log -Message 'configured service process did not stop in time; refusing to start another instance' -Path $Config.log
        return $false
    }
    Write-Log -Message 'external keeper did not restart the service in time; starting it here' -Path $Config.log
    Start-ServiceProcess -Config $Config
    $startDeadline = (Get-Date).AddSeconds([Math]::Max(4, $WaitSec))
    while ((Get-Date) -lt $startDeadline) {
        try { $running = @(Get-ServiceProcessCandidates -Config $Config) }
        catch {
            Write-Log -Message ('cannot verify service start: ' + $_.Exception.Message) -Path $Config.log
            return $false
        }
        if ($running.Count -eq 1) { return $true }
        if ($running.Count -gt 1) {
            Write-Log -Message 'multiple configured service processes appeared after restart' -Path $Config.log
            return $false
        }
        Start-Sleep -Seconds 1
    }
    return $false
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

function Restore-ConfigBytes {
    <# Puts back the exact bytes that were read before the first write of a failover attempt. #>
    param([Parameter(Mandatory)]$Config, $Bytes)
    if ($null -eq $Bytes) {
        Write-Log -Message 'no copy of the previous configuration is available to restore' -Path $Config.log
        return $false
    }
    try {
        if (-not (Replace-FileBytesAtomically -Path ([string]$Config.service.configPath) -Bytes ([byte[]]$Bytes))) {
            Write-Log -Message 'could not atomically restore the previous configuration' -Path $Config.log
            return $false
        }
        Write-Log -Message 'previous configuration restored' -Path $Config.log
        return $true
    } catch {
        Write-Log -Message ('could not restore the previous configuration: ' + $_.Exception.Message) -Path $Config.log
        return $false
    }
}

function Invoke-Failover {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Reason, [int]$CurrentScore = 0, [switch]$Force, [switch]$DryRun)
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

    $originalBytes = $null
    foreach ($entry in $healthy) {
        $endpoint = $entry.Endpoint
        Write-Log -Message ('trying {0} {1}:{2} (probe score {3})' -f $endpoint.Label, $endpoint.Host, $endpoint.Port, $entry.Score) -Path $Config.log
        if ($DryRun) { Write-Log -Message 'dry run: configuration left untouched' -Path $Config.log; return $true }
        if ($null -eq $originalBytes) {
            try { $originalBytes = [System.IO.File]::ReadAllBytes([string]$Config.service.configPath) } catch { $originalBytes = $null }
        }
        if (-not (Set-ActiveEndpoint -Config $Config -Endpoint $endpoint)) { continue }
        if (-not (Restart-ServiceProcess -Config $Config)) {
            # The file has changed but the service did not follow. Scoring now would measure the old process and could
            # report a switch that never took effect, so put the file back and let a later round decide again.
            Write-Log -Message 'the service did not restart; restoring the previous configuration so the file matches the running process' -Path $Config.log
            Restore-ConfigBytes -Config $Config -Bytes $originalBytes | Out-Null
            return $false
        }
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

function Invoke-FailoverGuarded {
    <#
        The supervisor runs hidden, so an uncaught exception ends the process without a trace in the
        log. A failover that throws is treated like one that found nothing: log it, report failure,
        and let the next round decide again.
    #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Reason, [int]$CurrentScore = 0, [switch]$Force, [switch]$DryRun)
    try {
        return [bool](Invoke-Failover -Config $Config -Reason $Reason -CurrentScore $CurrentScore -Force:$Force -DryRun:$DryRun)
    } catch {
        Write-Log -Message ('failover aborted by an unexpected error: {0} (line {1})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) -Path $Config.log
        return $false
    }
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

while ($true) {
    try { $serviceState = Get-ServiceProcessSnapshot -Config $config }
    catch {
        Write-Log -Message ('cannot inspect service processes; deferring recovery: ' + $_.Exception.Message) -Path $logPath
        $missing = 0; $failures = 0; $degraded = 0
        if ($Once) { break }
        Start-Sleep -Seconds $CheckIntervalSec
        continue
    }
    if ($serviceState.Matching.Count -gt 1 -or ($serviceState.Processes.Count -gt 0 -and $serviceState.Matching.Count -eq 0)) {
        Write-Log -Message ('service executable is present but its configured instance is ambiguous; deferring recovery: ' + $serviceState.Reason) -Path $logPath
        $missing = 0; $failures = 0; $degraded = 0
        if ($Once) { break }
        Start-Sleep -Seconds $CheckIntervalSec
        continue
    }
    if ($serviceState.Matching.Count -eq 0) {
        $missing++
        if ($missing -eq 1) { Write-Log -Message 'service process is not running; deferring to the process keeper' -Path $logPath }
        if ($missing -ge $MissingThreshold) {
            Write-Log -Message ('service missing for {0} rounds and the process keeper has not acted; starting it here' -f $missing) -Path $logPath
            try { Start-ServiceProcess -Config $config }
            catch { Write-Log -Message ('could not start the service: ' + $_.Exception.Message) -Path $logPath }
            Start-Sleep -Seconds 5
            try { $startedState = Get-ServiceProcessSnapshot -Config $config }
            catch {
                Write-Log -Message ('cannot verify service start; will not launch another instance yet: ' + $_.Exception.Message) -Path $logPath
                $startedState = $null
            }
            if ($startedState -and $startedState.Matching.Count -eq 1) {
                Write-Log -Message 'service started by the supervisor' -Path $logPath
                $missing = 0
            } elseif ($startedState -and ($startedState.Matching.Count -gt 1 -or $startedState.Processes.Count -gt 0)) {
                Write-Log -Message ('service start is ambiguous; deferring further recovery: ' + $startedState.Reason) -Path $logPath
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
                Invoke-FailoverGuarded -Config $config -Reason 'forced re-selection' -CurrentScore $score -Force -DryRun:$DryRun | Out-Null
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
                if (Invoke-FailoverGuarded -Config $config -Reason $reason -CurrentScore $score -Force:$ForceSwitch -DryRun:$DryRun) { $lastSwitch = Get-Date }
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
                    if (Invoke-FailoverGuarded -Config $config -Reason $reason -CurrentScore $score -Force:$ForceSwitch -DryRun:$DryRun) { $lastSwitch = Get-Date }
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
