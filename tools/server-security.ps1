$script:usersFile = Join-Path $Root "config\users.json"
$script:rolesFile = Join-Path $Root "config\roles.json"
$script:runtimeDir = Join-Path $Root "runtime"
$script:sessions = @{}
$script:articleLocks = @{}
$script:sessionLifetime = [TimeSpan]::FromHours(12)
$script:lockLifetime = [TimeSpan]::FromMinutes(15)
$script:allPermissions = @(
  "articles.view", "articles.create", "articles.edit", "articles.delete", "articles.archive",
  "articles.suggest", "articles.requestDelete",
  "products.view", "products.create", "products.edit", "products.delete", "products.archive",
  "products.requestDelete",
  "categories.manage", "categories.assign", "users.manage", "roles.manage"
)
$script:defaultRoles = @{
  Administrator = @(
    "articles.view", "articles.create", "articles.edit", "articles.delete", "articles.archive",
    "articles.suggest", "articles.requestDelete",
    "products.view", "products.create", "products.edit", "products.delete", "products.archive",
    "products.requestDelete",
    "categories.manage", "categories.assign", "users.manage", "roles.manage"
  )
  Bearbeiter = @("articles.view", "articles.create", "articles.edit", "articles.suggest", "articles.requestDelete", "products.view", "products.edit", "products.requestDelete", "categories.assign")
  "Read-Only" = @("articles.view", "articles.suggest")
}

New-Item -ItemType Directory -Force (Split-Path -Parent $script:usersFile), $script:runtimeDir | Out-Null

function ConvertTo-SecurePasswordHash {
  param([string]$Password, [byte[]]$Salt)
  if ($Password.Length -lt 10) { throw "Das Passwort muss mindestens 10 Zeichen lang sein." }
  if ($null -eq $Salt) {
    $Salt = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($Salt)
  }
  $derive = [Security.Cryptography.Rfc2898DeriveBytes]::new($Password, $Salt, 120000, [Security.Cryptography.HashAlgorithmName]::SHA256)
  try { $hash = $derive.GetBytes(32) } finally { $derive.Dispose() }
  return [pscustomobject]@{ salt = [Convert]::ToBase64String($Salt); hash = [Convert]::ToBase64String($hash); iterations = 120000; algorithm = "PBKDF2-SHA256" }
}

function Test-SecurePassword {
  param([string]$Password, [object]$User)
  try {
    $salt = [Convert]::FromBase64String([string]$User.salt)
    $derive = [Security.Cryptography.Rfc2898DeriveBytes]::new($Password, $salt, [int]$User.iterations, [Security.Cryptography.HashAlgorithmName]::SHA256)
    try { $actual = $derive.GetBytes(32) } finally { $derive.Dispose() }
    $expected = [Convert]::FromBase64String([string]$User.passwordHash)
    if ($actual.Length -ne $expected.Length) { return $false }
    $difference = 0
    for ($index = 0; $index -lt $actual.Length; $index++) { $difference = $difference -bor ($actual[$index] -bxor $expected[$index]) }
    return $difference -eq 0
  } catch { return $false }
}

function Read-WikiUsers {
  if (-not (Test-Path $script:usersFile)) { return @() }
  try {
    $parsed = Get-Content -Raw -Encoding UTF8 $script:usersFile | ConvertFrom-Json
    foreach ($item in $parsed) { Write-Output $item }
  } catch { throw "Die Benutzerdatei ist ungueltig: $($_.Exception.Message)" }
}

function Write-WikiUsers {
  param([array]$Users)
  $temporary = "$script:usersFile.tmp"
  ConvertTo-Json -InputObject ([object[]]$Users) -Depth 8 | Set-Content -Encoding UTF8 $temporary
  Move-Item -LiteralPath $temporary -Destination $script:usersFile -Force
}

function New-WikiUserRecord {
  param([string]$Username, [string]$Password, [string]$Role)
  $name = (Sanitize-Line $Username).ToLowerInvariant()
  if ($name -notmatch '^[a-z0-9._-]{3,40}$') { throw "Der Benutzername muss 3 bis 40 Zeichen lang sein und darf nur Buchstaben, Zahlen, Punkt, Unterstrich und Bindestrich enthalten." }
  if ((Read-WikiRoles).Keys -notcontains (Sanitize-Line $Role)) { throw "Unbekannte Benutzerrolle." }
  $passwordData = ConvertTo-SecurePasswordHash -Password $Password
  return [pscustomobject]@{
    username = $name
    displayName = Sanitize-Line $Username
    role = Sanitize-Line $Role
    passwordHash = $passwordData.hash
    salt = $passwordData.salt
    iterations = $passwordData.iterations
    algorithm = $passwordData.algorithm
    active = $true
    createdAt = (Get-Date).ToString("o")
  }
}

function Get-PublicUser {
  param([object]$User)
  if ($null -eq $User) { return $null }
  return [pscustomobject]@{ username = $User.username; displayName = $User.displayName; role = $User.role; active = [bool]$User.active }
}

function Remove-ExpiredSessionsAndLocks {
  $now = Get-Date
  foreach ($token in @($script:sessions.Keys)) {
    if ($script:sessions[$token].expiresAt -lt $now) { $script:sessions.Remove($token) }
  }
  foreach ($slug in @($script:articleLocks.Keys)) {
    if ($script:articleLocks[$slug].expiresAt -lt $now) { $script:articleLocks.Remove($slug) }
  }
}

function Get-RequestCookieValue {
  param([object]$Request, [string]$Name)
  if (-not $Request.Headers.ContainsKey("cookie")) { return "" }
  foreach ($part in ([string]$Request.Headers["cookie"] -split ";")) {
    $pair = $part.Trim() -split "=", 2
    if ($pair.Count -eq 2 -and $pair[0] -eq $Name) { return [Uri]::UnescapeDataString($pair[1]) }
  }
  return ""
}

function Get-RequestSession {
  param([object]$Request)
  Remove-ExpiredSessionsAndLocks
  $token = Get-RequestCookieValue -Request $Request -Name "wiki_session"
  if (-not $token -or -not $script:sessions.ContainsKey($token)) { return $null }
  $session = $script:sessions[$token]
  $session.expiresAt = (Get-Date).Add($script:sessionLifetime)
  return $session
}

function New-SessionToken {
  $bytes = New-Object byte[] 32
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  return ([Convert]::ToBase64String($bytes)).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function New-WikiSession {
  param([object]$User)
  $token = New-SessionToken
  $script:sessions[$token] = [pscustomobject]@{
    token = $token
    username = $User.username
    displayName = $User.displayName
    role = $User.role
    createdAt = Get-Date
    expiresAt = (Get-Date).Add($script:sessionLifetime)
  }
  return $script:sessions[$token]
}

function Assert-Permission {
  param([object]$Session, [string[]]$Permissions)
  if ($null -eq $Session) { throw [UnauthorizedAccessException]::new("Bitte zuerst anmelden.") }
  $have = @(Get-RolePermissions -Role $Session.role)
  foreach ($permission in $Permissions) {
    if ($have -notcontains $permission) { throw [UnauthorizedAccessException]::new("Fuer diese Aktion fehlt die Berechtigung.") }
  }
}

function Read-WikiRoles {
  $defaults = @{}
  foreach ($key in $script:defaultRoles.Keys) { $defaults[$key] = @($script:defaultRoles[$key]) }
  if (-not (Test-Path $script:rolesFile)) {
    Write-WikiRoles -Roles $defaults
    return $defaults
  }
  try {
    $parsed = Get-Content -Raw -Encoding UTF8 $script:rolesFile | ConvertFrom-Json
  } catch {
    Write-WikiRoles -Roles $defaults
    return $defaults
  }
  $clean = @{}
  if ($null -ne $parsed.roles) {
    foreach ($property in $parsed.roles.PSObject.Properties) {
      $name = Sanitize-Line $property.Name
      if ([string]::IsNullOrWhiteSpace($name)) { continue }
      $clean[$name] = @(@($property.Value) | Where-Object { $script:allPermissions -contains $_ } | Select-Object -Unique | Sort-Object)
    }
  }
  if ($clean.Count -eq 0) {
    Write-WikiRoles -Roles $defaults
    return $defaults
  }
  return $clean
}

function Write-WikiRoles {
  param([hashtable]$Roles)
  $temporary = "$script:rolesFile.tmp"
  [pscustomobject]@{ roles = $Roles } | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $temporary
  Move-Item -LiteralPath $temporary -Destination $script:rolesFile -Force
}

function Get-RolePermissions {
  param([string]$Role)
  $roles = Read-WikiRoles
  if ($roles.ContainsKey($Role)) { return @($roles[$Role]) }
  return @()
}

# Einmalige Migration Redakteur/Leser -> Bearbeiter/Read-Only (idempotent).
# - Rollen: umbenennen, alte Rechte behalten, neue Workflow-Rechte ergaenzen.
# - Benutzer: role-Feld mitschreiben. Unbekannte/custom Rollen bleiben unangetastet.
function Invoke-UserRoleMigration {
  $renamed = @{}
  $roles = Read-WikiRoles
  $changed = $false
  $mapping = @{ "Redakteur" = "Bearbeiter"; "Leser" = "Read-Only" }
  $extra = @{ "Bearbeiter" = @("articles.requestDelete"); "Read-Only" = @("articles.suggest") }
  foreach ($old in @($mapping.Keys)) {
    $new = $mapping[$old]
    if ($roles.ContainsKey($old) -and -not $roles.ContainsKey($new)) {
      $merged = @(@($roles[$old]) + @($extra[$new]) | Where-Object { $script:allPermissions -contains $_ } | Select-Object -Unique | Sort-Object)
      $roles.Remove($old)
      $roles[$new] = $merged
      $changed = $true
    }
    if (-not $roles.ContainsKey($old)) { $renamed[$old] = $new }
  }
  if ($changed) { Write-WikiRoles -Roles $roles }
  # Administrator "kann alles": neue Workflow-Rechte ergaenzen, falls sie fehlen.
  # Bestehende (ggf. manuell reduzierte) Rechte werden nicht angetastet.
  if ($roles.ContainsKey("Administrator")) {
    $adminExtra = @("articles.suggest", "articles.requestDelete", "products.requestDelete") | Where-Object { $roles["Administrator"] -notcontains $_ }
    if ($adminExtra.Count -gt 0) {
      $roles["Administrator"] = @(@($roles["Administrator"]) + @($adminExtra) | Select-Object -Unique | Sort-Object)
      Write-WikiRoles -Roles $roles
      $changed = $true
    }
  }
  # Bearbeiter: Produkt-Loeschmarkierung ergaenzen (P4).
  if ($roles.ContainsKey("Bearbeiter") -and $roles["Bearbeiter"] -contains "articles.requestDelete" -and $roles["Bearbeiter"] -notcontains "products.requestDelete") {
    $roles["Bearbeiter"] = @(@($roles["Bearbeiter"]) + @("products.requestDelete") | Select-Object -Unique | Sort-Object)
    Write-WikiRoles -Roles $roles
    $changed = $true
  }
  # Bearbeiter: Aenderungsvorschlaege einreichen koennen (Vorschlags-Ampel).
  # Nur additiv – bestehende Rechte bleiben unangetastet.
  if ($roles.ContainsKey("Bearbeiter") -and $roles["Bearbeiter"] -notcontains "articles.suggest") {
    $roles["Bearbeiter"] = @(@($roles["Bearbeiter"]) + @("articles.suggest") | Select-Object -Unique | Sort-Object)
    Write-WikiRoles -Roles $roles
    $changed = $true
  }
  # Produktgruppe anlegen/zuordnen (Kategorienverwaltung): Admin + Bearbeiter.
  # Nur additiv – bestehende Rechte bleiben unangetastet.
  foreach ($roleName in @("Administrator", "Bearbeiter")) {
    if ($roles.ContainsKey($roleName) -and $roles[$roleName] -notcontains "categories.assign") {
      $roles[$roleName] = @(@($roles[$roleName]) + @("categories.assign") | Select-Object -Unique | Sort-Object)
      Write-WikiRoles -Roles $roles
      $changed = $true
    }
  }
  # Read-Only (Leserrolle): kein Produktzugriff — Menue, Routen und APIs
  # werden anhand der products.*-Rechte gesperrt (siehe P3).
  if ($roles.ContainsKey("Read-Only") -and $roles["Read-Only"] -contains "products.view") {
    $roles["Read-Only"] = @($roles["Read-Only"] | Where-Object { $_ -ne "products.view" })
    Write-WikiRoles -Roles $roles
    $changed = $true
  }
  $users = @(Read-WikiUsers)
  $usersChanged = $false
  foreach ($user in $users) {
    if ($renamed.ContainsKey($user.role)) {
      $user.role = $renamed[$user.role]
      $usersChanged = $true
    }
  }
  if ($usersChanged) { Write-WikiUsers -Users $users }
  return [pscustomobject]@{ rolesMigrated = $changed; usersMigrated = $usersChanged }
}

function Acquire-ArticleLock {
  param([string]$Slug, [object]$Session)
  Assert-Permission -Session $Session -Permissions @("articles.edit")
  Remove-ExpiredSessionsAndLocks
  $existing = $script:articleLocks[$Slug]
  if ($existing -and $existing.username -ne $Session.username) {
    throw "Der Artikel wird seit $($existing.acquiredAt.ToString('dd.MM.yyyy HH:mm')) von $($existing.displayName) bearbeitet."
  }
  $lock = [pscustomobject]@{
    slug = $Slug
    username = $Session.username
    displayName = $Session.displayName
    acquiredAt = if ($existing) { $existing.acquiredAt } else { Get-Date }
    expiresAt = (Get-Date).Add($script:lockLifetime)
  }
  $script:articleLocks[$Slug] = $lock
  return $lock
}

function Assert-ArticleLock {
  param([string]$Slug, [object]$Session)
  Remove-ExpiredSessionsAndLocks
  $lock = $script:articleLocks[$Slug]
  if (-not $lock -or $lock.username -ne $Session.username) { throw "Der Artikel ist nicht fuer diese Sitzung gesperrt. Oeffne die Bearbeitung erneut." }
  $lock.expiresAt = (Get-Date).Add($script:lockLifetime)
}

function Release-ArticleLock {
  param([string]$Slug, [object]$Session, [switch]$Force)
  $lock = $script:articleLocks[$Slug]
  if ($lock -and ($Force -or ($Session -and $lock.username -eq $Session.username))) { $script:articleLocks.Remove($Slug) }
}

function Release-UserLocks {
  param([string]$Username)
  foreach ($slug in @($script:articleLocks.Keys)) {
    if ($script:articleLocks[$slug].username -eq $Username) { $script:articleLocks.Remove($slug) }
  }
}

function Get-PublicLocks {
  Remove-ExpiredSessionsAndLocks
  return @($script:articleLocks.Values | ForEach-Object {
    [pscustomobject]@{ slug = $_.slug; username = $_.username; displayName = $_.displayName; acquiredAt = $_.acquiredAt.ToString("o"); expiresAt = $_.expiresAt.ToString("o") }
  })
}
