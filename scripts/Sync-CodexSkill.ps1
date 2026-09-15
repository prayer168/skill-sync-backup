param(
  [string]$SkillName = "",

  [string]$Repo = "",

  [ValidateSet("Pull", "Push", "Backup", "BackupAll", "Status")]
  [string]$Mode = "Pull",

  [string]$GitHubUser = "prayer168",

  [string]$CodexSkillsDir = (Join-Path $env:USERPROFILE ".codex\skills"),

  [string[]]$BackupRoots = @(),

  [switch]$Force
)

$ErrorActionPreference = "Stop"

function Resolve-FullPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Assert-ValidSkillName {
  param([Parameter(Mandatory = $true)][string]$Name)

  if (-not ($Name -match '^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]$|^[a-z0-9]$')) {
    throw "Invalid skill name: $Name"
  }
}

function Assert-UnderDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$Child,
    [Parameter(Mandatory = $true)][string]$Parent
  )

  $fullChild = Resolve-FullPath $Child
  $fullParent = Resolve-FullPath $Parent
  $comparison = [System.StringComparison]::OrdinalIgnoreCase
  if (-not $fullChild.StartsWith($fullParent.TrimEnd('\') + '\', $comparison)) {
    throw "Refusing to modify path outside Codex skills directory: $fullChild"
  }
}

function Assert-UnderParent {
  param(
    [Parameter(Mandatory = $true)][string]$Child,
    [Parameter(Mandatory = $true)][string]$Parent,
    [string]$Purpose = "operation"
  )

  $fullChild = Resolve-FullPath $Child
  $fullParent = Resolve-FullPath $Parent
  $comparison = [System.StringComparison]::OrdinalIgnoreCase
  if (-not $fullChild.StartsWith($fullParent.TrimEnd('\') + '\', $comparison)) {
    throw "Refusing $Purpose outside expected directory: $fullChild"
  }
}

function Copy-SkillContents {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )

  if (-not (Test-Path -LiteralPath $Destination)) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  }

  Get-ChildItem -LiteralPath $Source -Force |
    Where-Object { $_.Name -ne ".git" } |
    ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function Get-DefaultBackupRoots {
  $encoded = @(
    "Rzpc5oiR55qE6Zuy56uv56Gs56KfXDAwMDAwMDAwMGJhY2t1cFwwMDAwMDAwMDAw5pW45L2N5pWZ5p2QXHNraWxs",
    "RDpc5oiR55qE6Zuy56uv56Gs56KfXDAwMDAwMDAwMGJhY2t1cFwwMDAwMDAwMDAw5pW45L2N5pWZ5p2QXHNraWxs"
  )

  return $encoded | ForEach-Object {
    [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))
  }
}

function Get-BackupRoot {
  $roots = $BackupRoots
  if (-not $roots -or $roots.Count -eq 0) {
    $roots = Get-DefaultBackupRoots
  }

  foreach ($candidate in $roots) {
    $drive = Split-Path -Qualifier $candidate
    if ($drive -and -not (Test-Path -LiteralPath ($drive + "\"))) {
      continue
    }

    if (-not (Test-Path -LiteralPath $candidate)) {
      New-Item -ItemType Directory -Force -Path $candidate | Out-Null
    }
    return (Resolve-FullPath $candidate)
  }

  throw "No usable backup drive found. Checked: $($roots -join ', ')"
}

function New-SkillBackup {
  param([Parameter(Mandatory = $true)][string]$LocalSkillPath)

  if (-not (Test-Path -LiteralPath $LocalSkillPath)) {
    throw "Local skill does not exist, so there is nothing to back up: $LocalSkillPath"
  }

  $root = Get-BackupRoot
  $date = Get-Date -Format "yyyy-MM-dd"
  $baseName = "$SkillName,$date"
  $dest = Join-Path $root $baseName

  if (Test-Path -LiteralPath $dest) {
    $time = Get-Date -Format "HHmmss"
    $dest = Join-Path $root "$baseName-$time"
  }

  Copy-Item -LiteralPath $LocalSkillPath -Destination $dest -Recurse -Force
  return (Resolve-FullPath $dest)
}

function New-AllSkillsBackup {
  $root = Get-BackupRoot
  $date = Get-Date -Format "yyyy-MM-dd"
  $dest = Join-Path $root $date

  if (-not (Test-Path -LiteralPath $dest)) {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
  }

  $fullDest = Resolve-FullPath $dest
  $skills = Get-ChildItem -LiteralPath $codexRoot -Directory -Force |
    Where-Object { $_.Name -ne ".git" }

  $copied = @()
  foreach ($skill in $skills) {
    $target = Join-Path $fullDest $skill.Name
    if (Test-Path -LiteralPath $target) {
      Assert-UnderParent -Child $target -Parent $fullDest -Purpose "dated backup refresh"
      Remove-Item -LiteralPath $target -Recurse -Force
    }

    Copy-SkillContents -Source $skill.FullName -Destination $target
    $copied += $skill.Name
  }

  return [PSCustomObject]@{
    backupPath = $fullDest
    skillCount = $copied.Count
    skills = $copied
  }
}

function Get-RepoUrl {
  if ($Repo) {
    if ($Repo -match '^(https://|git@)') {
      return $Repo
    }
    if ($Repo -match '/') {
      return "https://github.com/$Repo.git"
    }
    return "https://github.com/$GitHubUser/$Repo.git"
  }

  return "https://github.com/$GitHubUser/$SkillName.git"
}

function Get-RemoteSkillRoot {
  param([Parameter(Mandatory = $true)][string]$ClonePath)

  if (Test-Path -LiteralPath (Join-Path $ClonePath "SKILL.md")) {
    return $ClonePath
  }

  $nested = Join-Path $ClonePath $SkillName
  if (Test-Path -LiteralPath (Join-Path $nested "SKILL.md")) {
    return $nested
  }

  $skillFiles = Get-ChildItem -LiteralPath $ClonePath -Filter "SKILL.md" -Recurse -File
  if ($skillFiles.Count -eq 1) {
    return $skillFiles[0].Directory.FullName
  }

  throw "Could not identify a single remote skill root in cloned repo: $ClonePath"
}

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)][string[]]$Args,
    [string]$WorkingDirectory = $PWD.Path
  )

  Push-Location $WorkingDirectory
  try {
    & git @Args
    if ($LASTEXITCODE -ne 0) {
      throw "git $($Args -join ' ') failed with exit code $LASTEXITCODE"
    }
  } finally {
    Pop-Location
  }
}

function Test-GitRepoExists {
  param([Parameter(Mandatory = $true)][string]$Remote)

  & git ls-remote $Remote HEAD *> $null
  return ($LASTEXITCODE -eq 0)
}

$codexRoot = Resolve-FullPath $CodexSkillsDir

if ($Mode -eq "BackupAll") {
  $result = New-AllSkillsBackup
  [PSCustomObject]@{
    mode = $Mode
    codexSkillsDir = $codexRoot
    backupPath = $result.backupPath
    skillCount = $result.skillCount
    skills = $result.skills
  } | ConvertTo-Json -Depth 4
  exit 0
}

if (-not $SkillName) {
  throw "SkillName is required for $Mode mode. Use -Mode BackupAll to back up every installed Codex skill."
}

Assert-ValidSkillName -Name $SkillName
$localSkillPath = Join-Path $codexRoot $SkillName
Assert-UnderDirectory -Child $localSkillPath -Parent $codexRoot
$repoUrl = Get-RepoUrl

if ($Mode -eq "Status") {
  [PSCustomObject]@{
    skillName = $SkillName
    localSkillPath = $localSkillPath
    localExists = (Test-Path -LiteralPath $localSkillPath)
    repoUrl = $repoUrl
    backupRoot = (Get-BackupRoot)
  } | ConvertTo-Json -Depth 3
  exit 0
}

$backupPath = $null
if (Test-Path -LiteralPath $localSkillPath) {
  $backupPath = New-SkillBackup -LocalSkillPath $localSkillPath
}

if ($Mode -eq "Backup") {
  [PSCustomObject]@{
    mode = $Mode
    skillName = $SkillName
    localSkillPath = $localSkillPath
    backupPath = $backupPath
  } | ConvertTo-Json -Depth 3
  exit 0
}

if (-not (Test-GitRepoExists -Remote $repoUrl)) {
  throw "GitHub repo is not reachable: $repoUrl"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("skill-sync-backup-" + $SkillName + "-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  $clonePath = Join-Path $tempRoot "repo"
  Invoke-Git -Args @("clone", "--depth", "1", $repoUrl, $clonePath)
  $remoteSkillRoot = Get-RemoteSkillRoot -ClonePath $clonePath
  Assert-UnderParent -Child $remoteSkillRoot -Parent $clonePath -Purpose "remote skill sync"

  if ($Mode -eq "Pull") {
    if ((Test-Path -LiteralPath (Join-Path $localSkillPath ".git")) -and -not $Force) {
      $dirty = & git -C $localSkillPath status --porcelain
      if ($dirty) {
        throw "Local skill is a dirty git repo. Backup was created at $backupPath. Re-run with -Force only if overwriting is intended."
      }
    }

    if (Test-Path -LiteralPath $localSkillPath) {
      Assert-UnderDirectory -Child $localSkillPath -Parent $codexRoot
      Remove-Item -LiteralPath $localSkillPath -Recurse -Force
    }

    Copy-SkillContents -Source $remoteSkillRoot -Destination $localSkillPath

    [PSCustomObject]@{
      mode = $Mode
      skillName = $SkillName
      repoUrl = $repoUrl
      localSkillPath = (Resolve-FullPath $localSkillPath)
      backupPath = $backupPath
      remoteSkillRoot = $remoteSkillRoot
    } | ConvertTo-Json -Depth 4
    exit 0
  }

  if ($Mode -eq "Push") {
    if (-not (Test-Path -LiteralPath $localSkillPath)) {
      throw "Local skill does not exist: $localSkillPath"
    }

    if (-not $Force) {
      throw "Push mode changes GitHub. Re-run with -Force after confirming the installed Codex copy should overwrite the repo content."
    }

    Get-ChildItem -LiteralPath $remoteSkillRoot -Force |
      Where-Object { $_.Name -ne ".git" } |
      Remove-Item -Recurse -Force
    Copy-SkillContents -Source $localSkillPath -Destination $remoteSkillRoot

    Push-Location $clonePath
    try {
      git add -A
      $status = git status --porcelain
      if ($status) {
        git commit -m "Update $SkillName from Codex local copy"
        git push
      }
    } finally {
      Pop-Location
    }

    [PSCustomObject]@{
      mode = $Mode
      skillName = $SkillName
      repoUrl = $repoUrl
      localSkillPath = $localSkillPath
      backupPath = $backupPath
      pushedChanges = [bool]$status
    } | ConvertTo-Json -Depth 4
    exit 0
  }
} finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Assert-UnderParent -Child $tempRoot -Parent ([System.IO.Path]::GetTempPath()) -Purpose "temporary cleanup"
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}
