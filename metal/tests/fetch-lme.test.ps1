# Offline tests: load only function ASTs, never execute the collector entry point or sync_public.ps1.
$ErrorActionPreference = 'Stop'
$collector = Join-Path (Split-Path -Parent $PSScriptRoot) 'fetch_lme.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($collector, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
  . ([scriptblock]::Create($function.Extent.Text))
}
$script:passed = 0
function Assert-True($Condition, $Message) {
  if (-not $Condition) { throw $Message }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
  & $Body
  $script:passed++
  Write-Host "PASS $Name"
}
function Assert-Throws([scriptblock]$Body) {
  $threw = $false
  try { & $Body | Out-Null } catch { $threw = $true }
  Assert-True $threw 'Expected a validation failure'
}
function New-WestmetallFixture([int]$Year) {
  return "<table><tr><th>Date</th></tr><tr><td >02. January $Year</td><td >9,123.50</td><td >9,100.00</td><td class=`"last`">100,000</td></tr></table>"
}
$year = [datetime]::UtcNow.Year - 1
$validHtml = New-WestmetallFixture $year
$date = [datetime]::ParseExact("$year-01-02", 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
$script:unix = ([DateTimeOffset]::new([datetime]::SpecifyKind($date, [DateTimeKind]::Utc))).ToUnixTimeSeconds()
function New-SilverFixture($Timestamp, $Close) {
  return '{"chart":{"error":null,"result":[{"meta":{"symbol":"SI=F"},"timestamp":[' + $Timestamp + '],"indicators":{"quote":[{"close":[' + $Close + ']}]}}]}}'
}
$script:rss = '<rss><channel><item><title>Metal market - Example</title><source url="https://example.test">Example</source><link>https://example.test/article</link><pubDate>Fri, 02 Jan 2026 09:00:00 GMT</pubDate></item></channel></rss>'
# Construct a deterministic past date (independent of the machine's current year).
$script:rss = $script:rss -replace 'Fri, 02 Jan 2026 09:00:00 GMT', $date.ToString('ddd, dd MMM yyyy 09:00:00', [Globalization.CultureInfo]::InvariantCulture).Replace('09:00:00', '09:00:00 GMT')

Test-Case 'collector syntax parses' { Assert-True ($parseErrors.Count -eq 0) 'Syntax errors' }
Test-Case 'valid Westmetall row' { $rows = ConvertFrom-Westmetall $validHtml $year; Assert-True ($rows.Count -eq 1 -and $rows["$year-01-02"].p -eq 9123.5) 'Wrong price' }
Test-Case 'empty Westmetall HTML rejected' { Assert-Throws { ConvertFrom-Westmetall '<html>Unavailable</html>' $year } }
Test-Case 'impossible Westmetall date rejected' { Assert-Throws { ConvertFrom-Westmetall ($validHtml -replace '02. January','31. February') $year } }
Test-Case 'unknown month rejected' { Assert-Throws { ConvertFrom-Westmetall ($validHtml -replace 'January','NotAMonth') $year } }
Test-Case 'wrong response year rejected' { Assert-Throws { ConvertFrom-Westmetall $validHtml ($year - 1) } }
Test-Case 'duplicate Westmetall dates rejected' { Assert-Throws { ConvertFrom-Westmetall ($validHtml + $validHtml) $year } }
Test-Case 'malformed row among valid rows rejected' { Assert-Throws { ConvertFrom-Westmetall ($validHtml + ($validHtml -replace '9,123.50','oops')) $year } }
Test-Case 'invalid numeric forms rejected' {
  foreach ($value in @('', '-', 'NaN', 'Infinity', '-1', '0', '1.2.3', '1,23', '1e3')) { Assert-Throws { ConvertTo-LmeNumber $value } }
  Assert-Throws { ConvertTo-LmeNumber '1.5' -Stock }
  Assert-True ((ConvertTo-LmeNumber '0' -Stock) -eq 0) 'Zero stock must be allowed'
}
Test-Case 'numeric parsing is culture independent' {
  $old = [Threading.Thread]::CurrentThread.CurrentCulture
  try { [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE'); Assert-True ((ConvertTo-LmeNumber '9,123.50') -eq 9123.5) 'Culture-dependent parsing' }
  finally { [Threading.Thread]::CurrentThread.CurrentCulture = $old }
}
Test-Case 'valid Yahoo series' { Assert-True ((ConvertFrom-LmeSilver (New-SilverFixture $script:unix '25.5')).Count -eq 1) 'Wrong series' }
Test-Case 'Yahoo null holiday skipped' { Assert-True ((ConvertFrom-LmeSilver (New-SilverFixture "$script:unix,$($script:unix + 86400)" '25.5,null')).Count -eq 1) 'Null holiday not handled' }
Test-Case 'Yahoo invalid shapes rejected' {
  foreach ($json in @('{}','{"chart":{"error":{"code":"Not Found"},"result":null}}','not json', (New-SilverFixture $script:unix 'null'), (New-SilverFixture "$script:unix,$($script:unix + 86400)" '25.5'))) { Assert-Throws { ConvertFrom-LmeSilver $json } }
}
Test-Case 'Yahoo invalid values rejected' {
  foreach ($close in @('0', '-1', '"NaN"', '"25.5"', 'true', '1e400')) { Assert-Throws { ConvertFrom-LmeSilver (New-SilverFixture $script:unix $close) } }
}
Test-Case 'Yahoo invalid timestamps rejected' {
  foreach ($timestamp in @('0', '-1', '1.5', '999999999999999999999999', '253402300799')) { Assert-Throws { ConvertFrom-LmeSilver (New-SilverFixture $timestamp '25.5') } }
  Assert-Throws { ConvertFrom-LmeSilver (New-SilverFixture "$script:unix,$script:unix" '25.5,26') }
}
Test-Case 'valid RSS normalized' { $items = @(ConvertFrom-LmeNews $script:rss 'Copper' 'en' @('casino')); Assert-True ($items.Count -eq 1 -and $items[0].t -eq 'Metal market') 'Wrong RSS result' }
Test-Case 'empty and malformed RSS rejected' {
  foreach ($xml in @('<rss><channel/></rss>', '<broken', ($script:rss -replace 'https://example.test/article','javascript:alert(1)'), ($script:rss -replace '<pubDate>.*?</pubDate>','<pubDate>invalid</pubDate>'), ($script:rss -replace 'Metal market','casino'))) { Assert-Throws { ConvertFrom-LmeNews $xml 'Copper' 'en' @('casino') } }
}

# This function shadows the cmdlet; every request is a fixture, including success cases.
function Invoke-WebRequest {
  param($Uri, [switch]$UseBasicParsing, $TimeoutSec, $ErrorAction)
  $script:requests++
  $body = ''
  if ($Uri -match 'westmetall') {
    $requestYear = [int]([regex]::Match($Uri, 'year=(\d+)').Groups[1].Value)
    $body = New-WestmetallFixture $requestYear
    if ($script:mode -eq 'partial-year' -and $script:requests -eq 2) { throw 'Injected required-year source failure' }
    if ($script:mode -eq 'partial-metal' -and $Uri -match 'LME_Al_cash') { $body = '<html>Unavailable</html>' }
  } elseif ($Uri -match 'finance.yahoo') {
    $body = New-SilverFixture $script:unix '25.5'
    if ($script:mode -eq 'empty-silver') { $body = New-SilverFixture $script:unix 'null' }
  } elseif ($Uri -match 'news.google') {
    $body = $script:rss
    if ($script:mode -eq 'late-news-failure' -and $script:requests -eq 11) { throw 'Injected last RSS failure' }
    if ($script:mode -eq 'empty-news' -and $script:requests -eq 7) { $body = '<rss><channel/></rss>' }
  } else { throw "Unexpected request: $Uri" }
  return [pscustomobject]@{ Content=$body; RawContentStream=(New-Object IO.MemoryStream(,[Text.Encoding]::UTF8.GetBytes($body))) }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('lme-offline-test-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($root)
try {
  $files = @('data.js','stock.js','news.js')
  foreach ($scenario in @('partial-year','partial-metal','empty-silver','late-news-failure','empty-news')) {
    Test-Case "$scenario leaves all feeds byte-identical" {
      foreach ($name in $files) { [IO.File]::WriteAllText((Join-Path $root $name), "original-$name") }
      $script:mode = $scenario
      $script:requests = 0
      Assert-Throws { Invoke-LmeCollection $root 2 }
      foreach ($name in $files) { Assert-True ([IO.File]::ReadAllText((Join-Path $root $name)) -ceq "original-$name") "Overwrote $name" }
      Assert-True (@([IO.Directory]::GetFiles($root)).Count -eq 3) 'Failure left staging artifacts'
    }
  }
  Test-Case 'successful offline batch replaces all three feeds' {
    $script:mode = 'success'
    $script:requests = 0
    Invoke-LmeCollection $root 2
    Assert-True ($script:requests -eq 11) 'Not all required sources requested'
    Assert-True ([IO.File]::ReadAllText((Join-Path $root 'data.js')).Contains('y:25.5')) 'Missing silver'
    Assert-True ([IO.File]::ReadAllText((Join-Path $root 'stock.js')).Contains('s:100000')) 'Missing stock'
    Assert-True ([IO.File]::ReadAllText((Join-Path $root 'news.js')).Contains('Metal market')) 'Missing news'
    Assert-True (@([IO.Directory]::GetFiles($root)).Count -eq 3) 'Staging artifacts remain'
  }
  Test-Case 'staging failure leaves earlier destination untouched' {
    $blocked = Join-Path $root 'blocked'
    $null = [IO.Directory]::CreateDirectory($blocked)
    $null = [IO.Directory]::CreateDirectory((Join-Path $blocked 'stock.js'))
    [IO.File]::WriteAllText((Join-Path $blocked 'data.js'), 'original')
    Assert-Throws { Write-LmeBatch $blocked ([ordered]@{ 'data.js'='new'; 'stock.js'='new'; 'news.js'='new' }) }
    Assert-True ([IO.File]::ReadAllText((Join-Path $blocked 'data.js')) -eq 'original') 'Partial staged write reached live file'
    Assert-True (@([IO.Directory]::GetFiles($blocked)).Count -eq 1) 'Temp artifact left behind'
  }
  Test-Case 'commit failure rolls back earlier replacement' {
    [IO.File]::WriteAllText((Join-Path $root 'data.js'), 'original-data')
    [IO.File]::WriteAllText((Join-Path $root 'stock.js'), 'original-stock')
    $lock = [IO.File]::Open((Join-Path $root 'stock.js'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try { Assert-Throws { Write-LmeBatch $root ([ordered]@{ 'data.js'='new'; 'stock.js'='new' }) } }
    finally { $lock.Dispose() }
    Assert-True ([IO.File]::ReadAllText((Join-Path $root 'data.js')) -eq 'original-data') 'Rollback did not restore data.js'
    Assert-True ([IO.File]::ReadAllText((Join-Path $root 'stock.js')) -eq 'original-stock') 'Locked feed changed'
    Assert-True (@([IO.Directory]::GetFiles($root)).Count -eq 3) 'Rollback artifacts remain'
  }
} finally {
  [IO.Directory]::Delete($root, $true)
}
Write-Host "$script:passed offline tests passed; no network or public sync was executed."
