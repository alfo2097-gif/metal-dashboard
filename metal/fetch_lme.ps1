﻿# Metal 시황 데이터 수집: Westmetall 시세/재고 + Yahoo 은 + Google News RSS
# 사용: powershell -File fetch_lme.ps1 [-Years 10]
param([ValidateRange(1,50)][int]$Years = 5)

function ConvertTo-LmeNumber {
  param([object]$Value, [switch]$Stock)
  $text = [string]$Value
  # Invariant decimal notation, with optional correctly grouped thousands separators.
  if ($text -notmatch '^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]+)?$') { throw "Invalid numeric value: '$text'" }
  $number = 0.0
  if (-not [double]::TryParse(($text -replace ',',''), [Globalization.NumberStyles]::AllowDecimalPoint, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
      [double]::IsNaN($number) -or [double]::IsInfinity($number) -or
      ($Stock -and ($number -lt 0 -or $number -ne [Math]::Truncate($number))) -or
      (-not $Stock -and $number -le 0)) { throw "Invalid numeric value: '$text'" }
  return $number
}

function ConvertFrom-Westmetall {
  param([string]$Html, [int]$Year)
  $records = @{}
  foreach ($row in [regex]::Matches($Html, '(?is)<tr\b[^>]*>(.*?)</tr>')) {
    $cells = [regex]::Matches($row.Groups[1].Value, '(?is)<td\b[^>]*>(.*?)</td>')
    if ($cells.Count -eq 0) { continue }
    $values = @($cells | ForEach-Object { [Net.WebUtility]::HtmlDecode(($_.Groups[1].Value -replace '<[^>]+>', '')).Trim() })
    # Ignore headings/footers, but never silently discard a malformed dated row.
    if ($cells.Count -lt 4 -and $values[0] -notmatch '^\d{1,2}\.') { continue }
    if ($cells.Count -ne 4) { throw "Unexpected Westmetall column count for $Year" }
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($values[0], [string[]]@('dd. MMMM yyyy','d. MMMM yyyy'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date) -or
        $date.Year -ne $Year -or $date.Date -gt [datetime]::UtcNow.Date) { throw "Invalid Westmetall date for ${Year}: $($values[0])" }
    $key = $date.ToString('yyyy-MM-dd')
    if ($records.ContainsKey($key)) { throw "Duplicate Westmetall date: $key" }
    $price = ConvertTo-LmeNumber $values[1]
    # Validate the unused three-month price too, so a shifted/malformed table is rejected.
    $null = ConvertTo-LmeNumber $values[2]
    $stock = ConvertTo-LmeNumber $values[3] -Stock
    $records[$key] = @{ p = $price; s = $stock }
  }
  if ($records.Count -eq 0) { throw "Empty or unrecognized Westmetall response for $Year" }
  return $records
}

function ConvertFrom-LmeSilver {
  param([string]$Json)
  $chart = ($Json | ConvertFrom-Json -ErrorAction Stop).chart
  if ($null -eq $chart -or $null -ne $chart.error -or @($chart.result).Count -ne 1 -or $null -eq $chart.result[0]) { throw 'Invalid Yahoo chart response' }
  $result = $chart.result[0]
  if ($result.meta.symbol -ne 'SI=F' -or @($result.indicators.quote).Count -ne 1) { throw 'Unexpected Yahoo symbol or quote structure' }
  $timestamps = @($result.timestamp)
  $closes = @($result.indicators.quote[0].close)
  if ($null -eq $result.timestamp -or $null -eq $result.indicators.quote[0].close -or $timestamps.Count -eq 0 -or $timestamps.Count -ne $closes.Count) { throw 'Missing or misaligned Yahoo observations' }
  $records = @{}
  $seen = @{}
  for ($i = 0; $i -lt $timestamps.Count; $i++) {
    $seconds = 0L
    if ([string]$timestamps[$i] -notmatch '^\d+$' -or -not [long]::TryParse([string]$timestamps[$i], [ref]$seconds) -or $seconds -le 0) { throw 'Invalid Yahoo timestamp' }
    $date = [DateTimeOffset]::FromUnixTimeSeconds($seconds).UtcDateTime
    if ($date.Date -gt [datetime]::UtcNow.Date) { throw 'Future Yahoo date' }
    $key = $date.ToString('yyyy-MM-dd')
    if ($seen.ContainsKey($key)) { throw "Duplicate Yahoo date: $key" }
    $seen[$key] = $true
    # Null closes are expected on exchange holidays; all-null series are not valid.
    if ($null -eq $closes[$i]) { continue }
    if ($closes[$i] -is [string] -or $closes[$i] -is [bool]) { throw 'Yahoo close must be a JSON number' }
    $value = [double]$closes[$i]
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -le 0) { throw 'Invalid Yahoo close' }
    $records[$key] = $value
  }
  if ($records.Count -eq 0) { throw 'Empty Yahoo price series' }
  return $records
}

function ConvertFrom-LmeNews {
  param([string]$Xml, [string]$Metal, [string]$Language, [string[]]$Deny)
  # Disable external entity resolution for untrusted RSS.
  $document = New-Object System.Xml.XmlDocument
  $document.XmlResolver = $null
  $document.LoadXml($Xml)
  $items = @($document.SelectNodes('/rss/channel/item'))
  if ($items.Count -eq 0) { throw "Empty or unrecognized RSS: $Metal/$Language" }
  $accepted = @()
  foreach ($item in $items) {
    $source = [string]$item.source.InnerText
    $title = ([string]$item.title).Trim()
    $link = [string]$item.link
    $date = [DateTimeOffset]::MinValue
    $uri = $null
    if ([string]::IsNullOrWhiteSpace($title) -or [string]::IsNullOrWhiteSpace($source) -or
        -not [uri]::TryCreate($link, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https') -or
        -not [DateTimeOffset]::TryParse([string]$item.pubDate, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$date) -or
        $date.UtcDateTime.Date -gt [datetime]::UtcNow.Date) { throw "Malformed RSS item: $Metal/$Language" }
    $title = ($title -replace ('\s+-\s+' + [regex]::Escape($source) + '$'), '').Trim()
    if ([string]::IsNullOrWhiteSpace($title)) { throw 'Empty RSS title after source removal' }
    $bad = $false
    foreach ($word in $Deny) {
      if ($title.IndexOf($word, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $source.IndexOf($word, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $bad = $true; break }
    }
    if (-not $bad) { $accepted += [pscustomobject]@{ m=$Metal; t=$title; u=$link; s=$source; d=$date.UtcDateTime.ToString('yyyy-MM-dd HH:mm'); l=$Language } }
  }
  if ($accepted.Count -eq 0) { throw "No usable RSS items: $Metal/$Language" }
  return $accepted | Sort-Object -Property d -Descending | Select-Object -First 10
}

function Write-LmeBatch {
  param([string]$Directory, [System.Collections.IDictionary]$Files)
  $staged = @()
  $committed = @()
  $encoding = New-Object Text.UTF8Encoding $false
  try {
    # Stage every complete feed on the destination volume before changing any live file.
    foreach ($name in $Files.Keys) {
      $target = Join-Path $Directory $name
      if ([IO.Directory]::Exists($target)) { throw "Feed destination is a directory: $target" }
      $entry = [pscustomobject]@{ Target=$target; Temp=($target + '.' + [guid]::NewGuid().ToString('N') + '.tmp'); Backup=($target + '.' + [guid]::NewGuid().ToString('N') + '.bak'); Existed=[IO.File]::Exists($target) }
      $staged += $entry
      [IO.File]::WriteAllText($entry.Temp, $Files[$name], $encoding)
    }
    foreach ($entry in $staged) {
      if ($entry.Existed) { [IO.File]::Replace($entry.Temp, $entry.Target, $entry.Backup) }
      else { [IO.File]::Move($entry.Temp, $entry.Target) }
      $committed += $entry
    }
  } catch {
    $failure = $_
    # Best-effort rollback of a filesystem failure during the multi-file commit.
    for ($i = $committed.Count - 1; $i -ge 0; $i--) {
      $entry = $committed[$i]
      try {
        if ($entry.Existed) { [IO.File]::Replace($entry.Backup, $entry.Target, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Delete($entry.Target) }
      } catch { Write-Warning "Rollback failed for $($entry.Target); retained backup $($entry.Backup): $($_.Exception.Message)" }
    }
    throw $failure
  } finally {
    foreach ($entry in $staged) {
      if ([IO.File]::Exists($entry.Temp)) {
        try { [IO.File]::Delete($entry.Temp) } catch { Write-Warning "Could not remove staged file $($entry.Temp)" }
      }
    }
  }
  # Backups are removed only after the entire commit succeeds.
  foreach ($entry in $staged) {
    if ([IO.File]::Exists($entry.Backup)) {
      try { [IO.File]::Delete($entry.Backup) } catch { Write-Warning "Could not remove backup $($entry.Backup)" }
    }
  }
}

function Invoke-LmeCollection {
  param([string]$Directory, [ValidateRange(1,50)][int]$Years = 5)
  $ErrorActionPreference = 'Stop'
  $ci = [Globalization.CultureInfo]::InvariantCulture
  $thisYear = [datetime]::UtcNow.Year
  $wm = @{ c = @{}; a = @{} }
  foreach ($field in @(@('c','LME_Cu_cash'),@('a','LME_Al_cash'))) {
    foreach ($year in (($thisYear - $Years + 1)..$thisYear)) {
      try {
        $response = Invoke-WebRequest -Uri "https://www.westmetall.com/en/markdaten.php?action=table&field=$($field[1])&year=$year" -UseBasicParsing -TimeoutSec 40 -ErrorAction Stop
        $html = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
        $records = ConvertFrom-Westmetall -Html $html -Year $year
        foreach ($date in $records.Keys) { $wm[$field[0]][$date] = $records[$date] }
        Write-Host "Westmetall $($field[0]) $year : $($records.Count) rows"
      } catch { throw "Westmetall $($field[0]) $year failed; feeds unchanged: $($_.Exception.Message)" }
    }
  }
  $response = Invoke-WebRequest -Uri 'https://query1.finance.yahoo.com/v8/finance/chart/SI=F?range=5y&interval=1d' -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
  $silver = ConvertFrom-LmeSilver -Json $response.Content
  $dates = @(@($wm.c.Keys) + @($wm.a.Keys) | Sort-Object -Unique)
  if (@($dates | Where-Object { $silver.ContainsKey($_) }).Count -eq 0) { throw 'Yahoo series does not overlap Westmetall dates; feeds unchanged' }

  $queries = @(
    @('Silver',    'ko', '국제 은값 OR "은 시세" OR "은 선물" OR "은 가격" OR "은값" OR "은 현물" OR "은 ETF" OR "은 수요" OR "은 페이스트 가격"'),
    @('Silver',    'en', '"silver price" OR "silver prices" OR "silver futures" OR "COMEX silver" OR "LBMA silver" OR "spot silver" OR "silver ounce" OR "gold and silver prices" OR "silver rally" OR "silver demand"'),
    @('Aluminium', 'ko', '"알루미늄 가격" OR "알루미늄 LME" OR "LME 알루미늄" OR "알루미늄 시세" OR "알루미늄 재고" OR "알루미늄 공급" OR "알루미늄값"'),
    @('Aluminium', 'en', '"aluminum price" OR "aluminium price" OR "LME aluminium" OR "LME aluminum" OR "aluminum futures" OR "aluminium stocks" OR "aluminium supply" OR "aluminum tariff"'),
    @('Copper',    'ko', '"구리 가격" OR "구리값" OR "구리 LME" OR "LME 구리" OR "구리 시세" OR "구리 재고" OR "구리 선물" OR "구리 광산"'),
    @('Copper',    'en', '"copper price" OR "copper prices" OR "LME copper" OR "copper futures" OR "COMEX copper" OR "copper stocks" OR "copper mine" OR "copper tariff"')
  )
  $deny = @('카지노','도박','토토','바카라','슬롯','배팅','베팅','먹튀','온라인 게임','사이트 메뉴','Roughnecks','casino','gambling','betting','slot machine',
    'Silver Rail','Silver Bulletin','Silver Waves','Silver Lake','Silver Spring','Silver Line','Silver Linings','silver medal','silver screen','총격','shooting','football','basketball','election forecast','토마토','CNT','배터리','statue','동상','trays','pet food','antacid','hydroxide')
  $news = @()
  foreach ($query in $queries) {
    $locale = if ($query[1] -eq 'ko') { '&hl=ko&gl=KR&ceid=KR:ko' } else { '&hl=en-US&gl=US&ceid=US:en' }
    $url = 'https://news.google.com/rss/search?q=' + [uri]::EscapeDataString($query[2] + ' when:7d') + $locale
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    $xml = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
    $news += @(ConvertFrom-LmeNews -Xml $xml -Metal $query[0] -Language $query[1] -Deny $deny)
  }

  # Serialize all three feeds only after every required source has passed validation.
  $lines = foreach ($date in $dates) {
    $copper = if ($wm.c.ContainsKey($date)) { $wm.c[$date].p.ToString($ci) } else { 'null' }
    $aluminium = if ($wm.a.ContainsKey($date)) { $wm.a[$date].p.ToString($ci) } else { 'null' }
    $y = if ($silver.ContainsKey($date)) { ',y:' + [Math]::Round($silver[$date],2).ToString($ci) } else { '' }
    '{{d:"{0}",a:{1},c:{2}{3}}}' -f $date, $aluminium, $copper, $y
  }
  $js = "// 자동 생성: $(Get-Date -Format 'yyyy-MM-dd HH:mm') / 출처: Westmetall LME Cash-Settlement (US`$/톤), 은: Yahoo SI=F`nwindow.LME_DATA=[`n" + ($lines -join ",`n") + "`n];`n"
  $stock = @{}
  foreach ($key in 'c','a') {
    $stock[$key] = ($wm[$key].Keys | Sort-Object | ForEach-Object { '{{d:"{0}",p:{1},s:{2}}}' -f $_, $wm[$key][$_].p.ToString($ci), $wm[$key][$_].s.ToString($ci) }) -join ','
  }
  $sjs = "// 자동 생성: Westmetall LME stock`nwindow.STOCK_DATA={c:[" + $stock.c + '],a:[' + $stock.a + "]};`n"
  $news = @($news | Sort-Object -Property d -Descending | Group-Object -Property m, t | ForEach-Object { $_.Group[0] } | Sort-Object -Property d -Descending)
  $items = @($news | ForEach-Object { $_ | ConvertTo-Json -Compress })
  $njs = "// 자동 생성 뉴스 (Google News RSS, 한글+영문; UTC)`nwindow.NEWS_DATA=[" + ($items -join ',') + "];`n"
  Write-LmeBatch -Directory $Directory -Files ([ordered]@{ 'data.js'=$js; 'stock.js'=$sjs; 'news.js'=$njs })
  Write-Host "Saved validated batch: $($dates.Count) price dates, $($news.Count) news items"
}

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Invoke-LmeCollection -Directory $dir -Years $Years
# Existing public-folder synchronization runs only after a successful local batch.
try { & (Join-Path $dir 'sync_public.ps1') } catch { Write-Host "공개 폴더 갱신 실패: $($_.Exception.Message)" }
