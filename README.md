```
#####  #####  #### #   # ####  ##### #####  #####
d  e  s  k  t  o  p     o  r  g  a  n  i  z  e  r
```

> desktop inbox-zero, one keypress at a time.

my desktop kept filling up with half-finished projects, random installers, and
resumes. some of it was already safe on github, some of it existed *only* on my
laptop, and some of it was straight junk. this is the little tool i built to deal
with it without thinking too hard.

it scans your desktop, figures out what each thing actually is, and then walks you
through everything one card at a time. you press **one key** per item. that's it.

made for me, but it's plain powershell + git + the github cli, so it'll work for
anyone on windows. help yourself.

## what it does

- **knows what's already safe** — if a folder is a git repo that's clean and fully
  pushed, it says so and tells you to just keep it.
- **catches un-backed-up work** — repos with unpushed commits or uncommitted
  changes get flagged, including repos nested one level down (e.g. `game/src`).
- **one-key triage** — for each item:

  ```
  [P] push / back up to a PRIVATE github repo
  [B] back up to private repo, THEN remove from desktop (reclaim the space)
  [A] archive  -> moves it to Desktop\Archive
  [D] delete   -> recycle bin, never permanent
  [O] open in explorer to peek, then ask again
  [K] keep / skip   (enter does the same)
  [Q] quit
  ```

- **sorts loose files** — at the end it offers to sweep stray pdfs/images/etc.
  into `Documents\`, `Images\`, `Installers\`. your `.lnk` app shortcuts are left
  on the desktop where they belong.
- **nothing is destructive** — deletes go to the recycle bin, backups go to
  *private* repos. a plain scan changes nothing.

## use it

needs: [`git`](https://git-scm.com) and the [github cli](https://cli.github.com)
(`gh auth login`) if you want the push/backup actions.

```powershell
# interactive triage (the fun one)
powershell -ExecutionPolicy Bypass -File .\DesktopOrganizer.ps1

# or just look, change nothing
powershell -ExecutionPolicy Bypass -Command ". .\DesktopOrganizer.ps1; Show-DesktopReport"
```

prefer to script it? dot-source the file and call the pieces yourself:

```powershell
. .\DesktopOrganizer.ps1

Show-DesktopReport                                   # categorized inventory
Backup-ToPrivateRepo -Path 'C:\...\Desktop\art'      # init + private repo + push
Backup-ToPrivateRepo -Path '...\old' -ThenDelete     # back up, then recycle it
Move-ToArchive       -Path '...\Desktop\old-stuff'   # -> Desktop\Archive
Remove-ItemToRecycle -Path '...\Desktop\junk.zip'    # -> recycle bin
Organize-LooseFiles  -WhatIf                          # preview the file sweep
```

## tweak it

everything lives at the top of `DesktopOrganizer.ps1`:

- `$Protected` — names the tool never touches.
- `$FileRoutes` — extension → destination folder for the loose-file sweep.
- `$ArchiveDir` — where `[A]rchive` drops things.

## the honest caveat

it backs up to a **private** repo, but it does not scan your folders for secrets
first. if a folder has an api key or token in it, that's on you to pull out before
you push. (ask me how i know.)

---

mit licensed. built by [sinehan](https://sinehan.dev).
