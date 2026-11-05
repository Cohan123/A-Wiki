param(
  [int]$Port = 8765,
  [string]$Root = (Split-Path -Parent $PSScriptRoot),
  [string]$BindAddress = "0.0.0.0"
)

$ErrorActionPreference = "Stop"

$articlesDir = Join-Path $Root "content\articles"
$archiveDir = Join-Path $Root "content\archive"
$uploadsDir = Join-Path $Root "content\uploads"
$suggestionsDir = Join-Path $Root "content\suggestions"
$categoriesFile = Join-Path $Root "content\categories.json"
$categoryGroupsFile = Join-Path $Root "content\category-groups.json"
$productsFile = Join-Path $Root "content\products.json"
$productArchiveFile = Join-Path $Root "content\product-archive.json"
$buildScript = Join-Path $PSScriptRoot "build.ps1"
$backupDir = Join-Path $Root "versions\backups"
$backupConfigFile = Join-Path $Root "runtime\backup-config.json"

New-Item -ItemType Directory -Force $articlesDir, $archiveDir, $uploadsDir, $suggestionsDir, $backupDir | Out-Null

function ConvertTo-Slug {
  param([string]$Text)
  $slug = $Text.ToLowerInvariant()
  $slug = $slug.Replace([string][char]0x00e4, "ae").Replace([string][char]0x00f6, "oe").Replace([string][char]0x00fc, "ue").Replace([string][char]0x00df, "ss")
  $slug = [regex]::Replace($slug, "[^a-z0-9]+", "-").Trim("-")
  if ([string]::IsNullOrWhiteSpace($slug)) { return "artikel" }
  return $slug
}

function Sanitize-Line {
  param([string]$Value)
  return (($Value -replace "\r?\n", " ") -replace "\s+", " ").Trim()
}

function Sanitize-FileName {
  param([string]$Value)
  $name = [IO.Path]::GetFileName((Sanitize-Line $Value))
  if ([string]::IsNullOrWhiteSpace($name)) { $name = "datei" }
  return [regex]::Replace($name, "[^\p{L}\p{Nd}\.\-_ ]+", "_").Trim()
}

. (Join-Path $PSScriptRoot "server-security.ps1")

function Start-WikiSnapshot {
  param([string]$Message)
  try {
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
      "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
      "-File", (Join-Path $PSScriptRoot "snapshot.ps1"), "-Root", $Root, "-Message", $Message
    ) -WorkingDirectory $Root -WindowStyle Hidden | Out-Null
  } catch {
    Add-Content -Encoding UTF8 (Join-Path $Root "versions\snapshot-errors.log") "$(Get-Date -Format o) Start: $($_.Exception.Message)"
  }
}

function Read-Products {
  if (-not (Test-Path $productsFile)) { return @() }
  $rawItems = Get-Content -Raw -Encoding UTF8 $productsFile | ConvertFrom-Json
  $products = @()
  foreach ($item in $rawItems) {
    $name = Sanitize-Line $item.name
    $article = if ($item.PSObject.Properties.Name -contains "article") { Sanitize-Line $item.article } else { Sanitize-Line $item.artikel }
    $hardwareRevision = if ($item.PSObject.Properties.Name -contains "hardwareRevision") { Sanitize-Line $item.hardwareRevision } else { Sanitize-Line $item.hardwarerevision }
    $description = if ($item.PSObject.Properties.Name -contains "description") { Sanitize-Line $item.description } else { "" }
    $id = if ($item.PSObject.Properties.Name -contains "id") { Sanitize-Line $item.id } else { ConvertTo-Slug "$name-$article-$hardwareRevision" }
    $categories = @()
    if ($item.PSObject.Properties.Name -contains "categories") {
      foreach ($category in $item.categories) { $categories += Sanitize-Line $category }
    }
    if ($item.PSObject.Properties.Name -contains "categoryIds") {
      foreach ($category in $item.categoryIds) { $categories += Sanitize-Line $category }
    }
    $revision = 1
    if ($item.PSObject.Properties.Name -contains "revision") { [int]::TryParse([string]$item.revision, [ref]$revision) | Out-Null }
    $status = if ($item.PSObject.Properties.Name -contains "status") { Sanitize-Line $item.status } else { "Aktiv" }
    $updated = if ($item.PSObject.Properties.Name -contains "updated") { Sanitize-Line $item.updated } else { "" }
    $changeDate = if ($item.PSObject.Properties.Name -contains "changeDate") { Sanitize-Line $item.changeDate } elseif ($item.PSObject.Properties.Name -contains "change_date") { Sanitize-Line $item.change_date } else { "" }
    $changeAction = if ($item.PSObject.Properties.Name -contains "changeAction") { Sanitize-Line $item.changeAction } elseif ($item.PSObject.Properties.Name -contains "change_action") { Sanitize-Line $item.change_action } else { "" }
    $changeReason = if ($item.PSObject.Properties.Name -contains "changeReason") { Sanitize-Line $item.changeReason } elseif ($item.PSObject.Properties.Name -contains "change_reason") { Sanitize-Line $item.change_reason } else { "" }
    $deleteRequest = $null
    if ($item.PSObject.Properties.Name -contains "deleteRequest" -and $null -ne $item.deleteRequest) {
      $deleteRequestBy = if ($item.deleteRequest.PSObject.Properties.Name -contains "by") { Sanitize-Line $item.deleteRequest.by } else { "" }
      if (-not [string]::IsNullOrWhiteSpace($deleteRequestBy)) {
        $deleteRequest = [pscustomobject]@{
          by = $deleteRequestBy
          at = if ($item.deleteRequest.PSObject.Properties.Name -contains "at") { Sanitize-Line $item.deleteRequest.at } else { "" }
          reason = if ($item.deleteRequest.PSObject.Properties.Name -contains "reason") { Sanitize-Line $item.deleteRequest.reason } else { "" }
        }
      }
    }
    if ($name -and $article) {
      $products += [pscustomobject]@{
        id = $id
        name = $name
        article = $article
        hardwareRevision = $hardwareRevision
        description = $description
        categories = @($categories | Where-Object { $_ } | Select-Object -Unique)
        revision = [Math]::Max(1, $revision)
        status = if ($status) { $status } else { "Aktiv" }
        updated = $updated
        changeDate = $changeDate
        changeAction = $changeAction
        changeReason = $changeReason
        deleteRequest = $deleteRequest
      }
    }
  }
  return @($products)
}

function Write-Products {
  param([array]$Products)
  Write-JsonFileAtomic -Path $productsFile -Data $Products
}

function Read-ArchivedProducts {
  if (-not (Test-Path $productArchiveFile)) { return @() }
  $rawItems = Get-Content -Raw -Encoding UTF8 $productArchiveFile | ConvertFrom-Json
  $products = @()
  foreach ($item in $rawItems) {
    $name = Sanitize-Line $item.name
    $article = if ($item.PSObject.Properties.Name -contains "article") { Sanitize-Line $item.article } else { Sanitize-Line $item.artikel }
    $hardwareRevision = if ($item.PSObject.Properties.Name -contains "hardwareRevision") { Sanitize-Line $item.hardwareRevision } else { Sanitize-Line $item.hardwarerevision }
    $description = if ($item.PSObject.Properties.Name -contains "description") { Sanitize-Line $item.description } else { "" }
    $id = if ($item.PSObject.Properties.Name -contains "id") { Sanitize-Line $item.id } else { ConvertTo-Slug "$name-$article-$hardwareRevision" }
    $categories = @()
    if ($item.PSObject.Properties.Name -contains "categories") {
      foreach ($category in $item.categories) { $categories += Sanitize-Line $category }
    }
    $revision = 1
    if ($item.PSObject.Properties.Name -contains "revision") { [int]::TryParse([string]$item.revision, [ref]$revision) | Out-Null }
    if ($name -and $article) {
      $products += [pscustomobject]@{
        id = $id
        name = $name
        article = $article
        hardwareRevision = $hardwareRevision
        description = $description
        categories = @($categories | Where-Object { $_ } | Select-Object -Unique)
        revision = [Math]::Max(1, $revision)
        status = if ($item.PSObject.Properties.Name -contains "status") { Sanitize-Line $item.status } else { "Archiviert" }
        updated = if ($item.PSObject.Properties.Name -contains "updated") { Sanitize-Line $item.updated } else { "" }
        changeDate = if ($item.PSObject.Properties.Name -contains "changeDate") { Sanitize-Line $item.changeDate } elseif ($item.PSObject.Properties.Name -contains "change_date") { Sanitize-Line $item.change_date } else { "" }
        changeAction = if ($item.PSObject.Properties.Name -contains "changeAction") { Sanitize-Line $item.changeAction } elseif ($item.PSObject.Properties.Name -contains "change_action") { Sanitize-Line $item.change_action } else { "" }
        changeReason = if ($item.PSObject.Properties.Name -contains "changeReason") { Sanitize-Line $item.changeReason } elseif ($item.PSObject.Properties.Name -contains "change_reason") { Sanitize-Line $item.change_reason } else { "" }
      }
    }
  }
  return @($products)
}

function Write-ArchivedProducts {
  param([array]$Products)
  Write-JsonFileAtomic -Path $productArchiveFile -Data $Products
}

function Read-Categories {
  if (-not (Test-Path $categoriesFile)) { return @() }
  $rawItems = Get-Content -Raw -Encoding UTF8 $categoriesFile | ConvertFrom-Json
  $categories = @()
  foreach ($item in $rawItems) {
    if ($item -is [string]) {
      $name = Sanitize-Line $item
      if ($name) { $categories += [pscustomobject]@{ name = $name; products = @() } }
    } else {
      $name = Sanitize-Line $item.name
      $products = @()
      if ($item.PSObject.Properties.Name -contains "products") {
        foreach ($productId in $item.products) { $products += Sanitize-Line $productId }
      }
      if ($item.PSObject.Properties.Name -contains "productIds") {
        foreach ($productId in $item.productIds) { $products += Sanitize-Line $productId }
      }
      if ($name) { $categories += [pscustomobject]@{ name = $name; products = @($products | Where-Object { $_ }) } }
    }
  }
  return @($categories)
}

function Write-JsonFileAtomic {
  # Schreibt JSON-Daten atomar (tmp + Move), damit nebenlaeufige Leser
  # (Server, Build, Tests) nie eine halb geschriebene/leere Datei sehen.
  param([string]$Path, [array]$Data)
  $json = ConvertTo-Json -InputObject @($Data) -Depth 8
  $temporary = "$Path.tmp"
  Set-Content -Encoding UTF8 -LiteralPath $temporary -Value $json
  Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-Categories {
  param([array]$Categories)
  Write-JsonFileAtomic -Path $categoriesFile -Data $Categories
}

function Read-CategoryGroups {
  if (-not (Test-Path $categoryGroupsFile)) { return @() }
  $rawItems = Get-Content -Raw -Encoding UTF8 $categoryGroupsFile | ConvertFrom-Json
  $groups = @()
  foreach ($item in $rawItems) {
    $name = Sanitize-Line $item.name
    $categories = @()
    if ($item.PSObject.Properties.Name -contains "categories") {
      foreach ($category in $item.categories) { $categories += Sanitize-Line $category }
    }
    if ($name) { $groups += [pscustomobject]@{ name = $name; categories = @($categories | Where-Object { $_ } | Select-Object -Unique) } }
  }
  return @($groups)
}

function Write-CategoryGroups {
  param([array]$Groups)
  Write-JsonFileAtomic -Path $categoryGroupsFile -Data $Groups
}

function Read-FrontMatter {
  param([string]$Text)
  $result = @{ Meta = @{}; Body = $Text }
  if (-not $Text.StartsWith("---")) { return $result }
  $match = [regex]::Match($Text, "(?s)^---\r?\n(.*?)\r?\n---\r?\n?(.*)$")
  if (-not $match.Success) { return $result }
  foreach ($line in ($match.Groups[1].Value -split "\r?\n")) {
    $pair = [regex]::Match($line, "^\s*([A-Za-z0-9_-]+)\s*:\s*(.*?)\s*$")
    if ($pair.Success) {
      $result.Meta[$pair.Groups[1].Value.ToLowerInvariant()] = $pair.Groups[2].Value.Trim().Trim('"')
    }
  }
  $result.Body = $match.Groups[2].Value.Trim()
  return $result
}

function Remove-RevisionLog {
  param([string]$Body)
  return [regex]::Replace($Body, "(?s)\r?\n?<!-- WIKI_REVISION_LOG_START -->.*?<!-- WIKI_REVISION_LOG_END -->\r?\n?", "").Trim()
}

function Get-RevisionLog {
  param([string]$Body)
  $match = [regex]::Match($Body, "(?s)<!-- WIKI_REVISION_LOG_START -->(.*?)<!-- WIKI_REVISION_LOG_END -->")
  if ($match.Success) { return $match.Groups[1].Value.Trim() }
  return ""
}

function Add-RevisionEntry {
  param(
    [string]$Body,
    [string]$ExistingLog,
    [int]$Revision,
    [string]$Action,
    [string]$Reason,
    [string]$ChangedBy = "System"
  )
  $cleanBody = Remove-RevisionLog $Body
  $log = $ExistingLog.Trim()
  if ([string]::IsNullOrWhiteSpace($log)) { $log = "## Revisionsverlauf" }
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm"
  $safeReason = Sanitize-Line $Reason
  $actor = Sanitize-Line $ChangedBy
  $log = $log.TrimEnd() + "`n- ${timestamp}: Revision $Revision, $Action durch $actor. Grund: $safeReason"
  return ($cleanBody.TrimEnd() + "`n`n<!-- WIKI_REVISION_LOG_START -->`n" + $log + "`n<!-- WIKI_REVISION_LOG_END -->`n")
}

function Read-AttachmentMeta {
  param([hashtable]$Meta)
  if (-not $Meta.ContainsKey("attachments") -or [string]::IsNullOrWhiteSpace($Meta["attachments"])) { return @() }
  return $Meta["attachments"] -split ";" | ForEach-Object {
    $entry = $_.Trim()
    if ($entry) {
      $parts = $entry -split "\|", 2
      $path = $parts[0].Trim()
      $name = if ($parts.Count -gt 1) { $parts[1].Trim() } else { [IO.Path]::GetFileName($path) }
      if ($path) { [pscustomobject]@{ path = $path; name = $name } }
    }
  }
}

function Format-AttachmentMeta {
  param([array]$Attachments)
  $items = @()
  foreach ($attachment in @($Attachments)) {
    if ($null -eq $attachment) { continue }
    $path = if ($attachment.PSObject.Properties.Name -contains "path") { Sanitize-Line $attachment.path } else { "" }
    $name = if ($attachment.PSObject.Properties.Name -contains "name") { Sanitize-Line $attachment.name } else { [IO.Path]::GetFileName($path) }
    if ($path) { $items += "$path|$name" }
  }
  return ($items -join "; ")
}

function Read-ProductMeta {
  param([hashtable]$Meta)
  if (-not $Meta.ContainsKey("products") -or [string]::IsNullOrWhiteSpace($Meta["products"])) { return @() }
  return $Meta["products"].Trim("[", "]") -split "," |
    ForEach-Object { (Sanitize-Line $_).Trim('"').Trim("'") } |
    Where-Object { $_ }
}

function Read-RelatedMeta {
  param([hashtable]$Meta)
  if (-not $Meta.ContainsKey("related") -or [string]::IsNullOrWhiteSpace($Meta["related"])) { return @() }
  return $Meta["related"].Trim("[", "]") -split "," |
    ForEach-Object { (Sanitize-Line $_).Trim('"').Trim("'") } |
    Where-Object { $_ }
}

function ConvertTo-RelatedSlugs {
  param([array]$Related)
  $items = @()
  foreach ($item in @($Related)) {
    $raw = [string]$item
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    $slug = ConvertTo-Slug $raw
    if ($slug -and $items -notcontains $slug) { $items += $slug }
  }
  return @($items)
}

function Format-RelatedMeta {
  param([array]$Related)
  return ((ConvertTo-RelatedSlugs -Related $Related) -join ", ")
}

function Set-RelatedInRaw {
  # Ersetzt ausschliesslich das related-Feld im Frontmatter; alle anderen
  # Zeilen und der Body bleiben bytegenau erhalten.
  param([string]$Raw, [array]$Related)
  $value = Format-RelatedMeta -Related $Related
  $match = [regex]::Match($Raw, "(?s)^(---\r?\n)(.*?)(\r?\n---(?:\r?\n|$))(.*)$")
  if (-not $match.Success) { return $Raw }
  $opening = $match.Groups[1].Value
  $frontmatter = $match.Groups[2].Value
  $closing = $match.Groups[3].Value
  $body = $match.Groups[4].Value
  $newline = if ($opening.Contains("`r`n")) { "`r`n" } else { "`n" }
  $lines = New-Object System.Collections.Generic.List[string]
  $found = $false
  foreach ($line in [regex]::Split($frontmatter, "\r?\n")) {
    if ($line -match "^\s*related\s*:") {
      if (-not $found) {
        $lines.Add("related: $value")
        $found = $true
      }
      continue
    }
    $lines.Add($line)
  }
  if (-not $found) { $lines.Add("related: $value") }
  return $opening + ($lines -join $newline) + $closing + $body
}

function Get-ActiveRelatedMap {
  $map = @{}
  foreach ($file in (Get-ChildItem $articlesDir -Filter "*.md" -File)) {
    $raw = Get-Content -Raw -Encoding UTF8 $file.FullName
    $parsed = Read-FrontMatter $raw
    $title = if ($parsed.Meta.ContainsKey("title")) { $parsed.Meta["title"] } else { $file.BaseName }
    $slug = if ($parsed.Meta.ContainsKey("slug")) { ConvertTo-Slug $parsed.Meta["slug"] } else { ConvertTo-Slug $title }
    $map[$slug] = @(ConvertTo-RelatedSlugs -Related @(Read-RelatedMeta $parsed.Meta))
  }
  return $map
}

function Get-EffectiveRelated {
  param([string]$Slug, [hashtable]$Map)
  $values = New-Object System.Collections.Generic.List[string]
  if ($Map.ContainsKey($Slug)) {
    foreach ($item in @($Map[$Slug])) {
      if ($item -and $item -ne $Slug -and -not $values.Contains($item)) { $values.Add($item) }
    }
  }
  foreach ($other in @($Map.Keys)) {
    if ($other -ne $Slug -and @($Map[$other]) -contains $Slug -and -not $values.Contains($other)) {
      $values.Add($other)
    }
  }
  return @($values)
}

function Plan-RelatedSync {
  param([string]$CurrentSlug, [array]$NewRelated, [object]$BaseRelated)
  $map = Get-ActiveRelatedMap
  $effectiveNow = @(Get-EffectiveRelated -Slug $CurrentSlug -Map $map)
  $requested = @(ConvertTo-RelatedSlugs -Related $NewRelated | Where-Object { $_ -ne $CurrentSlug })
  if ($null -eq $BaseRelated) {
    $baseSet = @($effectiveNow)
  } else {
    $baseSet = @(ConvertTo-RelatedSlugs -Related @($BaseRelated) | Where-Object { $_ -ne $CurrentSlug })
  }
  $concurrent = @($effectiveNow | Where-Object { $baseSet -notcontains $_ })
  $final = @($requested)
  foreach ($item in $concurrent) {
    if ($final -notcontains $item) { $final += $item }
  }
  $additions = @($final | Where-Object { $effectiveNow -notcontains $_ })
  $removals = @($baseSet | Where-Object { $requested -notcontains $_ })
  return [pscustomobject]@{
    Final = @($final)
    Additions = @($additions)
    Removals = @($removals)
  }
}

function Set-RelatedMembership {
  param([string]$TargetSlug, [string]$MemberSlug, [bool]$Present)
  if ([string]::IsNullOrWhiteSpace($TargetSlug) -or [string]::IsNullOrWhiteSpace($MemberSlug) -or $TargetSlug -eq $MemberSlug) { return $false }
  $target = Get-ArticleBySlug $TargetSlug
  if (-not $target) { return $false }
  $related = @(ConvertTo-RelatedSlugs -Related @(Read-RelatedMeta $target.Meta) | Where-Object { $_ -ne $TargetSlug })
  if ($Present) {
    if ($related -contains $MemberSlug) { return $false }
    $related += $MemberSlug
  } else {
    if ($related -notcontains $MemberSlug) { return $false }
    $related = @($related | Where-Object { $_ -ne $MemberSlug })
  }
  $newRaw = Set-RelatedInRaw -Raw $target.Raw -Related $related
  if ($newRaw -eq $target.Raw) { return $false }
  [IO.File]::WriteAllText($target.File.FullName, $newRaw, [Text.UTF8Encoding]::new($false))
  return $true
}

function Apply-RelatedChanges {
  param([string]$CurrentSlug, [array]$Additions, [array]$Removals, [string]$PreviousSlug = "")
  foreach ($target in @($Additions)) { Set-RelatedMembership -TargetSlug $target -MemberSlug $CurrentSlug -Present $true | Out-Null }
  foreach ($target in @($Removals)) {
    Set-RelatedMembership -TargetSlug $target -MemberSlug $CurrentSlug -Present $false | Out-Null
    if ($PreviousSlug -and $PreviousSlug -ne $CurrentSlug) {
      Set-RelatedMembership -TargetSlug $target -MemberSlug $PreviousSlug -Present $false | Out-Null
    }
  }
}

function Rename-RelatedReferences {
  param([string]$OldSlug, [string]$NewSlug)
  if ([string]::IsNullOrWhiteSpace($OldSlug) -or [string]::IsNullOrWhiteSpace($NewSlug) -or $OldSlug -eq $NewSlug) { return }
  foreach ($file in (Get-ChildItem $articlesDir -Filter "*.md" -File)) {
    $raw = Get-Content -Raw -Encoding UTF8 $file.FullName
    $parsed = Read-FrontMatter $raw
    $title = if ($parsed.Meta.ContainsKey("title")) { $parsed.Meta["title"] } else { $file.BaseName }
    $slug = if ($parsed.Meta.ContainsKey("slug")) { ConvertTo-Slug $parsed.Meta["slug"] } else { ConvertTo-Slug $title }
    if ($slug -eq $NewSlug) { continue }
    $related = @(ConvertTo-RelatedSlugs -Related @(Read-RelatedMeta $parsed.Meta))
    if ($related -notcontains $OldSlug) { continue }
    $changed = @()
    foreach ($item in $related) {
      $replacement = if ($item -eq $OldSlug) { $NewSlug } else { $item }
      if ($changed -notcontains $replacement) { $changed += $replacement }
    }
    $newRaw = Set-RelatedInRaw -Raw $raw -Related $changed
    if ($newRaw -ne $raw) { [IO.File]::WriteAllText($file.FullName, $newRaw, [Text.UTF8Encoding]::new($false)) }
  }
}

function Format-ProductMeta {
  param([array]$ProductIds)
  $items = @()
  foreach ($productId in @($ProductIds)) {
    $value = Sanitize-Line $productId
    if ($value) { $items += $value }
  }
  return (($items | Select-Object -Unique) -join ", ")
}

function Read-CategoryMeta {
  param([hashtable]$Meta)
  if ($Meta.ContainsKey("categories") -and -not [string]::IsNullOrWhiteSpace($Meta["categories"])) {
    return $Meta["categories"].Trim("[", "]") -split "," |
      ForEach-Object { Sanitize-Line $_ } |
      Where-Object { $_ } |
      Select-Object -Unique
  }
  if ($Meta.ContainsKey("category") -and -not [string]::IsNullOrWhiteSpace($Meta["category"])) {
    return @(Sanitize-Line $Meta["category"])
  }
  return @()
}

function Get-ArticleCategoriesFromData {
  param([object]$Data)
  $categories = @()
  if ($Data.PSObject.Properties.Name -contains "categories") {
    foreach ($category in $Data.categories) { $categories += Sanitize-Line $category }
  }
  if ($categories.Count -eq 0 -and $Data.PSObject.Properties.Name -contains "category") {
    $categories += Sanitize-Line $Data.category
  }
  $categories = @($categories | Where-Object { $_ } | Select-Object -Unique)
  if ($categories.Count -eq 0) { throw "Mindestens eine Kategorie muss ausgewaehlt werden." }
  $knownCategories = @(Read-Categories | ForEach-Object { $_.name })
  foreach ($category in $categories) {
    if ($knownCategories -notcontains $category) { throw "Unbekannte Kategorie: $category" }
  }
  return @($categories)
}

function Format-CategoryMeta {
  param([array]$Categories)
  return ((@($Categories) | ForEach-Object { Sanitize-Line $_ } | Where-Object { $_ } | Select-Object -Unique) -join ", ")
}

function Read-DeleteRequestMeta {
  param([hashtable]$Meta)
  if (-not $Meta.ContainsKey("delete_request_by") -or [string]::IsNullOrWhiteSpace($Meta["delete_request_by"])) { return $null }
  return [pscustomobject]@{
    by = [string]$Meta["delete_request_by"]
    at = if ($Meta.ContainsKey("delete_request_at")) { [string]$Meta["delete_request_at"] } else { "" }
    reason = if ($Meta.ContainsKey("delete_request_reason")) { [string]$Meta["delete_request_reason"] } else { "" }
  }
}

function Format-DeleteRequestMeta {
  param([object]$DeleteRequest)
  if ($null -eq $DeleteRequest) { return @("", "", "") }
  $by = Sanitize-Line $DeleteRequest.by
  if ([string]::IsNullOrWhiteSpace($by)) { return @("", "", "") }
  return @($by, (Sanitize-Line $DeleteRequest.at), (Sanitize-Line $DeleteRequest.reason))
}

function Save-UploadedFiles {
  param(
    [string]$ArticleSlug,
    [array]$Files
  )

  # Punkt 6 (Sicherheit): erlaubte Bild-/Dateiformate, max. 8 MB, MIME-Sniffing,
  # Dateinamen sanitizen, Kollisionen auflösen, Path Traversal verhindern.
  # Ablage: content/uploads/<artikel-slug>/ (stabile technische ID = Slug;
  # Umbenennungen machen Dateien nicht unbrauchbar, Kategorie/Produkt stehen als
  # Metadaten im Artikel-Frontmatter und werden beim Backup mitgesichert).
  $allowedExt = @(".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg", ".pdf")
  $maxBytes = 8 * 1024 * 1024
  $saved = @()
  if ([string]::IsNullOrWhiteSpace($ArticleSlug)) { $ArticleSlug = "medien" }
  $targetSlug = ConvertTo-Slug $ArticleSlug
  $targetDir = Join-Path $uploadsDir $targetSlug
  New-Item -ItemType Directory -Force $targetDir | Out-Null
  $targetFull = [IO.Path]::GetFullPath($targetDir)

  foreach ($file in @($Files)) {
    if ($null -eq $file) { continue }
    $name = if ($file.PSObject.Properties.Name -contains "name") { Sanitize-FileName $file.name } else { "datei" }
    $base64 = if ($file.PSObject.Properties.Name -contains "data") { [string]$file.data } else { "" }
    if ($base64 -match "^data:[^;]+;base64,(.+)$") { $base64 = $Matches[1] }
    if ([string]::IsNullOrWhiteSpace($base64)) { continue }
    try { $bytes = [Convert]::FromBase64String(($base64 -replace "\s+", "")) } catch { continue }
    if ($bytes.Length -eq 0 -or $bytes.Length -gt $maxBytes) { continue }
    $ext = [IO.Path]::GetExtension($name).ToLowerInvariant()
    if ($allowedExt -notcontains $ext) { continue }
    if (-not (Test-ImageBytes -Bytes $bytes -Extension $ext)) { continue }
    $path = Join-Path $targetFull $name
    $stem = [IO.Path]::GetFileNameWithoutExtension($name)
    if ([string]::IsNullOrWhiteSpace($stem)) { $stem = "datei" }
    $counter = 1
    while (Test-Path -LiteralPath $path) {
      $path = Join-Path $targetFull ("$stem-$counter$ext")
      $counter += 1
      if ($counter -gt 500) { break }
    }
    $resolved = [IO.Path]::GetFullPath($path)
    if (-not $resolved.StartsWith($targetFull, [StringComparison]::OrdinalIgnoreCase)) { continue }
    [IO.File]::WriteAllBytes($resolved, $bytes)
    $relative = $resolved.Substring($Root.Length).TrimStart("\", "/") -replace "\\", "/"
    $saved += [pscustomobject]@{ path = $relative; name = [IO.Path]::GetFileName($resolved) }
  }

  return @($saved)
}

function Test-ImageBytes {
  param([byte[]]$Bytes, [string]$Extension)
  try {
    if ($Extension -eq ".pdf") {
      return $Bytes.Length -gt 4 -and $Bytes[0] -eq 0x25 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x44 -and $Bytes[3] -eq 0x46
    }
    if ($Extension -eq ".svg") {
      $head = [Text.Encoding]::UTF8.GetString($Bytes, 0, [Math]::Min(512, $Bytes.Length))
      return $head -match "<svg"
    }
    if ($Bytes.Length -lt 4) { return $false }
    $png = ($Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x4E -and $Bytes[3] -eq 0x47)
    $jpg = ($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xD8 -and $Bytes[2] -eq 0xFF)
    $gif = ($Bytes[0] -eq 0x47 -and $Bytes[1] -eq 0x49 -and $Bytes[2] -eq 0x46)
    $bmp = ($Bytes[0] -eq 0x42 -and $Bytes[1] -eq 0x4D)
    $webp = ($Bytes.Length -gt 12 -and $Bytes[0] -eq 0x52 -and $Bytes[1] -eq 0x49 -and $Bytes[2] -eq 0x46 -and $Bytes[3] -eq 0x46 -and $Bytes[8] -eq 0x57 -and $Bytes[9] -eq 0x45 -and $Bytes[10] -eq 0x42 -and $Bytes[11] -eq 0x50)
    if ($Extension -in @(".png")) { return $png }
    if ($Extension -in @(".jpg", ".jpeg")) { return $jpg }
    if ($Extension -in @(".gif")) { return $gif }
    if ($Extension -in @(".bmp")) { return $bmp }
    if ($Extension -in @(".webp")) { return $webp }
    return ($png -or $jpg -or $gif -or $bmp -or $webp)
  } catch { return $false }
}

# Lagert data:image-URIs aus Artikel-Body als Dateien unter content\uploads\<slug>\
# aus (stabile Artikel-ID; Kategorie/Produkt stehen im Frontmatter). Dedup per SHA12,
# max. 8 MB, nur erlaubte Bildformate. Rueckfall: Original unveraendert lassen.
function Convert-InlineBase64ToFiles {
  param([string]$Body, [string]$ArticleSlug)
  if ([string]::IsNullOrEmpty($Body) -or $Body.IndexOf("data:image/") -lt 0) { return $Body }
  if ([string]::IsNullOrWhiteSpace($ArticleSlug)) { $ArticleSlug = "medien" }
  $targetSlug = ConvertTo-Slug $ArticleSlug
  $articleDir = Join-Path $uploadsDir $targetSlug
  $inlineDir = Join-Path $uploadsDir "inline"
  $mimeToExt = @{
    "png" = "png"; "jpg" = "jpg"; "jpeg" = "jpg"; "gif" = "gif"
    "webp" = "webp"; "svg+xml" = "svg"; "bmp" = "bmp"
  }
  try {
    New-Item -ItemType Directory -Force $articleDir | Out-Null
    New-Item -ItemType Directory -Force $inlineDir | Out-Null
  } catch {
    return $Body
  }
  $base = ($targetSlug -replace "[^a-z0-9]+", "-").Trim("-")
  if ([string]::IsNullOrWhiteSpace($base)) { $base = "bild" }
  if ($base.Length -gt 30) { $base = $base.Substring(0, 30) }
  return [regex]::Replace($Body, '\]\(data:image/([^;,\)]+);base64,([A-Za-z0-9+/=\s]+?)\)', {
    param($m)
    try {
      $mime = $m.Groups[1].Value.Trim().ToLowerInvariant()
      $b64 = $m.Groups[2].Value -replace "\s+", ""
      if (-not $mimeToExt.ContainsKey($mime)) { return $m.Value }
      if (($b64.Length % 4) -ne 0) { return $m.Value }
      $bytes = [Convert]::FromBase64String($b64)
      if ($bytes.Length -eq 0 -or $bytes.Length -gt (8 * 1024 * 1024)) { return $m.Value }
      $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace("-", "").ToLowerInvariant().Substring(0, 12)
      $name = "bild-$base-$sha.$($mimeToExt[$mime])"
      $dest = Join-Path $articleDir $name
      if (-not (Test-Path -LiteralPath $dest)) {
        [IO.File]::WriteAllBytes($dest, $bytes)
      }
      return '](content/uploads/' + $targetSlug + '/' + $name + ')'
    } catch {
      return $m.Value
    }
  })
}

function Get-Revision {
  param([hashtable]$Meta)
  $revision = 1
  if ($Meta.ContainsKey("revision")) { [int]::TryParse($Meta["revision"], [ref]$revision) | Out-Null }
  return [Math]::Max(1, $revision)
}

function Get-ArticleBySlug {
  param([string]$Slug)
  foreach ($file in (Get-ChildItem $articlesDir -Filter "*.md" -File)) {
    $raw = Get-Content -Raw -Encoding UTF8 $file.FullName
    $parsed = Read-FrontMatter $raw
    $title = if ($parsed.Meta.ContainsKey("title")) { $parsed.Meta["title"] } else { $file.BaseName }
    $articleSlug = if ($parsed.Meta.ContainsKey("slug")) { ConvertTo-Slug $parsed.Meta["slug"] } else { ConvertTo-Slug $title }
    if ($articleSlug -eq $Slug) {
      return [pscustomobject]@{ File = $file; Raw = $raw; Meta = $parsed.Meta; Body = $parsed.Body; Slug = $articleSlug; Title = $title }
    }
  }
  return $null
}

function New-ArticleMarkdown {
  param(
    [object]$Data,
    [int]$Revision,
    [string]$Action,
    [string]$Reason,
    [string]$ExistingLog = ""
  )
  $title = Sanitize-Line $Data.title
  $slug = ConvertTo-Slug $title
  $categories = @(Get-ArticleCategoriesFromData $Data)
  $category = $categories[0]
  $categoryValue = Format-CategoryMeta $categories
  $tags = Sanitize-Line $Data.tags
  $owner = Sanitize-Line $Data.owner
  $summary = if ($Data.PSObject.Properties.Name -contains "summary") { Sanitize-Line $Data.summary } else { "" }
  $changedBy = if ($Data.PSObject.Properties.Name -contains "changedBy") { Sanitize-Line $Data.changedBy } else { "System" }
  $body = if ($null -ne $Data.body -and $Data.body.Trim().Length -gt 0) { [string]$Data.body } else { "# $title`n`n" }
  $productValue = if ($Data.PSObject.Properties.Name -contains "products") { Format-ProductMeta @($Data.products) } else { "" }
  $attachments = if ($Data.PSObject.Properties.Name -contains "attachments") { @($Data.attachments) } else { @() }
  $attachmentValue = Format-AttachmentMeta $attachments
  $relatedSlugs = @()
  if ($Data.PSObject.Properties.Name -contains "related") {
    foreach ($related in @($Data.related)) {
      $relatedSlug = ConvertTo-Slug ([string]$related)
      if ($relatedSlug -and $relatedSlug -ne $slug -and $relatedSlugs -notcontains $relatedSlug) { $relatedSlugs += $relatedSlug }
    }
  }
  $relatedValue = $relatedSlugs -join ", "
  $reasonValue = if ([string]::IsNullOrWhiteSpace($Reason)) { "Erstellt" } else { Sanitize-Line $Reason }
  $deleteRequest = if ($Data.PSObject.Properties.Name -contains "deleteRequest") { $Data.deleteRequest } else { $null }
  $deleteRequestValues = @(Format-DeleteRequestMeta $deleteRequest)
  $bodyWithLog = Add-RevisionEntry -Body $body -ExistingLog $ExistingLog -Revision $Revision -Action $Action -Reason $reasonValue -ChangedBy $changedBy
  $ownerValue = if ($owner) { $owner } else { "Wiki-Verantwortlicher" }
  $date = Get-Date -Format "yyyy-MM-dd"
  $dateTime = Get-Date -Format "yyyy-MM-dd HH:mm"

  return @(
    "---",
    "title: $title",
    "slug: $slug",
    "category: $category",
    "categories: $categoryValue",
    "tags: $tags",
    "owner: $ownerValue",
    "status: Entwurf",
    "updated: $date",
    "summary: $summary",
    "products: $productValue",
    "attachments: $attachmentValue",
    "revision: $Revision",
    "change_date: $dateTime",
    "change_action: $Action",
    "change_reason: $reasonValue",
    "changed_by: $changedBy",
    "related: $relatedValue",
    "delete_request_by: $($deleteRequestValues[0])",
    "delete_request_at: $($deleteRequestValues[1])",
    "delete_request_reason: $($deleteRequestValues[2])",
    "---",
    "",
    $bodyWithLog.TrimEnd(),
    ""
  ) -join "`n"
}

function New-ArchivedMarkdown {
  param(
    [object]$Article,
    [string]$ArchiveSlug,
    [string]$ArchiveAction,
    [string]$Reason,
    [string]$ChangedBy = "System"
  )
  $meta = $Article.Meta
  $revision = Get-Revision $meta
  $title = if ($meta.ContainsKey("title")) { $meta["title"] } else { $Article.Title }
  $originalSlug = if ($meta.ContainsKey("slug")) { ConvertTo-Slug $meta["slug"] } else { ConvertTo-Slug $title }
  if ($Article.PSObject.Properties.Name -contains "Slug" -and -not [string]::IsNullOrWhiteSpace([string]$Article.Slug)) { $originalSlug = ConvertTo-Slug ([string]$Article.Slug) }
  $category = if ($meta.ContainsKey("category")) { $meta["category"] } else { "Archiv" }
  $categoryValue = Format-CategoryMeta (Read-CategoryMeta $meta)
  $tags = if ($meta.ContainsKey("tags")) { $meta["tags"] } else { "" }
  $owner = if ($meta.ContainsKey("owner")) { $meta["owner"] } else { "" }
  $summary = if ($meta.ContainsKey("summary")) { $meta["summary"] } else { "" }
  $productValue = Format-ProductMeta (Read-ProductMeta $meta)
  $attachmentValue = Format-AttachmentMeta (Read-AttachmentMeta $meta)
  $existingLog = Get-RevisionLog $Article.Body
  $bodyWithLog = Add-RevisionEntry -Body $Article.Body -ExistingLog $existingLog -Revision $revision -Action $ArchiveAction -Reason $Reason -ChangedBy $ChangedBy
  $date = Get-Date -Format "yyyy-MM-dd"
  $dateTime = Get-Date -Format "yyyy-MM-dd HH:mm"

  return @(
    "---",
    "title: Archiv: $(Sanitize-Line $title) (Revision $revision)",
    "slug: $ArchiveSlug",
    "category: Archiv",
    "original_slug: $originalSlug",
    "original_title: $(Sanitize-Line $title)",
    "original_category: $(Sanitize-Line $category)",
    "original_categories: $categoryValue",
    "categories: Archiv",
    "tags: $(Sanitize-Line $tags)",
    "owner: $(Sanitize-Line $owner)",
    "status: Archiviert",
    "updated: $date",
    "summary: Archivierte Fassung von $(Sanitize-Line $title). $(Sanitize-Line $summary)",
    "products: $productValue",
    "attachments: $attachmentValue",
    "revision: $revision",
    "change_date: $dateTime",
    "change_action: $ArchiveAction",
    "change_reason: $(Sanitize-Line $Reason)",
    "changed_by: $(Sanitize-Line $ChangedBy)",
    "related:",
    "---",
    "",
    $bodyWithLog.TrimEnd(),
    ""
  ) -join "`n"
}

function Invoke-WikiBuild {
  & $buildScript -Root $Root | Out-Null
}

# Fingerabdruck aller Build-Eingaben (mtime + Anzahl). Wird verwendet, um
# Get-WikiData ohne Neuaufbau zu beantworten, solange sich nichts geaendert hat.
# Bewusst AUSGENOMMEN (Build-Outputs bzw. irrelevant):
# - content\conflicts\report.json (wird pro Request frisch gelesen, siehe Get-WikiData)
# - content\suggestions\ (eigener Endpunkt, kein Build-Input)
# - data\wiki-data.js (Build-Output; Einbezug -> Endlosschleife)
# - versions\, .git\, runtime\, Anhaenge\ (keine Build-Eingaben)
function Get-WikiFingerprint {
  $maxTicks = 0
  $count = 0
  $sumTicks = 0
  $sumLength = 0
  $conflictPrefix = (Join-Path $Root "content\conflicts") + [IO.Path]::DirectorySeparatorChar
  $suggestionPrefix = (Join-Path $Root "content\suggestions") + [IO.Path]::DirectorySeparatorChar
  foreach ($dir in @((Join-Path $Root "content"), (Join-Path $Root "config"), (Join-Path $Root "tools"))) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $files = Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue |
      Where-Object { -not $_.FullName.StartsWith($conflictPrefix, [StringComparison]::OrdinalIgnoreCase) -and -not $_.FullName.StartsWith($suggestionPrefix, [StringComparison]::OrdinalIgnoreCase) }
    foreach ($f in $files) {
      $count++
      $ticks = $f.LastWriteTimeUtc.Ticks
      if ($ticks -gt $maxTicks) { $maxTicks = $ticks }
      # Summen verhindern, dass zwei Schreibvorgaenge innerhalb derselben
      # Zeitaufloesung als unveraendert gelten (Cache bliebe sonst stale).
      $sumTicks = ($sumTicks + ($ticks % 1000000007)) % 1000000007
      $sumLength += $f.Length
    }
  }
  return "$maxTicks|$count|$sumTicks|$sumLength"
}

$script:wikiCache = $null
$script:wikiCacheKey = $null

function Get-WikiData {
  $key = Get-WikiFingerprint
  if ($null -eq $script:wikiCache -or $key -ne $script:wikiCacheKey) {
    try {
      Invoke-WikiBuild
      $script:lastBuildError = ""
    } catch {
      $script:lastBuildError = $_.Exception.Message
    }
    $dataFile = Join-Path $Root "data\wiki-data.js"
    if (-not (Test-Path $dataFile)) { throw "Das Wiki konnte nicht gebaut werden: $script:lastBuildError" }
    $content = Get-Content -Raw -Encoding UTF8 $dataFile
    $json = $content -replace "^\s*window\.WIKI_DATA\s*=\s*", ""
    $json = $json -replace ";\s*$", ""
    $script:wikiCache = $json | ConvertFrom-Json
    $script:wikiCacheKey = $key
  }
  $data = $script:wikiCache
  $reportFile = Join-Path $Root "content\conflicts\report.json"
  $conflicts = if (Test-Path $reportFile) { Get-Content -Raw -Encoding UTF8 $reportFile | ConvertFrom-Json } else { [pscustomobject]@{ conflicts = @(); duplicateSlugs = @() } }
  $data | Add-Member -NotePropertyName systemStatus -NotePropertyValue ([pscustomobject]@{ buildError = $script:lastBuildError; conflicts = $conflicts }) -Force
  return $data
}

function Test-ProductIds {
  param([array]$ProductIds)
  $productIds = @($ProductIds | ForEach-Object { Sanitize-Line $_ } | Where-Object { $_ })
  $knownIds = @(@(Read-Products) | ForEach-Object { $_.id })
  foreach ($productId in $productIds) {
    if ($knownIds -notcontains $productId) { throw "Unbekanntes Produkt: $productId" }
  }
  return @($productIds)
}

function Add-CategoryToGroup {
  param([string]$Name, [string]$GroupName)
  $groups = @(Read-CategoryGroups)
  $group = $groups | Where-Object { $_.name -eq $GroupName } | Select-Object -First 1
  if (-not $group) {
    $groups += [pscustomobject]@{ name = $GroupName; categories = @($Name) }
  } elseif (@($group.categories) -notcontains $Name) {
    $group.categories = @((@($group.categories) + $Name) | Select-Object -Unique)
  }
  Write-CategoryGroups $groups
}

function Assert-CategoryAssign {
  # Produktgruppe anlegen/zuordnen: categories.assign genuegt,
  # categories.manage schliesst das Recht immer mit ein.
  param([object]$Session)
  if ($null -eq $Session) { throw [UnauthorizedAccessException]::new("Bitte zuerst anmelden.") }
  $have = @(Get-RolePermissions -Role $Session.role)
  if (($have -notcontains "categories.assign") -and ($have -notcontains "categories.manage")) {
    throw [UnauthorizedAccessException]::new("Fuer diese Aktion fehlt die Berechtigung.")
  }
}

function Save-Categories {
  # Legt eine Produktgruppe unabhaengig an: Produkte und Ueberkategorie sind
  # beide optional. Ohne Gruppe bleibt sie unzugeordnet (kein Auto-Assign).
  param([object]$Data)
  $name = Sanitize-Line $Data.name
  $groupName = if ($Data.PSObject.Properties.Name -contains "group") { Sanitize-Line $Data.group } else { "" }
  if ([string]::IsNullOrWhiteSpace($name)) { throw "Kategorie fehlt." }
  if ($name -eq "Archiv") { throw "Die systemseitige Kategorie Archiv kann nicht angelegt oder veraendert werden." }
  $productIds = @()
  if ($Data.PSObject.Properties.Name -contains "products") { $productIds = @($Data.products | ForEach-Object { Sanitize-Line $_ }) }
  if ($Data.PSObject.Properties.Name -contains "productIds") { $productIds = @($Data.productIds | ForEach-Object { Sanitize-Line $_ }) }
  $productIds = @($productIds | Where-Object { $_ })
  if ($productIds.Count -gt 0) { $productIds = @(Test-ProductIds $productIds) }

  $categories = @(Read-Categories)
  $existing = $categories | Where-Object { $_.name -eq $name } | Select-Object -First 1
  if ($existing) {
    if ($productIds.Count -gt 0) { $existing.products = @($productIds) }
  } else {
    $categories += [pscustomobject]@{ name = $name; products = @($productIds) }
  }
  Write-Categories $categories

  if ($groupName) {
    if ($groupName -eq "Archiv") { throw "Die systemseitige Kategorie Archiv kann nicht zugeordnet werden." }
    Add-CategoryToGroup -Name $name -GroupName $groupName
  }
}

function Save-CategoryGroup {
  # Neue Ueberkategorie -> categories.manage (Admin). Bestehende Gruppe
  # veraendern (Zuordnung) -> categories.assign genuegt (Admin/Bearbeiter).
  # "Weitere Kategorien" ist ein reiner Anzeige-Bucket und darf nie echt werden.
  param([object]$Data, [object]$Session)
  $name = Sanitize-Line $Data.name
  if ([string]::IsNullOrWhiteSpace($name)) { throw "Ueberkategorie fehlt." }
  if ($name -eq "Archiv") { throw "Die systemseitige Kategorie Archiv kann nicht angelegt oder veraendert werden." }
  if ($name -eq "Weitere Kategorien") { throw 'Der Name "Weitere Kategorien" ist ein Anzeigeordner und kann nicht als Ueberkategorie angelegt werden.' }

  $groups = @(Read-CategoryGroups)
  $isNew = -not ($groups | Where-Object { $_.name -eq $name } | Select-Object -First 1)
  if ($isNew) {
    Assert-Permission -Session $Session -Permissions @("categories.manage")
  } else {
    Assert-CategoryAssign -Session $Session
  }

  $categories = @()
  if ($Data.PSObject.Properties.Name -contains "categories") {
    foreach ($category in $Data.categories) { $categories += Sanitize-Line $category }
  }
  $categories = @($categories | Where-Object { $_ } | Select-Object -Unique)
  if ($categories -contains "Archiv") { throw "Die systemseitige Kategorie Archiv kann nicht zugeordnet werden." }

  # Direkt in der Ueberkategorie neu angelegte Produktgruppen duerfen ohne
  # Produkte entstehen, gehoeren aber sofort zur Gruppe.
  if ($Data.PSObject.Properties.Name -contains "newCategories") {
    foreach ($item in @($Data.newCategories)) {
      $itemName = ""
      $itemProducts = @()
      if ($item -is [string]) { $itemName = Sanitize-Line $item }
      else {
        if ($item.PSObject.Properties.Name -contains "name") { $itemName = Sanitize-Line $item.name }
        if ($item.PSObject.Properties.Name -contains "products") { $itemProducts = @($item.products) }
      }
      if ([string]::IsNullOrWhiteSpace($itemName)) { continue }
      if ($itemName -eq "Archiv") { throw "Die systemseitige Kategorie Archiv kann nicht angelegt werden." }
      $knownNames = @(@(Read-Categories) | ForEach-Object { $_.name })
      if ($knownNames -contains $itemName) { throw "Kategorie existiert bereits: $itemName" }
      $itemProducts = @(Test-ProductIds $itemProducts)
      $allCategories = @(Read-Categories)
      $allCategories += [pscustomobject]@{ name = $itemName; products = @($itemProducts) }
      Write-Categories $allCategories
      if ($categories -notcontains $itemName) { $categories += $itemName }
    }
  }

  $knownNames = @(@(Read-Categories) | ForEach-Object { $_.name })
  foreach ($category in $categories) {
    if ($knownNames -notcontains $category) { throw "Unbekannte Kategorie: $category" }
  }

  $groups = @(Read-CategoryGroups)
  $existing = $groups | Where-Object { $_.name -eq $name } | Select-Object -First 1
  if ($existing) {
    $existing.categories = $categories
  } else {
    $groups += [pscustomobject]@{ name = $name; categories = $categories }
  }
  Write-CategoryGroups $groups
}

function Remove-CategoryGroup {
  # Loescht eine Ueberkategorie. Zugeordnete Produktgruppen bleiben als
  # eigenstaendige (unzugeordnete) Eintraege erhalten. Kein Archiv.
  param([string]$Name)
  $name = Sanitize-Line $Name
  if ([string]::IsNullOrWhiteSpace($name)) { throw "Ueberkategorie fehlt." }
  if ($name -eq "Archiv") { throw "Die systemseitige Kategorie Archiv kann nicht geloescht werden." }
  $groups = @(Read-CategoryGroups)
  $existing = $groups | Where-Object { $_.name -eq $name } | Select-Object -First 1
  if (-not $existing) { throw "Ueberkategorie nicht gefunden." }
  $groups = @($groups | Where-Object { $_.name -ne $name })
  Write-CategoryGroups $groups
}

function Get-CategoryUsage {
  # Ermittelt Verwendung einer Produktgruppe (fuer Loeschpruefung/Anzeige).
  param([string]$Name)
  $usedArticles = @()
  foreach ($file in (Get-ChildItem $articlesDir -Filter "*.md" -File -ErrorAction SilentlyContinue)) {
    try {
      $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName
      $parsed = Read-FrontMatter $raw
      $cats = @(Read-CategoryMeta $parsed.Meta)
      if ($cats -contains $Name) {
        $title = if ($parsed.Meta.ContainsKey("title")) { $parsed.Meta["title"] } else { $file.BaseName }
        $usedArticles += $title
      }
    } catch { }
  }
  $usedProducts = @()
  foreach ($product in @(Read-Products)) {
    if (@($product.categories) -contains $Name) { $usedProducts += $product.name }
  }
  return [pscustomobject]@{ Articles = @($usedArticles); Products = @($usedProducts) }
}

function Remove-Category {
  # Loescht eine Produktgruppe vollstaendig (kein Archiv, kein Archiveintrag).
  # Bei Verwendung durch Artikel/Produkte wird blockiert statt Daten zu verlieren.
  param([string]$Name)
  $name = Sanitize-Line $Name
  if ([string]::IsNullOrWhiteSpace($name)) { throw "Kategorie fehlt." }
  if ($name -eq "Archiv") { throw "Die systemseitige Kategorie Archiv kann nicht geloescht werden." }
  $categories = @(Read-Categories)
  $existing = $categories | Where-Object { $_.name -eq $name } | Select-Object -First 1
  if (-not $existing) { throw "Kategorie nicht gefunden." }
  $usage = Get-CategoryUsage -Name $name
  if (@($usage.Articles).Count -gt 0 -or @($usage.Products).Count -gt 0) {
    $parts = @()
    if (@($usage.Articles).Count -gt 0) { $parts += "$($usage.Articles.Count) Artikel ($((@($usage.Articles) | Select-Object -First 3) -join ', '))" }
    if (@($usage.Products).Count -gt 0) { $parts += "$($usage.Products.Count) Produkte ($((@($usage.Products) | Select-Object -First 3) -join ', '))" }
    throw "Kategorie wird noch verwendet und kann nicht geloescht werden: $($parts -join '; '). Bitte zuerst die Zuordnungen entfernen."
  }
  $groups = @(Read-CategoryGroups)
  foreach ($group in $groups) {
    $group.categories = @(@($group.categories) | Where-Object { $_ -ne $name })
  }
  Write-CategoryGroups $groups
  $categories = @($categories | Where-Object { $_.name -ne $name })
  Write-Categories $categories
}

function Get-ProductCategoriesFromData {
  param([object]$Data)
  $categories = @()
  if ($Data.PSObject.Properties.Name -contains "categories") {
    foreach ($category in $Data.categories) { $categories += Sanitize-Line $category }
  }
  if ($Data.PSObject.Properties.Name -contains "categoryIds") {
    foreach ($category in $Data.categoryIds) { $categories += Sanitize-Line $category }
  }
  $categories = @($categories | Where-Object { $_ } | Select-Object -Unique)
  $knownCategories = @(Read-Categories | ForEach-Object { $_.name })
  foreach ($category in $categories) {
    if ($knownCategories -notcontains $category) { throw "Unbekannte Kategorie: $category" }
  }
  return @($categories)
}

function New-ProductRecord {
  param(
    [object]$Data,
    [string]$Id,
    [int]$Revision,
    [string]$Status,
    [string]$Action,
    [string]$Reason
  )

  $name = Sanitize-Line $Data.name
  $article = if ($Data.PSObject.Properties.Name -contains "article") { Sanitize-Line $Data.article } else { Sanitize-Line $Data.artikel }
  $hardwareRevision = if ($Data.PSObject.Properties.Name -contains "hardwareRevision") { Sanitize-Line $Data.hardwareRevision } else { Sanitize-Line $Data.hardwarerevision }
  $description = if ($Data.PSObject.Properties.Name -contains "description") { Sanitize-Line $Data.description } else { "" }
  $deleteRequest = if ($Data.PSObject.Properties.Name -contains "deleteRequest") { $Data.deleteRequest } else { $null }
  if ($null -ne $deleteRequest) {
    $deleteRequestBy = if ($deleteRequest.PSObject.Properties.Name -contains "by") { Sanitize-Line $deleteRequest.by } else { "" }
    if ([string]::IsNullOrWhiteSpace($deleteRequestBy)) { $deleteRequest = $null }
  }
  if ([string]::IsNullOrWhiteSpace($name)) { throw "Produktname fehlt." }
  if ([string]::IsNullOrWhiteSpace($article)) { throw "Artikel ist ein Pflichtfeld." }
  if ([string]::IsNullOrWhiteSpace($Id)) { $Id = ConvertTo-Slug "$name-$article-$hardwareRevision" }
  $date = Get-Date -Format "yyyy-MM-dd"
  $dateTime = Get-Date -Format "yyyy-MM-dd HH:mm"

  return [pscustomobject]@{
    id = $Id
    name = $name
    article = $article
    hardwareRevision = $hardwareRevision
    description = $description
    categories = @(Get-ProductCategoriesFromData $Data)
    revision = [Math]::Max(1, $Revision)
    status = $Status
    updated = $date
    changeDate = $dateTime
    changeAction = $Action
    changeReason = if ($Reason) { Sanitize-Line $Reason } else { $Action }
    deleteRequest = $deleteRequest
  }
}

function New-ArchivedProductRecord {
  param(
    [object]$Product,
    [string]$Action,
    [string]$Reason
  )
  $date = Get-Date -Format "yyyy-MM-dd"
  $dateTime = Get-Date -Format "yyyy-MM-dd HH:mm"
  $archivedDeleteRequest = $null
  if ($Product.PSObject.Properties.Name -contains "deleteRequest" -and $null -ne $Product.deleteRequest) {
    $archivedDeleteRequest = $Product.deleteRequest
  }
  return [pscustomobject]@{
    id = $Product.id
    name = $Product.name
    article = $Product.article
    hardwareRevision = $Product.hardwareRevision
    description = if ($Product.PSObject.Properties.Name -contains "description") { Sanitize-Line $Product.description } else { ""}
    categories = @($Product.categories)
    revision = $Product.revision
    status = "Archiviert"
    updated = $date
    changeDate = $dateTime
    changeAction = $Action
    changeReason = Sanitize-Line $Reason
    deleteRequest = $archivedDeleteRequest
  }
}

function Save-Product {
  param([object]$Data)

  $products = @(Read-Products)
  $record = New-ProductRecord -Data $Data -Id "" -Revision 1 -Status "Aktiv" -Action "Angelegt" -Reason "Erstellt"
  $id = $record.id
  if ($products | Where-Object { $_.id -eq $id }) { throw "Dieses Produkt existiert bereits." }
  $products += $record
  Write-Products $products
}

function Update-Product {
  param([string]$Id, [object]$Data)
  $reason = if ($Data.PSObject.Properties.Name -contains "reason") { Sanitize-Line $Data.reason } else { "" }
  if ([string]::IsNullOrWhiteSpace($reason)) { throw "Vor dem Aendern muss ein Grund angegeben werden." }

  $products = @(Read-Products)
  $product = $products | Where-Object { $_.id -eq $Id } | Select-Object -First 1
  if (-not $product) { throw "Produkt nicht gefunden." }

  $archive = @(Read-ArchivedProducts)
  $archive += New-ArchivedProductRecord -Product $product -Action "Archiviert vor Aenderung zu Revision $($product.revision + 1)" -Reason $reason
  Write-ArchivedProducts $archive

  # Eine bestehende Loeschmarkierung ueberlebt normale Bearbeitungen.
  if (-not ($Data.PSObject.Properties.Name -contains "deleteRequest")) {
    $Data | Add-Member -NotePropertyName deleteRequest -NotePropertyValue $product.deleteRequest -Force
  }
  $updated = New-ProductRecord -Data $Data -Id $product.id -Revision ($product.revision + 1) -Status "Aktiv" -Action "Geaendert" -Reason $reason
  $nextProducts = @()
  foreach ($item in $products) {
    if ($item.id -eq $Id) { $nextProducts += $updated } else { $nextProducts += $item }
  }
  Write-Products $nextProducts
}

function Delete-Product {
  param([string]$Id, [object]$Data)
  $reason = if ($Data.PSObject.Properties.Name -contains "reason") { Sanitize-Line $Data.reason } else { "" }
  if ([string]::IsNullOrWhiteSpace($reason)) { throw "Vor dem Loeschen muss ein Grund angegeben werden." }

  $products = @(Read-Products)
  $product = $products | Where-Object { $_.id -eq $Id } | Select-Object -First 1
  if (-not $product) { throw "Produkt nicht gefunden." }

  $archive = @(Read-ArchivedProducts)
  $archive += New-ArchivedProductRecord -Product $product -Action "Geloescht und archiviert" -Reason $reason
  Write-ArchivedProducts $archive

  $nextProducts = @($products | Where-Object { $_.id -ne $Id })
  Write-Products $nextProducts

  $categories = @(Read-Categories)
  foreach ($category in $categories) {
    $category.products = @($category.products | Where-Object { $_ -ne $Id })
  }
  Write-Categories $categories
}

function Filter-ArticleProducts {
  # Punkte 3/4 (serverseitig): nur Produkte der gewählten Kategorie behalten,
  # Selbst-Verknüpfung bei verwandten Artikeln verhindern.
  param([object]$Data, [string]$CurrentSlug)
  try {
    $cats = @()
    if ($Data.PSObject.Properties.Name -contains "categories") { $cats = @($Data.categories | ForEach-Object { Sanitize-Line ([string]$_) } | Where-Object { $_ }) }
    elseif ($Data.PSObject.Properties.Name -contains "category") { $cats = @((Sanitize-Line ([string]$Data.category)) | Where-Object { $_ }) }
    if ($Data.PSObject.Properties.Name -contains "products" -and $cats.Count -gt 0) {
      $all = @(Read-Products)
      $wanted = @($cats)
      $validIds = @($all | Where-Object {
        $pcats = @($_.categories)
        foreach ($c in $wanted) { if ($pcats -contains $c) { return $true } }
        return $false
      } | ForEach-Object { $_.id })
      $Data.products = @(@($Data.products | ForEach-Object { Sanitize-Line ([string]$_) } | Where-Object { $validIds -contains $_ }) | Select-Object -Unique)
    }
    if ($Data.PSObject.Properties.Name -contains "related") {
      $Data.related = @(@($Data.related | ForEach-Object { ConvertTo-Slug ([string]$_) } | Where-Object { $_ -and $_ -ne $CurrentSlug }) | Select-Object -Unique)
    }
  } catch { }
}

function Create-Article {
  param([object]$Data)
  $title = Sanitize-Line $Data.title
  if ([string]::IsNullOrWhiteSpace($title)) { throw "Titel fehlt." }
  $slug = ConvertTo-Slug $title
  if (Get-ArticleBySlug $slug) { throw "Ein aktiver Artikel mit diesem Titel existiert bereits." }
  $attachments = @()
  if ($Data.PSObject.Properties.Name -contains "attachments") { $attachments += @($Data.attachments) }
  if ($Data.PSObject.Properties.Name -contains "attachmentFiles") { $attachments += Save-UploadedFiles -ArticleSlug $slug -Files @($Data.attachmentFiles) }
  $Data | Add-Member -NotePropertyName attachments -NotePropertyValue @($attachments) -Force
  if ($Data.PSObject.Properties.Name -contains "body") { $Data.body = Convert-InlineBase64ToFiles -Body ([string]$Data.body) -ArticleSlug $slug }
  Filter-ArticleProducts -Data $Data -CurrentSlug $slug
  $newRelated = if ($Data.PSObject.Properties.Name -contains "related") { @($Data.related) } else { @() }
  $relatedPlan = Plan-RelatedSync -CurrentSlug $slug -NewRelated $newRelated -BaseRelated @()
  $Data | Add-Member -NotePropertyName related -NotePropertyValue @($relatedPlan.Final) -Force
  $markdown = New-ArticleMarkdown -Data $Data -Revision 1 -Action "Angelegt" -Reason "Erstellt"
  [IO.File]::WriteAllText((Join-Path $articlesDir "$slug.md"), $markdown, [Text.UTF8Encoding]::new($false))
  Apply-RelatedChanges -CurrentSlug $slug -Additions @($relatedPlan.Additions) -Removals @($relatedPlan.Removals)
  Start-WikiSnapshot -Message "Artikel angelegt: $title"
  return $slug
}

function Update-Article {
  param([string]$Slug, [object]$Data)
  $reason = Sanitize-Line $Data.reason
  if ([string]::IsNullOrWhiteSpace($reason)) { throw "Vor dem Aendern muss ein Grund angegeben werden." }
  $article = Get-ArticleBySlug $Slug
  if (-not $article) { throw "Artikel nicht gefunden." }

  $currentRevision = Get-Revision $article.Meta
  if ($Data.PSObject.Properties.Name -contains "baseRevision" -and [int]$Data.baseRevision -ne $currentRevision) {
    throw "Der Artikel wurde zwischenzeitlich geaendert. Bitte lade ihn neu."
  }
  $newRevision = $currentRevision + 1
  $newTitle = Sanitize-Line $Data.title
  $newSlug = ConvertTo-Slug $newTitle
  if ($newSlug -ne $Slug -and (Get-ArticleBySlug $newSlug)) { throw "Ein aktiver Artikel mit dem neuen Titel existiert bereits." }
  $attachments = @(Read-AttachmentMeta $article.Meta)
  if ($Data.PSObject.Properties.Name -contains "attachments") { $attachments = @($Data.attachments) }
  if ($Data.PSObject.Properties.Name -contains "attachmentFiles") { $attachments += Save-UploadedFiles -ArticleSlug $newSlug -Files @($Data.attachmentFiles) }
  $Data | Add-Member -NotePropertyName attachments -NotePropertyValue @($attachments) -Force
  if ($Data.PSObject.Properties.Name -contains "body") { $Data.body = Convert-InlineBase64ToFiles -Body ([string]$Data.body) -ArticleSlug $newSlug }
  Filter-ArticleProducts -Data $Data -CurrentSlug $newSlug
  $relatedProvided = $Data.PSObject.Properties.Name -contains "related"
  if (-not ($Data.PSObject.Properties.Name -contains "products")) {
    $Data | Add-Member -NotePropertyName products -NotePropertyValue @(Read-ProductMeta $article.Meta) -Force
  }
  if (-not ($Data.PSObject.Properties.Name -contains "categories")) {
    $Data | Add-Member -NotePropertyName categories -NotePropertyValue @(Read-CategoryMeta $article.Meta) -Force
  }
  if (-not ($Data.PSObject.Properties.Name -contains "related")) {
    $Data | Add-Member -NotePropertyName related -NotePropertyValue @(Read-RelatedMeta $article.Meta) -Force
  }
  $baseRelated = $null
  if ($Data.PSObject.Properties.Name -contains "relatedBase") { $baseRelated = @($Data.relatedBase) }
  if (-not $relatedProvided) {
    # Kein related-Feld im Request: bestehende (auch gegenlaeufige) Links
    # unveraendert uebernehmen.
    $Data | Add-Member -NotePropertyName related -NotePropertyValue @(Get-EffectiveRelated -Slug $Slug -Map (Get-ActiveRelatedMap)) -Force
    $baseRelated = $null
  }
  $relatedPlan = Plan-RelatedSync -CurrentSlug $newSlug -NewRelated @($Data.related) -BaseRelated $baseRelated
  $Data | Add-Member -NotePropertyName related -NotePropertyValue @($relatedPlan.Final) -Force
  # Eine bestehende Loeschmarkierung ueberlebt normale Bearbeitungen;
  # entfernt wird sie nur ueber den Request-Delete-Endpunkt (Admin).
  if (-not ($Data.PSObject.Properties.Name -contains "deleteRequest")) {
    $Data | Add-Member -NotePropertyName deleteRequest -NotePropertyValue (Read-DeleteRequestMeta $article.Meta) -Force
  }

  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $archiveSlug = "archiv-$stamp-$Slug-r$currentRevision"
  $archivePath = Join-Path $archiveDir "$archiveSlug.md"
  $changedBy = if ($Data.PSObject.Properties.Name -contains "changedBy") { Sanitize-Line $Data.changedBy } else { "System" }
  [IO.File]::WriteAllText($archivePath, (New-ArchivedMarkdown -Article $article -ArchiveSlug $archiveSlug -ArchiveAction "Archiviert vor Aenderung zu Revision $newRevision" -Reason $reason -ChangedBy $changedBy), [Text.UTF8Encoding]::new($false))

  $existingLog = Get-RevisionLog $article.Body
  $newPath = Join-Path $articlesDir "$newSlug.md"
  [IO.File]::WriteAllText($newPath, (New-ArticleMarkdown -Data $Data -Revision $newRevision -Action "Geaendert" -Reason $reason -ExistingLog $existingLog), [Text.UTF8Encoding]::new($false))
  if ($newPath -ne $article.File.FullName) { Remove-Item -LiteralPath $article.File.FullName -Force }
  Apply-RelatedChanges -CurrentSlug $newSlug -Additions @($relatedPlan.Additions) -Removals @($relatedPlan.Removals) -PreviousSlug $(if ($newSlug -ne $Slug) { $Slug } else { "" })
  if ($newSlug -ne $Slug) { Rename-RelatedReferences -OldSlug $Slug -NewSlug $newSlug }
  Start-WikiSnapshot -Message "Artikel aktualisiert: $newTitle"
  return $newSlug
}

function Save-UploadBatch {
  param([object]$Data)
  $slug = if ($Data.PSObject.Properties.Name -contains "articleSlug") { Sanitize-Line $Data.articleSlug } else { "medien" }
  $files = if ($Data.PSObject.Properties.Name -contains "files") { @($Data.files) } else { @() }
  return [pscustomobject]@{ files = @(Save-UploadedFiles -ArticleSlug $slug -Files $files) }
}

function Assert-BackupAdmin {
  param([object]$Session)
  if ($null -eq $Session) { throw [UnauthorizedAccessException]::new("Bitte zuerst anmelden.") }
  $role = [string]$Session.role
  $perms = @(Get-RolePermissions -Role $role)
  if ($role -ne "Administrator" -and -not ($perms -contains "users.manage" -and $perms -contains "roles.manage")) {
    throw [UnauthorizedAccessException]::new("Nur Administratoren duerfen Backups verwalten.")
  }
}

function New-WikiBackup {
  param([object]$Data, [object]$Session)
  Assert-BackupAdmin -Session $Session
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $fileName = "wiki-backup-$stamp.zip"
  $destZip = Join-Path $backupDir $fileName
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("wiki-backup-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force $tmp | Out-Null
  try {
    $manifest = [pscustomobject]@{
      backupVersion = 1
      createdAt = (Get-Date).ToString("o")
      applicationVersion = "wiki-2026-10"
      createdBy = [string]$Session.username
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 (Join-Path $tmp "manifest.json")
    foreach ($rel in @("content\articles", "content\archive", "content\uploads")) {
      $src = Join-Path $Root $rel
      if (Test-Path -LiteralPath $src) {
        $dst = Join-Path $tmp $rel
        New-Item -ItemType Directory -Force $dst | Out-Null
        # ACHTUNG: Wildcard braucht -Path (nicht -LiteralPath), sonst wird nichts kopiert.
        Copy-Item -Path (Join-Path $src "*") -Destination $dst -Recurse -Force -ErrorAction Stop
      }
    }
    foreach ($f in @("content\categories.json", "content\category-groups.json", "content\products.json", "content\product-archive.json", "data\wiki-data.js", "config\roles.json")) {
      $src = Join-Path $Root $f
      if (Test-Path -LiteralPath $src) {
        $dst = Join-Path $tmp $f
        New-Item -ItemType Directory -Force (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
      }
    }
    # Hinweis-Datei: Benutzer-Hashes werden bewusst NICHT gesichert (nur Rollenmodell).
    "Benutzerkonten (config/users.json) sind aus Sicherheitsgruenden nicht enthalten. Rollen in config/roles.json." | Set-Content -Encoding UTF8 (Join-Path $tmp "HINWEIS-Benutzer.txt")
    Compress-Archive -Path (Join-Path $tmp "*") -DestinationPath $destZip -Force
    $articleCount = @(Get-ChildItem -LiteralPath $articlesDir -Filter "*.md" -File -ErrorAction SilentlyContinue).Count
    $imageCount = @(Get-ChildItem -LiteralPath $uploadsDir -File -Recurse -ErrorAction SilentlyContinue).Count
    # Optional: Kopie auf konfigurierten Server-Pfad (kein Client-Pfad blind übernehmen: nur absolute
    # Server-Pfade, keine relativen Ausbrüche).
    $targetPath = if ($Data.PSObject.Properties.Name -contains "targetPath") { Sanitize-Line $Data.targetPath } else { "" }
    $targetNote = ""
    if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
      try {
        $full = [IO.Path]::GetFullPath($targetPath)
        New-Item -ItemType Directory -Force $full | Out-Null
        Copy-Item -LiteralPath $destZip -Destination (Join-Path $full $fileName) -Force
        $targetNote = " Kopie nach $full."
      } catch { $targetNote = " Zielpfad nicht erreichbar (Server-Sicht): $($_.Exception.Message)" }
    }
    # Optional: WebDAV-Upload (Basic-Auth, Passwort nie loggen).
    $webdavUrl = if ($Data.PSObject.Properties.Name -contains "webdavUrl") { ([string]$Data.webdavUrl).Trim() } else { "" }
    $webdavUser = if ($Data.PSObject.Properties.Name -contains "webdavUser") { ([string]$Data.webdavUser).Trim() } else { "" }
    $webdavPassword = if ($Data.PSObject.Properties.Name -contains "webdavPassword") { [string]$Data.webdavPassword } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($webdavUrl)) {
      try {
        if ($webdavUrl -notmatch "^https?://") { throw "WebDAV-URL muss mit http(s):// beginnen." }
        $url = $webdavUrl.TrimEnd("/") + "/" + $fileName
        $headers = @{}
        if ($webdavUser) {
          $pair = "${webdavUser}:${webdavPassword}"
          $headers["Authorization"] = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
        }
        Invoke-WebRequest -Uri $url -Method Put -InFile $destZip -Headers $headers -UseBasicParsing -TimeoutSec 120 | Out-Null
        $targetNote += " WebDAV-Upload ok."
      } catch { $targetNote += " WebDAV fehlgeschlagen (Details serverseitig protokolliert, ohne Passwort)." }
    }
    if ($targetNote) { Add-Content -Encoding UTF8 (Join-Path $Root "versions\snapshot-errors.log") "$(Get-Date -Format o) Backup ${fileName}:${targetNote}" }
    return [pscustomobject]@{
      ok = $true
      fileName = $fileName
      articleCount = $articleCount
      imageCount = $imageCount
      downloadUrl = "/api/backup/download/$fileName"
      note = $targetNote.Trim()
    }
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Restore-WikiBackup {
  param([object]$Data, [object]$Session)
  Assert-BackupAdmin -Session $Session
  $fileName = Sanitize-FileName ([string]$Data.fileName)
  $b64 = if ($Data.PSObject.Properties.Name -contains "data") { [string]$Data.data } else { "" }
  if ([string]::IsNullOrWhiteSpace($b64)) { throw "Backup-Datei fehlt." }
  try { $bytes = [Convert]::FromBase64String(($b64 -replace "\s+", "")) } catch { throw "Backup-Datei ist beschaedigt (kein gueltiges Base64)." }
  if ($bytes.Length -eq 0 -or $bytes.Length -gt (500 * 1024 * 1024)) { throw "Backup-Datei ist ungueltig oder zu gross." }
  $tmpZip = Join-Path ([IO.Path]::GetTempPath()) ("restore-" + [Guid]::NewGuid().ToString("N") + ".zip")
  $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("restore-" + [Guid]::NewGuid().ToString("N"))
  [IO.File]::WriteAllBytes($tmpZip, $bytes)
  try {
    New-Item -ItemType Directory -Force $tmpDir | Out-Null
    try { Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpDir -Force }
    catch { throw "Backup ist beschaedigt (kein gueltiges ZIP)." }
    $manifestPath = Join-Path $tmpDir "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Backup ungueltig: manifest.json fehlt." }
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    if ([int]$manifest.backupVersion -ne 1) { throw "Backup-Version $($manifest.backupVersion) wird nicht unterstuetzt (erwartet 1)." }
    foreach ($req in @("content\articles", "content\categories.json", "content\products.json")) {
      if (-not (Test-Path -LiteralPath (Join-Path $tmpDir $req))) { throw "Backup unvollstaendig: $req fehlt." }
    }
    # Leere Backups (z. B. ohne Artikel-Dateien) duerfen nie einen Restore ausloesen –
    # sonst wuerde das Loeschen des Ziels zu Datenverlust fuehren.
    $backupArticles = @(Get-ChildItem -LiteralPath (Join-Path $tmpDir "content\articles") -Filter "*.md" -File -ErrorAction SilentlyContinue)
    if ($backupArticles.Count -eq 0) { throw "Backup unvollstaendig: keine Artikel-Dateien enthalten. Restore abgebrochen, Daten unveraendert." }
    # JSONs validieren, bevor etwas überschrieben wird (kein halbfertiger Restore).
    foreach ($jf in @("content\categories.json", "content\category-groups.json", "content\products.json", "content\product-archive.json")) {
      $p = Join-Path $tmpDir $jf
      if (Test-Path -LiteralPath $p) { try { $null = Get-Content -Raw -Encoding UTF8 -LiteralPath $p | ConvertFrom-Json } catch { throw "Backup beschaedigt: $jf ist kein gueltiges JSON." } }
    }
    # Sicherheitskopie des aktuellen Stands (Rollback-Strategie).
    $preName = "pre-restore-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".zip"
    $preZip = Join-Path $backupDir $preName
    Compress-Archive -Path (Join-Path $Root "content"), (Join-Path $Root "config\roles.json") -DestinationPath $preZip -Force -ErrorAction SilentlyContinue
    foreach ($rel in @("content\articles", "content\archive", "content\uploads")) {
      $src = Join-Path $tmpDir $rel
      $dst = Join-Path $Root $rel
      if (Test-Path -LiteralPath $src) {
        $hasFiles = @(Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0
        # Artikel/Archiv duerfen nie durch leere Backup-Ordner ueberschrieben werden.
        if (($rel -ne "content\uploads") -and -not $hasFiles -and (Test-Path -LiteralPath $dst)) { continue }
        New-Item -ItemType Directory -Force $dst | Out-Null
        Get-ChildItem -LiteralPath $dst -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        # ACHTUNG: Wildcard braucht -Path (nicht -LiteralPath).
        Copy-Item -Path (Join-Path $src "*") -Destination $dst -Recurse -Force -ErrorAction Stop
      }
    }
    foreach ($f in @("content\categories.json", "content\category-groups.json", "content\products.json", "content\product-archive.json")) {
      $src = Join-Path $tmpDir $f
      if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $Root $f) -Force }
    }
    Invoke-WikiBuild
    Start-WikiSnapshot -Message "Backup wiederhergestellt: $fileName durch $($Session.username)"
    $restoredArticles = @(Get-ChildItem -LiteralPath $articlesDir -Filter "*.md" -File -ErrorAction SilentlyContinue).Count
    $restoredImages = @(Get-ChildItem -LiteralPath $uploadsDir -File -Recurse -ErrorAction SilentlyContinue).Count
    $wikiData = Get-WikiData
    $wikiData | Add-Member -NotePropertyName restoredArticles -NotePropertyValue $restoredArticles -Force
    $wikiData | Add-Member -NotePropertyName restoredImages -NotePropertyValue $restoredImages -Force
    return $wikiData
  } finally {
    Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Write-SuggestionFile {
  param([string]$Id, [object]$Record)
  $safeId = Sanitize-Line $Id
  if ($safeId -notmatch '^[A-Za-z0-9._-]+$' -or $safeId.Contains("..")) { throw "Unbekannter Vorschlag." }
  $path = Join-Path $suggestionsDir "$safeId.json"
  $temporary = "$path.tmp"
  $Record | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $temporary
  Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Invoke-SuggestionMigration {
  # Ergaenzt fehlende Felder aelterer Vorschlagsdateien (idempotent, atomar je Datei).
  # Statusmodell: open (Warten auf Freigabe) -> accepted/rejected (Bearbeitet,
  # wartet auf Abschluss durch Ersteller) -> per Acknowledge geloescht (kein Archiv).
  if (-not (Test-Path -LiteralPath $suggestionsDir)) { return }
  foreach ($file in (Get-ChildItem -LiteralPath $suggestionsDir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
    try {
      $item = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName | ConvertFrom-Json
      $changed = $false
      foreach ($field in @("kind", "type", "status", "productId", "title", "body", "note", "author", "authorDisplay", "createdAt", "rejectionReason", "rejectedAt", "rejectedBy", "processedAt", "processedBy", "decision")) {
        if (-not ($item.PSObject.Properties.Name -contains $field)) {
          $item | Add-Member -NotePropertyName $field -NotePropertyValue "" -Force
          $changed = $true
        }
      }
      if (-not $item.kind) { $item.kind = "article"; $changed = $true }
      if (-not $item.type) { $item.type = "change"; $changed = $true }
      if (-not $item.status) { $item.status = "open"; $changed = $true }
      if ($item.status -eq "rejected" -and -not $item.decision) { $item.decision = "rejected"; $changed = $true }
      if ($changed) { Write-SuggestionFile -Id ([IO.Path]::GetFileNameWithoutExtension($file.Name)) -Record $item }
    } catch { }
  }
}

function Read-Suggestions {
  if (-not (Test-Path -LiteralPath $suggestionsDir)) { return @() }
  $items = @()
  foreach ($file in (Get-ChildItem -LiteralPath $suggestionsDir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
    try {
      $item = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName | ConvertFrom-Json
      $items += [pscustomobject]@{
        id = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        kind = if ($item.PSObject.Properties.Name -contains "kind" -and $item.kind) { [string]$item.kind } else { "article" }
        type = if ($item.PSObject.Properties.Name -contains "type" -and $item.type) { [string]$item.type } else { "change" }
        status = if ($item.PSObject.Properties.Name -contains "status" -and $item.status) { [string]$item.status } else { "open" }
        slug = [string]$item.slug
        productId = if ($item.PSObject.Properties.Name -contains "productId") { [string]$item.productId } else { "" }
        title = [string]$item.title
        body = [string]$item.body
        note = if ($item.PSObject.Properties.Name -contains "note") { [string]$item.note } else { "" }
        fields = if ($item.PSObject.Properties.Name -contains "fields" -and $null -ne $item.fields) { $item.fields } else { $null }
        author = [string]$item.author
        authorDisplay = if ($item.PSObject.Properties.Name -contains "authorDisplay") { [string]$item.authorDisplay } else { [string]$item.author }
        createdAt = [string]$item.createdAt
        rejectionReason = if ($item.PSObject.Properties.Name -contains "rejectionReason") { [string]$item.rejectionReason } else { "" }
        rejectedAt = if ($item.PSObject.Properties.Name -contains "rejectedAt") { [string]$item.rejectedAt } else { "" }
        rejectedBy = if ($item.PSObject.Properties.Name -contains "rejectedBy") { [string]$item.rejectedBy } else { "" }
        processedAt = if ($item.PSObject.Properties.Name -contains "processedAt") { [string]$item.processedAt } else { "" }
        processedBy = if ($item.PSObject.Properties.Name -contains "processedBy") { [string]$item.processedBy } else { "" }
        decision = if ($item.PSObject.Properties.Name -contains "decision") { [string]$item.decision } else { "" }
      }
    } catch { }
  }
  return @($items | Sort-Object createdAt -Descending)
}

function Save-Suggestion {
  param([string]$Slug, [string]$Title, [string]$Body, [string]$Note, [object]$Session,
    [string]$Kind = "article", [string]$ProductId = "", [object]$Fields = $null)
  $kind = (Sanitize-Line $Kind).ToLowerInvariant()
  if ($kind -ne "product") { $kind = "article" }
  $productId = Sanitize-Line $ProductId
  $title = Sanitize-Line $Title
  $body = if ($null -eq $Body) { "" } else { [string]$Body }
  $note = Sanitize-Line $Note
  if ($kind -eq "product") {
    if ([string]::IsNullOrWhiteSpace($productId)) { throw "Unbekanntes Produkt." }
    $product = @(Read-Products) | Where-Object { $_.id -eq $productId } | Select-Object -First 1
    if (-not $product) { throw "Produkt nicht gefunden." }
    if ($null -eq $Fields) { throw "Der Vorschlag ist leer." }
    $fieldNames = @("name", "article", "hardwareRevision", "description", "categories")
    $cleanFields = [pscustomobject]@{}
    $filled = 0
    foreach ($fieldName in $fieldNames) {
      $hasField = $false
      $rawValue = $null
      if ($Fields -is [hashtable]) { $hasField = $Fields.ContainsKey($fieldName); if ($hasField) { $rawValue = $Fields[$fieldName] } }
      elseif ($null -ne $Fields -and ($Fields.PSObject.Properties.Name -contains $fieldName)) { $hasField = $true; $rawValue = $Fields.$fieldName }
      if ($hasField) {
        if ($fieldName -eq "categories") {
          $cleanFields | Add-Member -NotePropertyName categories -NotePropertyValue @(@($rawValue) | ForEach-Object { Sanitize-Line ([string]$_) } | Where-Object { $_ }) -Force
        } else {
          $cleanFields | Add-Member -NotePropertyName $fieldName -NotePropertyValue (Sanitize-Line ([string]$rawValue)) -Force
        }
        $filled++
      }
    }
    if ($filled -eq 0 -and [string]::IsNullOrWhiteSpace($note)) { throw "Der Vorschlag ist leer." }
    $id = "{0}-{1}-{2}" -f (Get-Date -Format "yyyyMMdd-HHmmssfff"), ("produkt-" + $productId), ([Guid]::NewGuid().ToString("N").Substring(0, 6))
    $record = [pscustomobject]@{
      kind = "product"
      type = "change"
      status = "open"
      slug = ""
      productId = $productId
      title = $product.name
      body = ""
      fields = $cleanFields
      note = $note
      author = $Session.username
      authorDisplay = $Session.displayName
      createdAt = (Get-Date).ToString("o")
      rejectionReason = ""
      rejectedAt = ""
      rejectedBy = ""
    }
    Write-SuggestionFile -Id $id -Record $record
    return [pscustomobject]@{
      id = $id; kind = "product"; type = "change"; status = "open"; productId = $productId
      title = $record.title; fields = $cleanFields; note = $note
      author = $record.author; authorDisplay = $record.authorDisplay; createdAt = $record.createdAt
    }
  }
  $slug = ConvertTo-Slug (Sanitize-Line $Slug)
  if ([string]::IsNullOrWhiteSpace($slug)) { throw "Unbekannter Artikel." }
  if ([string]::IsNullOrWhiteSpace($body) -and [string]::IsNullOrWhiteSpace($title)) { throw "Der Vorschlag ist leer." }
  if ($body.Length -gt 200000) { throw "Der Vorschlag ist zu lang (max. 200.000 Zeichen)." }
  $article = Get-ArticleBySlug $slug
  if (-not $article) { throw "Artikel nicht gefunden." }
  $id = "{0}-{1}-{2}" -f (Get-Date -Format "yyyyMMdd-HHmmssfff"), $slug, ([Guid]::NewGuid().ToString("N").Substring(0, 6))
  $record = [pscustomobject]@{
    kind = "article"
    type = "change"
    status = "open"
    slug = $slug
    productId = ""
    title = $title
    body = $body
    note = $note
    author = $Session.username
    authorDisplay = $Session.displayName
    createdAt = (Get-Date).ToString("o")
    rejectionReason = ""
    rejectedAt = ""
    rejectedBy = ""
  }
  Write-SuggestionFile -Id $id -Record $record
  return [pscustomobject]@{
    id = $id; kind = "article"; type = "change"; status = "open"; slug = $slug
    title = $record.title; body = $body; note = $note
    author = $record.author; authorDisplay = $record.authorDisplay; createdAt = $record.createdAt
  }
}

function Get-SuggestionFile {
  param([string]$Id)
  $safeId = Sanitize-Line $Id
  if ($safeId -notmatch '^[A-Za-z0-9._-]+$' -or $safeId.Contains("..")) { throw "Unbekannter Vorschlag." }
  $path = Join-Path $suggestionsDir "$safeId.json"
  if (-not (Test-Path -LiteralPath $path)) { throw "Vorschlag nicht gefunden." }
  $item = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
  return [pscustomobject]@{ Id = $safeId; Path = $path; Item = $item }
}

function Reject-Suggestion {
  # Lehnt einen Vorschlag mit Pflicht-Begruendung ab (atomar, persistent).
  param([string]$Id, [string]$Reason, [object]$Session)
  $found = Get-SuggestionFile -Id $Id
  $item = $found.Item
  $status = if ($item.PSObject.Properties.Name -contains "status") { [string]$item.status } else { "open" }
  if ($status -ne "open") { throw "Der Vorschlag wurde bereits bearbeitet." }
  $reason = Sanitize-Line $Reason
  if ([string]::IsNullOrWhiteSpace($reason)) { throw "Bitte einen Ablehnungsgrund angeben." }
  if ($reason.Length -gt 2000) { throw "Der Ablehnungsgrund ist zu lang (max. 2000 Zeichen)." }
  $item | Add-Member -NotePropertyName status -NotePropertyValue "rejected" -Force
  $item | Add-Member -NotePropertyName rejectionReason -NotePropertyValue $reason -Force
  $item | Add-Member -NotePropertyName rejectedAt -NotePropertyValue ((Get-Date).ToString("o")) -Force
  $item | Add-Member -NotePropertyName rejectedBy -NotePropertyValue $Session.username -Force
  $item | Add-Member -NotePropertyName processedAt -NotePropertyValue ((Get-Date).ToString("o")) -Force
  $item | Add-Member -NotePropertyName processedBy -NotePropertyValue $Session.username -Force
  $item | Add-Member -NotePropertyName decision -NotePropertyValue "rejected" -Force
  Write-SuggestionFile -Id $found.Id -Record $item
  Start-WikiSnapshot -Message "Vorschlag abgelehnt durch $($Session.username): $($found.Id)"
}

function Acknowledge-Suggestion {
  # Schließt einen bearbeiteten Vorschlag ab: nur der Ersteller (eigene
  # accepted/rejected) oder ein Pruefer (articles.edit, Cleanup). Die Datei wird
  # geloescht, es wird kein Archiv angelegt.
  param([string]$Id, [object]$Session)
  $found = Get-SuggestionFile -Id $Id
  $item = $found.Item
  $status = if ($item.PSObject.Properties.Name -contains "status") { [string]$item.status } else { "open" }
  if ($status -eq "open") { throw "Offene Vorschlaege muessen erst vom Administrator bearbeitet werden." }
  $canEdit = @(Get-RolePermissions -Role $Session.role) -contains "articles.edit"
  $isAuthor = [string]$item.author -eq $Session.username
  if (-not ($isAuthor -or $canEdit)) { throw [UnauthorizedAccessException]::new("Fuer diese Aktion fehlt die Berechtigung.") }
  Remove-Item -LiteralPath $found.Path -Force
}

function Accept-Suggestion {
  # Uebernimmt einen Aenderungsvorschlag: Produkte werden serverseitig
  # angewendet, Artikel wurden bereits ueber den Editor gespeichert.
  # Der Vorschlag bleibt als status=accepted (Bearbeitet) bestehen, bis der
  # Ersteller ihn per Acknowledge abschliesst (kein Archiv).
  param([string]$Id, [object]$Session)
  $found = Get-SuggestionFile -Id $Id
  $item = $found.Item
  $status = if ($item.PSObject.Properties.Name -contains "status") { [string]$item.status } else { "open" }
  if ($status -ne "open") { throw "Der Vorschlag wurde bereits bearbeitet." }
  $kind = if ($item.PSObject.Properties.Name -contains "kind" -and $item.kind) { [string]$item.kind } else { "article" }
  if ($kind -eq "product") {
    $productId = if ($item.PSObject.Properties.Name -contains "productId") { [string]$item.productId } else { "" }
    $product = @(Read-Products) | Where-Object { $_.id -eq $productId } | Select-Object -First 1
    if (-not $product) { throw "Produkt nicht gefunden." }
    $apply = [pscustomobject]@{
      name = $product.name
      article = $product.article
      hardwareRevision = $product.hardwareRevision
      description = $product.description
      categories = @($product.categories)
      reason = if ($item.PSObject.Properties.Name -contains "note" -and -not [string]::IsNullOrWhiteSpace([string]$item.note)) { [string]$item.note } else { "Vorschlag uebernommen" }
    }
    if ($item.PSObject.Properties.Name -contains "fields" -and $null -ne $item.fields) {
      foreach ($property in $item.fields.PSObject.Properties) {
        if ($property.Name -eq "categories") {
          $apply.categories = @(@($property.Value) | ForEach-Object { Sanitize-Line ([string]$_) } | Where-Object { $_ })
        } elseif (@("name", "article", "hardwareRevision", "description") -contains $property.Name) {
          $apply | Add-Member -NotePropertyName $property.Name -NotePropertyValue (Sanitize-Line ([string]$property.Value)) -Force
        }
      }
    }
    $apply | Add-Member -NotePropertyName changedBy -NotePropertyValue $Session.username -Force
    Update-Product -Id $productId -Data $apply
    Start-WikiSnapshot -Message "Produktvorschlag uebernommen durch $($Session.username): $($product.name)"
  }
  $item | Add-Member -NotePropertyName status -NotePropertyValue "accepted" -Force
  $item | Add-Member -NotePropertyName processedAt -NotePropertyValue ((Get-Date).ToString("o")) -Force
  $item | Add-Member -NotePropertyName processedBy -NotePropertyValue $Session.username -Force
  $item | Add-Member -NotePropertyName decision -NotePropertyValue "approved" -Force
  Write-SuggestionFile -Id $found.Id -Record $item
}

function Write-DeleteRejection {
  # Haelt die Ablehnung einer Loeschmarkierung dauerhaft fest, damit der
  # Ersteller Status und Grund auch nach Reload/Login sieht.
  param([string]$Kind, [string]$TargetId, [string]$TargetTitle, [string]$Proposer, [string]$ProposedAt, [string]$ProposerReason, [string]$RejectionReason, [object]$Session)
  $reason = Sanitize-Line $RejectionReason
  if ([string]::IsNullOrWhiteSpace($reason)) { throw "Bitte einen Ablehnungsgrund angeben." }
  if ($reason.Length -gt 2000) { throw "Der Ablehnungsgrund ist zu lang (max. 2000 Zeichen)." }
  $kind = (Sanitize-Line $Kind).ToLowerInvariant()
  if ($kind -ne "product") { $kind = "article" }
  $prefix = if ($kind -eq "product") { "produkt" } else { "artikel" }
  $id = "{0}-{1}-{2}-{3}" -f (Get-Date -Format "yyyyMMdd-HHmmssfff"), "ablehnung", $prefix, ([Guid]::NewGuid().ToString("N").Substring(0, 6))
  $record = [pscustomobject]@{
    kind = $kind
    type = "delete"
    status = "rejected"
    slug = if ($kind -eq "article") { [string]$TargetId } else { "" }
    productId = if ($kind -eq "product") { [string]$TargetId } else { "" }
    title = Sanitize-Line $TargetTitle
    body = ""
    note = Sanitize-Line $ProposerReason
    author = Sanitize-Line $Proposer
    authorDisplay = Sanitize-Line $Proposer
    createdAt = if ($ProposedAt) { [string]$ProposedAt } else { (Get-Date).ToString("o") }
    rejectionReason = $reason
    rejectedAt = (Get-Date).ToString("o")
    rejectedBy = $Session.username
    processedAt = (Get-Date).ToString("o")
    processedBy = $Session.username
    decision = "rejected"
  }
  Write-SuggestionFile -Id $id -Record $record
  Start-WikiSnapshot -Message "Loeschmarkierung abgelehnt durch $($Session.username): $(Sanitize-Line $TargetTitle)"
  return $id
}

function Remove-Suggestion {
  param([string]$Id, [object]$Session)
  $found = Get-SuggestionFile -Id $Id
  $item = $found.Item
  $status = if ($item.PSObject.Properties.Name -contains "status") { [string]$item.status } else { "open" }
  $canEdit = @(Get-RolePermissions -Role $Session.role) -contains "articles.edit"
  $isAuthor = [string]$item.author -eq $Session.username
  if ($status -eq "open") {
    # Offene Vorschlaege duerfen nur vom Ersteller zurueckgezogen werden;
    # Pruefer lehnen mit Begruendung ab (Reject) bzw. uebernehmen (Accept).
    if (-not $isAuthor) {
      if (-not $canEdit) { throw [UnauthorizedAccessException]::new("Fuer diese Aktion fehlt die Berechtigung.") }
      throw "Offene Vorschlaege muessen mit Ablehnungsgrund abgelehnt werden."
    }
  } else {
    if (-not ($isAuthor -or $canEdit)) { throw [UnauthorizedAccessException]::new("Fuer diese Aktion fehlt die Berechtigung.") }
  }
  Remove-Item -LiteralPath $found.Path -Force
}

function Set-DeleteRequest {
  param([string]$Slug, [string]$Reason, [object]$Session)
  $article = Get-ArticleBySlug $Slug
  if (-not $article) { throw "Artikel nicht gefunden." }
  if ($article.File.DirectoryName -ne (Get-Item -LiteralPath $articlesDir).FullName) { throw "Nur aktive Artikel koennen markiert werden." }
  $reason = Sanitize-Line $Reason
  if ([string]::IsNullOrWhiteSpace($reason)) { throw "Bitte einen Grund fuer die Loeschmarkierung angeben." }
  $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $article.File.FullName
  $lines = $raw -split "\r?\n"
  $endIndex = -1
  for ($i = 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq "---") { $endIndex = $i; break }
  }
  if ($endIndex -lt 0) { throw "Artikeldatei ist ungueltig (FrontMatter fehlt)." }
  $meta = @{}
  for ($i = 1; $i -lt $endIndex; $i++) {
    $pair = [regex]::Match($lines[$i], "^\s*([A-Za-z0-9_-]+)\s*:\s*(.*?)\s*$")
    if ($pair.Success) { $meta[$pair.Groups[1].Value.ToLowerInvariant()] = $pair.Groups[2].Value.Trim() }
  }
  $meta["delete_request_by"] = $Session.username
  $meta["delete_request_at"] = (Get-Date).ToString("o")
  $meta["delete_request_reason"] = $reason
  $head = @("---")
  foreach ($key in ($meta.Keys | Sort-Object)) { $head += "${key}: $($meta[$key])" }
  $head += "---"
  $rest = if ($endIndex + 1 -lt $lines.Count) { ($lines[($endIndex + 1)..($lines.Count - 1)] -join "`n") } else { "" }
  $newRaw = ($head -join "`n") + "`n" + $rest
  [IO.File]::WriteAllText($article.File.FullName, $newRaw, [Text.UTF8Encoding]::new($false))
  Start-WikiSnapshot -Message "Loeschmarkierung durch $($Session.username): $($article.Title)"
}

function Clear-DeleteRequest {
  param([string]$Slug, [string]$Reason, [object]$Session)
  $article = Get-ArticleBySlug $Slug
  if (-not $article) { throw "Artikel nicht gefunden." }
  $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $article.File.FullName
  $lines = $raw -split "\r?\n"
  $endIndex = -1
  for ($i = 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq "---") { $endIndex = $i; break }
  }
  if ($endIndex -lt 0) { throw "Artikeldatei ist ungueltig (FrontMatter fehlt)." }
  $meta = @{}
  for ($i = 1; $i -lt $endIndex; $i++) {
    $pair = [regex]::Match($lines[$i], "^\s*([A-Za-z0-9_-]+)\s*:\s*(.*?)\s*$")
    if ($pair.Success) { $meta[$pair.Groups[1].Value.ToLowerInvariant()] = $pair.Groups[2].Value.Trim() }
  }
  if (-not $meta.ContainsKey("delete_request_by")) { return }
  $reason = Sanitize-Line $Reason
  if ([string]::IsNullOrWhiteSpace($reason)) { throw "Bitte einen Ablehnungsgrund angeben." }
  if ($reason.Length -gt 2000) { throw "Der Ablehnungsgrund ist zu lang (max. 2000 Zeichen)." }
  $proposer = [string]$meta["delete_request_by"]
  $proposedAt = if ($meta.ContainsKey("delete_request_at")) { [string]$meta["delete_request_at"] } else { "" }
  $proposerReason = if ($meta.ContainsKey("delete_request_reason")) { [string]$meta["delete_request_reason"] } else { "" }
  $meta.Remove("delete_request_by")
  $meta.Remove("delete_request_at")
  $meta.Remove("delete_request_reason")
  $head = @("---")
  foreach ($key in ($meta.Keys | Sort-Object)) {
    if ([string]::IsNullOrWhiteSpace($meta[$key]) -and $key.StartsWith("delete_request_")) { continue }
    $head += "${key}: $($meta[$key])"
  }
  $head += "---"
  $rest = if ($endIndex + 1 -lt $lines.Count) { ($lines[($endIndex + 1)..($lines.Count - 1)] -join "`n") } else { "" }
  [IO.File]::WriteAllText($article.File.FullName, (($head -join "`n") + "`n" + $rest), [Text.UTF8Encoding]::new($false))
  Write-DeleteRejection -Kind "article" -TargetId $Slug -TargetTitle $article.Title -Proposer $proposer -ProposedAt $proposedAt -ProposerReason $proposerReason -RejectionReason $reason -Session $Session | Out-Null
}

function Set-ProductDeleteRequest {
  param([string]$Id, [string]$Reason, [object]$Session)
  $products = @(Read-Products)
  $product = $products | Where-Object { $_.id -eq $Id } | Select-Object -First 1
  if (-not $product) { throw "Produkt nicht gefunden." }
  $reason = Sanitize-Line $Reason
  if ([string]::IsNullOrWhiteSpace($reason)) { throw "Bitte einen Grund fuer die Loeschmarkierung angeben." }
  $product.deleteRequest = [pscustomobject]@{
    by = $Session.username
    at = (Get-Date).ToString("o")
    reason = $reason
  }
  Write-Products $products
  Start-WikiSnapshot -Message "Produkt-Loeschmarkierung durch $($Session.username): $($product.name)"
}

function Clear-ProductDeleteRequest {
  param([string]$Id, [string]$Reason, [object]$Session)
  $products = @(Read-Products)
  $product = $products | Where-Object { $_.id -eq $Id } | Select-Object -First 1
  if (-not $product) { throw "Produkt nicht gefunden." }
  if ($null -eq $product.deleteRequest) { return }
  $reason = Sanitize-Line $Reason
  if ([string]::IsNullOrWhiteSpace($reason)) { throw "Bitte einen Ablehnungsgrund angeben." }
  if ($reason.Length -gt 2000) { throw "Der Ablehnungsgrund ist zu lang (max. 2000 Zeichen)." }
  $proposer = if ($product.deleteRequest.PSObject.Properties.Name -contains "by") { [string]$product.deleteRequest.by } else { "" }
  $proposedAt = if ($product.deleteRequest.PSObject.Properties.Name -contains "at") { [string]$product.deleteRequest.at } else { "" }
  $proposerReason = if ($product.deleteRequest.PSObject.Properties.Name -contains "reason") { [string]$product.deleteRequest.reason } else { "" }
  $product.deleteRequest = $null
  Write-Products $products
  Write-DeleteRejection -Kind "product" -TargetId $Id -TargetTitle $product.name -Proposer $proposer -ProposedAt $proposedAt -ProposerReason $proposerReason -RejectionReason $reason -Session $Session | Out-Null
}

function Delete-Article {
  param([string]$Slug, [object]$Data)
  $reason = Sanitize-Line $Data.reason
  if ([string]::IsNullOrWhiteSpace($reason)) { throw "Vor dem Loeschen muss ein Grund angegeben werden." }
  $article = Get-ArticleBySlug $Slug
  if (-not $article) { throw "Artikel nicht gefunden." }

  $currentRevision = Get-Revision $article.Meta
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $archiveSlug = "archiv-$stamp-$Slug-r$currentRevision"
  $archivePath = Join-Path $archiveDir "$archiveSlug.md"
  $changedBy = if ($Data.PSObject.Properties.Name -contains "changedBy") { Sanitize-Line $Data.changedBy } else { "System" }
  [IO.File]::WriteAllText($archivePath, (New-ArchivedMarkdown -Article $article -ArchiveSlug $archiveSlug -ArchiveAction "Geloescht und archiviert" -Reason $reason -ChangedBy $changedBy), [Text.UTF8Encoding]::new($false))
  Remove-Item -LiteralPath $article.File.FullName -Force
  Start-WikiSnapshot -Message "Artikel archiviert: $($article.Title)"
}

function Get-ArchivedArticle {
  param([string]$Slug)
  if (-not (Test-Path -LiteralPath $archiveDir)) { return $null }
  foreach ($file in (Get-ChildItem -LiteralPath $archiveDir -Filter "*.md" -File -Recurse)) {
    $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName
    $parsed = Read-FrontMatter $raw
    $fileSlug = if ($parsed.Meta.ContainsKey("slug")) { ConvertTo-Slug $parsed.Meta["slug"] } else { "" }
    if ($fileSlug -eq $Slug) {
      $title = if ($parsed.Meta.ContainsKey("title")) { $parsed.Meta["title"] } else { $file.BaseName }
      return [pscustomobject]@{ File = $file; Raw = $raw; Meta = $parsed.Meta; Body = $parsed.Body; Slug = $fileSlug; Title = $title }
    }
  }
  return $null
}

function Restore-Article {
  param([string]$Slug, [object]$Data)
  $reason = Sanitize-Line $Data.reason
  if ([string]::IsNullOrWhiteSpace($reason)) { throw "Vor dem Wiederherstellen muss ein Grund angegeben werden." }
  $archived = Get-ArchivedArticle $Slug
  if (-not $archived) { throw "Archivierter Artikel nicht gefunden." }
  $meta = $archived.Meta
  # Originalposition: gespeicherte Referenz, sonst aus Archivtitel ableiten.
  $originalSlug = if ($meta.ContainsKey("original_slug") -and -not [string]::IsNullOrWhiteSpace($meta["original_slug"])) { ConvertTo-Slug $meta["original_slug"] } else { "" }
  $originalTitle = if ($meta.ContainsKey("original_title") -and -not [string]::IsNullOrWhiteSpace($meta["original_title"])) { [string]$meta["original_title"] } else { "" }
  if ([string]::IsNullOrWhiteSpace($originalTitle)) {
    $originalTitle = [string]$archived.Title
    $originalTitle = [regex]::Replace($originalTitle, "^Archiv:\s*", "")
    $originalTitle = [regex]::Replace($originalTitle, "\s*\(Revision \d+\)\s*$", "")
  }
  if ([string]::IsNullOrWhiteSpace($originalSlug)) { $originalSlug = ConvertTo-Slug $originalTitle }
  if (Get-ArticleBySlug $originalSlug) { throw "Ein aktiver Artikel mit diesem Titel existiert bereits." }
  $originalCategories = @()
  if ($meta.ContainsKey("original_categories") -and -not [string]::IsNullOrWhiteSpace($meta["original_categories"])) {
    $originalCategories = @($meta["original_categories"] -split "," | ForEach-Object { Sanitize-Line $_ } | Where-Object { $_ -and $_ -ne "Archiv" })
  }
  if ($originalCategories.Count -eq 0 -and $meta.ContainsKey("original_category")) {
    $candidate = Sanitize-Line $meta["original_category"]
    if ($candidate -and $candidate -ne "Archiv") { $originalCategories = @($candidate) }
  }
  $knownCategories = @(Read-Categories | ForEach-Object { $_.name })
  $originalCategories = @($originalCategories | Where-Object { $knownCategories -contains $_ })
  $fallbackCategory = if ($knownCategories.Count -gt 0) { $knownCategories[0] } else { "Wiki Anleitung" }
  if ($originalCategories.Count -eq 0 -and $meta.ContainsKey("original_category")) {
    $candidate = Sanitize-Line $meta["original_category"]
    if ($candidate -and $candidate -ne "Archiv" -and $knownCategories -contains $candidate) { $originalCategories = @($candidate) }
  }
  if ($originalCategories.Count -eq 0) { $originalCategories = @($fallbackCategory) }
  $revision = Get-Revision $meta
  $changedBy = if ($Data.PSObject.Properties.Name -contains "changedBy") { Sanitize-Line $Data.changedBy } else { "System" }
  $restoreData = [pscustomobject]@{
    title = $originalTitle
    categories = $originalCategories
    tags = if ($meta.ContainsKey("tags")) { [string]$meta["tags"] } else { "" }
    owner = if ($meta.ContainsKey("owner")) { [string]$meta["owner"] } else { "" }
    summary = if ($meta.ContainsKey("summary")) { [string]$meta["summary"] } else { "" }
    products = @(Read-ProductMeta $meta)
    attachments = @(Read-AttachmentMeta $meta)
    related = @()
    body = (Remove-RevisionLog $archived.Body)
    deleteRequest = $null
  }
  $existingLog = Get-RevisionLog $archived.Body
  $markdown = New-ArticleMarkdown -Data $restoreData -Revision $revision -Action "Wiederhergestellt" -Reason $reason -ExistingLog $existingLog
  [IO.File]::WriteAllText((Join-Path $articlesDir "$originalSlug.md"), $markdown, [Text.UTF8Encoding]::new($false))
  Remove-Item -LiteralPath $archived.File.FullName -Force
  Start-WikiSnapshot -Message "Artikel wiederhergestellt: $originalTitle"
  return $originalSlug
}

function Restore-Product {
  param([string]$Id, [object]$Data)
  $reason = Sanitize-Line $Data.reason
  if ([string]::IsNullOrWhiteSpace($reason)) { throw "Vor dem Wiederherstellen muss ein Grund angegeben werden." }
  $archived = @(Read-ArchivedProducts) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
  if (-not $archived) { throw "Archiviertes Produkt nicht gefunden." }
  $active = @(Read-Products) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
  if ($active) { throw "Ein aktives Produkt mit dieser Kennung existiert bereits." }
  $changedBy = if ($Data.PSObject.Properties.Name -contains "changedBy") { Sanitize-Line $Data.changedBy } else { "System" }
  $restored = [pscustomobject]@{
    id = $archived.id
    name = $archived.name
    article = $archived.article
    hardwareRevision = $archived.hardwareRevision
    description = $archived.description
    categories = @($archived.categories)
    revision = [Math]::Max(1, [int]$archived.revision)
    status = "Aktiv"
    updated = (Get-Date -Format "yyyy-MM-dd")
    changeDate = (Get-Date -Format "yyyy-MM-dd HH:mm")
    changeAction = "Wiederhergestellt"
    changeReason = $reason
    changedBy = $changedBy
  }
  $products = @(Read-Products) + @($restored)
  Write-Products $products
  $remaining = @(Read-ArchivedProducts) | Where-Object { $_.id -ne $Id }
  Write-ArchivedProducts $remaining
  # Produkt wieder in seinen Kategorien verankern.
  $categories = @(Read-Categories)
  $categoriesChanged = $false
  foreach ($category in $categories) {
    if (@($restored.categories) -contains $category.name) {
      if (-not $category.products) { $category | Add-Member -NotePropertyName products -NotePropertyValue @() -Force }
      if (@($category.products) -notcontains $restored.id) {
        $category.products = @(@($category.products) + @($restored.id))
        $categoriesChanged = $true
      }
    }
  }
  if ($categoriesChanged) { Write-Categories $categories }
  Start-WikiSnapshot -Message "Produkt wiederhergestellt: $($restored.name)"
  return $restored.id
}

function Get-ContentType {
  param([string]$Path)
  switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    ".html" { return "text/html; charset=utf-8" }
    ".css" { return "text/css; charset=utf-8" }
    ".js" { return "application/javascript; charset=utf-8" }
    ".json" { return "application/json; charset=utf-8" }
    ".md" { return "text/markdown; charset=utf-8" }
    ".png" { return "image/png" }
    ".jpg" { return "image/jpeg" }
    ".jpeg" { return "image/jpeg" }
    ".gif" { return "image/gif" }
    ".webp" { return "image/webp" }
    ".svg" { return "image/svg+xml" }
    ".pdf" { return "application/pdf" }
    ".doc" { return "application/msword" }
    ".docx" { return "application/vnd.openxmlformats-officedocument.wordprocessingml.document" }
    ".xls" { return "application/vnd.ms-excel" }
    ".xlsx" { return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }
    default { return "application/octet-stream" }
  }
}

function New-HttpResponseBytes {
  param([int]$StatusCode, [string]$Content, [string]$ContentType = "application/json; charset=utf-8", [array]$Headers = @())
  $reason = switch ($StatusCode) {
    200 { "OK" }
    204 { "No Content" }
    400 { "Bad Request" }
    401 { "Unauthorized" }
    403 { "Forbidden" }
    404 { "Not Found" }
    409 { "Conflict" }
    405 { "Method Not Allowed" }
    default { "OK" }
  }
  $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Content)
  $extraHeaders = if ($Headers.Count) { ($Headers -join "`r`n") + "`r`n" } else { "" }
  $header = "HTTP/1.1 $StatusCode $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($bodyBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET,POST,PUT,DELETE,OPTIONS`r`nAccess-Control-Allow-Headers: Content-Type`r`n${extraHeaders}Connection: close`r`n`r`n"
  $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
  $bytes = New-Object byte[] ($headerBytes.Length + $bodyBytes.Length)
  [Array]::Copy($headerBytes, 0, $bytes, 0, $headerBytes.Length)
  [Array]::Copy($bodyBytes, 0, $bytes, $headerBytes.Length, $bodyBytes.Length)
  return $bytes
}

function New-JsonResponseBytes {
  param([int]$StatusCode, [object]$Data, [array]$Headers = @())
  return New-HttpResponseBytes -StatusCode $StatusCode -Content ($Data | ConvertTo-Json -Depth 20) -Headers $Headers
}

function New-ErrorBytes {
  param([int]$StatusCode, [string]$Message)
  return New-JsonResponseBytes -StatusCode $StatusCode -Data ([pscustomobject]@{ error = $Message })
}

function New-FileDownloadBytes {
  param([string]$FilePath, [string]$DownloadName)
  $fileBytes = [IO.File]::ReadAllBytes($FilePath)
  $safe = [string]$DownloadName
  $header = "HTTP/1.1 200 OK`r`nContent-Type: application/zip`r`nContent-Length: $($fileBytes.Length)`r`nContent-Disposition: attachment; filename=`"$safe`"`r`nCache-Control: no-cache`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
  $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
  $bytes = New-Object byte[] ($headerBytes.Length + $fileBytes.Length)
  [Array]::Copy($headerBytes, 0, $bytes, 0, $headerBytes.Length)
  [Array]::Copy($fileBytes, 0, $bytes, $headerBytes.Length, $fileBytes.Length)
  return $bytes
}

function New-FileResponseBytes {
  param([string]$UrlPath)
  $path = [Uri]::UnescapeDataString($UrlPath.TrimStart("/"))
  if ([string]::IsNullOrWhiteSpace($path)) { $path = "index.html" }
  $normalizedPath = $path -replace "\\", "/"
  $allowed = $normalizedPath -eq "index.html" -or $normalizedPath.StartsWith("assets/") -or $normalizedPath.StartsWith("content/uploads/") -or $normalizedPath.StartsWith("Anhaenge/") -or $normalizedPath.StartsWith("Anhänge/")
  if (-not $allowed) { return New-ErrorBytes -StatusCode 404 -Message "Datei nicht gefunden." }
  $fullPath = [IO.Path]::GetFullPath((Join-Path $Root $path))
  $rootFull = [IO.Path]::GetFullPath($Root)
  if (-not $fullPath.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path $fullPath -PathType Leaf)) {
    return New-ErrorBytes -StatusCode 404 -Message "Datei nicht gefunden."
  }
  $fileBytes = [IO.File]::ReadAllBytes($fullPath)
  # App-Dateien (HTML/JS/CSS) nie aus dem Browser-Cache bedienen: nach jedem
  # Update muss garantiert der neue Stand laufen (sonst z. B. alte Workflows
  # mit neuem Backend bzw. umgekehrt). Medien duerfen gecacht werden.
  $cacheControl = "Cache-Control: public, max-age=3600`r`n"
  if ($fullPath -match '\.(html|js|css)$') { $cacheControl = "Cache-Control: no-cache`r`n" }
  $header = "HTTP/1.1 200 OK`r`nContent-Type: $(Get-ContentType $fullPath)`r`nContent-Length: $($fileBytes.Length)`r`n${cacheControl}Access-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
  $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
  $bytes = New-Object byte[] ($headerBytes.Length + $fileBytes.Length)
  [Array]::Copy($headerBytes, 0, $bytes, 0, $headerBytes.Length)
  [Array]::Copy($fileBytes, 0, $bytes, $headerBytes.Length, $fileBytes.Length)
  return $bytes
}

function Read-HttpRequest {
  param([Net.Sockets.NetworkStream]$Stream)
  $buffer = New-Object byte[] 8192
  $data = New-Object System.Collections.Generic.List[byte]
  $headerEnd = -1
  do {
    $read = $Stream.Read($buffer, 0, $buffer.Length)
    if ($read -le 0) { break }
    for ($i = 0; $i -lt $read; $i++) { $data.Add($buffer[$i]) }
    $text = [Text.Encoding]::ASCII.GetString($data.ToArray())
    $headerEnd = $text.IndexOf("`r`n`r`n")
  } while ($headerEnd -lt 0)

  if ($headerEnd -lt 0) { throw "Ungueltige HTTP-Anfrage." }
  $allBytes = $data.ToArray()
  $headerText = [Text.Encoding]::ASCII.GetString($allBytes, 0, $headerEnd)
  $lines = $headerText -split "`r`n"
  $requestLine = $lines[0] -split " "
  $headers = @{}
  foreach ($line in $lines[1..($lines.Length - 1)]) {
    $idx = $line.IndexOf(":")
    if ($idx -gt 0) { $headers[$line.Substring(0, $idx).ToLowerInvariant()] = $line.Substring($idx + 1).Trim() }
  }
  $contentLength = if ($headers.ContainsKey("content-length")) { [int]$headers["content-length"] } else { 0 }
  $bodyStart = $headerEnd + 4
  $bodyBytes = New-Object System.Collections.Generic.List[byte]
  for ($i = $bodyStart; $i -lt $allBytes.Length; $i++) { $bodyBytes.Add($allBytes[$i]) }
  while ($bodyBytes.Count -lt $contentLength) {
    $read = $Stream.Read($buffer, 0, [Math]::Min($buffer.Length, $contentLength - $bodyBytes.Count))
    if ($read -le 0) { break }
    for ($i = 0; $i -lt $read; $i++) { $bodyBytes.Add($buffer[$i]) }
  }
  $bodyText = if ($bodyBytes.Count -gt 0) { [Text.Encoding]::UTF8.GetString($bodyBytes.ToArray()) } else { "" }
  return [pscustomobject]@{ Method = $requestLine[0]; Path = ($requestLine[1] -split "\?")[0]; Body = $bodyText; Headers = $headers }
}

function Handle-Request {
  param([object]$Request)
  if ($Request.Method -eq "OPTIONS") { return New-HttpResponseBytes -StatusCode 204 -Content "" }
  $users = @(Read-WikiUsers)
  $session = Get-RequestSession -Request $Request
  $setupRequired = $users.Count -eq 0

  if ($Request.Path -eq "/api/status" -and $Request.Method -eq "GET") {
    $permissions = @()
    if ($session) { $permissions = @(Get-RolePermissions -Role $session.role) }
    return New-JsonResponseBytes -StatusCode 200 -Data ([pscustomobject]@{
      editor = $true; root = $Root; setupRequired = $setupRequired; authenticated = $null -ne $session
      user = if ($session) { [pscustomobject]@{ username = $session.username; displayName = $session.displayName; role = $session.role } } else { $null }
      permissions = $permissions
      locks = if ($session) { @(Get-PublicLocks) } else { @() }
    })
  }
  if ($Request.Path -eq "/api/auth/setup" -and $Request.Method -eq "POST") {
    if (-not $setupRequired) { return New-ErrorBytes -StatusCode 409 -Message "Die Ersteinrichtung wurde bereits abgeschlossen." }
    $data = $Request.Body | ConvertFrom-Json
    $admin = New-WikiUserRecord -Username $data.username -Password $data.password -Role "Administrator"
    Write-WikiUsers @($admin)
    $newSession = New-WikiSession -User $admin
    return New-JsonResponseBytes -StatusCode 200 -Data ([pscustomobject]@{ user = Get-PublicUser $admin }) -Headers @("Set-Cookie: wiki_session=$($newSession.token); Path=/; HttpOnly; SameSite=Strict; Max-Age=43200")
  }
  if ($Request.Path -eq "/api/auth/login" -and $Request.Method -eq "POST") {
    $data = $Request.Body | ConvertFrom-Json
    $username = (Sanitize-Line $data.username).ToLowerInvariant()
    $user = $users | Where-Object { $_.username -eq $username -and $_.active } | Select-Object -First 1
    if (-not $user -or -not (Test-SecurePassword -Password ([string]$data.password) -User $user)) { return New-ErrorBytes -StatusCode 401 -Message "Benutzername oder Passwort ist falsch." }
    $newSession = New-WikiSession -User $user
    return New-JsonResponseBytes -StatusCode 200 -Data ([pscustomobject]@{ user = Get-PublicUser $user }) -Headers @("Set-Cookie: wiki_session=$($newSession.token); Path=/; HttpOnly; SameSite=Strict; Max-Age=43200")
  }
  if ($Request.Path -eq "/api/auth/logout" -and $Request.Method -eq "POST") {
    if ($session) {
      Release-UserLocks -Username $session.username
      $script:sessions.Remove($session.token)
    }
    return New-JsonResponseBytes -StatusCode 200 -Data ([pscustomobject]@{ ok = $true }) -Headers @("Set-Cookie: wiki_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0")
  }

  if ($null -eq $session) {
    if ($Request.Method -eq "GET" -and ($Request.Path -eq "/" -or $Request.Path -eq "/index.html" -or $Request.Path.StartsWith("/assets/"))) { return New-FileResponseBytes -UrlPath $Request.Path }
    return New-ErrorBytes -StatusCode 401 -Message "Bitte zuerst anmelden."
  }

  if ($Request.Path -eq "/api/account" -and $Request.Method -eq "GET") {
    $own = $users | Where-Object { $_.username -eq $session.username } | Select-Object -First 1
    if (-not $own) { return New-ErrorBytes -StatusCode 404 -Message "Benutzer nicht gefunden." }
    return New-JsonResponseBytes -StatusCode 200 -Data (Get-PublicUser $own)
  }
  if ($Request.Path -eq "/api/account" -and $Request.Method -eq "PUT") {
    $own = $users | Where-Object { $_.username -eq $session.username } | Select-Object -First 1
    if (-not $own) { return New-ErrorBytes -StatusCode 404 -Message "Benutzer nicht gefunden." }
    if (-not $own.active) { throw [UnauthorizedAccessException]::new("Das Konto ist deaktiviert.") }
    $accountData = $Request.Body | ConvertFrom-Json
    $accountChanged = $false
    # Anzeigename: beeinflusst Rolle/Berechtigungen nicht, Login-Name bleibt.
    if ($accountData.PSObject.Properties.Name -contains "displayName") {
      $newDisplay = Sanitize-Line $accountData.displayName
      if ([string]::IsNullOrWhiteSpace($newDisplay) -or $newDisplay.Length -gt 80) { throw "Der Anzeigename muss 1 bis 80 Zeichen lang sein." }
      if ($newDisplay -cne [string]$own.displayName) {
        $own.displayName = $newDisplay
        $session.displayName = $newDisplay
        $accountChanged = $true
      }
    }
    # Passwort: nur mit Nachweis des aktuellen Passworts, gleiche
    # Sicherheitsanforderungen wie bei der Anlage (PBKDF2, min. 10 Zeichen).
    $wantsPassword = ($accountData.PSObject.Properties.Name -contains "newPassword") -and -not [string]::IsNullOrEmpty([string]$accountData.newPassword)
    if ($wantsPassword) {
      $current = if ($accountData.PSObject.Properties.Name -contains "currentPassword") { [string]$accountData.currentPassword } else { "" }
      if (-not (Test-SecurePassword -Password $current -User $own)) { return New-ErrorBytes -StatusCode 403 -Message "Das aktuelle Passwort ist falsch." }
      $passwordData = ConvertTo-SecurePasswordHash -Password ([string]$accountData.newPassword)
      $own.passwordHash = $passwordData.hash; $own.salt = $passwordData.salt; $own.iterations = $passwordData.iterations
      $accountChanged = $true
    }
    if ($accountChanged) { Write-WikiUsers $users }
    return New-JsonResponseBytes -StatusCode 200 -Data (Get-PublicUser $own)
  }

  if ($Request.Path -eq "/api/wiki-data" -and $Request.Method -eq "GET") {
    Assert-Permission -Session $session -Permissions @("articles.view")
    $wikiData = Get-WikiData
    # Leserrolle (Read-Only): keine Produktdaten ausliefern. Der Cache bleibt
    # unangetastet — es wird eine flache Kopie mit geleerten Listen serialisiert.
    $sessionPerms = @(Get-RolePermissions -Role $session.role)
    $hasProductAccess = @($sessionPerms | Where-Object { $_ -like "products.*" }).Count -gt 0
    if (-not $hasProductAccess) {
      $filtered = $wikiData.PSObject.Copy()
      $filtered.products = @()
      $filtered.archivedProducts = @()
      $filtered.categoryProducts = [pscustomobject]@{}
      return New-JsonResponseBytes -StatusCode 200 -Data $filtered
    }
    return New-JsonResponseBytes -StatusCode 200 -Data $wikiData
  }
  if ($Request.Path -eq "/api/roles" -and $Request.Method -eq "GET") {
    Assert-Permission -Session $session -Permissions @("roles.manage")
    return New-JsonResponseBytes -StatusCode 200 -Data ([pscustomobject]@{ roles = (Read-WikiRoles); permissions = @($script:allPermissions) })
  }
  if ($Request.Path -eq "/api/roles" -and $Request.Method -eq "PUT") {
    Assert-Permission -Session $session -Permissions @("roles.manage")
    $data = $Request.Body | ConvertFrom-Json
    if ($data.roles -isnot [pscustomobject]) { throw "Rollen fehlen." }
    $clean = @{}
    foreach ($property in $data.roles.PSObject.Properties) {
      $roleName = Sanitize-Line $property.Name
      if ($roleName -notmatch '^[A-Za-z0-9._-]{3,40}$') { throw "Ungueltiger Rollenname: $($property.Name)" }
      $unknown = @(@($property.Value) | Where-Object { $script:allPermissions -notcontains $_ })
      if ($unknown.Count -gt 0) { throw "Unbekannte Berechtigungen: $($unknown -join ', ')" }
      $clean[$roleName] = @(@($property.Value) | Select-Object -Unique | Sort-Object)
    }
    if ($clean.Count -eq 0) { throw "Rollen fehlen." }
    $hasManager = $false
    foreach ($roleName in $clean.Keys) {
      if (($clean[$roleName] -contains "roles.manage") -and ($clean[$roleName] -contains "users.manage")) { $hasManager = $true }
    }
    if (-not $hasManager) { throw "Mindestens eine Rolle muss Benutzer- und Rollenverwaltung behalten." }
    Write-WikiRoles -Roles $clean
    Start-WikiSnapshot -Message "Rollen aktualisiert durch $($session.username)"
    return New-JsonResponseBytes -StatusCode 200 -Data ([pscustomobject]@{ roles = (Read-WikiRoles); permissions = @($script:allPermissions) })
  }
  if ($Request.Path -eq "/api/users" -and $Request.Method -eq "GET") {
    Assert-Permission -Session $session -Permissions @("users.manage")
    return New-JsonResponseBytes -StatusCode 200 -Data @($users | ForEach-Object { Get-PublicUser $_ })
  }
  if ($Request.Path -eq "/api/users" -and $Request.Method -eq "POST") {
    Assert-Permission -Session $session -Permissions @("users.manage")
    $data = $Request.Body | ConvertFrom-Json
    $newUser = New-WikiUserRecord -Username $data.username -Password $data.password -Role $data.role
    if ($users | Where-Object { $_.username -eq $newUser.username }) { return New-ErrorBytes -StatusCode 409 -Message "Der Benutzername ist bereits vergeben." }
    Write-WikiUsers @($users + $newUser)
    Start-WikiSnapshot -Message "Benutzer angelegt: $($newUser.username)"
    return New-JsonResponseBytes -StatusCode 200 -Data @((Read-WikiUsers) | ForEach-Object { Get-PublicUser $_ })
  }
  $userMatch = [regex]::Match($Request.Path, "^/api/users/([^/]+)$")
  if ($userMatch.Success) {
    Assert-Permission -Session $session -Permissions @("users.manage")
    $username = [Uri]::UnescapeDataString($userMatch.Groups[1].Value).ToLowerInvariant()
    $target = $users | Where-Object { $_.username -eq $username } | Select-Object -First 1
    if (-not $target) { return New-ErrorBytes -StatusCode 404 -Message "Benutzer nicht gefunden." }
    if ($Request.Method -eq "PUT") {
      $data = $Request.Body | ConvertFrom-Json
      if ($data.PSObject.Properties.Name -contains "role") {
        $newRole = Sanitize-Line $data.role
        if ((Read-WikiRoles).Keys -notcontains $newRole) { throw "Unbekannte Benutzerrolle." }
        $target.role = $newRole
      }
      if ($data.PSObject.Properties.Name -contains "displayName") {
        $newDisplay = Sanitize-Line $data.displayName
        if ([string]::IsNullOrWhiteSpace($newDisplay) -or $newDisplay.Length -gt 80) { throw "Der Anzeigename muss 1 bis 80 Zeichen lang sein." }
        $target.displayName = $newDisplay
      }
      if ($data.PSObject.Properties.Name -contains "active") { $target.active = [bool]$data.active }
      if ($data.PSObject.Properties.Name -contains "password" -and -not [string]::IsNullOrWhiteSpace([string]$data.password)) {
        $passwordData = ConvertTo-SecurePasswordHash -Password ([string]$data.password)
        $target.passwordHash = $passwordData.hash; $target.salt = $passwordData.salt; $target.iterations = $passwordData.iterations
      }
      if ($target.username -eq $session.username) {
        $ownPermissions = @(Get-RolePermissions -Role $target.role)
        if (-not $target.active -or $ownPermissions -notcontains "users.manage" -or $ownPermissions -notcontains "roles.manage") { throw "Das eigene Konto darf nicht von Benutzer-/Rollenverwaltung ausgeschlossen oder deaktiviert werden." }
      }
      Write-WikiUsers $users
      return New-JsonResponseBytes -StatusCode 200 -Data @((Read-WikiUsers) | ForEach-Object { Get-PublicUser $_ })
    }
  }

  if ($Request.Path -eq "/api/locks" -and $Request.Method -eq "GET") { return New-JsonResponseBytes -StatusCode 200 -Data @(Get-PublicLocks) }
  $lockMatch = [regex]::Match($Request.Path, "^/api/locks/([^/]+)$")
  if ($lockMatch.Success) {
    $slug = [Uri]::UnescapeDataString($lockMatch.Groups[1].Value)
    if ($Request.Method -eq "POST") { return New-JsonResponseBytes -StatusCode 200 -Data (Acquire-ArticleLock -Slug $slug -Session $session) }
    if ($Request.Method -eq "DELETE") { Release-ArticleLock -Slug $slug -Session $session; return New-JsonResponseBytes -StatusCode 200 -Data ([pscustomobject]@{ ok = $true }) }
  }

  if ($Request.Path -eq "/api/categories" -and $Request.Method -eq "POST") {
    Assert-CategoryAssign -Session $session
    Save-Categories ($Request.Body | ConvertFrom-Json)
    Start-WikiSnapshot -Message "Kategorien aktualisiert durch $($session.username)"
    return New-JsonResponseBytes -StatusCode 200 -Data (Get-WikiData)
  }
  if ($Request.Path -eq "/api/category-groups" -and $Request.Method -eq "POST") {
    # Feinpruefung (neu vs. Zuordnung) erfolgt in Save-CategoryGroup.
    Save-CategoryGroup -Data ($Request.Body | ConvertFrom-Json) -Session $session
    return New-JsonResponseBytes -StatusCode 200 -Data (Get-WikiData)
  }
  $categoryMatch = [regex]::Match($Request.Path, "^/api/categories/([^/]+)$")
  if ($categoryMatch.Success -and $Request.Method -eq "DELETE") {
    Assert-Permission -Session $session -Permissions @("categories.manage")
    Remove-Category -Name ([Uri]::UnescapeDataString($categoryMatch.Groups[1].Value))
    Start-WikiSnapshot -Message "Produktgruppe geloescht durch $($session.username)"
    return New-JsonResponseBytes -StatusCode 200 -Data (Get-WikiData)
  }
  $categoryGroupMatch = [regex]::Match($Request.Path, "^/api/category-groups/([^/]+)$")
  if ($categoryGroupMatch.Success -and $Request.Method -eq "DELETE") {
    Assert-Permission -Session $session -Permissions @("categories.manage")
    Remove-CategoryGroup -Name ([Uri]::UnescapeDataString($categoryGroupMatch.Groups[1].Value))
    Start-WikiSnapshot -Message "Ueberkategorie geloescht durch $($session.username)"
    return New-JsonResponseBytes -StatusCode 200 -Data (Get-WikiData)
  }
  if ($Request.Path -eq "/api/products" -and $Request.Method -eq "POST") {
    Assert-Permission -Session $session -Permissions @("products.create")
    $productData = $Request.Body | ConvertFrom-Json
    Save-Product $productData
    Start-WikiSnapshot -Message "Produkt angelegt durch $($session.username)"
    return New-JsonResponseBytes -StatusCode 200 -Data (Get-WikiData)
  }
  $productMatch = [regex]::Match($Request.Path, "^/api/products/([^/]+)$")
  if ($productMatch.Success) {
    $id = [Uri]::UnescapeDataString($productMatch.Groups[1].Value)
    if ($Request.Method -eq "PUT") {
      Assert-Permission -Session $session -Permissions @("products.edit")
      Update-Product -Id $id -Data ($Request.Body | ConvertFrom-Json)
      return New-JsonResponseBytes -StatusCode 200 -Data (Get-WikiData)
    }
    if ($Request.Method -eq "DELETE") {
      Assert-Permission -Session $session -Permissions @("products.delete", "products.archive")
      Delete-Product -Id $id -Data ($Request.Body | ConvertFrom-Json)
      return New-JsonResponseBytes -StatusCode 200 -Data (Get-WikiData)
    }
  }
  $productRestoreMatch = [regex]::Match($Request.Path, "^/api/products/([^/]+)/restore$")
  if ($productRestoreMatch.Success -and $Request.Method -eq "POST") {
    Assert-Permission -Session $session -Permissions @("products.delete")
    $restoreData = $Request.Body | ConvertFrom-Json
    $restoreData | Add-Member -NotePropertyName changedBy -NotePropertyValue $session.username -Force
    $restoredId = Restore-Product -Id ([Uri]::UnescapeDataString($productRestoreMatch.Groups[1].Value)) -Data $restoreData
    $wikiData = Get-WikiData
    $wikiData | Add-Member -NotePropertyName savedProductId -NotePropertyValue $restoredId -Force
    return New-JsonResponseBytes -StatusCode 200 -Data $wikiData
  }
  $productRequestDeleteMatch = [regex]::Match($Request.Path, "^/api/products/([^/]+)/request-delete$")
  if ($productRequestDeleteMatch.Success) {
    $requestProductId = [Uri]::UnescapeDataString($productRequestDeleteMatch.Groups[1].Value)
    if ($Request.Method -eq "POST") {
      Assert-Permission -Session $session -Permissions @("products.requestDelete")
      $requestData = $Request.Body | ConvertFrom-Json
      Set-ProductDeleteRequest -Id $requestProductId -Reason ([string]$requestData.reason) -Session $session
      return New-JsonResponseBytes -StatusCode 200 -Data (Get-WikiData)
    }
    if ($Request.Method -eq "DELETE") {
      Assert-Permission -Session $session -Permissions @("products.delete")
      $clearProductData = $Request.Body | ConvertFrom-Json
      Clear-ProductDeleteRequest -Id $requestProductId -Reason ([string]$clearProductData.reason) -Session $session
      return New-JsonResponseBytes -StatusCode 200 -Data (Get-WikiData)
    }
  }
  if ($Request.Path -eq "/api/uploads" -and $Request.Method -eq "POST") {
    Assert-Permission -Session $session -Permissions @("articles.edit")
    return New-JsonResponseBytes -StatusCode 200 -Data (Save-UploadBatch ($Request.Body | ConvertFrom-Json))
  }
  if ($Request.Path -eq "/api/articles" -and $Request.Method -eq "POST") {
    Assert-Permission -Session $session -Permissions @("articles.create")
    $articleData = $Request.Body | ConvertFrom-Json
    $articleData | Add-Member -NotePropertyName changedBy -NotePropertyValue $session.username -Force
    $savedSlug = Create-Article $articleData
    $wikiData = Get-WikiData
    $wikiData | Add-Member -NotePropertyName savedSlug -NotePropertyValue $savedSlug -Force
    return New-JsonResponseBytes -StatusCode 200 -Data $wikiData
  }
  if ($Request.Path -eq "/api/suggestions" -and $Request.Method -eq "GET") {
    Assert-Permission -Session $session -Permissions @("articles.view")
    $all = @(Read-Suggestions)
    $canEdit = @(Get-RolePermissions -Role $session.role) -contains "articles.edit"
    if (-not $canEdit) { $all = @($all | Where-Object { $_.author -eq $session.username }) }
    return New-JsonResponseBytes -StatusCode 200 -Data $all
  }
  if ($Request.Path -eq "/api/suggestions" -and $Request.Method -eq "POST") {
    Assert-Permission -Session $session -Permissions @("articles.suggest")
    $suggestionData = $Request.Body | ConvertFrom-Json
    $kind = if ($suggestionData.PSObject.Properties.Name -contains "kind") { [string]$suggestionData.kind } else { "article" }
    if ($kind -eq "product") { Assert-Permission -Session $session -Permissions @("products.view") }
    $fields = if ($suggestionData.PSObject.Properties.Name -contains "fields") { $suggestionData.fields } else { $null }
    $saved = Save-Suggestion -Slug ([string]$suggestionData.slug) -Title ([string]$suggestionData.title) -Body ([string]$suggestionData.body) -Note ([string]$suggestionData.note) -Session $session -Kind $kind -ProductId ([string]$suggestionData.productId) -Fields $fields
    if ($kind -eq "product") {
      Start-WikiSnapshot -Message "Produktvorschlag von $($session.username) fuer $($saved.title)"
    } else {
      Start-WikiSnapshot -Message "Aenderungsvorschlag von $($session.username) fuer $($saved.slug)"
    }
    return New-JsonResponseBytes -StatusCode 200 -Data $saved
  }
  $suggestionMatch = [regex]::Match($Request.Path, "^/api/suggestions/([^/]+)$")
  if ($suggestionMatch.Success -and $Request.Method -eq "DELETE") {
    if ($null -eq $session) { throw [UnauthorizedAccessException]::new("Bitte zuerst anmelden.") }
    Remove-Suggestion -Id ([Uri]::UnescapeDataString($suggestionMatch.Groups[1].Value)) -Session $session
    return New-JsonResponseBytes -StatusCode 200 -Data ([pscustomobject]@{ ok = $true })
  }
  $suggestionRejectMatch = [regex]::Match($Request.Path, "^/api/suggestions/([^/]+)/reject$")
  if ($suggestionRejectMatch.Success -and $Request.Method -eq "POST") {
    Assert-Permission -Session $session -Permissions @("articles.edit")
    $rejectData = $Request.Body | ConvertFrom-Json
    Reject-Suggestion -Id ([Uri]::UnescapeDataString($suggestionRejectMatch.Groups[1].Value)) -Reason ([string]$rejectData.reason) -Session $session
    return New-JsonResponseBytes -StatusCode 200 -Data ([pscustomobject]@{ ok = $true })
  }
  $suggestionAcceptMatch = [regex]::Match($Request.Path, "^/api/suggestions/([^/]+)/accept$")
  if ($suggestionAcceptMatch.Success -and $Request.Method -eq "POST") {
    Assert-Permission -Session $session -Permissions @("articles.edit")
    Accept-Suggestion -Id ([Uri]::UnescapeDataString($suggestionAcceptMatch.Groups[1].Value)) -Session $session
    return New-JsonResponseBytes -StatusCode 200 -Data (Get-WikiData)
  }
  $suggestionAckMatch = [regex]::Match($Request.Path, "^/api/suggestions/([^/]+)/acknowledge$")
  if ($suggestionAckMatch.Success -and $Request.Method -eq "POST") {
    # Ersteller (suggest) wie Pruefer (edit) duerfen abschliessen; Feinpruefung
    # (eigener Vorschlag vs. Admin-Cleanup) erfolgt in Acknowledge-Suggestion.
    $ackPerms = @(Get-RolePermissions -Role $session.role)
    if (($ackPerms -notcontains "articles.suggest") -and ($ackPerms -notcontains "articles.edit")) {
      throw [UnauthorizedAccessException]::new("Fuer diese Aktion fehlt die Berechtigung.")
    }
    Acknowledge-Suggestion -Id ([Uri]::UnescapeDataString($suggestionAckMatch.Groups[1].Value)) -Session $session
    return New-JsonResponseBytes -StatusCode 200 -Data ([pscustomobject]@{ ok = $true })
  }
  $requestDeleteMatch = [regex]::Match($Request.Path, "^/api/articles/([^/]+)/request-delete$")
  if ($requestDeleteMatch.Success) {
    $requestSlug = [Uri]::UnescapeDataString($requestDeleteMatch.Groups[1].Value)
    if ($Request.Method -eq "POST") {
      Assert-Permission -Session $session -Permissions @("articles.requestDelete")
      $requestData = $Request.Body | ConvertFrom-Json
      Set-DeleteRequest -Slug $requestSlug -Reason ([string]$requestData.reason) -Session $session
      return New-JsonResponseBytes -StatusCode 200 -Data (Get-WikiData)
    }
    if ($Request.Method -eq "DELETE") {
      Assert-Permission -Session $session -Permissions @("articles.delete")
      $clearData = $Request.Body | ConvertFrom-Json
      Clear-DeleteRequest -Slug $requestSlug -Reason ([string]$clearData.reason) -Session $session
      return New-JsonResponseBytes -StatusCode 200 -Data (Get-WikiData)
    }
  }
  $articleMatch = [regex]::Match($Request.Path, "^/api/articles/([^/]+)$")
  if ($articleMatch.Success) {
    $slug = [Uri]::UnescapeDataString($articleMatch.Groups[1].Value)
    if ($Request.Method -eq "PUT") {
      Assert-Permission -Session $session -Permissions @("articles.edit")
      Assert-ArticleLock -Slug $slug -Session $session
      $articleData = $Request.Body | ConvertFrom-Json
      $articleData | Add-Member -NotePropertyName changedBy -NotePropertyValue $session.username -Force
      $newArticleSlug = Update-Article -Slug $slug -Data $articleData
      Release-ArticleLock -Slug $slug -Session $session
      $wikiData = Get-WikiData
      $wikiData | Add-Member -NotePropertyName savedSlug -NotePropertyValue $newArticleSlug -Force
      return New-JsonResponseBytes -StatusCode 200 -Data $wikiData
    }
    if ($Request.Method -eq "DELETE") {
      Assert-Permission -Session $session -Permissions @("articles.delete", "articles.archive")
      Assert-ArticleLock -Slug $slug -Session $session
      $articleData = $Request.Body | ConvertFrom-Json
      $articleData | Add-Member -NotePropertyName changedBy -NotePropertyValue $session.username -Force
      Delete-Article -Slug $slug -Data $articleData
      Release-ArticleLock -Slug $slug -Session $session
      return New-JsonResponseBytes -StatusCode 200 -Data (Get-WikiData)
    }
  }
  $articleRestoreMatch = [regex]::Match($Request.Path, "^/api/articles/([^/]+)/restore$")
  if ($articleRestoreMatch.Success -and $Request.Method -eq "POST") {
    Assert-Permission -Session $session -Permissions @("articles.delete")
    $restoreData = $Request.Body | ConvertFrom-Json
    $restoreData | Add-Member -NotePropertyName changedBy -NotePropertyValue $session.username -Force
    $restoredSlug = Restore-Article -Slug ([Uri]::UnescapeDataString($articleRestoreMatch.Groups[1].Value)) -Data $restoreData
    $wikiData = Get-WikiData
    $wikiData | Add-Member -NotePropertyName savedSlug -NotePropertyValue $restoredSlug -Force
    return New-JsonResponseBytes -StatusCode 200 -Data $wikiData
  }
  if ($Request.Path -eq "/api/backup/create" -and $Request.Method -eq "POST") {
    return New-JsonResponseBytes -StatusCode 200 -Data (New-WikiBackup -Data ($Request.Body | ConvertFrom-Json) -Session $session)
  }
  if ($Request.Path -eq "/api/backup/restore" -and $Request.Method -eq "POST") {
    return New-JsonResponseBytes -StatusCode 200 -Data (Restore-WikiBackup -Data ($Request.Body | ConvertFrom-Json) -Session $session)
  }
  $backupDownloadMatch = [regex]::Match($Request.Path, "^/api/backup/download/([^/]+)$")
  if ($backupDownloadMatch.Success -and $Request.Method -eq "GET") {
    Assert-BackupAdmin -Session $session
    $name = Sanitize-FileName ([Uri]::UnescapeDataString($backupDownloadMatch.Groups[1].Value))
    if ($name -notmatch '^wiki-backup-[0-9-]+\.zip$') { throw "Unbekannte Backup-Datei." }
    $path = Join-Path $backupDir $name
    $resolved = [IO.Path]::GetFullPath($path)
    $base = [IO.Path]::GetFullPath($backupDir)
    if (-not $resolved.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $resolved)) { throw "Backup-Datei nicht gefunden." }
    return New-FileDownloadBytes -FilePath $resolved -DownloadName $name
  }
  if ($Request.Method -eq "GET") { return New-FileResponseBytes -UrlPath $Request.Path }
  return New-ErrorBytes -StatusCode 405 -Message "Methode nicht erlaubt."
}

$instanceMutex = [Threading.Mutex]::new($false, "Local\FirmenWikiEditorServer-$Port")
if (-not $instanceMutex.WaitOne(0)) { throw "Der Wiki-Server laeuft auf Port $Port bereits." }
try { Invoke-UserRoleMigration | Out-Null } catch { Write-Warning "Rollenmigration: $($_.Exception.Message)" }
try { Invoke-SuggestionMigration | Out-Null } catch { Write-Warning "Vorschlagsmigration: $($_.Exception.Message)" }
& (Join-Path $PSScriptRoot "sync-check.ps1") -Root $Root | Out-Null
Invoke-WikiBuild

try { $listenIp = [Net.IPAddress]::Parse($BindAddress) } catch { throw "Ungueltige Bind-Adresse: $BindAddress" }
$listener = [Net.Sockets.TcpListener]::new($listenIp, $Port)
try { $listener.Start() } catch { $instanceMutex.ReleaseMutex(); throw "Port $Port kann nicht verwendet werden: $($_.Exception.Message)" }
Write-Host "Wiki editor running: http://127.0.0.1:$Port/ (Bind: $BindAddress)"
Write-Host "Press Ctrl+C to stop."

while ($true) {
  $client = $listener.AcceptTcpClient()
  try {
    $stream = $client.GetStream()
    try {
      $request = Read-HttpRequest -Stream $stream
      $responseBytes = Handle-Request -Request $request
    } catch [UnauthorizedAccessException] {
      $responseBytes = New-ErrorBytes -StatusCode 403 -Message $_.Exception.Message
    } catch {
      $status = if ($_.Exception.Message -match "gesperrt|zwischenzeitlich|bearbeitet|existiert bereits|wird noch verwendet") { 409 } else { 400 }
      $responseBytes = New-ErrorBytes -StatusCode $status -Message $_.Exception.Message
    }
    $stream.Write($responseBytes, 0, $responseBytes.Length)
  } finally {
    $client.Close()
  }
}
