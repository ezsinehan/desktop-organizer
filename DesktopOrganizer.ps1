<#
  DesktopOrganizer - an interactive "desktop inbox-zero" triage tool.

  Run it:        powershell -ExecutionPolicy Bypass -File .\DesktopOrganizer.ps1
  Or dot-source:  . .\DesktopOrganizer.ps1   (loads the functions without the TUI)

  It scans your Desktop, classifies every item (git repo / plain folder / loose
  file), and walks you through them one at a time. Each item shows a card with a
  recommended action; you press ONE key to act:

     [P] Push/back up to a PRIVATE GitHub repo
     [B] Back up to private repo, THEN remove from desktop (reclaim space)
     [A] Archive  (move to Desktop\Archive)
     [D] Delete   (send to Recycle Bin - never permanent)
     [O] Open in File Explorer to inspect, then ask again
     [K] Keep / skip  (leave it exactly as is)   [Enter] does the same
     [Q] Quit

  Loose files are handled in one batch at the end (sort into Documents/Images/...).

  Requirements: git, and gh (GitHub CLI) authenticated, for the push actions.
#>

#region ---------- config ----------
$script:DesktopRoot = Join-Path $env:USERPROFILE 'Desktop'
$script:ArchiveDir  = Join-Path $script:DesktopRoot 'Archive'
$script:Protected   = @('desktop.ini', 'Archive', 'desktop-organizer', '.claude')
$script:FileRoutes  = @{
  '.pdf'='Documents'; '.docx'='Documents'; '.doc'='Documents'; '.txt'='Documents';
  '.xlsx'='Documents'; '.xls'='Documents'; '.csv'='Documents'; '.pptx'='Documents';
  '.png'='Images'; '.jpg'='Images'; '.jpeg'='Images'; '.jfif'='Images'; '.gif'='Images';
  '.webp'='Images'; '.bmp'='Images'; '.svg'='Images';
  '.exe'='Installers'; '.msi'='Installers'; '.zip'='Installers'
  # .lnk shortcuts are intentionally left on the desktop.
}
#endregion

#region ---------- inventory ----------
function Get-GitInfo {
  param([string]$Path)
  if (-not (Test-Path (Join-Path $Path '.git'))) { return $null }
  $remote = (& git -C $Path remote get-url origin 2>$null)
  $branch = (& git -C $Path rev-parse --abbrev-ref HEAD 2>$null)
  $dirty  = (& git -C $Path status --porcelain 2>$null | Measure-Object).Count
  $ahead  = 0
  if ($remote) { $ahead = [int](& git -C $Path rev-list --count '@{u}..HEAD' 2>$null) }
  [PSCustomObject]@{ Remote=$remote; Branch=$branch; Dirty=$dirty; Ahead=$ahead; HasRemote=[bool]$remote }
}

function Get-FolderSizeMB {
  param([string]$Path)
  [math]::Round((Get-ChildItem $Path -Recurse -Force -EA SilentlyContinue |
    Measure-Object -Property Length -Sum).Sum / 1MB, 1)
}

function Get-DesktopInventory {
  param([string]$Root = $script:DesktopRoot)
  Get-ChildItem $Root -Force -EA SilentlyContinue |
    Where-Object { $script:Protected -notcontains $_.Name } |
    ForEach-Object {
      $item = $_; $git = $null; $kind = 'file'; $repoPath = $item.FullName
      if ($item.PSIsContainer) {
        $kind = 'folder'
        $git  = Get-GitInfo -Path $item.FullName
        if (-not $git) {
          $kids = Get-ChildItem $item.FullName -Force -Directory -EA SilentlyContinue
          if ($kids.Count -eq 1) {
            $nested = Get-GitInfo -Path $kids[0].FullName
            if ($nested) { $git = $nested; $kind = 'nested-repo'; $repoPath = $kids[0].FullName }
          }
        }
      }
      if     ($git -and $git.HasRemote -and $git.Ahead -eq 0 -and $git.Dirty -eq 0) { $status='pushed-clean';  $rec='keep'   }
      elseif ($git -and $git.HasRemote)        { $status="needs-push (ahead=$($git.Ahead), dirty=$($git.Dirty))"; $rec='push' }
      elseif ($git -and -not $git.HasRemote)   { $status='git, no remote';  $rec='push'    }
      elseif ($item.PSIsContainer)             { $status='no git backup';   $rec='backup'  }
      else                                     { $status='loose file';      $rec='sort'    }

      if ($item.PSIsContainer) { $sizeMB = Get-FolderSizeMB $item.FullName }
      else { $sizeMB = [math]::Round($item.Length/1MB, 2) }

      [PSCustomObject]@{
        Name=$item.Name; Kind=$kind; SizeMB=$sizeMB; Status=$status; Recommend=$rec
        Remote=$(if($git){$git.Remote}else{''}); Path=$item.FullName; RepoPath=$repoPath
        LastWrite=$item.LastWriteTime.ToString('yyyy-MM-dd'); IsFolder=$item.PSIsContainer
      }
    }
}

function Show-DesktopReport {
  param([string]$Root = $script:DesktopRoot)
  Get-DesktopInventory -Root $Root | Sort-Object IsFolder, SizeMB -Descending |
    Format-Table Name, Kind, SizeMB, Status, Recommend, LastWrite -AutoSize
}
#endregion

#region ---------- actions ----------
function Backup-ToPrivateRepo {
  param([Parameter(Mandatory)][string]$Path, [string]$RepoName,
        [string]$CommitMessage='Backup via DesktopOrganizer', [switch]$ThenDelete)
  if (-not $RepoName) { $RepoName = Split-Path $Path -Leaf }
  Push-Location $Path
  try {
    if (-not (Test-Path '.git')) { & git init | Out-Null }
    & git add -A
    if (& git status --porcelain) { & git commit -m $CommitMessage | Out-Null }
    if (& git remote get-url origin 2>$null) { & git push }
    else { & gh repo create $RepoName --private --source=. --remote=origin --push }
    Write-Host "  -> backed up to private repo '$RepoName'" -ForegroundColor Green
    $ok = $true
  } catch { Write-Host "  -> backup FAILED: $_" -ForegroundColor Red; $ok = $false }
  finally { Pop-Location }
  if ($ok -and $ThenDelete) { Remove-ItemToRecycle -Path $Path }
}

function Move-ToArchive {
  param([Parameter(Mandatory)][string]$Path)
  New-Item -ItemType Directory -Force $script:ArchiveDir | Out-Null
  Move-Item $Path (Join-Path $script:ArchiveDir (Split-Path $Path -Leaf))
  Write-Host "  -> archived to Desktop\Archive" -ForegroundColor Cyan
}

function Remove-ItemToRecycle {
  param([Parameter(Mandatory)][string]$Path)
  Add-Type -AssemblyName Microsoft.VisualBasic
  if ((Get-Item $Path).PSIsContainer) {
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path,'OnlyErrorDialogs','SendToRecycleBin')
  } else {
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path,'OnlyErrorDialogs','SendToRecycleBin')
  }
  Write-Host "  -> sent to Recycle Bin" -ForegroundColor Yellow
}

function Organize-LooseFiles {
  param([string]$Root = $script:DesktopRoot, [switch]$WhatIf)
  $moved = 0
  Get-ChildItem $Root -File -Force -EA SilentlyContinue |
    Where-Object { $script:Protected -notcontains $_.Name } | ForEach-Object {
      $dest = $script:FileRoutes[$_.Extension.ToLower()]
      if ($dest) {
        if ($WhatIf) { Write-Host ("  {0,-45} -> {1}" -f $_.Name, $dest) }
        else {
          $destDir = Join-Path $Root $dest
          New-Item -ItemType Directory -Force $destDir | Out-Null
          Move-Item $_.FullName (Join-Path $destDir $_.Name) -Force
          Write-Host ("  {0,-45} -> {1}" -f $_.Name, $dest) -ForegroundColor Green
        }
        $moved++
      }
    }
  if ($moved -eq 0) { Write-Host "  (no loose files to sort)" -ForegroundColor DarkGray }
}
#endregion

#region ---------- TUI ----------
function Read-Key {
  $k = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
  return [string]$k.Character
}

# sinehan.dev house style: lowercase, pixel-art, white + subdued gray + rainbow accent.
function Write-Rainbow {
  param([string]$Text)
  $palette = @('Red','Yellow','Green','Cyan','Blue','Magenta')
  $chars = $Text.ToCharArray()
  for ($j = 0; $j -lt $chars.Length; $j++) {
    Write-Host -NoNewline $chars[$j] -ForegroundColor $palette[$j % $palette.Length]
  }
  Write-Host ''
}

function Show-Banner {
  Clear-Host
  Write-Host ''
  Write-Rainbow '   #####  #####  #### #   # ####  ##### #####  #####'
  Write-Host    '   d e s k t o p   o r g a n i z e r' -ForegroundColor White
  Write-Host    "   by sinehan  .  desktop inbox-zero, one keypress at a time" -ForegroundColor DarkGray
  Write-Host    '   ----------------------------------------------------------' -ForegroundColor DarkGray
  Write-Host ''
}

function Write-Card {
  param($Item, [int]$Index, [int]$Total)
  $recColor = @{ keep='DarkGray'; push='Yellow'; backup='Cyan'; sort='Gray' }[$Item.Recommend]
  Show-Banner
  Write-Host ("   item $Index of $Total") -ForegroundColor DarkGray
  Write-Host ("  " + ('-'*58)) -ForegroundColor DarkGray
  Write-Host ("   {0}" -f $Item.Name) -ForegroundColor White
  Write-Host ("   {0}  |  {1} MB  |  modified {2}" -f $Item.Kind, $Item.SizeMB, $Item.LastWrite) -ForegroundColor DarkGray
  Write-Host ("   status: {0}" -f $Item.Status) -ForegroundColor $recColor
  if ($Item.Remote) { Write-Host ("   remote: {0}" -f $Item.Remote) -ForegroundColor DarkGray }
  Write-Host ("  " + ('-'*58)) -ForegroundColor DarkGray
  $hint = @{ keep='already safe - recommend KEEP'; push='has un-backed-up work - recommend PUSH'
             backup='not in git anywhere - recommend BACK UP'; sort='loose file - handled in batch' }[$Item.Recommend]
  Write-Host ("   recommendation: {0}" -f $hint) -ForegroundColor $recColor
  Write-Host ""
  Write-Host "   [P]ush  [B]ackup+delete  [A]rchive  [D]elete  [O]pen  [K]eep  [Q]uit" -ForegroundColor White
  Write-Host -NoNewline "   > "
}

function Show-Info {
  Show-Banner
  Write-Host "   what is this?" -ForegroundColor White
  Write-Host "   your desktop fills up with half-finished projects, random installers," -ForegroundColor Gray
  Write-Host "   and files you forgot about. this walks you through all of it, one card" -ForegroundColor Gray
  Write-Host "   at a time. you press ONE key per item. that's the whole thing.`n" -ForegroundColor Gray

  Write-Host "   it already knows:" -ForegroundColor White
  Write-Host "    . which folders are git repos that are clean + already on github" -ForegroundColor Gray
  Write-Host "    . which have unpushed commits or uncommitted work (even nested repos)" -ForegroundColor Gray
  Write-Host "    . which exist ONLY on this laptop and aren't backed up anywhere" -ForegroundColor Gray
  Write-Host "    . which loose files are just clutter to sweep into folders`n" -ForegroundColor Gray

  Write-Host "   your one-key moves:" -ForegroundColor White
  Write-Host "    [P] push / back up to a PRIVATE github repo" -ForegroundColor Yellow
  Write-Host "    [B] back up to a private repo, THEN recycle it (reclaim the space)" -ForegroundColor Yellow
  Write-Host "    [A] archive  -> moves it to Desktop\Archive" -ForegroundColor Cyan
  Write-Host "    [D] delete   -> recycle bin, never permanent" -ForegroundColor Yellow
  Write-Host "    [O] open in explorer to peek, then ask again" -ForegroundColor Gray
  Write-Host "    [K] keep / skip   (enter does the same)" -ForegroundColor DarkGray
  Write-Host "    [Q] quit`n" -ForegroundColor DarkGray

  Write-Host "   nothing here is destructive: deletes go to the recycle bin," -ForegroundColor Gray
  Write-Host "   backups go to PRIVATE repos, and a plain scan changes nothing.`n" -ForegroundColor Gray

  Write-Rainbow "   !! the one warning that matters !!"
  Write-Host "   private is NOT the same as safe for a secret. this tool does not scan" -ForegroundColor White
  Write-Host "   for api keys or tokens before pushing, and anything you commit lives in" -ForegroundColor White
  Write-Host "   git history forever. got a token/.env in a folder? pull it out AND" -ForegroundColor White
  Write-Host "   rotate the key before you back that folder up. no exceptions.`n" -ForegroundColor White
  Write-Host "   ----------------------------------------------------------" -ForegroundColor DarkGray
  Write-Host "   full details: README.md  .  built by sinehan -> sinehan.dev" -ForegroundColor DarkGray
}

function Start-DesktopTriage {
  param([string]$Root = $script:DesktopRoot)
  Show-Banner
  Write-Host "   press [i] for info / how it works  .  any other key to start`n" -ForegroundColor DarkGray
  Write-Host -NoNewline "   > "
  if ((Read-Key).ToUpper() -eq 'I') {
    Show-Info
    Write-Host "`n   press any key to begin triage..." -ForegroundColor DarkGray
    [void](Read-Key)
  }
  Show-Banner
  Write-Host '   scanning your desktop...' -ForegroundColor DarkGray
  $inv = @(Get-DesktopInventory -Root $Root)
  $folders = @($inv | Where-Object IsFolder | Sort-Object SizeMB -Descending)
  $files   = @($inv | Where-Object { -not $_.IsFolder })
  Write-Host "   found $($folders.Count) folders + $($files.Count) loose files. let's tidy up.`n" -ForegroundColor White
  Start-Sleep -Milliseconds 700
  $actions = @()
  $i = 0
  foreach ($it in $folders) {
    $i++
    $done = $false
    while (-not $done) {
      Write-Card -Item $it -Index $i -Total $folders.Count
      $key = (Read-Key).ToUpper()
      Write-Host $key
      switch ($key) {
        'P' { Backup-ToPrivateRepo -Path $it.RepoPath -RepoName $it.Name; $actions += "PUSH   $($it.Name)"; $done=$true }
        'B' { Backup-ToPrivateRepo -Path $it.RepoPath -RepoName $it.Name -ThenDelete; $actions += "BACKUP+DEL $($it.Name)"; $done=$true }
        'A' { Move-ToArchive -Path $it.Path; $actions += "ARCHIVE $($it.Name)"; $done=$true }
        'D' { Remove-ItemToRecycle -Path $it.Path; $actions += "DELETE  $($it.Name)"; $done=$true }
        'O' { Start-Process explorer.exe $it.Path; Start-Sleep -Milliseconds 400 }
        'Q' { Write-Host "`n  quitting."; return (Show-Summary $actions) }
        default { $actions += "keep    $($it.Name)"; $done=$true }  # K or Enter
      }
      if ($done -and $key -ne 'O') { Start-Sleep -Milliseconds 600 }
    }
  }
  # Loose files in one batch.
  if ($files.Count -gt 0) {
    Clear-Host
    Write-Host "  LOOSE FILES - preview of sort:`n" -ForegroundColor Magenta
    Organize-LooseFiles -Root $Root -WhatIf
    Write-Host "`n  Sort these into subfolders? [Y]es / [N]o / [Q]uit" -ForegroundColor White
    Write-Host -NoNewline "   > "
    $key = (Read-Key).ToUpper(); Write-Host $key
    if ($key -eq 'Y') { Write-Host ""; Organize-LooseFiles -Root $Root; $actions += "SORTED loose files" }
  }
  Show-Summary $actions
}

function Show-Summary {
  param([string[]]$Actions)
  Show-Banner
  Write-Host "   all done. here's what happened:`n" -ForegroundColor White
  if ($Actions.Count -eq 0) { Write-Host "   (nothing changed - you kept everything)" -ForegroundColor DarkGray }
  else { $Actions | ForEach-Object { Write-Host "    $_" } }
  Write-Host "`n   deletes went to the recycle bin (recoverable). backups live in private github repos." -ForegroundColor DarkGray
  Write-Host "   run me again any time your desktop gets messy <3`n" -ForegroundColor DarkGray
}

Set-Alias triage Start-DesktopTriage
Set-Alias info   Show-Info
#endregion

# When executed directly (not dot-sourced), launch the TUI.
if ($MyInvocation.InvocationName -ne '.') {
  Start-DesktopTriage
} else {
  Write-Host "DesktopOrganizer loaded. Commands: info | triage | Show-DesktopReport | Backup-ToPrivateRepo | Move-ToArchive | Remove-ItemToRecycle | Organize-LooseFiles" -ForegroundColor Magenta
}
