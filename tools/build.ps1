param(
  [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"

$articlesDir = Join-Path $Root "content\articles"
$archiveDir = Join-Path $Root "content\archive"
$categoriesFile = Join-Path $Root "content\categories.json"
$categoryGroupsFile = Join-Path $Root "content\category-groups.json"
$productsFile = Join-Path $Root "content\products.json"
$productArchiveFile = Join-Path $Root "content\product-archive.json"
$syncCheckScript = Join-Path $PSScriptRoot "sync-check.ps1"

if (Test-Path $syncCheckScript) { & $syncCheckScript -Root $Root | Out-Null }
$dataDir = Join-Path $Root "data"
$outFile = Join-Path $dataDir "wiki-data.js"

if (-not (Test-Path $articlesDir)) {
  throw "Article folder not found: $articlesDir"
}

New-Item -ItemType Directory -Force $dataDir | Out-Null

function ConvertTo-Slug {
  param([string]$Text)

  $slug = $Text.ToLowerInvariant()
  $slug = $slug.Replace([string][char]0x00e4, "ae").Replace([string][char]0x00f6, "oe").Replace([string][char]0x00fc, "ue").Replace([string][char]0x00df, "ss")
  $slug = [regex]::Replace($slug, "[^a-z0-9]+", "-")
  $slug = $slug.Trim("-")
  if ([string]::IsNullOrWhiteSpace($slug)) { return "artikel" }
  return $slug
}

function Normalize-Category {
  param([string]$Category)

  if ([string]::IsNullOrWhiteSpace($Category)) { return "Wiki Anleitung" }

  switch ($Category.Trim()) {
    "Allgemein" { return "Wiki Anleitung" }
    "Wiki Pflege" { return "Wiki Anleitung" }
    "Wikipflege" { return "Wiki Anleitung" }
    "HR & Organisation" { return "Wiki Anleitung" }
    "HR & Organisierung" { return "Wiki Anleitung" }
    "IT & Systeme" { return "IT&Systeme" }
    default { return $Category.Trim() }
  }
}

function Normalize-Product {
  param([object]$Product)

  $name = ""
  $article = ""
  $hardwareRevision = ""
  $description = ""
  $id = ""
  $categories = @()
  $revision = 1
  $status = "Aktiv"
  $updated = ""
  $changeDate = ""
  $changeAction = ""
  $changeReason = ""

  if ($Product -is [string]) {
    $name = $Product
    $article = $Product
  } else {
    if ($Product.PSObject.Properties.Name -contains "name") { $name = [string]$Product.name }
    if ($Product.PSObject.Properties.Name -contains "article") { $article = [string]$Product.article }
    if ($Product.PSObject.Properties.Name -contains "artikel") { $article = [string]$Product.artikel }
    if ($Product.PSObject.Properties.Name -contains "hardwareRevision") { $hardwareRevision = [string]$Product.hardwareRevision }
    if ($Product.PSObject.Properties.Name -contains "hardwarerevision") { $hardwareRevision = [string]$Product.hardwarerevision }
    if ($Product.PSObject.Properties.Name -contains "description") { $description = [string]$Product.description }
    if ($Product.PSObject.Properties.Name -contains "id") { $id = [string]$Product.id }
    if ($Product.PSObject.Properties.Name -contains "categories") { $categories = @($Product.categories | ForEach-Object { Normalize-Category ([string]$_) }) }
    if ($Product.PSObject.Properties.Name -contains "categoryIds") { $categories = @($Product.categoryIds | ForEach-Object { Normalize-Category ([string]$_) }) }
    if ($Product.PSObject.Properties.Name -contains "revision") { [int]::TryParse([string]$Product.revision, [ref]$revision) | Out-Null }
    if ($Product.PSObject.Properties.Name -contains "status") { $status = [string]$Product.status }
    if ($Product.PSObject.Properties.Name -contains "updated") { $updated = [string]$Product.updated }
    if ($Product.PSObject.Properties.Name -contains "changeDate") { $changeDate = [string]$Product.changeDate }
    if ($Product.PSObject.Properties.Name -contains "change_date") { $changeDate = [string]$Product.change_date }
    if ($Product.PSObject.Properties.Name -contains "changeAction") { $changeAction = [string]$Product.changeAction }
    if ($Product.PSObject.Properties.Name -contains "change_action") { $changeAction = [string]$Product.change_action }
    if ($Product.PSObject.Properties.Name -contains "changeReason") { $changeReason = [string]$Product.changeReason }
    if ($Product.PSObject.Properties.Name -contains "change_reason") { $changeReason = [string]$Product.change_reason }
  }

  $name = $name.Trim()
  $article = $article.Trim()
  $hardwareRevision = $hardwareRevision.Trim()
  if ([string]::IsNullOrWhiteSpace($id)) { $id = ConvertTo-Slug "$name-$article-$hardwareRevision" }
  if ([string]::IsNullOrWhiteSpace($updated)) { $updated = "" }
  $revision = [Math]::Max(1, $revision)
  $deleteRequest = $null
  if ($Product.PSObject.Properties.Name -contains "deleteRequest" -and $null -ne $Product.deleteRequest) {
    $deleteRequestBy = if ($Product.deleteRequest.PSObject.Properties.Name -contains "by") { [string]$Product.deleteRequest.by } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($deleteRequestBy)) {
      $deleteRequest = [pscustomobject]@{
        by = $deleteRequestBy
        at = if ($Product.deleteRequest.PSObject.Properties.Name -contains "at") { [string]$Product.deleteRequest.at } else { "" }
        reason = if ($Product.deleteRequest.PSObject.Properties.Name -contains "reason") { [string]$Product.deleteRequest.reason } else { "" }
      }
    }
  }

  return [pscustomobject]@{
    id = $id
    name = $name
    article = $article
    hardwareRevision = $hardwareRevision
    description = $description.Trim()
    categories = @($categories | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    revision = $revision
    status = $status.Trim()
    updated = $updated.Trim()
    changeDate = $changeDate.Trim()
    changeAction = $changeAction.Trim()
    changeReason = $changeReason.Trim()
    deleteRequest = $deleteRequest
  }
}

function Normalize-CategoryEntry {
  param([object]$Category)

  if ($Category -is [string]) {
    return [pscustomobject]@{
      name = Normalize-Category $Category
      products = @()
    }
  }

  $name = ""
  $products = @()
  if ($Category.PSObject.Properties.Name -contains "name") { $name = [string]$Category.name }
  if ($Category.PSObject.Properties.Name -contains "products") { $products = @($Category.products | ForEach-Object { [string]$_ }) }
  if ($Category.PSObject.Properties.Name -contains "productIds") { $products = @($Category.productIds | ForEach-Object { [string]$_ }) }

  return [pscustomobject]@{
    name = Normalize-Category $name
    products = @($products | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  }
}

function Normalize-CategoryGroup {
  param([object]$Group)

  $name = ""
  $categories = @()

  if ($Group -is [string]) {
    $name = [string]$Group
  } else {
    if ($Group.PSObject.Properties.Name -contains "name") { $name = [string]$Group.name }
    if ($Group.PSObject.Properties.Name -contains "categories") { $categories = @($Group.categories | ForEach-Object { Normalize-Category ([string]$_) }) }
  }

  return [pscustomobject]@{
    name = $name.Trim()
    categories = @($categories | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  }
}

function Read-FrontMatter {
  param([string]$Text)

  $result = @{
    Meta = @{}
    Body = $Text
  }

  if (-not $Text.StartsWith("---")) {
    return $result
  }

  $match = [regex]::Match($Text, "(?s)^---\r?\n(.*?)\r?\n---\r?\n?(.*)$")
  if (-not $match.Success) {
    return $result
  }

  foreach ($line in ($match.Groups[1].Value -split "\r?\n")) {
    if ($line.Trim().Length -eq 0) { continue }
    $pair = [regex]::Match($line, "^\s*([A-Za-z0-9_-]+)\s*:\s*(.*?)\s*$")
    if ($pair.Success) {
      $result.Meta[$pair.Groups[1].Value.ToLowerInvariant()] = $pair.Groups[2].Value.Trim().Trim('"')
    }
  }

  $result.Body = $match.Groups[2].Value.Trim()
  return $result
}

function Split-ListValue {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
  return $Value.Trim("[", "]") -split "," |
    ForEach-Object { $_.Trim().Trim('"').Trim("'") } |
    Where-Object { $_ }
}

function Split-CategoryValue {
  param([string]$Value)

  return Split-ListValue $Value | ForEach-Object { Normalize-Category $_ } | Where-Object { $_ } | Select-Object -Unique
}

function Split-AttachmentValue {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
  return $Value -split ";" | ForEach-Object {
    $entry = $_.Trim()
    if ($entry) {
      $parts = $entry -split "\|", 2
      $path = $parts[0].Trim()
      $name = if ($parts.Count -gt 1) { $parts[1].Trim() } else { [IO.Path]::GetFileName($path) }
      if ($path) {
      [pscustomobject]@{
        path = $path
        name = $name
      }
      }
    }
  }
}

function Remove-RevisionLog {
  param([string]$Body)

  return [regex]::Replace($Body, "(?s)\r?\n?<!-- WIKI_REVISION_LOG_START -->.*?<!-- WIKI_REVISION_LOG_END -->\r?\n?", "").Trim()
}

function Get-CleanSpanStyle {
  param([string]$Style)

  $out = @()
  foreach ($declaration in ($Style -split ";")) {
    $colon = $declaration.IndexOf(":")
    if ($colon -lt 0) { continue }
    $property = $declaration.Substring(0, $colon).Trim().ToLowerInvariant()
    $value = $declaration.Substring($colon + 1).Trim()
    if (-not $value -or $value -match '[\"<>]') { continue }
    if ($property -eq "color" -and $value -match '^(#[0-9a-fA-F]{3,8}|rgba?\([^)]*\)|[a-zA-Z]+)$') { $out += "color: $value" }
    if ($property -eq "font-size" -and $value -match '^(\d+(\.\d+)?(rem|px|em|%)|small|medium|large|x-small|x-large|xx-small|xx-large|smaller|larger)$') { $out += "font-size: $value" }
  }
  return ($out -join "; ")
}

function Convert-SpanStyles {
  param([string]$Encoded)

  # <span style="..."> ueberlebt das HtmlEncode als &lt;span style=&quot;...:
  # validierte Styles zurueck in echtes HTML verwandeln, damit der Inhalt
  # (bereits inline-verarbeitet) formatiert dargestellt wird.
  $step = [regex]::Replace($Encoded, '&lt;span\s+style=&quot;(.*?)&quot;\s*&gt;', {
    param($m)
    $style = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
    $clean = Get-CleanSpanStyle $style
    if ($clean) { return "<span style=`"$([System.Net.WebUtility]::HtmlEncode($clean))`">" }
    return $m.Value
  })
  $step = $step -replace '&lt;/span\s*&gt;', '</span>'
  return $step
}

function Convert-InlineMarkdown {
  param(
    [string]$Text,
    [hashtable]$SlugLookup
  )

  # Schnellpfad: Zeilen ohne Markup-Zeichen brauchen keine 6 Regex-Durchlaeufe
  # (Micro-Benchmark: 0,008 ms statt 2,5 ms pro Aufruf). Alle Muster unten
  # benoetigen mindestens eines dieser Zeichen: [ (Links/Bilder), * (fett/kursiv),
  # ` (Code), <span (Schriftgroesse/-farbe). Ohne sie kann nichts gematcht werden.
  if ($Text.IndexOf('[') -lt 0 -and $Text.IndexOf('*') -lt 0 -and $Text.IndexOf('`') -lt 0 -and $Text.IndexOf('<span') -lt 0 -and $Text.IndexOf('~~') -lt 0) {
    return [System.Net.WebUtility]::HtmlEncode($Text)
  }

  $encoded = [System.Net.WebUtility]::HtmlEncode($Text)
  $encoded = Convert-SpanStyles $encoded

  $encoded = [regex]::Replace($encoded, "!\[([^\]]*)\]\(([^)]+)\)(?:\{([^}]*)\})?", {
    param($m)
    $rawAlt = $m.Groups[1].Value
    $href = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value.Trim())
    $attrText = $m.Groups[3].Value
    $width = ""
    $caption = ""
    if ($attrText -match "width\s*=\s*([0-9]+)") { $width = $Matches[1] }
    # $attrText ist HTML-kodiert: Anfuehrungszeichen stehen als &quot; da.
    if ($attrText -match 'caption\s*=\s*(?:"([^"]*)"|&quot;(.*?)&quot;)') { $caption = [string]$Matches[1]; if ([string]::IsNullOrEmpty($caption)) { $caption = [string]$Matches[2] } }
    if (-not (Test-SafeLocalHref $href)) { return $m.Value }
    $safeHref = [System.Net.WebUtility]::HtmlEncode($href)
    $safeAlt = [System.Net.WebUtility]::HtmlEncode($rawAlt)
    $style = ""
    if ($width -match "^[0-9]+$") {
      $bounded = [Math]::Min([Math]::Max([int]$width, 80), 1200)
      $style = " style=`"width: ${bounded}px; max-width: 100%;`""
    }
    $img = "<img src=`"$safeHref`" alt=`"$safeAlt`"$style>"
    if ($caption) {
      # $caption stammt aus bereits kodiertem Text: erst dekodieren, dann sicher kodieren.
      $safeCap = [System.Net.WebUtility]::HtmlEncode([System.Net.WebUtility]::HtmlDecode($caption))
      return "<figure class=`"wiki-figure`">$img<figcaption>$safeCap</figcaption></figure>"
    }
    return $img
  })

  $encoded = [regex]::Replace($encoded, "\[\[([^\]|]+)\|([^\]]+)\]\]", {
    param($m)
    $target = ConvertTo-Slug ([System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value.Trim()))
    $label = $m.Groups[2].Value.Trim()
    if ($SlugLookup.ContainsKey($target)) {
      return "<a href=`"#/artikel/$target`">$label</a>"
    }
    return "<span class=`"missing-link`">$label</span>"
  })

  $encoded = [regex]::Replace($encoded, "\[\[([^\]]+)\]\]", {
    param($m)
    $targetText = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value.Trim())
    $target = ConvertTo-Slug $targetText
    $label = [System.Net.WebUtility]::HtmlEncode($targetText)
    if ($SlugLookup.ContainsKey($target)) {
      return "<a href=`"#/artikel/$target`">$label</a>"
    }
    return "<span class=`"missing-link`">$label</span>"
  })

  $encoded = [regex]::Replace($encoded, "\[([^\]]+)\]\(([^)]+)\)", {
    param($m)
    $label = $m.Groups[1].Value
    $href = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value.Trim())
    if ($href -match "^(https?:|mailto:)" -or (Test-SafeLocalHref $href)) {
      return "<a href=`"$([System.Net.WebUtility]::HtmlEncode($href))`" target=`"_blank`" rel=`"noreferrer`">$label</a>"
    }
    $slug = ConvertTo-Slug $href
    return "<a href=`"#/artikel/$slug`">$label</a>"
  })

  $encoded = [regex]::Replace($encoded, '`([^`]+)`', '<code>$1</code>')
  $encoded = [regex]::Replace($encoded, '\*\*([^*]+)\*\*', '<strong>$1</strong>')
  $encoded = [regex]::Replace($encoded, '\*([^*]+)\*', '<em>$1</em>')
  $encoded = [regex]::Replace($encoded, '~~([^~]+)~~', '<s>$1</s>')
  return $encoded
}

function Test-SafeLocalHref {
  param([string]$Href)

  if ([string]::IsNullOrWhiteSpace($Href)) { return $false }
  if ($Href -match "^[a-zA-Z][a-zA-Z0-9+.-]*:") { return $false }
  if ($Href -match "^\s*(/|\\)") { return $false }
  return $Href -match "^(content/uploads/|assets/|data/|\.\/|\.\./)" -or $Href -match "/[^/]+\.[A-Za-z0-9]{2,8}$"
}

function Close-ArticleLists {
  if ($script:buildInUl) { $script:buildHtml.Add("</ul>"); $script:buildInUl = $false }
  if ($script:buildInOl) { $script:buildHtml.Add("</ol>"); $script:buildInOl = $false }
}

function Split-ArticleTableRow {
  param([string]$Line)
  return $Line.Trim().Trim("|") -split "\|" | ForEach-Object { $_.Trim() }
}

function Split-LeadingSpanPrefix {
  param([string]$Line)
  $m = [regex]::Match($Line, '^\s*((?:<span\s+style="[^"]*"\s*>)*)(.*)$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not $m.Success) {
    return @{ Spans = ""; Rest = $Line }
  }
  return @{ Spans = $m.Groups[1].Value; Rest = $m.Groups[2].Value }
}

function Convert-MarkdownToHtml {
  param(
    [string]$Markdown,
    [hashtable]$SlugLookup
  )

  $lines = $Markdown -split "\r?\n"
  $html = New-Object System.Collections.Generic.List[string]
  $inCode = $false
  $inUl = $false
  $inOl = $false

  $script:buildHtml = $html
  $script:buildInUl = $false
  $script:buildInOl = $false
  $pendingBr = $false

  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    # Backslash am Zeilenende = harter Umbruch (konsistent zum Client-Editor).
    $hardBreak = $false
    if (-not $inCode -and $line -match '\\\s*$') {
      $line = $line -replace '\\\s*$', ''
      $hardBreak = $true
    }
    if ($line -match '^\s*<!--.*-->\s*$') {
      $pendingBr = $false
      continue
    }

    if ($line -match '^\s*```') {
      Close-ArticleLists
      $pendingBr = $false
      if ($inCode) {
        $html.Add("</code></pre>")
        $inCode = $false
      } else {
        $html.Add("<pre><code>")
        $inCode = $true
      }
      continue
    }

    if ($inCode) {
      $pendingBr = $false
      $html.Add([System.Net.WebUtility]::HtmlEncode($line))
      continue
    }

    if ($line -match "\|" -and ($i + 1) -lt $lines.Count -and $lines[$i + 1] -match "^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$") {
      Close-ArticleLists
      $pendingBr = $false
      $headers = @(Split-ArticleTableRow $line)
      $html.Add("<table><thead><tr>")
      foreach ($header in $headers) {
        $html.Add("<th>$(Convert-InlineMarkdown $header $SlugLookup)</th>")
      }
      $html.Add("</tr></thead><tbody>")
      $i += 2
      while ($i -lt $lines.Count -and $lines[$i] -match "\|" -and $lines[$i].Trim().Length -gt 0) {
        $cells = @(Split-ArticleTableRow $lines[$i])
        $html.Add("<tr>")
        foreach ($cell in $cells) {
          $html.Add("<td>$(Convert-InlineMarkdown $cell $SlugLookup)</td>")
        }
        $html.Add("</tr>")
        $i++
      }
      $i--
      $html.Add("</tbody></table>")
      continue
    }

    if ($line.Trim().Length -eq 0) {
      Close-ArticleLists
      $pendingBr = $false
      continue
    }

    $leading = Split-LeadingSpanPrefix $line

    if ($leading.Rest -match "^\s*(#{1,6})\s+(.+)$") {
      Close-ArticleLists
      $pendingBr = $false
      $level = [Math]::Min($Matches[1].Length, 6)
      $content = $leading.Spans + $Matches[2]
      $text = Convert-InlineMarkdown $content $SlugLookup
      $html.Add("<h$level>$text</h$level>")
      continue
    }

    if ($leading.Rest -match "^\s*\d+([.)])\s+(.+)$") {
      $pendingBr = $false
      $content = $leading.Spans + $Matches[2]
      if ($script:buildInUl) { $html.Add("</ul>"); $script:buildInUl = $false }
      if (-not $script:buildInOl) { $html.Add("<ol>"); $script:buildInOl = $true }
      $html.Add("<li>$(Convert-InlineMarkdown $content $SlugLookup)</li>")
      continue
    }

    if ($leading.Rest -match "^\s*[-*+]\s+(.+)$") {
      $pendingBr = $false
      $content = $leading.Spans + $Matches[1]
      if ($script:buildInOl) { $html.Add("</ol>"); $script:buildInOl = $false }
      if (-not $script:buildInUl) { $html.Add("<ul>"); $script:buildInUl = $true }
      $html.Add("<li>$(Convert-InlineMarkdown $content $SlugLookup)</li>")
      continue
    }

    if ($leading.Rest -match "^\s*>\s+(.+)$") {
      Close-ArticleLists
      $pendingBr = $false
      $html.Add("<blockquote>$(Convert-InlineMarkdown ($leading.Spans + $Matches[1]) $SlugLookup)</blockquote>")
      continue
    }

    if ($line -match "^\s*---+\s*$") {
      Close-ArticleLists
      $pendingBr = $false
      $html.Add("<hr>")
      continue
    }

    Close-ArticleLists
    if ($pendingBr -and $html.Count -gt 0 -and $html[$html.Count - 1] -match "^<p>.*</p>$") {
      $html[$html.Count - 1] = $html[$html.Count - 1] -replace "</p>$", ("<br>" + (Convert-InlineMarkdown $line $SlugLookup) + "</p>")
    } else {
      $html.Add("<p>$(Convert-InlineMarkdown $line $SlugLookup)</p>")
    }
    $pendingBr = $hardBreak
  }

  Close-ArticleLists
  if ($inCode) { $html.Add("</code></pre>") }
  return ($html -join "`n")
}

$configuredCategories = @()
$categoryProducts = @{}
$categoryGroups = @()
$products = @()
$archivedProducts = @()

if (Test-Path $productsFile) {
  $productData = Get-Content -Raw -Encoding UTF8 $productsFile | ConvertFrom-Json
  foreach ($product in $productData) {
    $normalized = Normalize-Product $product
    if (-not [string]::IsNullOrWhiteSpace($normalized.name) -and -not [string]::IsNullOrWhiteSpace($normalized.article)) {
      $products += $normalized
    }
  }
}

if (Test-Path $productArchiveFile) {
  $productArchiveData = Get-Content -Raw -Encoding UTF8 $productArchiveFile | ConvertFrom-Json
  foreach ($product in $productArchiveData) {
    $normalized = Normalize-Product $product
    if (-not [string]::IsNullOrWhiteSpace($normalized.name) -and -not [string]::IsNullOrWhiteSpace($normalized.article)) {
      $normalized.status = if ($normalized.status) { $normalized.status } else { "Archiviert" }
      $archivedProducts += $normalized
    }
  }
}

if (Test-Path $categoriesFile) {
  $categoryData = Get-Content -Raw -Encoding UTF8 $categoriesFile | ConvertFrom-Json
  foreach ($category in $categoryData) {
    $entry = Normalize-CategoryEntry $category
    if (-not [string]::IsNullOrWhiteSpace($entry.name)) {
      $configuredCategories += $entry.name
      $categoryProducts[$entry.name] = @($entry.products)
    }
  }
}

if (Test-Path $categoryGroupsFile) {
  $groupData = Get-Content -Raw -Encoding UTF8 $categoryGroupsFile | ConvertFrom-Json
  foreach ($group in $groupData) {
    $entry = Normalize-CategoryGroup $group
    if (-not [string]::IsNullOrWhiteSpace($entry.name)) {
      $categoryGroups += $entry
    }
  }
  # Punkt 2: stabile Gruppenreihenfolge (Alle implizit zuerst, Archiv zuletzt).
  $order = @("Alarmtechnik", "Videotechnik", "Zutrittskontrolle", "Wiki", "Technik")
  $categoryGroups = @($categoryGroups | Sort-Object {
    $i = [Array]::IndexOf($order, $_.name)
    if ($_.name -eq "Archiv") { 999 } elseif ($i -ge 0) { $i } elseif ($_.name -eq "Weitere Kategorien") { 50 } else { 40 }
  }, { $_.name })
}

$rawArticles = @()
$slugLookup = @{}

$sourceFiles = @()
$sourceFiles += Get-ChildItem $articlesDir -Filter "*.md" -File | ForEach-Object {
  [pscustomobject]@{
    File = $_
    Archived = $false
  }
}
if (Test-Path $archiveDir) {
  $sourceFiles += Get-ChildItem $archiveDir -Filter "*.md" -File -Recurse | ForEach-Object {
    [pscustomobject]@{
      File = $_
      Archived = $true
    }
  }
}

$sourceFiles | Sort-Object { $_.File.FullName } | ForEach-Object {
  $file = $_.File
  $archived = $_.Archived
  $raw = Get-Content -Raw -Encoding UTF8 $file.FullName
  $parsed = Read-FrontMatter $raw
  $title = if ($parsed.Meta.ContainsKey("title")) { $parsed.Meta["title"] } else { $file.BaseName }
  $slug = if ($parsed.Meta.ContainsKey("slug")) { ConvertTo-Slug $parsed.Meta["slug"] } else { ConvertTo-Slug $title }

  if ($slugLookup.ContainsKey($slug)) {
    throw "Duplicate slug '$slug' in $($file.FullName)"
  }

  $slugLookup[$slug] = $true
  $rawArticles += [pscustomobject]@{
    Source = $file.Name
    SourcePath = $file.FullName.Substring($Root.Length).TrimStart("\", "/")
    Archived = $archived
    Slug = $slug
    Title = $title
    Meta = $parsed.Meta
    Body = $parsed.Body
  }
}

$articles = foreach ($article in $rawArticles) {
  $meta = $article.Meta
  $html = Convert-MarkdownToHtml $article.Body $slugLookup
  $plain = [regex]::Replace($article.Body, "[#*_`\[\]\(\)>-]", " ")
  # Sicherheitsnetz: eingebettete data-URIs gehoeren nicht in den Suchindex
  # (wirkt auch, falls jemand ein Bild direkt in die .md-Datei schreibt).
  $plain = [regex]::Replace($plain, "data:image/[^;]+;base64,[A-Za-z0-9+/=\s]+", "[Bild]")
  $articleCategories = @()
  if ($meta.ContainsKey("categories")) { $articleCategories = @(Split-CategoryValue $meta["categories"]) }
  if ($articleCategories.Count -eq 0 -and $meta.ContainsKey("category")) { $articleCategories = @(Normalize-Category $meta["category"]) }
  if ($articleCategories.Count -eq 0) { $articleCategories = @("Wiki Anleitung") }
  $category = if ($article.Archived) { "Archiv" } else { $articleCategories[0] }
  $revision = 1
  if ($meta.ContainsKey("revision") -and [int]::TryParse($meta["revision"], [ref]$revision)) {
    $revision = [Math]::Max(1, $revision)
  }
  $articleProducts = @(if ($meta.ContainsKey("products")) { Split-ListValue $meta["products"] } else { @() })
  if ($articleProducts.Count -eq 0) {
    $fallbackProducts = @()
    foreach ($articleCategory in $articleCategories) {
      if ($categoryProducts.ContainsKey($articleCategory)) { $fallbackProducts += @($categoryProducts[$articleCategory]) }
    }
    $articleProducts = @($fallbackProducts | Where-Object { $_ } | Select-Object -Unique)
  }

  [pscustomobject]@{
    slug = $article.Slug
    title = $article.Title
    category = $category
    categories = @(if ($article.Archived) { @("Archiv") } else { $articleCategories })
    tags = @(if ($meta.ContainsKey("tags")) { Split-ListValue $meta["tags"] } else { @() })
    owner = if ($meta.ContainsKey("owner")) { $meta["owner"] } else { "" }
    status = if ($article.Archived) { "Archiviert" } elseif ($meta.ContainsKey("status")) { $meta["status"] } else { "Entwurf" }
    updated = if ($meta.ContainsKey("updated")) { $meta["updated"] } else { "" }
    summary = if ($meta.ContainsKey("summary")) { $meta["summary"] } else { "" }
    revision = $revision
    changeDate = if ($meta.ContainsKey("change_date")) { $meta["change_date"] } else { "" }
    changeReason = if ($meta.ContainsKey("change_reason")) { $meta["change_reason"] } else { "" }
    changeAction = if ($meta.ContainsKey("change_action")) { $meta["change_action"] } else { "" }
    changedBy = if ($meta.ContainsKey("changed_by")) { $meta["changed_by"] } else { "" }
    archived = $article.Archived
    products = @($articleProducts)
    attachments = @(if ($meta.ContainsKey("attachments")) { Split-AttachmentValue $meta["attachments"] } else { @() })
    related = @(if ($meta.ContainsKey("related")) { Split-ListValue $meta["related"] | ForEach-Object { ConvertTo-Slug $_ } | Where-Object { $_ } | Select-Object -Unique } else { @() })
    deleteRequest = if ($meta.ContainsKey("delete_request_by") -and -not [string]::IsNullOrWhiteSpace($meta["delete_request_by"])) {
      [pscustomobject]@{
        by = [string]$meta["delete_request_by"]
        at = if ($meta.ContainsKey("delete_request_at")) { [string]$meta["delete_request_at"] } else { "" }
        reason = if ($meta.ContainsKey("delete_request_reason")) { [string]$meta["delete_request_reason"] } else { "" }
      }
    } else { $null }
    source = $article.Source
    sourcePath = $article.SourcePath
    editBody = Remove-RevisionLog $article.Body
    html = $html
    searchText = $plain
  }
}

# Gegenverknuepfungen auch fuer Altdaten sichtbar machen: Ein Link in einem
# aktiven Artikel erzeugt automatisch den Ruecklink. Persistiert wird der
# Ruecklink erst beim naechsten Speichern durch den Editor-Server.
$activeRelated = @{}
foreach ($article in @($articles)) {
  if (-not $article.archived) { $activeRelated[$article.slug] = @($article.related) }
}
$reverseRelated = @{}
foreach ($sourceSlug in @($activeRelated.Keys)) {
  foreach ($targetSlug in @($activeRelated[$sourceSlug])) {
    if ($targetSlug -and $targetSlug -ne $sourceSlug) {
      if (-not $reverseRelated.ContainsKey($targetSlug)) { $reverseRelated[$targetSlug] = @() }
      if (@($reverseRelated[$targetSlug]) -notcontains $sourceSlug) { $reverseRelated[$targetSlug] += $sourceSlug }
    }
  }
}
foreach ($article in @($articles)) {
  if ($article.archived) { continue }
  $merged = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($article.related)) {
    if ($item -and -not $merged.Contains($item)) { $merged.Add($item) }
  }
  if ($reverseRelated.ContainsKey($article.slug)) {
    foreach ($item in @($reverseRelated[$article.slug] | Sort-Object)) {
      if ($item -and -not $merged.Contains($item)) { $merged.Add($item) }
    }
  }
  $article.related = @($merged)
}

$allCategories = New-Object System.Collections.Generic.List[string]
foreach ($category in $configuredCategories) {
  if (-not [string]::IsNullOrWhiteSpace($category) -and -not $allCategories.Contains($category)) {
    $allCategories.Add($category)
  }
}
foreach ($article in $articles) {
  foreach ($category in @($article.categories)) {
    if (-not [string]::IsNullOrWhiteSpace($category) -and -not $allCategories.Contains($category)) {
      $allCategories.Add($category)
    }
  }
}
if (($articles | Where-Object { $_.archived }).Count -gt 0 -and -not $allCategories.Contains("Archiv")) {
  $allCategories.Add("Archiv")
}

$groupedCategoryNames = New-Object System.Collections.Generic.HashSet[string]
foreach ($group in $categoryGroups) {
  foreach ($category in @($group.categories)) {
    [void]$groupedCategoryNames.Add($category)
  }
}
$ungrouped = @()
foreach ($category in $allCategories) {
  if (-not $groupedCategoryNames.Contains($category)) { $ungrouped += $category }
}
if ($ungrouped.Count -gt 0) {
  $categoryGroups += [pscustomobject]@{
    name = "Weitere Kategorien"
    categories = @($ungrouped)
  }
}

$contentRoot = Join-Path $Root "content"
$conflictPathPrefix = (Join-Path $contentRoot "conflicts") + [IO.Path]::DirectorySeparatorChar
$latestContentFile = Get-ChildItem -LiteralPath $contentRoot -Recurse -File |
  Where-Object { -not $_.FullName.StartsWith($conflictPathPrefix, [StringComparison]::OrdinalIgnoreCase) } |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
$generatedAt = if ($latestContentFile) { $latestContentFile.LastWriteTime.ToString("yyyy-MM-ddTHH:mm:ssK") } else { (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK") }

$payload = [pscustomobject]@{
  generatedAt = $generatedAt
  articleCount = $articles.Count
  categories = [object[]]@($allCategories)
  categoryGroups = [object[]]@($categoryGroups)
  categoryProducts = $categoryProducts
  products = [object[]]@($products)
  archivedProducts = [object[]]@($archivedProducts)
  articles = [object[]]@($articles)
}

$json = $payload | ConvertTo-Json -Depth 12
$content = "window.WIKI_DATA = $json;"
[System.IO.File]::WriteAllText($outFile, $content, [System.Text.UTF8Encoding]::new($false))

Write-Host "Wiki built: $outFile"
Write-Host "Articles: $($articles.Count)"
Write-Host "Categories: $($allCategories.Count)"
Write-Host "Products: $($products.Count)"
Write-Host "Archived products: $($archivedProducts.Count)"
