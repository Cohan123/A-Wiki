param(
  [string]$Message = "Wiki aktualisiert"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $PSScriptRoot "build.ps1"
$versionsDir = Join-Path $root "versions"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$zipPath = Join-Path $versionsDir "wiki-$stamp.zip"
$manifestPath = Join-Path $versionsDir "wiki-$stamp.json"

& $buildScript -Root $root

New-Item -ItemType Directory -Force $versionsDir | Out-Null

$items = @(
  (Join-Path $root "index.html"),
  (Join-Path $root "assets"),
  (Join-Path $root "data"),
  (Join-Path $root "content"),
  (Join-Path $root "README.md")
)

Compress-Archive -Path $items -DestinationPath $zipPath -Force

$manifest = [pscustomobject]@{
  createdAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
  message = $Message
  archive = (Split-Path -Leaf $zipPath)
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 $manifestPath

if (Get-Command git -ErrorAction SilentlyContinue) {
  Push-Location $root
  try {
    if (-not (Test-Path (Join-Path $root ".git"))) {
      git init | Out-Null
    }

    $gitName = git config user.name
    if (-not $gitName) {
      git config user.name "Firmen-Wiki"
    }

    $gitEmail = git config user.email
    if (-not $gitEmail) {
      git config user.email "wiki@local.invalid"
    }

    git add index.html assets content data README.md tools .gitignore
    git diff --cached --quiet
    if ($LASTEXITCODE -eq 1) {
      git commit -m $Message
    } elseif ($LASTEXITCODE -eq 0) {
      Write-Host "Keine Git-Aenderungen fuer Commit."
    } else {
      throw "Git konnte die vorgemerkten Aenderungen nicht pruefen."
    }
  } finally {
    Pop-Location
  }
}

Write-Host "Snapshot erstellt: $zipPath"
