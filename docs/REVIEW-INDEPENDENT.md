# 独立复核：StackSupervisor.ps1 关键路径

复核对象：D:\stack-supervisor\src\StackSupervisor.ps1（769 行，当前修订）。
复核范围：Invoke-GatewayProbe（L217-L272）、Get-JsonObjectBlock（L112-L166）、Set-ActiveEndpoint 与 Update-EndpointBlock（L330-L394）、Restart-ServiceProcess 与 Start-ServiceProcess（L571-L595）。行号均为该修订中的实际行号。
本次复核对文件只读：除本文件外未创建、未修改任何文件，未启动或停止任何进程。下表中标【实测】的结论已在 PowerShell 5.1 中用内存字符串复现。

## 1. 缺陷表

| 严重度 | 位置（函数名+行号） | 问题一句话 | 触发条件 | 最小修复 |
|---|---|---|---|---|
| Critical | Set-ActiveEndpoint L366-L371（回读校验） | 回读只在顶层数组属性里按 tag 找对象、命中不 break、只查一层，可能校验到另一个同 tag 对象，也可能根本找不到 | 配置里 inbound 与 outbound 同 tag（实测：最后一个匹配胜出并冒充"校验通过"），或端点块嵌在二级数组（实测：outbounds[0].settings.vnext[0] 直接漏检） | 校验必须针对刚打补丁的那一块：用 Get-JsonObjectBlock 在 updated 文本中按偏移重新定位，找不到即拒写，禁止遍历数组猜 |
| Critical | Set-ActiveEndpoint L392（写入） | 直接 WriteAllText 覆盖目标文件，非原子；写到一半失败即留下截断的 JSON，服务再也起不来 | 断电、进程被杀、磁盘满、杀软锁定发生在写入过程中 | 写同目录临时文件 -> 重读比对 -> File.Replace 原子替换；写后重读，失败则用备份回滚 |
| High | Invoke-GatewayProbe L244 与 L249 | 用 StreamReader 读完 CONNECT 响应头后弃用它、改从底层流读正文：reader 内部 1024 字节缓冲区里已读出的正文字节再也拿不回来，正文被截断 | 对端数据与响应头落在同一次 socket 读里：明文（-NoTls）目标、代理预取上游 banner、代理在 CONNECT 响应后附带 body。TLS 路径表现为握手解码错误，明文路径表现为 expect 失配 | 不再用 StreamReader 读头：自己在同一 NetworkStream 上按字节扫描到 CRLFCRLF（上限 16 KB），随后把这个流直接交给 SslStream |
| High | Invoke-GatewayProbe L251-L253 | 证书校验回调恒为 $true，任何自签或中间人证书都被判为"健康"，探针结论可被伪造 | 本地代理被替换、上游被劫持、企业根证书注入 | 默认走系统校验，只有显式开关才放行不受信证书，并记录证书指纹与主体 |
| High | Get-JsonObjectBlock L126 | needle 写死一个空格（"tag" + ': "'），配置若写成 "tag":"x" 或 "tag" : "x" 就永远匹配不到，静默返回 $null，failover 永久失效且无任何日志 | 任何非该精确格式的 JSON（实测：两种写法均返回 NULL，调用方当成"端点不存在"） | 改为词法扫描或至少 '"tag"\s*:\s*"..."' 正则；匹配不到时应告警而非静默 |
| High | Get-JsonObjectBlock L132（配合 L134-L163 花括号配对） | 扫描起点由 LastIndexOf('{') 决定且不看字符串上下文；一旦该 '{' 落在字符串里，深度状态机从错误的 inString 状态起步，块边界错乱（帧内的转义处理本身是对的，起点错则整体失效） | 对象内、tag 键之前的字符串值里出现 '{'（实测：整块返回 NULL，failover 静默失效） | 从文件开头做一次有序扫描，先判定字符串/转义状态，再用 '{' 栈配对得到每个对象区间 |
| High | Set-ActiveEndpoint L373-L378 | 回读只比对 host 与 port；patchRules 改坏的 sni、token 等字段一律不校验 | 示例配置里 "serverName"/"id" 规则命中错位置而 host/port 未变（实测路径成立），随后被当作"校验通过"写盘 | 按 readFields 逐字段比对，并断言改动只落在 readFields 覆盖的叶子路径上；契约：规则要改的字段必须出现在 readFields 里 |
| High | Update-EndpointBlock L339-L348 | 每条规则对整个块做"首个匹配"替换，块内出现同名键时静默改错字段（示例配置的 "host"\s*:\s*"[^"]*" 可命中 streamSettings 里的 host） | 端点块内存在两个同名键，或前一条规则的输出被后一条规则二次命中 | 规则必须唯一匹配：0 次或 >1 次直接抛错拒写；后续再引入按 JSON 路径锚定的规则 |
| High | Update-EndpointBlock L336 | 属性值为 0、空串、$false 时不生成 {attr:x} token，引用它的规则被 continue 静默跳过，字段漏改 | 候选属性带 alterId=0、security='' 等假值 | 只跳过 $null；布尔/数字用 ConvertTo-Json 生成 JSON 字面量（false 而非 False）；跳过时必须写日志 |
| High | Start-ServiceProcess L574 | 用正则惰性拆分命令行，'"?([^"]+?)"?\s+(.+)' 会把带空格的引号路径从中间劈开 | 示例配置第 8 行的 startCommand（实测：FilePath=C:\Program，Args=Files\EdgeGateway\...，Start-Process 必然失败） | 用引号感知的参数解析，或让配置直接给出 executable 与 arguments 两段；无法安全拆分时抛错而不是猜 |
| High | Restart-ServiceProcess L585 | 按进程名 Stop-Process：同名但不同路径/不同用户的进程一并被杀，可能杀掉无关程序或另一个实例 | 机器上存在同名可执行文件，或用户手工启动过同名程序 | 按可执行文件路径 + 命令行匹配后再停，且只停匹配到的 PID，日志里记录 PID 与路径 |
| High | Restart-ServiceProcess L586-L590 | Stop-Process 是异步的，循环不等旧进程退出；2 秒后只要看到同名进程（可能正是尚未退出的旧进程）就 return $true，且不校验 PID 变化 | 旧进程退出较慢，或外部 keeper 抢先拉起 | 先记下旧 PID 与其启动时间，等到旧 PID 消失且出现新 PID（命令行含新配置路径）才算成功 |
| Medium | Set-ActiveEndpoint L357 与 L392 | 读-改-写之间无锁、无 hash/mtime 校验，服务或 keeper 同时改写配置会丢失更新 | 服务自身在写同一个配置文件 | 写前比对文件 hash，变化则放弃本轮；写盘用独占打开 |
| Medium | Invoke-GatewayProbe L263-L269 | 正文读取只有单次 ReadTimeout，没有总时长和总字节上限；慢速或超大响应可长时间挂住主管、把内存吃满 | 上游返回大响应或慢速滴流 | 加总 deadline 与最大字节数，超限即抛出；SslStream 包装后显式设置 Read/WriteTimeout |
| Medium | Invoke-GatewayProbe L247 | 响应头读取循环无行数/字节上限，异常代理可无限发头使探针永不返回 | 恶意或有缺陷的代理 | 头部累计上限（如 16 KB）后抛错 |
| Medium | Invoke-GatewayProbe L270 | 整个响应恒按 UTF-8 解码，不清除分块编码、不处理 Content-Encoding: gzip，expect 正则必然失配 | 上游返回 chunked 或 gzip | 解析响应头后按 charset 解码并处理 chunked/gzip，或显式发送 Accept-Encoding: identity 并断言响应未压缩 |
| Medium | Get-JsonObjectBlock L149-L157 | 空 catch 吞掉一切异常（含 StrictMode 下访问不存在属性的异常），任何失败都表现为 $null，无日志 | 任何解析或属性访问异常 | catch 里至少写日志（含候选片段），或先判断属性存在再访问 |
| Medium | Get-JsonObjectBlock L153-L155 | RequireProperty 只在候选对象顶层比对属性名，无法表达嵌套要求 | 需要断言 settings 内存在某键 | 支持点路径逐层检查（本文件第 3.1 节的改写已实现） |
| Medium | Set-RegexFirst L170 与 Update-EndpointBlock L347 | 正则无超时（病态模式可挂死主管）；替换串按 .NET 替换语义解析，属性值里的 $ 会被当引用 | 配置模式回溯爆炸，或候选属性值含 $ | Regex 构造带 timeout；替换前把 $ 转义为 $$，走字面量替换 |
| Low | Restart-ServiceProcess L590-L594 与 Invoke-Failover L656 | 超时后自行拉起，可能与外部 keeper 并发双启；函数返回的布尔被管道丢弃，成功与否无人判定 | keeper 与主管同时判定进程缺失 | 自启前加单实例互斥；返回值参与判定并写日志 |

关于"StreamReader 读头后从底层流读正文是否吞字节"的结论：机制成立，但需要到达时序配合。CONNECT 成功后正常代理在收到客户端 ClientHello 之前不会回传数据，所以典型 HTTPS 场景被吞掉的往往只有头部自身的 CRLF；真正会丢正文的是明文目标与"响应头之后紧跟对端数据"的情形。缺陷的本质不是 Dispose（该 reader 用了 leaveOpen=$true，Dispose 也不归还缓冲区），而是"同一个流上叠两层缓冲"这一模式本身不可靠，且丢字节时没有任何检测手段。修法是唯一的：头部自己按字节扫描，正文只用同一条流。

## 2. Pester v5 测试方案（20 例，零真实服务、零网络）

前置约定（全部用例都适用）：

- 不要 dot-source 整个脚本：L672 起是主流程，会读真实配置、占 Mutex、连网。用 AST 只取出函数定义后执行，例如：
```powershell
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
```
- 文件类用例一律用 Pester 的 TestDrive，不碰 D:\stack-supervisor 之外的真实路径；进程类用例全部 Mock；目录源走 catalog.file 分支，因此不会调用 Invoke-WebRequest。
- 建议先落三个测试缝（seam），否则前三个用例无法在无网络下编写：New-ProbeConnection（连接工厂）、Write-TextFile（写入下沉）、ConvertTo-ProcessStartInfo（命令行解析）。

| 用例名 | 被测函数 | 依赖的 mock | 断言要点 | 是否为 Critical/High 缺陷的回归测试 |
|---|---|---|---|---|
| Probe.BufferedHeaderBytesAreNotLost | Invoke-GatewayProbe | Mock New-ProbeConnection，返回预置字节的 MemoryStream（头与正文同段） | 返回串必须完整包含正文标记；不得出现截断 | 是 |
| Probe.CertificateValidationIsNotAlwaysTrue | Invoke-GatewayProbe / Test-ServerCertificate | 在内存中构造自签 X509Certificate2，不建立连接 | 默认回调对不受信证书返回 $false；仅当显式开关开启才返回 $true | 是 |
| Probe.CapsResponseSizeAndDeadline | Invoke-GatewayProbe | 假流无限返回字节 | 超过最大字节数或 deadline 时抛错，而不是无限循环 | 否 |
| JsonBlock.ToleratesTagWhitespaceVariants | Get-JsonObjectBlock | 无（纯内存字符串） | "tag":"x"、"tag" : "x"、换行与 Tab 四种写法均能正确定位同一块 | 是 |
| JsonBlock.IgnoresNeedleInsideStringValue | Get-JsonObjectBlock | 无 | 字符串值里出现 "tag": "live" 时，返回的仍是真正的端点块，或明确返回 $null，绝不返回错误区间 | 是 |
| JsonBlock.BraceMatchWithBracesInsideStrings | Get-JsonObjectBlock | 无 | 值含 { } \" \\ 时 Start/End/Text 精确；含未配对 '{' 的字符串不得使整块丢失 | 是 |
| JsonBlock.RequiresNestedPropertyPath | Get-JsonObjectBlock | 无 | requireProperties 支持点路径；不满足的候选被跳过，满足的候选被返回 | 否 |
| SetActive.RoundTripsHostAndPort | Set-ActiveEndpoint | TestDrive 真文件 + Mock Copy-Item、Get-ChildItem（备份轮转） | 写盘后可 ConvertFrom-Json；host/port 为新值；块外字节逐字不变 | 否 |
| SetActive.RefusesPatchOfWrongField | Set-ActiveEndpoint | TestDrive 真文件；patchRules 故意命中同名错误字段 | 返回 $false，且文件内容与 LastWriteTime 均未变 | 是 |
| SetActive.ReadBackFindsNestedBlock | Set-ActiveEndpoint | TestDrive 真文件 | 端点块位于 outbounds[0].settings.vnext[0] 时仍能完成校验并写入 | 是 |
| SetActive.ReadBackRejectsDuplicateTag | Set-ActiveEndpoint | TestDrive 真文件（inbound 与 outbound 同 tag） | 不允许"最后一个匹配"冒充校验结果；必须校验被改的那一块，否则拒写 | 是 |
| SetActive.ValidatesAllPatchedAttributes | Set-ActiveEndpoint | TestDrive 真文件；patchRules 篡改 tls.serverName | 回读必须失败并保持文件原样 | 是 |
| SetActive.WriteIsAtomicOnFailure | Set-ActiveEndpoint | Mock Write-TextFile，在写临时文件后抛错 | 目标文件内容不变；目录里无残留 .new-* 临时文件 | 是 |
| UpdateBlock.RulesDoNotInterfere | Update-EndpointBlock | Mock Write-Log | 前一条规则的输出不被后一条规则二次命中；同名字段规则匹配次数不为 1 时抛错 | 是 |
| UpdateBlock.MissingAttrValuesAreNotSilent | Update-EndpointBlock | Mock Write-Log | 属性值 0/空串/$false 仍生成 token（$false 生成 false 字面量）；确实缺值时必须写日志 | 是 |
| UpdateBlock.ReplacementIsLiteral | Set-RegexFirstLiteral | 无 | 属性值含 $1、$& 或反斜杠时按字面量写回 | 否 |
| StartService.ParsesQuotedPathWithSpaces | Start-ServiceProcess | Mock Start-Process | "C:\Program Files\...\svc.exe" serve --config "{config}" 得到完整 FilePath 与原样 ArgumentList | 是 |
| StartService.RejectsUnparseableCommand | Start-ServiceProcess | Mock Start-Process | 不可安全拆分时抛错，且 Assert-MockCalled Start-Process -Times 0 | 否 |
| RestartService.KillsOnlyMatchingProcess | Restart-ServiceProcess | Mock Get-Process（返回带 Path/CommandLine 的假对象）、Stop-Process、Start-Sleep | 只对路径或命令行匹配的 PID 调用 Stop-Process；同名不同路径的进程不被调用 | 是 |
| RestartService.WaitsForNewPidBeforeReturningTrue | Restart-ServiceProcess | Mock Get-Process（先旧 PID 后新 PID）、Stop-Process、Start-Sleep、Start-ServiceProcess | 旧 PID 仍在时不得返回 $true；必须等到新 PID 出现才返回 $true | 是 |

## 3. 最该重写的两个函数

选择理由：这两个函数共同持有"唯一会写坏生产配置"的路径。Get-JsonObjectBlock 定位错了，整条自愈链路静默失效（实测：正确格式之外的 JSON 与含 '{' 的字符串都直接返回 $null）；Set-ActiveEndpoint 校验错了或写坏了，服务直接起不来且没有可用的旧版本。其余缺陷要么不落盘，要么已被上表用例拦住。

### 3.1 Get-JsonObjectBlock（自包含，可直接替换）

改动理由：改为单遍有序词法扫描——先判定字符串与转义状态，再用 '{' 栈配对得到每个对象区间，用"键"而非"文本 needle"判定 tag，从而同时消除空格敏感、字符串内花括号、needle 落在字符串内三类失效；RequireProperty 支持点路径；返回契约（Start/End/Text）保持不变，调用方无需改动。

```powershell
function Get-JsonObjectBlock {
    <#
        Locates the first JSON object that declares a KEY named "tag" with value -Tag and
        carries every property named in -RequireProperty (dotted paths walk nested objects).
        Offsets are inclusive and Text is the exact source slice, so callers keep splicing
        with Substring(0, Start) + patched + Substring(End + 1).

        Two failures of the previous implementation are gone by construction:
          * the '"tag": "' needle baked in one exact spacing, so any other formatting made
            the function return $null forever instead of stopping the switch;
          * the scan started at LastIndexOf('{') without knowing whether that brace sits
            inside a string, so a brace inside a string value desynchronised the depth
            machine and produced the wrong block or none at all.
        Every byte of the file is classified once, in order, so string and escape state is
        always known before a brace is counted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Tag,
        [string[]]$RequireProperty = @()
    )

    if ([string]::IsNullOrEmpty($Text)) { return $null }

    $quote = [char]34
    $colon = [char]58
    $open  = [char]123
    $close = [char]125
    $back  = [char]92

    $length  = $Text.Length
    $stack   = New-Object 'System.Collections.Generic.Stack[int]'
    $objects = New-Object 'System.Collections.Generic.List[object]'
    $props   = @{}

    $inString    = $false
    $escaped     = $false
    $stringStart = -1
    $pendingKey  = $null
    $pendingOwner = -1

    for ($i = 0; $i -lt $length; $i++) {
        $ch = $Text[$i]

        if ($inString) {
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq $back) { $escaped = $true }
            elseif ($ch -eq $quote) {
                $inString = $false
                $raw = $Text.Substring($stringStart + 1, $i - $stringStart - 1)
                if ($null -ne $pendingKey) {
                    $table = Get-JsonPropertyTable -Tables $props -Key $pendingOwner
                    $table[$pendingKey] = [pscustomobject]@{ Kind = 'String'; Value = $raw }
                    $pendingKey = $null
                }
                else {
                    $j = $i + 1
                    while ($j -lt $length -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
                    if ($j -lt $length -and $Text[$j] -eq $colon) {
                        $pendingKey = $raw
                        if ($stack.Count -gt 0) { $pendingOwner = $stack.Peek() } else { $pendingOwner = -1 }
                    }
                }
            }
            continue
        }

        if ($ch -eq $quote) { $inString = $true; $stringStart = $i; continue }

        if ($ch -eq $open) {
            $objects.Add([pscustomobject]@{ Start = $i; End = -1 })
            $index = $objects.Count - 1
            $stack.Push($index)
            if ($null -ne $pendingKey) {
                $table = Get-JsonPropertyTable -Tables $props -Key $pendingOwner
                $table[$pendingKey] = [pscustomobject]@{ Kind = 'Object'; Key = $index }
                $pendingKey = $null
            }
            continue
        }

        if ($ch -eq $close) {
            if ($stack.Count -gt 0) { $objects[$stack.Pop()].End = $i }
            continue
        }

        if ($null -ne $pendingKey -and -not [char]::IsWhiteSpace($ch) -and $ch -ne $colon) {
            # the value is a number, boolean, null or array: it cannot be walked by name
            $pendingKey = $null
        }
    }

    for ($n = 0; $n -lt $objects.Count; $n++) {
        $object = $objects[$n]
        if ($object.End -lt 0) { continue }
        if (-not $props.ContainsKey($n)) { continue }
        $table = $props[$n]
        if (-not $table.ContainsKey('tag')) { continue }
        $tag = $table['tag']
        if ($tag.Kind -ne 'String') { continue }
        if ($tag.Value -ne $Tag) { continue }
        $matched = $true
        foreach ($path in $RequireProperty) {
            if (-not (Test-JsonPropertyPath -Tables $props -Table $table -Path $path)) { $matched = $false; break }
        }
        if (-not $matched) { continue }
        return [pscustomobject]@{
            Start = $object.Start
            End   = $object.End
            Text  = $Text.Substring($object.Start, $object.End - $object.Start + 1)
        }
    }
    return $null
}

function Get-JsonPropertyTable {
    param([Parameter(Mandatory)][hashtable]$Tables, [Parameter(Mandatory)][int]$Key)
    if (-not $Tables.ContainsKey($Key)) { $Tables[$Key] = @{} }
    return $Tables[$Key]
}

function Test-JsonPropertyPath {
    param(
        [Parameter(Mandatory)][hashtable]$Tables,
        [Parameter(Mandatory)][hashtable]$Table,
        [Parameter(Mandatory)][string]$Path
    )
    $segments = $Path.Split('.')
    $current = $Table
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $name = $segments[$i]
        if (-not $current.ContainsKey($name)) { return $false }
        if ($i -eq $segments.Count - 1) { return $true }
        $descriptor = $current[$name]
        if ($descriptor.Kind -ne 'Object') { return $false }
        if (-not $Tables.ContainsKey($descriptor.Key)) { return $false }
        $current = $Tables[$descriptor.Key]
    }
    return $false
}
```

### 3.2 Set-ActiveEndpoint（连带 Update-EndpointBlock 与 Set-RegexFirstLiteral）

改动理由：把"改"与"验"绑在一起——补丁必须唯一匹配（消掉改错字段），写完必须按 readFields 逐字段回读并断言改动只落在可读回的叶子路径上（消掉"校验了另一个对象"与"只比 host/port"），落盘改为临时文件加 File.Replace 原子替换并做写后重读（消掉截断配置），任何一步失败都不触碰线上文件。它依赖 3.1 的 Get-JsonObjectBlock。

```powershell
function Set-RegexFirstLiteral {
    <# Replaces the one and only occurrence of $Pattern with $Literal, taken verbatim. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Literal,
        [int]$TimeoutMs = 2000
    )
    $regex = New-Object System.Text.RegularExpressions.Regex($Pattern, [System.Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromMilliseconds($TimeoutMs))
    $hits = $regex.Matches($Text)
    if ($hits.Count -ne 1) {
        throw ('patch rule "' + $Pattern + '" matched ' + $hits.Count + ' time(s); exactly one match is required')
    }
    return $regex.Replace($Text, $Literal.Replace('$', '$$'), 1)
}

function Update-EndpointBlock {
    <#
        Applies every configured patch rule to one endpoint block.

        A rule must match the block exactly once: two matches mean the rule is not specific
        enough to know which field it is supposed to rewrite, zero means the rule and the
        configuration have drifted apart. Both are hard errors, so a half-applied patch can
        never reach the file. Attribute values are taken as they are, including 0, empty
        string and $false; only a genuinely absent value skips a rule, and that is logged.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$BlockText, [Parameter(Mandatory)]$Endpoint)

    $selector = Get-Selector -Config $Config
    $tokens = @{}
    if ($Endpoint.Fields) {
        foreach ($name in $Endpoint.Fields.Keys) {
            $value = $Endpoint.Fields[$name]
            if ($null -eq $value) { continue }
            if ($value -is [string]) { $tokens['attr:' + $name] = $value }
            else { $tokens['attr:' + $name] = ($value | ConvertTo-Json -Compress) }
        }
    }
    $tokens['host'] = [string]$Endpoint.Host
    $tokens['port'] = [string]$Endpoint.Port

    $patched = $BlockText
    $rules = @($selector.Patch)
    for ($index = 0; $index -lt $rules.Count; $index++) {
        $rule = $rules[$index]
        $replacement = [string]$rule.replacement
        $missing = @()
        foreach ($placeholder in [regex]::Matches($replacement, '\{attr:([^\}]+)\}')) {
            $name = $placeholder.Groups[1].Value
            if (-not $tokens.ContainsKey('attr:' + $name)) { $missing += $name }
        }
        if ($missing.Count -gt 0) {
            Write-Log -Message ('patch rule ' + ($index + 1) + ' skipped: no value for ' + ($missing -join ', ')) -Path $Config.log
            continue
        }
        $literal = Expand-Template -Template $replacement -Tokens $tokens
        $patched = Set-RegexFirstLiteral -Text $patched -Pattern ([string]$rule.pattern) -Literal $literal
    }
    return $patched
}

function Get-JsonLeafMap {
    <# Flattens a ConvertFrom-Json tree into 'path.with[0].index' -> leaf text. #>
    param($Object, [string]$Prefix = '', [hashtable]$Into)
    if ($null -eq $Into) { $Into = @{} }
    if ($null -eq $Object) {
        $Into[$Prefix] = '<null>'
        return $Into
    }
    if ($Object -is [System.Array]) {
        for ($i = 0; $i -lt $Object.Count; $i++) {
            $null = Get-JsonLeafMap -Object $Object[$i] -Prefix ($Prefix + '[' + $i + ']') -Into $Into
        }
        return $Into
    }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Object.PSObject.Properties) {
            $null = Get-JsonLeafMap -Object $property.Value -Prefix ($Prefix + '.' + $property.Name) -Into $Into
        }
        return $Into
    }
    $Into[$Prefix] = [string]$Object
    return $Into
}

function Test-EndpointPatch {
    <#
        Proves the patched block really carries the requested endpoint and that nothing else
        moved. The contract is deliberately strict: every field a patch rule rewrites must be
        listed in endpointSelector.readFields, otherwise the supervisor cannot verify it and
        refuses to write.
    #>
    param(
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$After,
        [Parameter(Mandatory)]$Endpoint,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ReadFields
    )

    if ($ReadFields.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Reason = 'readFields is empty, nothing can be verified' }
    }

    $mapBefore = Get-JsonLeafMap -Object $Before
    $mapAfter = Get-JsonLeafMap -Object $After

    $changed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in $mapAfter.Keys) {
        if (-not $mapBefore.ContainsKey($key) -or $mapBefore[$key] -ne $mapAfter[$key]) { $changed.Add([string]$key) }
    }
    foreach ($key in $mapBefore.Keys) {
        if (-not $mapAfter.ContainsKey($key)) { $changed.Add([string]$key) }
    }
    if ($changed.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Reason = 'no field changed' }
    }

    foreach ($field in $ReadFields) {
        $wanted = $null
        if ($field.Name -eq 'host') { $wanted = [string]$Endpoint.Host }
        elseif ($field.Name -eq 'port') { $wanted = [string]$Endpoint.Port }
        elseif ($Endpoint.Fields -and $Endpoint.Fields.ContainsKey($field.Name)) { $wanted = [string]$Endpoint.Fields[$field.Name] }
        if ($null -eq $wanted) { continue }
        $actual = Get-JsonPathValue -Object $After -Path ([string]$field.Path)
        if ([string]$actual -ne $wanted) {
            return [pscustomobject]@{ Ok = $false; Reason = ('read field ' + $field.Name + ' is "' + $actual + '", expected "' + $wanted + '"') }
        }
    }

    $allowed = @{}
    foreach ($field in $ReadFields) {
        $allowed[(([string]$field.Path) -replace '\[\d+\]', '').TrimStart('.')] = $true
    }
    foreach ($key in $changed) {
        $normalised = ($key -replace '\[\d+\]', '').TrimStart('.')
        if (-not $allowed.ContainsKey($normalised)) {
            return [pscustomobject]@{ Ok = $false; Reason = ('unexpected field changed: ' + $key) }
        }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

function Set-ActiveEndpoint {
    <#
        Rewrites one endpoint block in the live configuration, atomically and verifiably.

        Order of operations:
          1. locate the block by tag plus required properties (string-aware locator);
          2. apply the patch rules to the block text only;
          3. re-parse the patched block and prove that every field the supervisor reads back
             carries the requested value, that nothing else moved and that something did;
          4. splice the block back, prove the whole document still parses, and locate the
             block again in the result - never trust a heuristic that scans the document for
             "an object with this tag", because more than one object may carry it;
          5. back up the previous revision, write a temporary file, re-read it, then swap it
             in with File.Replace so the live path is never left half-written;
          6. read the file back from disk; if it differs, restore the backup and fail.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Endpoint)

    $path = [string]$Config.service.configPath
    $selector = Get-Selector -Config $Config
    if (-not $selector.Read) {
        Write-Log -Message 'endpointSelector.readFields is missing; nothing can be verified, refusing to write' -Path $Config.log
        return $false
    }
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Log -Message ('configuration file not found: ' + $path) -Path $Config.log
        return $false
    }

    $readFields = @()
    foreach ($property in $selector.Read.PSObject.Properties) {
        $readFields += [pscustomobject]@{ Name = $property.Name; Path = [string]$property.Value }
    }

    $text = Read-TextFile -Path $path
    $block = Get-JsonObjectBlock -Text $text -Tag $selector.Tag -RequireProperty $selector.Required
    if (-not $block) {
        Write-Log -Message 'endpoint block not found; refusing to write' -Path $Config.log
        return $false
    }

    $before = $null
    try { $before = $block.Text | ConvertFrom-Json }
    catch {
        Write-Log -Message ('endpoint block does not parse: ' + $_.Exception.Message) -Path $Config.log
        return $false
    }

    $patchedText = $null
    try { $patchedText = Update-EndpointBlock -Config $Config -BlockText $block.Text -Endpoint $Endpoint }
    catch {
        Write-Log -Message ('patch rules rejected the block: ' + $_.Exception.Message) -Path $Config.log
        return $false
    }
    if ($patchedText -eq $block.Text) {
        Write-Log -Message 'no patch rule changed the block; refusing to write a no-op' -Path $Config.log
        return $false
    }

    $after = $null
    try { $after = $patchedText | ConvertFrom-Json }
    catch {
        Write-Log -Message ('patched block does not parse: ' + $_.Exception.Message) -Path $Config.log
        return $false
    }
    $verdict = Test-EndpointPatch -Before $before -After $after -Endpoint $Endpoint -ReadFields $readFields
    if (-not $verdict.Ok) {
        Write-Log -Message ('patched block rejected: ' + $verdict.Reason) -Path $Config.log
        return $false
    }

    $updated = $text.Substring(0, $block.Start) + $patchedText + $text.Substring($block.End + 1)
    try { $null = $updated | ConvertFrom-Json }
    catch {
        Write-Log -Message ('updated configuration does not parse: ' + $_.Exception.Message) -Path $Config.log
        return $false
    }

    $located = Get-JsonObjectBlock -Text $updated -Tag $selector.Tag -RequireProperty $selector.Required
    if (-not $located) {
        Write-Log -Message 'the patched block cannot be located in the updated text; refusing to write' -Path $Config.log
        return $false
    }
    $locatedObject = $null
    try { $locatedObject = $located.Text | ConvertFrom-Json }
    catch {
        Write-Log -Message ('re-located block does not parse: ' + $_.Exception.Message) -Path $Config.log
        return $false
    }
    $verdict2 = Test-EndpointPatch -Before $before -After $locatedObject -Endpoint $Endpoint -ReadFields $readFields
    if (-not $verdict2.Ok) {
        Write-Log -Message ('re-located block rejected: ' + $verdict2.Reason) -Path $Config.log
        return $false
    }

    $backupPath = ''
    $backupDir = [string]$Config.service.backupDir
    if ($backupDir) {
        if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
        $backupPath = Join-Path $backupDir ('config-' + (Get-Date -Format 'yyyyMMddHHmmssfff') + '.json')
        Copy-Item -LiteralPath $path -Destination $backupPath -Force
    }

    $tempPath = $path + '.new-' + [guid]::NewGuid().ToString('N')
    try {
        Write-TextFile -Path $tempPath -Text $updated
        $reread = Read-TextFile -Path $tempPath
        if ($reread -ne $updated) { throw 'the temporary file does not contain the validated text' }
        $null = $reread | ConvertFrom-Json
        if ([System.IO.File]::Exists($path)) { [System.IO.File]::Replace($tempPath, $path, $null) }
        else { [System.IO.File]::Move($tempPath, $path) }
    }
    catch {
        Write-Log -Message ('write failed; the live configuration was not modified: ' + $_.Exception.Message) -Path $Config.log
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        return $false
    }

    if ((Read-TextFile -Path $path) -ne $updated) {
        Write-Log -Message 'on-disk verification failed; restoring the previous revision' -Path $Config.log
        if ($backupPath) { Copy-Item -LiteralPath $backupPath -Destination $path -Force }
        return $false
    }

    if ($backupDir) {
        Get-ChildItem -LiteralPath $backupDir -Filter 'config-*.json' |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 10 |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    return $true
}
```

兼容性说明：全部代码为 Windows PowerShell 5.1 语法，未使用反引号续行，未使用 PS 7 专有语法；正则构造带 2000 ms 超时，字面量替换通过 $ 转义实现（.NET 替换串中反斜杠不是特殊字符）。调用方接口不变：Get-JsonObjectBlock 仍返回 Start/End/Text，Set-ActiveEndpoint 仍返回 [bool]。
