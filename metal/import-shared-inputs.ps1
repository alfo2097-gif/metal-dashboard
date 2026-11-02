param([switch]$Publish)
$ErrorActionPreference = 'Stop'
# Read data assignments as JSON, never execute imported JavaScript.
function Read-AssignmentJson([string]$Path) {
  $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
  $start = $text.IndexOf('=') + 1
  $end = $text.LastIndexOf(';')
  if ($start -le 0 -or $end -le $start) { throw 'Invalid data assignment' }
  return ($text.Substring($start, $end - $start) | ConvertFrom-Json)
}
$comments = Read-AssignmentJson (Join-Path $PSScriptRoot 'comments.js')
$silver = Read-AssignmentJson (Join-Path $PSScriptRoot 'silver_mi.js')
$configText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'shared-config.js'), [Text.Encoding]::UTF8)
$url = [regex]::Match($configText, 'url:\s*"([^"]+)"').Groups[1].Value
$key = [regex]::Match($configText, 'publishableKey:\s*"([^"]+)"').Groups[1].Value
if (-not $url.StartsWith('https://') -or -not $key.StartsWith('sb_publishable_')) { throw 'Public configuration required' }
$headers = @{ apikey = $key }
$readUrl = $url + '/rest/v1/metal_shared_state?id=eq.main&select=revision,payload,updated_at'
$current = @(Invoke-RestMethod -Uri $readUrl -Headers $headers -Method Get -TimeoutSec 30)
if ($current.Count -gt 0) { throw 'Shared state now exists. Stop: review current snapshot before merging; do not overwrite.' }
$reports = [ordered]@{}
$locks = [ordered]@{}
foreach ($r in $comments) {
  $reports[$r.w] = [ordered]@{ f=$r.f; sheet=$r.sheet; s=$r.s; a=$r.a; c=$r.c; n=$r.n }
  $locks[$r.w] = $r.sheet -ne '(웹 작성)'
}
$payload = [ordered]@{schema=1; reports=$reports; locks=$locks; silver=$silver; news=@(); latest='2026-10-30'}
$week = @(54.05,53.27,53.77,52.42,50.1)
$previous = @(57.64,57.1,57.55,55.84,53.9)
$a = ($week | Measure-Object -Average).Average
$b = ($previous | Measure-Object -Average).Average
[pscustomobject]@{Reports=$reports.Count; SilverDays=$silver.PSObject.Properties.Count; Latest=$payload.latest; WeeklyAverage=$a; PreviousAverage=$b; ChangePercent=($a/$b-1)*100}
if (-not $Publish) { return }
$body = @{p_expected_revision=0; p_payload=$payload} | ConvertTo-Json -Depth 12 -Compress
$result = Invoke-RestMethod -Uri ($url+'/rest/v1/rpc/metal_save') -Headers $headers -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30
$verified = @(Invoke-RestMethod -Uri $readUrl -Headers $headers -Method Get -TimeoutSec 30)
if ($verified.Count -ne 1) { throw 'Published response received but read-back failed' }
$r = $verified[0]
if ($r.payload.reports.'2026-10-30'.s -cne $reports['2026-10-30'].s -or $r.payload.reports.'2026-10-30'.a -cne $reports['2026-10-30'].a -or $r.payload.silver.'2026-10-30' -ne 50.1) { throw 'Read-back differs; inspect latest server data before retrying' }
[pscustomobject]@{Verified=$true; Revision=$r.revision; UpdatedAt=$r.updated_at; SilverOct30=$r.payload.silver.'2026-10-30'}
