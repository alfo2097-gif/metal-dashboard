$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$html = [IO.File]::ReadAllText((Join-Path $root 'metal_dashboard.html'))
$public = Join-Path (Split-Path $root -Parent) 'metal_public/index.html'
$checks = 0
function Assert-Static([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
  $script:checks++
  Write-Host "PASS: $Message"
}
$ids = @([regex]::Matches($html, 'id="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
$refs = @([regex]::Matches($html, 'getElementById\("([^"]+)"\)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
foreach ($id in $refs) { Assert-Static ($ids -contains $id) "DOM target exists: $id" }
Assert-Static (@($ids | Group-Object | Where-Object Count -gt 1).Count -eq 0) 'DOM IDs are unique'
Assert-Static ($html -notmatch 'draftbox|draftTbl|readDraftCells|function applyDraft') 'Removed draft UI has no stale handlers'
$toolbar = [regex]::Match($html, '(?s)<div class="syncbar">(.*?)</div>').Groups[1].Value
Assert-Static (([regex]::Matches($toolbar, '<button\b')).Count -eq 1 -and $toolbar.Contains('id="publishBtn"')) 'Toolbar has only the save button'
Assert-Static ($html.Contains('getData("text/plain")')) 'Pasted commentary uses plain text'
Assert-Static ($html.Contains('el.dispatchEvent(new Event("input",{bubbles:true}))')) 'Paste marks commentary dirty through input handler'
Assert-Static ($html.Contains('saveInputs();await shared.reload();')) 'Conflict recovery preserves a backup before reloading'
Assert-Static ($html.Contains('const monday=viewCell ? sh(T(friOf(viewCell)),-4) : mondayOf(last)')) 'Latest feed week is independent of report date'
Assert-Static ($html.Contains('shared.saveDrafts(clean)')) 'Legacy drafts remain recoverable through backup import'
Assert-Static ((Get-FileHash (Join-Path $root 'metal_dashboard.html')).Hash -eq (Get-FileHash $public).Hash) 'Public HTML matches source'
Write-Host "$checks static checks passed. Browser execution and live Supabase behavior are not tested here."
