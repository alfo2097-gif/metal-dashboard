# metal 폴더의 대시보드 파일을 공개용 폴더(metal_public)로 복사한다. (GitHub 등에 올릴 폴더)
# 사용: powershell -File sync_public.ps1
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$dst = Join-Path (Split-Path -Parent $src) "metal_public"
New-Item -ItemType Directory -Force $dst | Out-Null
$files = "data.js","stock.js","news.js","comments.js","silver_mi.js","shared-config.js","shared-store.js"
foreach ($f in $files) {
  if (Test-Path (Join-Path $src $f)) { Copy-Item (Join-Path $src $f) (Join-Path $dst $f) -Force }
  else { Write-Host "없음: $f" }
}
Copy-Item (Join-Path $src "metal_dashboard.html") (Join-Path $dst "index.html") -Force
# Preserve the old draft outside the public bundle; never overwrite a previous backup.
$oldDraft = Join-Path $dst "draft.js"
if (Test-Path $oldDraft) {
  $backup = Join-Path $src ("draft-public-backup-" + [guid]::NewGuid().ToString("N") + ".js")
  Move-Item -LiteralPath $oldDraft -Destination $backup
  Write-Host "Previous public draft preserved: $backup"
}
Write-Host "공개용 폴더 갱신: $dst"
Get-ChildItem $dst | ForEach-Object { Write-Host ("{0,-16} {1}" -f $_.Name, $_.LastWriteTime) }
