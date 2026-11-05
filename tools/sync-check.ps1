param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = "Stop"
$conflictRoot = Join-Path $Root "content\conflicts"
$identicalDir = Join-Path $conflictRoot "identical"
$reviewDir = Join-Path $conflictRoot "review"
$reportFile = Join-Path $conflictRoot "report.json"
New-Item -ItemType Directory -Force $identicalDir, $reviewDir | Out-Null

$report = @()
if (Test-Path $reportFile) {
  try { $report = @((Get-Content -Raw -Encoding UTF8 $reportFile | ConvertFrom-Json).conflicts) } catch { $report = @() }
}
$patterns = @("*.sync-conflict-*", "*conflicted copy*", "*Konfliktkopie*")
$candidates = Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object {
  $_.FullName -notlike "$conflictRoot*" -and $_.FullName -notlike "$(Join-Path $Root 'versions')*" -and (
    $_.Name -like $patterns[0] -or $_.Name -like $patterns[1] -or $_.Name -like $patterns[2]
  )
}

foreach ($file in $candidates) {
  $baseName = [regex]::Replace($file.Name, "\.sync-conflict-[^.]+(?=\.[^.]+$)", "")
  $baseName = [regex]::Replace($baseName, "\s*\(conflicted copy[^)]*\)(?=\.[^.]+$)", "", "IgnoreCase")
  $original = Join-Path $file.DirectoryName $baseName
  $identical = $false
  if (Test-Path -LiteralPath $original -PathType Leaf) {
    $identical = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash -eq (Get-FileHash -Algorithm SHA256 -LiteralPath $original).Hash
  }
  $destinationDir = if ($identical) { $identicalDir } else { $reviewDir }
  $destinationName = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmssfff"), $file.Name
  $destination = Join-Path $destinationDir $destinationName
  Move-Item -LiteralPath $file.FullName -Destination $destination
  $report += [pscustomobject]@{
    detectedAt = (Get-Date).ToString("o")
    source = $file.FullName.Substring($Root.Length).TrimStart("\")
    original = if (Test-Path -LiteralPath $original) { $original.Substring($Root.Length).TrimStart("\") } else { "" }
    storedAt = $destination.Substring($Root.Length).TrimStart("\")
    status = if ($identical) { "identisch-ausgelagert" } else { "pruefung-erforderlich" }
  }
}

$duplicates = @()
$seen = @{}
foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $Root "content\articles") -Filter "*.md" -File)) {
  $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName
  $title = if ($raw -match "(?m)^title:\s*(.+)$") { $Matches[1].Trim() } else { $file.BaseName }
  $slugValue = if ($raw -match "(?m)^slug:\s*(.+)$") { $Matches[1].Trim() } else { $title }
  $slug = $slugValue.ToLowerInvariant() -replace "[^a-z0-9]+", "-"
  if ($seen.ContainsKey($slug)) { $duplicates += [pscustomobject]@{ slug = $slug; files = @($seen[$slug], $file.FullName) } } else { $seen[$slug] = $file.FullName }
}

$payload = [pscustomobject]@{ checkedAt = (Get-Date).ToString("o"); conflicts = @($report); duplicateSlugs = @($duplicates) }
$payload | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $reportFile
$payload
