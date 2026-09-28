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
  $timestamp = Get-Date -Format "yyyy-MM-dd-HHmmss"
  $reportPath = Join-Path $fullReportDirectory "skill-backup-report_$timestamp.md"
  if (Test-Path -LiteralPath $reportPath) {
    $timestamp = Get-Date -Format "yyyy-MM-dd-HHmmss-fff"
    $reportPath = Join-Path $fullReportDirectory "skill-backup-report_$timestamp.md"
  }
  $reportFileName = Split-Path -Leaf $reportPath

  $localSkillLines = if ($LocalSkills.Count -eq 0) { "- $([char]0x7121)" } else {
    (@($LocalSkills | ForEach-Object { "- $_" }) -join "`n")
  }
  $githubSkillLines = [System.Collections.Generic.List[string]]::new()
  foreach ($skill in $GitHubSkills) {
    if ($skill -is [string]) {
      $githubSkillLines.Add("- $skill")
    } elseif ($skill.repo) {
      $detail = if ($skill.skillPath) { " ($($skill.skillPath))" } else { "" }
      $githubSkillLines.Add("- $($skill.repo)$detail")
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
    "{{completed_at}}" = (Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz")
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
    $branch = "main"
    if ($repo.defaultBranchRef -and $repo.defaultBranchRef.name) {
      $branch = $repo.defaultBranchRef.name
    }

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      $treeJson = & gh api "repos/$GitHubUser/$($repo.name)/git/trees/$branch`?recursive=1" 2>$null
      $treeExitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $oldErrorActionPreference
    }

    if ($treeExitCode -ne 0 -or -not $treeJson) {
      continue
    }

    $tree = $treeJson | ConvertFrom-Json
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
      }
    }
  }

  return $skillRepos
}

function New-GitHubSkillsBackup {
  param([Parameter(Mandatory = $true)][string]$DatedBackupPath)

  $githubDest = Join-Path $DatedBackupPath "github"
  if (-not (Test-Path -LiteralPath $githubDest)) {
    New-Item -ItemType Directory -Force -Path $githubDest | Out-Null
  }
  $fullGithubDest = Resolve-FullPath $githubDest

  $script:GitHubBackupProgress = @()
  $skillRepos = Get-GitHubSkillRepositories
  $copied = @()

  foreach ($repo in $skillRepos) {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("skill-sync-github-" + $repo.name + "-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

    try {
      $clonePath = Join-Path $tempRoot "repo"
      Invoke-Git -Args @("clone", "--depth", "1", $repo.url, $clonePath)

      foreach ($skillPath in $repo.skillPaths) {
        $relativeSkillRoot = Split-Path -Parent $skillPath
        if ([string]::IsNullOrWhiteSpace($relativeSkillRoot)) {
          $source = $clonePath
          $targetName = Convert-ToSafeFolderName -Name $repo.name
        } else {
          $source = Join-Path $clonePath $relativeSkillRoot
          $targetName = Convert-ToSafeFolderName -Name ($repo.name + "--" + ($relativeSkillRoot -replace '[\\/]', '-'))
        }

        Assert-UnderParent -Child $source -Parent $clonePath -Purpose "GitHub skill backup"
        $target = Join-Path $fullGithubDest $targetName
        if (Test-Path -LiteralPath $target) {
          Assert-UnderParent -Child $target -Parent $fullGithubDest -Purpose "GitHub dated backup refresh"
          Remove-Item -LiteralPath $target -Recurse -Force
        }

        Copy-SkillContents -Source $source -Destination $target
        $copied += [PSCustomObject]@{
          repo = $repo.name
          skillPath = $skillPath
          backupFolder = $targetName
        }
        $script:GitHubBackupProgress += [PSCustomObject]@{
          repo = $repo.name
          skillPath = $skillPath
          backupFolder = $targetName
        }
      }
    } finally {
      if (Test-Path -LiteralPath $tempRoot) {
        Assert-UnderParent -Child $tempRoot -Parent ([System.IO.Path]::GetTempPath()) -Purpose "GitHub temporary cleanup"
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
      }
    }
  }

  return [PSCustomObject]@{
    backupPath = $fullGithubDest
    skillCount = $copied.Count
    skills = $copied
  }
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

  $github = $null
  $errors = @()
  if (-not $SkipGitHub) {
    try {
      $github = New-GitHubSkillsBackup -DatedBackupPath $fullDest
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
  $root = Get-BackupRoot
  $date = Get-Date -Format "yyyy-MM-dd"
  $dest = Join-Path $root $date
  if (-not (Test-Path -LiteralPath $dest)) {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
  }
  $fullDest = Resolve-FullPath $dest
  try {
    $result = New-GitHubSkillsBackup -DatedBackupPath $fullDest
    $reportPath = Write-BackupReport -Mode "BackupGitHub" -BackupPath $fullDest -ReportDirectory $fullDest `
      -GitHubSkills @($result.skills) -LastCompletedStep "GitHub skill repositories copied into dated backup"
  } catch {
    $partialSkills = @($script:GitHubBackupProgress)
    $githubDest = Join-Path $fullDest "github"
    $reportPath = Write-BackupReport -Mode "BackupGitHub" -BackupPath $fullDest -ReportDirectory $fullDest `
      -GitHubSkills $partialSkills -Status "Failed" -ErrorMessage $_.Exception.Message `
      -LastCompletedStep "GitHub backup stopped; see issue details"
    [PSCustomObject]@{
      mode = $Mode
      backupPath = $fullDest
      githubSkillCount = $partialSkills.Count
      githubBackupPath = $githubDest
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
  $backupPath = New-SkillBackup -LocalSkillPath $localSkillPath
  $backupRoot = Split-Path -Parent $backupPath
  $reportMode = if ($Mode -eq "Backup") { $Mode } else { "SafetyBackupBefore$Mode" }
  $reportPath = Write-BackupReport -Mode $reportMode -BackupPath $backupPath -ReportDirectory (Join-Path $backupRoot "reports") `
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
