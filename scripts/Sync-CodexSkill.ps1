param(
  [string]$SkillName = "",

  [string]$Repo = "",

  [ValidateSet("Pull", "Push", "Backup", "BackupAll", "BackupGitHub", "Status")]
  [string]$Mode = "Pull",

  [string]$GitHubUser = "prayer168",

  [int]$MaxGitHubRepos = 300,

  [string]$CodexSkillsDir = (Join-Path $env:USERPROFILE ".codex\skills"),

  [string[]]$BackupRoots = @(),

  [switch]$SkipGitHub,

  [switch]$ScanAllGitHubRepos,

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
  $normalizedParent = $fullParent.TrimEnd('\')
  if (-not ($fullChild.Equals($normalizedParent, $comparison) -or $fullChild.StartsWith($normalizedParent + '\', $comparison))) {
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

function Convert-ToSafeFolderName {
  param([Parameter(Mandatory = $true)][string]$Name)

  return ($Name -replace '[\\/:*?"<>|]', '-').Trim('. ')
}

function Get-DefaultBackupRoots {
  "G:\我的雲端硬碟\000000000backup\0000000000數位教材\skill"
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

function Get-BackupTime {
  [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTimeOffset]::UtcNow, "Taipei Standard Time")
}

function New-TimestampedBackupDirectory {
  $root = Get-BackupRoot
  $stamp = (Get-BackupTime).ToString("yyyy-MM-dd-HHmmss")
  $baseName = $stamp
  $name = $baseName
  $suffix = 1
  while ($true) {
    $destination = Join-Path $root $name
    try {
      $folder = New-Item -ItemType Directory -Path $destination -ErrorAction Stop
      return $folder.FullName
    } catch {
      if (-not (Test-Path -LiteralPath $destination -PathType Container)) { throw }
      $suffix++
      $name = "$baseName-$suffix"
    }
  }
}

function New-LocalSkillArchive {
  param(
    [Parameter(Mandatory = $true)][string]$LocalSkillPath,
    [Parameter(Mandatory = $true)][string]$SnapshotPath,
    [switch]$IncludeGit
  )

  $name = Split-Path -Leaf $LocalSkillPath
  $folder = Join-Path $SnapshotPath $name
  Assert-UnderDirectory -Child $folder -Parent $SnapshotPath
  New-Item -ItemType Directory -Force -Path $folder | Out-Null
  $target = Join-Path $folder "$name-local.zip"
  $pending = "$target.partial"
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  Add-Type -AssemblyName System.IO.Compression
  $zip = [System.IO.Compression.ZipFile]::Open($pending, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($item in Get-ChildItem -LiteralPath $LocalSkillPath -Recurse -Force) {
      $relative = $item.FullName.Substring($LocalSkillPath.Length + 1).Replace([char]92, [char]47)
      if (-not $IncludeGit -and ($relative -eq ".git" -or $relative.StartsWith(".git/"))) { continue }
      if ($item.PSIsContainer) {
        $zip.CreateEntry("$relative/") | Out-Null
      } else {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
          $zip, $item.FullName, $relative, [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
      }
    }
  } finally {
    $zip.Dispose()
  }
  $zip = [System.IO.Compression.ZipFile]::OpenRead($pending)
  try {
    if (-not $zip.GetEntry("SKILL.md")) { throw "Missing SKILL.md in the archive for $name." }
  } finally {
    $zip.Dispose()
  }
  Move-Item -LiteralPath $pending -Destination $target
}

function Write-BackupReport {
  param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$BackupPath,
    [Parameter(Mandatory = $true)][string]$ReportDirectory,
    [string[]]$LocalSkills = @(),
    [object[]]$GitHubSkills = @(),
    [ValidateSet("Completed", "Partial", "Failed")][string]$Status = "Completed",
    [string]$ErrorMessage = "",
    [string]$LastCompletedStep = "Backup contents recorded"
  )

  if (-not (Test-Path -LiteralPath $ReportDirectory)) {
    New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null
  }
  $fullReportDirectory = Resolve-FullPath $ReportDirectory
  $timestamp = (Get-BackupTime).ToString("yyyy-MM-dd-HHmmss")
  $reportPath = Join-Path $fullReportDirectory "skill-backup-report_$timestamp.md"
  if (Test-Path -LiteralPath $reportPath) {
    $timestamp = (Get-BackupTime).ToString("yyyy-MM-dd-HHmmss-fff")
    $reportPath = Join-Path $fullReportDirectory "skill-backup-report_$timestamp.md"
  }
  $reportFileName = Split-Path -Leaf $reportPath

  $localSkillLines = if ($LocalSkills.Count -eq 0) { "- $([char]0x7121)" } else {
    (@($LocalSkills | ForEach-Object { "- $_ ($_/$_-local.zip)" }) -join "`n")
  }
  $githubSkillLines = [System.Collections.Generic.List[string]]::new()
  foreach ($skill in $GitHubSkills) {
    if ($skill -is [string]) {
      $githubSkillLines.Add("- $skill")
    } elseif ($skill.repo) {
      $detail = if ($skill.skillPath) { " ($($skill.skillPath))" } else { "" }
      $archiveDetail = if ($skill.archiveFile) { " | $($skill.archiveFile) | $($skill.commit)" } else { "" }
      $githubSkillLines.Add("- $($skill.repo)$detail$archiveDetail")
    } elseif ($skill.name) {
      $githubSkillLines.Add("- $($skill.name)")
    } else {
      $githubSkillLines.Add("- $skill")
    }
  }
  if ($githubSkillLines.Count -eq 0) { $githubSkillLines.Add("- $([char]0x7121)") }
  $modeTranslations = @{
    'Backup' = [char]0x55ae + [char]0x4e00 + [char]0x6280 + [char]0x80fd + [char]0x5099 + [char]0x4efd
    'BackupAll' = [char]0x5168 + [char]0x90e8 + [char]0x6280 + [char]0x80fd + [char]0x5099 + [char]0x4efd
    'BackupGitHub' = [char]0x50c5 + [char]0x5099 + [char]0x4efd + [char]0x20 + [char]0x47 + [char]0x69 + [char]0x74 + [char]0x48 + [char]0x75 + [char]0x62 + [char]0x20 + [char]0x6280 + [char]0x80fd
    'SafetyBackupBeforePush' = [char]0x63a8 + [char]0x9001 + [char]0x524d + [char]0x5b89 + [char]0x5168 + [char]0x5099 + [char]0x4efd
    'SafetyBackupBeforePull' = [char]0x62c9 + [char]0x53d6 + [char]0x524d + [char]0x5b89 + [char]0x5168 + [char]0x5099 + [char]0x4efd
  }
  $statusTranslations = @{
    'Completed' = [char]0x5df2 + [char]0x5b8c + [char]0x6210
    'Partial' = [char]0x90e8 + [char]0x5206 + [char]0x5b8c + [char]0x6210
    'Failed' = [char]0x5931 + [char]0x6557
  }
  $lastStepTranslations = @{
    'Local skill copies completed; GitHub backup stopped' = [char]0x672c + [char]0x5730 + [char]0x6280 + [char]0x80fd + [char]0x5df2 + [char]0x5b8c + [char]0x6210 + [char]0x5099 + [char]0x4efd + [char]0xff1b + [char]0x47 + [char]0x69 + [char]0x74 + [char]0x48 + [char]0x75 + [char]0x62 + [char]0x20 + [char]0x5099 + [char]0x4efd + [char]0x4e2d + [char]0x6b62
    'Local skill copies completed; GitHub backup skipped by option' = [char]0x672c + [char]0x5730 + [char]0x6280 + [char]0x80fd + [char]0x5df2 + [char]0x5b8c + [char]0x6210 + [char]0x5099 + [char]0x4efd + [char]0xff1b + [char]0x4f9d + [char]0x8a2d + [char]0x5b9a + [char]0x7565 + [char]0x904e + [char]0x20 + [char]0x47 + [char]0x69 + [char]0x74 + [char]0x48 + [char]0x75 + [char]0x62 + [char]0x20 + [char]0x5099 + [char]0x4efd
    'Local and GitHub skill copies completed' = [char]0x672c + [char]0x5730 + [char]0x8207 + [char]0x20 + [char]0x47 + [char]0x69 + [char]0x74 + [char]0x48 + [char]0x75 + [char]0x62 + [char]0x20 + [char]0x6280 + [char]0x80fd + [char]0x5747 + [char]0x5df2 + [char]0x5b8c + [char]0x6210 + [char]0x5099 + [char]0x4efd
    'GitHub skill repositories copied into dated backup' = [char]0x47 + [char]0x69 + [char]0x74 + [char]0x48 + [char]0x75 + [char]0x62 + [char]0x20 + [char]0x6280 + [char]0x80fd + [char]0x5132 + [char]0x5b58 + [char]0x5eab + [char]0x5df2 + [char]0x8907 + [char]0x88fd + [char]0x81f3 + [char]0x65e5 + [char]0x671f + [char]0x5099 + [char]0x4efd + [char]0x8cc7 + [char]0x6599 + [char]0x593e
    'GitHub backup stopped; see issue details' = [char]0x47 + [char]0x69 + [char]0x74 + [char]0x48 + [char]0x75 + [char]0x62 + [char]0x20 + [char]0x5099 + [char]0x4efd + [char]0x4e2d + [char]0x6b62 + [char]0xff1b + [char]0x8acb + [char]0x53c3 + [char]0x95b1 + [char]0x554f + [char]0x984c + [char]0x8207 + [char]0x932f + [char]0x8aa4
    'Local skill backup copied successfully' = [char]0x672c + [char]0x5730 + [char]0x6280 + [char]0x80fd + [char]0x5df2 + [char]0x6210 + [char]0x529f + [char]0x8907 + [char]0x88fd + [char]0x5099 + [char]0x4efd
    'Backup contents recorded' = [char]0x5df2 + [char]0x8a18 + [char]0x9304 + [char]0x5099 + [char]0x4efd + [char]0x5167 + [char]0x5bb9
  }
  $modeLabel = if ($modeTranslations.ContainsKey($Mode)) { $modeTranslations[$Mode] } else { $Mode }
  $statusLabel = if ($statusTranslations.ContainsKey($Status)) { $statusTranslations[$Status] } else { $Status }
  $lastStepLabel = if ($lastStepTranslations.ContainsKey($LastCompletedStep)) { $lastStepTranslations[$LastCompletedStep] } else { $LastCompletedStep }

  $issuesSection = ""
  if ($ErrorMessage) {
    $issueLines = @($ErrorMessage -split "`r?`n" | Where-Object { $_ } | ForEach-Object { "- $_" })
    $issuesSection = "## Issues`n$($issueLines -join "`n")`n"
  }

  $templatePath = Resolve-FullPath (Join-Path $PSScriptRoot "..\templates\backup-report.md")
  if (-not (Test-Path -LiteralPath $templatePath)) {
    throw "Backup report template is missing: $templatePath"
  }
  $content = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
  $replacements = @{
    "{{completed_at}}" = (Get-BackupTime).ToString("yyyy-MM-dd HH:mm:ss zzz")
    "{{report_directory}}" = $fullReportDirectory
    "{{report_filename}}" = $reportFileName
    "{{mode}}" = $modeLabel
    "{{status}}" = $statusLabel
    "{{backup_path}}" = $BackupPath
    "{{last_completed_step}}" = $lastStepLabel
    "{{local_skill_count}}" = [string]$LocalSkills.Count
    "{{github_skill_count}}" = [string]$GitHubSkills.Count
    "{{local_skills}}" = $localSkillLines
    "{{github_skills}}" = ($githubSkillLines -join "`n")
    "{{issues_section}}" = $issuesSection.TrimEnd("`r", "`n")
  }
  foreach ($key in $replacements.Keys) {
    $content = $content.Replace($key, [string]$replacements[$key])
  }
  Set-Content -LiteralPath $reportPath -Value $content -Encoding UTF8
  return (Resolve-FullPath $reportPath)
}

function Get-GitHubSkillRepositories {
  $reposJson = & gh repo list $GitHubUser --limit $MaxGitHubRepos --json name,description,url,defaultBranchRef 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $reposJson) {
    throw "Could not list GitHub repositories for $GitHubUser. Check gh authentication and network access."
  }

  $repos = $reposJson | ConvertFrom-Json
  $localSkillNames = @()
  if (Test-Path -LiteralPath $codexRoot) {
    $localSkillNames = @(
      Get-ChildItem -LiteralPath $codexRoot -Directory -Force |
        Where-Object { $_.Name -ne ".git" } |
        Select-Object -ExpandProperty Name
    )
  }

  $candidatePattern = 'skill|codex|assessment|evaluator|kahoot|material|teaching|portal|rubric|science-fair|interactive|builder'
  if (-not $ScanAllGitHubRepos) {
    $repos = @(
      $repos | Where-Object {
        $localSkillNames -contains $_.name -or
        $_.name -match $candidatePattern -or
        ($_.description -and $_.description -match $candidatePattern)
      }
    )
  }

  $skillRepos = @()

  foreach ($repo in $repos) {
    if (-not $repo.defaultBranchRef -or -not $repo.defaultBranchRef.name) { continue }
    $branch = $repo.defaultBranchRef.name

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      $treeJson = & gh api "repos/$GitHubUser/$($repo.name)/git/trees/$([Uri]::EscapeDataString($branch))`?recursive=1" 2>$null
      $treeExitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $oldErrorActionPreference
    }

    if ($treeExitCode -ne 0 -or -not $treeJson) {
      throw "Could not inspect the default branch of $GitHubUser/$($repo.name)."
    }

    $tree = $treeJson | ConvertFrom-Json
    if ($tree.truncated) { throw "Incomplete GitHub tree: $($repo.name)" }
    $skillPaths = @(
      $tree.tree |
        Where-Object { $_.type -eq "blob" -and (Split-Path -Leaf $_.path) -eq "SKILL.md" } |
        Select-Object -ExpandProperty path
    )

    if ($skillPaths.Count -gt 0) {
      $skillRepos += [PSCustomObject]@{
        name = $repo.name
        url = $repo.url
        branch = $branch
        skillPaths = $skillPaths
        scannedObject = $tree.sha
      }
    }
  }

  return $skillRepos
}

function New-GitHubSkillsBackup {
  param([Parameter(Mandatory = $true)][string]$SnapshotPath)

  $script:GitHubBackupProgress = @()
  $skillRepos = Get-GitHubSkillRepositories
  $copied = @()

  foreach ($repo in $skillRepos) {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("skill-sync-github-" + $repo.name + "-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

    try {
      $clonePath = Join-Path $tempRoot "repo"
      Invoke-Git -Args @("clone", "--quiet", "--no-checkout", "--depth", "1", "--branch", $repo.branch, $repo.url, $clonePath)
      $commit = & git -C $clonePath rev-parse HEAD
      if ($LASTEXITCODE -ne 0) { throw "Could not read the commit for $($repo.name)." }
      $tree = & git -C $clonePath rev-parse 'HEAD^{tree}'
      if ($LASTEXITCODE -ne 0 -or $repo.scannedObject -notin @($commit, $tree)) {
        throw "The default branch changed during discovery for $($repo.name)."
      }

      $entries = & git -C $clonePath ls-tree -r HEAD
      if ($LASTEXITCODE -ne 0) { throw "Could not read the tracked entries for $($repo.name)." }
      if (@($entries -match '^160000 ').Count -gt 0) {
        throw "$($repo.name) contains Git submodules, which require a separate backup."
      }

      # Override export attributes so the ZIP contains every tracked file with its original contents.
      $attributes = Join-Path $clonePath '.git/info/attributes'
      Set-Content -LiteralPath $attributes -Encoding ASCII -Value '* -export-ignore -export-subst -text -eol -crlf -ident -filter -working-tree-encoding'
      $name = Convert-ToSafeFolderName -Name $repo.name
      $folder = Join-Path $SnapshotPath $name
      Assert-UnderDirectory -Child $folder -Parent $SnapshotPath
      New-Item -ItemType Directory -Force -Path $folder | Out-Null
      $archiveFile = "$name/$name-github.zip"
      $target = Join-Path $folder "$name-github.zip"
      $pending = "$target.partial"
      Assert-UnderDirectory -Child $target -Parent $folder
      Invoke-Git -Args @("-C", $clonePath, "-c", "core.autocrlf=false", "archive", "--format=zip", "--output=$pending", $commit)
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      $zip = [System.IO.Compression.ZipFile]::OpenRead($pending)
      try {
        $archivedFiles = @($zip.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
        if ($archivedFiles.Count -ne $entries.Count) {
          throw "ZIP file count differs from the Git tree for $($repo.name)."
        }
      } finally {
        $zip.Dispose()
      }
      Move-Item -LiteralPath $pending -Destination $target

      foreach ($skillPath in $repo.skillPaths) {
        $entry = [PSCustomObject]@{ repo = $repo.name; skillPath = $skillPath; archiveFile = $archiveFile; commit = $commit }
        $copied += $entry
        $script:GitHubBackupProgress += $entry
      }
    } finally {
      if (Test-Path -LiteralPath $tempRoot) {
        Assert-UnderParent -Child $tempRoot -Parent ([System.IO.Path]::GetTempPath()) -Purpose "GitHub temporary cleanup"
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
      }
    }
  }

  return [PSCustomObject]@{
    backupPath = $SnapshotPath
    repositoryCount = @($copied.repo | Sort-Object -Unique).Count
    skillCount = $copied.Count
    skills = $copied
  }
}

function New-AllSkillsBackup {
  $dest = New-TimestampedBackupDirectory

  $fullDest = Resolve-FullPath $dest
  $skills = Get-ChildItem -LiteralPath $codexRoot -Directory -Force |
    Where-Object { $_.Name -ne ".system" -and (Test-Path -LiteralPath (Join-Path $_.FullName "SKILL.md") -PathType Leaf) }

  $copied = @()
  foreach ($skill in $skills) {
    New-LocalSkillArchive -LocalSkillPath $skill.FullName -SnapshotPath $fullDest
    $copied += $skill.Name
  }

  $github = $null
  $errors = @()
  if (-not $SkipGitHub) {
    try {
      $github = New-GitHubSkillsBackup -SnapshotPath $fullDest
    } catch {
      $errors += $_.Exception.Message
    }
  }

  $githubSkills = if ($github) { @($github.skills) } else { @() }
  if ($errors.Count -gt 0) {
    $githubSkills = @($script:GitHubBackupProgress)
  }
  $githubCount = if ($github) { $github.skillCount } else { 0 }
  if ($errors.Count -gt 0) { $githubCount = $githubSkills.Count }
  $status = if ($errors.Count -gt 0) { "Partial" } else { "Completed" }
  $reportPath = Write-BackupReport -Mode "BackupAll" -BackupPath $fullDest -ReportDirectory $fullDest `
    -LocalSkills $copied -GitHubSkills $githubSkills -Status $status -ErrorMessage ($errors -join "`n") `
    -LastCompletedStep $(if ($errors.Count -gt 0) { "Local skill copies completed; GitHub backup stopped" } elseif ($SkipGitHub) { "Local skill copies completed; GitHub backup skipped by option" } else { "Local and GitHub skill copies completed" })

  return [PSCustomObject]@{
    backupPath = $fullDest
    reportPath = $reportPath
    status = $status
    errors = $errors
    localSkillCount = $copied.Count
    localSkills = $copied
    githubSkillCount = $githubCount
    githubBackupPath = if ($github) { $github.backupPath } else { $null }
    githubSkills = $githubSkills
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
    localSkillCount = $result.localSkillCount
    localSkills = $result.localSkills
    githubSkillCount = $result.githubSkillCount
    githubBackupPath = $result.githubBackupPath
    githubSkills = $result.githubSkills
    reportPath = $result.reportPath
    status = $result.status
    errors = $result.errors
  } | ConvertTo-Json -Depth 6
  if ($result.errors.Count -gt 0) { exit 1 }
  exit 0
}

if ($Mode -eq "BackupGitHub") {
  $dest = New-TimestampedBackupDirectory
  $fullDest = Resolve-FullPath $dest
  try {
    $result = New-GitHubSkillsBackup -SnapshotPath $fullDest
    $reportPath = Write-BackupReport -Mode "BackupGitHub" -BackupPath $fullDest -ReportDirectory $fullDest `
      -GitHubSkills @($result.skills) -LastCompletedStep "GitHub skill repositories copied into dated backup"
  } catch {
    $partialSkills = @($script:GitHubBackupProgress)
    $reportPath = Write-BackupReport -Mode "BackupGitHub" -BackupPath $fullDest -ReportDirectory $fullDest `
      -GitHubSkills $partialSkills -Status "Failed" -ErrorMessage $_.Exception.Message `
      -LastCompletedStep "GitHub backup stopped; see issue details"
    [PSCustomObject]@{
      mode = $Mode
      backupPath = $fullDest
      githubSkillCount = $partialSkills.Count
      githubBackupPath = $fullDest
      githubSkills = $partialSkills
      reportPath = $reportPath
      status = "Failed"
      error = $_.Exception.Message
    } | ConvertTo-Json -Depth 4
    exit 1
  }
  [PSCustomObject]@{
    mode = $Mode
    backupPath = $fullDest
    githubSkillCount = $result.skillCount
    githubBackupPath = $result.backupPath
    githubSkills = $result.skills
    reportPath = $reportPath
    status = "Completed"
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
  $backupPath = New-TimestampedBackupDirectory
  New-LocalSkillArchive -LocalSkillPath $localSkillPath -SnapshotPath $backupPath -IncludeGit
  $reportMode = if ($Mode -eq "Backup") { $Mode } else { "SafetyBackupBefore$Mode" }
  $reportPath = Write-BackupReport -Mode $reportMode -BackupPath $backupPath -ReportDirectory $backupPath `
    -LocalSkills @($SkillName) -Status "Completed" -LastCompletedStep "Local skill backup copied successfully"
}

if ($Mode -eq "Backup") {
  [PSCustomObject]@{
    mode = $Mode
    skillName = $SkillName
    localSkillPath = $localSkillPath
    backupPath = $backupPath
    reportPath = $reportPath
    status = "Completed"
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
      reportPath = $reportPath
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
      reportPath = $reportPath
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
