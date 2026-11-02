# Assemble only files approved for the public dashboard repository.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$bundle = Join-Path $root 'github_upload'
if (Test-Path $bundle) { throw 'github_upload exists; preserve it and choose a new destination before rebuilding.' }
$public = @('data.js','stock.js','news.js','comments.js','silver_mi.js','shared-config.js','shared-store.js')
$scripts = @('fetch_lme.ps1','sync_public.ps1','build_pages.ps1')
foreach ($name in @('metal_dashboard.html') + $public + $scripts + @('tests/fetch-lme.test.ps1')) {
  if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) { throw "Missing $name" }
}
New-Item -ItemType Directory -Path (Join-Path $bundle 'metal/tests') -Force | Out-Null
foreach ($name in $public) {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $bundle $name)
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $bundle "metal/$name")
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'metal_dashboard.html') -Destination (Join-Path $bundle 'index.html')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'metal_dashboard.html') -Destination (Join-Path $bundle 'metal/metal_dashboard.html')
foreach ($name in $scripts) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $bundle "metal/$name") }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tests/fetch-lme.test.ps1') -Destination (Join-Path $bundle 'metal/tests/fetch-lme.test.ps1')
Write-Host "Upload the contents, not the enclosing folder: $bundle"
Write-Host 'Create .github/workflows/update-dashboard.yml separately using the prepared workflow file.'
