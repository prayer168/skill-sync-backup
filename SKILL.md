---
name: skill-sync-backup
description: >-
  Synchronize Codex skills installed on this computer with the user's GitHub skill repositories,
  and back up installed Codex skills into the user's Google Drive backup folder. Use when the
  user asks to sync, update, pull, push, compare, or back up Codex skills between GitHub and
  C:\Users\NNKIEH\.codex\skills, including broad requests like "備份技能".
---

# Skill Sync Backup

Keep the user's GitHub skill repositories, installed Codex skills, and local cloud-drive backups aligned.

## Local Conventions

- Installed Codex skills live under `C:\Users\NNKIEH\.codex\skills\<skill-name>`.
- Backup destination is the first usable path below:
  - `G:\我的雲端硬碟\000000000backup\0000000000數位教材\skill`
  - `D:\我的雲端硬碟\000000000backup\0000000000數位教材\skill`
- When the user says "備份技能" without naming one skill, create a date folder under the backup root: `YYYY-MM-DD`.
  Put the latest installed Codex skill folders inside that date folder.
- Single-skill safety backups used before `Pull` or `Push` keep the older naming pattern:
  `<skill-name>,YYYY-MM-DD`. If today's single-skill backup already exists, append the time:
  `<skill-name>,YYYY-MM-DD-HHmmss`.
- Default GitHub owner is `prayer168` unless the user gives another owner or full repo URL.

## Standard Workflow

Use `scripts/Sync-CodexSkill.ps1` for real sync or backup work instead of rewriting ad hoc PowerShell.

Before mutating either side:

1. Identify the local skill name and GitHub repo. If the repo is not explicit, infer `prayer168/<skill-name>` and verify it with `gh repo view` or `gh repo list`.
2. Tell the user which direction will be used:
   - `Pull`: GitHub repo -> installed Codex skill.
   - `Push`: installed Codex skill -> GitHub repo.
   - `BackupAll`: all installed Codex skills -> dated local backup folder. Use this for "備份技能".
   - `Backup`: one named skill only, mostly for pre-sync safety.
3. Always back up the installed local skill before `Pull` or `Push`.
4. Do not overwrite local changes or push remote changes when the user's request is ambiguous. Ask a short clarification only when the direction or repo cannot be inferred safely.

## Automation Alignment Controls

- `Status`, `Backup`, and `BackupAll` are safe low-supervision modes when paths are valid. `Pull` and `Push` are mutation modes and must preserve the automatic backup and path-boundary checks in the script.
- `BackupAll` must first create or reuse the date folder directly under the backup root, then refresh each skill folder inside it from `C:\Users\NNKIEH\.codex\skills`.
- Never bypass `-Force` for `Push`; it is the human checkpoint that confirms the installed Codex copy should overwrite GitHub content.
- If backup creation, repo reachability, clone, validation, copy, commit, or push fails, stop with the backup path and last completed step. Do not retry destructive copy operations with a different inferred path.
- After any `Pull` or `Push`, run the skill validator on the installed skill or remote copy when available, and report validation results separately from sync completion.

Common commands:

Back up all currently installed Codex skills:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\NNKIEH\.codex\skills\skill-sync-backup\scripts\Sync-CodexSkill.ps1" -Mode BackupAll
```

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\NNKIEH\.codex\skills\skill-sync-backup\scripts\Sync-CodexSkill.ps1" -SkillName "<skill-name>" -Repo "prayer168/<repo-name>" -Mode Pull
```

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\NNKIEH\.codex\skills\skill-sync-backup\scripts\Sync-CodexSkill.ps1" -SkillName "<skill-name>" -Repo "prayer168/<repo-name>" -Mode Backup
```

Use `-Mode Push` only when the user explicitly wants the installed Codex copy to become the GitHub version.

## Reporting

After a run, report:

- local skill path
- GitHub repo or URL used
- backup path created
- sync direction
- whether validation passed
- any files left unchanged because the script stopped safely
