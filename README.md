# Skill Sync Backup

**Version:** 1.0.0  
**Codex skill directory:** `C:\Users\NNKIEH\.codex\skills\skill-sync-backup`  
**GitHub:** [prayer168/skill-sync-backup](https://github.com/prayer168/skill-sync-backup)

Synchronize locally installed Codex skills with GitHub repositories and create dated backups in the configured Google Drive backup folder. For maintained skills, its workflow also keeps the GitHub source, the Black Bear digital teaching portal's **skill** listing, and the installed local copy aligned.

## Requirements

- Windows PowerShell and Git
- GitHub CLI (`gh`) authenticated for repository discovery and GitHub operations
- Access to one configured backup root:
  - `G:\我的雲端硬碟\000000000backup\0000000000數位教材\skill`
  - `D:\我的雲端硬碟\000000000backup\0000000000數位教材\skill`

## Usage

Run the included script with PowerShell:

```powershell
$script = "C:\Users\NNKIEH\.codex\skills\skill-sync-backup\scripts\Sync-CodexSkill.ps1"

powershell -ExecutionPolicy Bypass -File $script -Mode BackupAll
powershell -ExecutionPolicy Bypass -File $script -Mode BackupGitHub
powershell -ExecutionPolicy Bypass -File $script -SkillName "skill-sync-backup" -Mode Backup
powershell -ExecutionPolicy Bypass -File $script -SkillName "skill-sync-backup" -Repo "prayer168/skill-sync-backup" -Mode Pull
powershell -ExecutionPolicy Bypass -File $script -SkillName "skill-sync-backup" -Repo "prayer168/skill-sync-backup" -Mode Push -Force
powershell -ExecutionPolicy Bypass -File $script -Mode Status
```

These commands respectively back up installed and GitHub skills, back up GitHub-hosted skills only, create a single-skill safety backup, pull or push a skill, and inspect status. `Push` requires `-Force` as an explicit confirmation. `BackupAll` creates or refreshes a `YYYY-MM-DD` folder containing local skills and a `github` subfolder. The default GitHub discovery checks likely skill repositories; add `-ScanAllGitHubRepos` for a full account scan.

## Backup reports

Every backup run—including the automatic safety backup before `Pull` or `Push`—produces a Markdown overall report named `skill-backup-report_YYYY-MM-DD-HHmmss.md`. Bulk reports are stored in that day's backup folder; single-skill safety reports are stored under `<backup-root>\reports`. Reports include status, backup path, local and GitHub skill counts and names, last completed step, and any errors. A partial or failed operation must not be described as complete.

## Publishing a skill update

For a locally maintained skill, create its safety backup, push through this script, update the matching portal skill listing only when required, verify the live page, and confirm the installed local copy matches the published GitHub source. Keep the overall backup report and report each destination's result. Do not publish bundled vendor or private/system skills as user-authored skills.
