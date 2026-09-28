---
name: skill-sync-backup
version: 1.0.0
description: >-
  Synchronize Codex skills installed on this computer with the user's GitHub skill repositories,
  search the user's GitHub account for skill repositories, and back up both installed and
  GitHub-hosted skills into the user's Google Drive backup folder. Also use whenever creating,
  editing, installing, pulling, publishing, or otherwise updating a locally maintained Codex skill,
  so the GitHub repo, Black Bear digital teaching portal skill listing, and installed local copy
  are synchronized together. Use for requests to sync, update, pull, push, compare, or back up
  Codex skills, including broad requests like "備份技能".
---

# Skill Sync Backup

Keep the user's GitHub skill repositories, installed Codex skills, and local cloud-drive backups aligned.

## Required Three-Way Publish Workflow

Whenever a locally maintained Codex skill is created, updated, pulled, or pushed, complete this
workflow as part of the same task. Treat the skill's own GitHub repository as the source of truth
after the skill change is ready. The three destinations are the GitHub skill repo, the `skill`
category on the Black Bear digital teaching portal, and the installed local skill folder.

1. **Identify and protect the source.** Resolve the skill directory and its GitHub repo from the
   skill's configured repo URL, its Git remote, or an exact `prayer168/<skill-name>` repo. Verify
   the repo and default branch before writing. If multiple candidates exist or the skill is not
   locally maintained, stop and report the ambiguity. Before replacing or publishing content,
   create the dated local safety backup using this skill's script. Keep unrelated files and user
   changes intact.
2. **Publish the skill repo.** For a requested local-to-GitHub update, use this skill's protected
   `Push` workflow (`-Force` is required by the script), inspect the diff, and push only the target
   skill. If GitHub has newer commits, fetch and integrate them without discarding either side;
   stop on unresolved conflicts. For a GitHub-to-local update, pull the verified remote version
   first, then continue with the portal and local-copy steps below.
3. **Update the portal skill listing.** Use the `science-portal-update-codex` workflow and edit
   `prayer168/science-portal` from a fresh clone. In `STATIC_SKILL_REPORTS`, update the existing
   entry for this skill's repo URL or add one if absent. Do not create duplicates. Use a readable
   Traditional Chinese title and stable emoji. If the entry name changes, update
   `MATERIAL_ICON_MAP` as needed. Do not modify Firestore directly. Preserve concurrent portal
   commits by fetching and integrating before push.
4. **Deploy and verify the portal.** Preview the changed `skill` category locally. Commit and push
   only the intended portal file, then verify the live GitHub Pages page with a cache-busting URL;
   confirm the title and repo link appear exactly once. A successful `git push` alone does not
   count as deployment verification.
5. **Refresh the installed local skill.** Once the GitHub skill repo is confirmed current, sync its
   contents back to `C:\Users\NNKIEH\.codex\skills\<skill-name>` while preserving required local
   configuration and checking for local-only changes. For this skill itself, compare the pushed
   repo with the local folder and refresh the local copy only after confirming the contents match.
6. **Sync the local portal copy.** After the live page is verified, back up the previous local
   `science-portal\index.html` once for today's date, then copy the deployed repo version to the
   local Google Drive portal folder. Never copy the stale local portal file over GitHub.
7. **Report completion per destination.** Give the skill repo URL and commit, portal commit and
   live verification, local skill path, local portal path and dated backup path. Mark any failed
   destination incomplete and state the last successful step.

This workflow applies to locally maintained skills under the user's Codex skills directory. Do
not publish bundled vendor/plugin skills or private/system skills as if they were user-authored.
If there is no verified GitHub repo, a repo would need to be created, or a local/remote conflict
cannot be reconciled safely, complete the non-dependent checks and ask for the missing repo or
source choice before publishing. For bulk `BackupAll`, keep its dated archive behavior; the
three-way publish workflow is for a skill being changed, not a request to add every skill to the
public portal.

## Local Conventions

- Installed Codex skills live under `C:\Users\NNKIEH\.codex\skills\<skill-name>`.
- Backup destination is the first usable path below:
  - `G:\我的雲端硬碟\000000000backup\0000000000數位教材\skill`
  - `D:\我的雲端硬碟\000000000backup\0000000000數位教材\skill`
- When the user says "備份技能" without naming one skill, create a date folder under the backup root: `YYYY-MM-DD`.
  Put the latest installed Codex skill folders inside that date folder, then search GitHub for skill repos and
  place their current contents under `YYYY-MM-DD\github\<repo-name>`.
- A GitHub repo counts as a skill repo when its default branch contains at least one `SKILL.md`.
  If a repo has nested skills, store each one as `<repo-name>--<nested-path>`.
- GitHub search defaults to likely skill repos based on repo name, description, and installed local skill names,
  then verifies each candidate by checking for `SKILL.md`. Use `-ScanAllGitHubRepos` only when a full account scan is needed.
- Single-skill safety backups used before `Pull` or `Push` keep the older naming pattern:
  `<skill-name>,YYYY-MM-DD`. If today's single-skill backup already exists, append the time:
  `<skill-name>,YYYY-MM-DD-HHmmss`.
- Every backup operation must create a Markdown overall report, including full, GitHub-only,
  single-skill, and automatic pre-sync safety backups. The report is named
  `skill-backup-report_YYYY-MM-DD-HHmmss.md`; bulk reports live in that dated backup folder and
  single-skill safety reports live under `<backup-root>\reports`. The report format is maintained
  in `templates/backup-report.md` and populated by `scripts/Sync-CodexSkill.ps1`.
- Default GitHub owner is `prayer168` unless the user gives another owner or full repo URL.

## Standard Workflow

Use `scripts/Sync-CodexSkill.ps1` for real sync or backup work instead of rewriting ad hoc PowerShell.

Before mutating either side:

1. Identify the local skill name and GitHub repo. If the repo is not explicit, infer `prayer168/<skill-name>` and verify it with `gh repo view` or `gh repo list`.
2. Tell the user which direction will be used:
   - `Pull`: GitHub repo -> installed Codex skill.
   - `Push`: installed Codex skill -> GitHub repo.
   - `BackupAll`: all installed Codex skills plus GitHub-hosted skill repos -> dated backup folder. Use this for "備份技能".
   - `BackupGitHub`: GitHub-hosted skill repos only -> dated backup folder.
   - `Backup`: one named skill only, mostly for pre-sync safety.
3. Always back up the installed local skill before `Pull` or `Push`.
4. Do not overwrite local changes or push remote changes when the user's request is ambiguous. Ask a short clarification only when the direction or repo cannot be inferred safely.

## Automation Alignment Controls

- `Status`, `Backup`, and `BackupAll` are safe low-supervision modes when paths are valid. `Pull` and `Push` are mutation modes and must preserve the automatic backup and path-boundary checks in the script.
- `BackupAll` must first create or reuse the date folder directly under the backup root, then refresh each skill folder inside it from `C:\Users\NNKIEH\.codex\skills`, then refresh the `github` subfolder from skill repos discovered under the configured GitHub owner.
- GitHub discovery uses `gh repo list <owner>` plus default-branch tree inspection for `SKILL.md`. Clone only repos confirmed to contain a skill file. Prefer the default fast candidate search; use `-ScanAllGitHubRepos` for exhaustive but slower discovery.
- Never bypass `-Force` for `Push`; it is the human checkpoint that confirms the installed Codex copy should overwrite GitHub content.
- If backup creation, repo reachability, clone, validation, copy, commit, or push fails, stop with the backup path and last completed step. Do not retry destructive copy operations with a different inferred path.
- Every backup command must render `templates/backup-report.md` and leave a report even when GitHub discovery or copying fails. The report records completion time, mode, status (`Completed`, `Partial`, or `Failed`), backup path, local and GitHub skill counts and names, and errors. For a partial backup, list everything copied before the failure and identify the last completed step. Never report a failed or partial backup as complete.
- After any `Pull` or `Push`, run the skill validator on the installed skill or remote copy when available, and report validation results separately from sync completion.

Common commands:

Back up all currently installed Codex skills:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\NNKIEH\.codex\skills\skill-sync-backup\scripts\Sync-CodexSkill.ps1" -Mode BackupAll
```

Back up GitHub-hosted skill repos only:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\NNKIEH\.codex\skills\skill-sync-backup\scripts\Sync-CodexSkill.ps1" -Mode BackupGitHub
```

Full GitHub account scan:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\NNKIEH\.codex\skills\skill-sync-backup\scripts\Sync-CodexSkill.ps1" -Mode BackupGitHub -ScanAllGitHubRepos
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
- overall backup report path, status, local and GitHub skill counts, and any incomplete items
- for a skill update, separate completion status for GitHub skill repo, portal `skill` listing,
  installed local skill, and local portal copy
