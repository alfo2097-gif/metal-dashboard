# Build a fresh, allowlisted Pages artifact. Never upload the repository root.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$destination = Join-Path $root 'pages_dist'
if (Test-Path $destination) { throw 'pages_dist already exists. Use a fresh checkout/build directory.' }
$files = @('data.js','stock.js','news.js','comments.js','silver_mi.js','shared-config.js','shared-store.js')
foreach ($file in @('metal_dashboard.html') + $files) {
  $path = Join-Path $PSScriptRoot $file
  if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) { throw "Missing or empty build input: $file" }
}
# A valid but stale source response must not be presented as this week's update.
$data = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'data.js'))
foreach ($metal in @('a','c','y')) {
  $dates = @([regex]::Matches($data, '\{d:"(\d{4}-\d{2}-\d{2})",([^}]+)\}') | Where-Object { $_.Groups[2].Value -match ("(?:^|,)" + $metal + ':\d') } | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
  if ($dates.Count -eq 0) { throw "Missing price series: $metal" }
  $latest = [datetime]::ParseExact($dates[-1], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
  if (([datetime]::UtcNow.Date - $latest).TotalDays -gt 10) { throw "Stale price series: $metal ($($dates[-1])). Deployment stopped." }
}
New-Item -ItemType Directory -Path $destination | Out-Null
foreach ($file in $files) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $destination $file) }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'metal_dashboard.html') -Destination (Join-Path $destination 'index.html')
$manifest = [ordered]@{
  collectedAtUtc = [datetime]::UtcNow.ToString('o')
  files = @($files | ForEach-Object { [ordered]@{ name=$_; sha256=(Get-FileHash -LiteralPath (Join-Path $destination $_) -Algorithm SHA256).Hash } })
}
[IO.File]::WriteAllText((Join-Path $destination 'deployment.json'), ($manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
Write-Host 'Built pages_dist from explicit public files only; no Supabase writes.'
