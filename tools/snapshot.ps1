param(
  [string]$Root = (Split-Path -Parent $PSScriptRoot),
  [string]$Message = "Automatischer Wiki-Snapshot"
)

$ErrorActionPreference = "Stop"
$mutex = [Threading.Mutex]::new($false, "Local\FirmenWikiSnapshot")
if (-not $mutex.WaitOne(0)) { exit 0 }
try {
  $versions = Join-Path $Root "versions"
  New-Item -ItemType Directory -Force $versions | Out-Null
  # Der Speichern-Request baut bereits via Get-WikiData (inkl. Sync-Check).
  # Hier nur bauen, falls Quellen neuer als data\wiki-data.js sind
  # (gleiche Eingaben wie Get-WikiFingerprint in editor-server.ps1).
  $dataFile = Join-Path $Root "data\wiki-data.js"
  $needsBuild = $true
  if (Test-Path -LiteralPath $dataFile) {
    $dataTime = (Get-Item -LiteralPath $dataFile).LastWriteTimeUtc
    $conflictPrefix = (Join-Path $Root "content\conflicts") + [IO.Path]::DirectorySeparatorChar
    $suggestionPrefix = (Join-Path $Root "content\suggestions") + [IO.Path]::DirectorySeparatorChar
    $maxSource = [datetime]::MinValue
    foreach ($dir in @((Join-Path $Root "content"), (Join-Path $Root "config"), (Join-Path $Root "tools"))) {
      if (-not (Test-Path -LiteralPath $dir)) { continue }
      foreach ($f in (Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.FullName.StartsWith($conflictPrefix, [StringComparison]::OrdinalIgnoreCase) -and -not $_.FullName.StartsWith($suggestionPrefix, [StringComparison]::OrdinalIgnoreCase) })) {
        if ($f.LastWriteTimeUtc -gt $maxSource) { $maxSource = $f.LastWriteTimeUtc }
      }
    }
    $needsBuild = $maxSource -gt $dataTime
  }
  if ($needsBuild) {
    & (Join-Path $PSScriptRoot "build.ps1") -Root $Root | Out-Null
  }
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $zip = Join-Path $versions "wiki-$stamp.zip"
  $items = @("index.html", "assets", "data", "content", "config", "README.md", "tools") | ForEach-Object { Join-Path $Root $_ } | Where-Object { Test-Path $_ }
  Compress-Archive -Path $items -DestinationPath $zip -CompressionLevel Optimal
  [pscustomobject]@{ createdAt = (Get-Date).ToString("o"); message = $Message; archive = [IO.Path]::GetFileName($zip) } |
    ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $versions "wiki-$stamp.json")

  if (Get-Command git -ErrorAction SilentlyContinue) {
    Push-Location $Root
    try {
      git add index.html assets content data config README.md tools .gitignore 2>$null
      git diff --cached --quiet
      if ($LASTEXITCODE -eq 1) { git commit -m $Message 2>$null | Out-Null }
    } catch { Add-Content -Encoding UTF8 (Join-Path $versions "snapshot-errors.log") "$(Get-Date -Format o) Git: $($_.Exception.Message)" } finally { Pop-Location }
  }
} catch {
  Add-Content -Encoding UTF8 (Join-Path $Root "versions\snapshot-errors.log") "$(Get-Date -Format o) Snapshot: $($_.Exception.Message)"
} finally {
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
