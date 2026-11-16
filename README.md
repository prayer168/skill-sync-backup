# Skill Sync Backup

**Version:** 1.4.0

**Codex skill directory:** `C:\Users\NNKIEH\.codex\skills\skill-sync-backup`

**GitHub:** [prayer168/skill-sync-backup](https://github.com/prayer168/skill-sync-backup)

Synchronize locally installed Codex skills with GitHub repositories and create dated backups in the configured Google Drive backup folder. For maintained skills, its workflow also keeps the GitHub source, the Black Bear digital teaching portal's **skill** listing, and the installed local copy aligned.

## Requirements

- Windows PowerShell and Git
- GitHub CLI (`gh`) authenticated for repository discovery and GitHub operations
- Access to the default backup root:
  - `G:\我的雲端硬碟\000000000backup\0000000000數位教材\skill`

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

These commands respectively back up installed and GitHub skills, back up GitHub-hosted skills only, create a single-skill safety backup, pull or push a skill, and inspect status. `Push` requires `-Force` as an explicit confirmation. Each run creates a new Taipei-time `YYYY-MM-DD-HHmmss` folder under the backup root. Inside it, each skill package has its own folder. Local packages use `<skill-name>/<skill-name>-local.zip`. GitHub packages use `<repo-name>/<repo-name>-github.zip` and preserve every tracked path in the default-branch commit, including nested skills. Matching names place both ZIPs in the same folder. The default GitHub discovery checks likely skill repositories; add `-ScanAllGitHubRepos` for a full account scan.

## skill-sync Integration

- After a successful `-Mode Push -Force`, the script adds the skill to `~/skill-sync/skills.json` (target `~/.codex/skills/<name>`) if it is not listed yet, then commits and pushes skill-sync, so every computer running the SkillSync task pulls it. The result appears as `skillSyncRegistration` in the output JSON. Use `-SkipSkillSyncRegister` to turn this off.
- Registration is skipped (with a reason) when SKILL.md is not at the repo root, `~/skill-sync` is missing, or it has uncommitted changes. A failure here never fails the Push.
- Pull mode is for one-off manual use; daily sync across computers is skill-sync's job.
- Backup roles: local `skill_backups/` folders hold short-term copies made before an overwrite; the G: drive ZIPs are the long-term archive.

## Backup reports

Every backup run—including the automatic safety backup before `Pull` or `Push`—produces a Markdown overall report in Traditional Chinese named `skill-backup-report_YYYY-MM-DD-HHmmss.md`. Each report is stored inside its timestamped snapshot folder. Each report explicitly gives its folder and filename and lists all backed-up skills, separating installed local skills from GitHub skills (`無` when a list is empty). It also includes status, backup path, counts, last completed step, and errors. A partial or failed operation must not be described as complete. The final response must likewise give the report folder, filename, and skill list in Chinese.

## Publishing a skill update

For a locally maintained skill, create its safety backup, push through this script, update the matching portal skill listing only when required, verify the live page, and confirm the installed local copy matches the published GitHub source. Keep the overall backup report and report each destination's result. Do not publish bundled vendor or private/system skills as user-authored skills.
