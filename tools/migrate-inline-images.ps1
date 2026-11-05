param(
  [string]$Root = (Split-Path -Parent $PSScriptRoot),
  [switch]$WhatIf
)

# Einmal-Migration: bettet Base64-Bilder (data:image/...) aus Artikel-Markdown
# als Dateien unter content\uploads\inline\ aus und ersetzt die Referenzen.
# Grund: jedes eingebettete Bild blaehte data\wiki-data.js dreifach auf
# (editBody + html + searchText) und machte jeden API-Request ~12 s langsam.
# Backups landen unter runtime\migrate-inline-images\<stamp>\ (ausserhalb von content\).

$ErrorActionPreference = "Stop"

$articlesDir = Join-Path $Root "content\articles"
$archiveDir = Join-Path $Root "content\archive"
$inlineDir = Join-Path $Root "content\uploads\inline"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRoot = Join-Path $Root "runtime\migrate-inline-images\$stamp"

$mimeToExt = @{
  "png" = "png"; "jpg" = "jpg"; "jpeg" = "jpg"; "gif" = "gif"
  "webp" = "webp"; "svg+xml" = "svg"; "bmp" = "bmp"
}

$files = @()
if (Test-Path -LiteralPath $articlesDir) { $files += Get-ChildItem -LiteralPath $articlesDir -Filter "*.md" -File }
if (Test-Path -LiteralPath $archiveDir) { $files += Get-ChildItem -LiteralPath $archiveDir -Filter "*.md" -File -Recurse }

$changedFiles = 0
$extractedImages = 0
$bytesSaved = 0

foreach ($file in ($files | Sort-Object FullName)) {
  $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName
  if ($raw.IndexOf("data:image/") -lt 0) { continue }

  $fileChanged = $false
  $new = [regex]::Replace($raw, '\]\(data:image/([^;,\)]+);base64,([A-Za-z0-9+/=\s]+?)\)', {
    param($m)
    $mime = $m.Groups[1].Value.Trim().ToLowerInvariant()
    $b64 = $m.Groups[2].Value -replace "\s+", ""
    if (-not $mimeToExt.ContainsKey($mime)) { return $m.Value }
    if ($b64.Length -lt 100 -or ($b64.Length % 4) -ne 0) { return $m.Value }
    try {
      $bytes = [Convert]::FromBase64String($b64)
    } catch {
      return $m.Value
    }
    $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace("-", "").ToLowerInvariant().Substring(0, 12)
    $ext = $mimeToExt[$mime]
    $base = [IO.Path]::GetFileNameWithoutExtension($file.Name)
    if ($base.Length -gt 30) { $base = $base.Substring(0, 30) }
    $base = ($base.ToLowerInvariant() -replace "[^a-z0-9]+", "-").Trim("-")
    if (-not $base) { $base = "bild" }
    $name = "inline-$base-$sha.$ext"
    $dest = Join-Path $inlineDir $name
    if (-not $WhatIf) {
      New-Item -ItemType Directory -Force $inlineDir | Out-Null
      if (-not (Test-Path -LiteralPath $dest)) {
        [IO.File]::WriteAllBytes($dest, $bytes)
      }
    }
    $script:extractedImages++
    $script:bytesSaved += $m.Value.Length
    return '](content/uploads/inline/' + $name + ')'
  })

  if ($new -ne $raw) {
    $fileChanged = $true
  }

  if ($fileChanged) {
    $changedFiles++
    $rel = $file.FullName.Substring($Root.Length).TrimStart("\", "/")
    if ($WhatIf) {
      Write-Host "WUERDE MIGRIEREN: $rel"
    } else {
      $backupPath = Join-Path $backupRoot $rel
      New-Item -ItemType Directory -Force (Split-Path -Parent $backupPath) | Out-Null
      Copy-Item -LiteralPath $file.FullName -Destination $backupPath -Force
      Set-Content -NoNewline -Encoding UTF8 -LiteralPath $file.FullName -Value $new
      Write-Host "MIGRIERT: $rel"
    }
  }
}

Write-Host "Dateien: $changedFiles, Bilder ausgelagert: $extractedImages, ca. $([math]::Round($bytesSaved / 1KB)) KB Inline-Base64 entfernt."
if (-not $WhatIf -and $changedFiles -gt 0) {
  Write-Host "Backups: $backupRoot"
  Write-Host "Naechster Schritt: tools\\build.ps1 ausfuehren (baut data\\wiki-data.js neu)."
}
