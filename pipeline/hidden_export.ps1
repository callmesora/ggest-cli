# Export HFSQL tables to XML with WDMap running on a hidden desktop (nothing shows on screen,
# no real keystrokes). Drives File > Export > to an XML file with posted window messages.
# Usage: hidden_export.ps1 -DataDir <dir with .fic> -OutDir <dir> [-Worker 0 -Workers 1] [-Tables a,b]
param([string]$DataDir, [string]$OutDir, [int]$Worker = 0, [int]$Workers = 1, [string[]]$Tables = @())
. "$PSScriptRoot\hidden_lib.ps1"
$WDMAP = "C:\PC SOFT\WINDEV 28 Express\Programs\WDMAP.exe"
New-Item -ItemType Directory -Force $OutDir | Out-Null
$log = Join-Path $OutDir "_log_worker$Worker.tsv"
$Tables = @($Tables | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

function Post($h, $msg, $w, $l) { [void][HD]::PostMessage($h, $msg, [IntPtr]$w, [IntPtr]$l); Start-Sleep -Milliseconds 300 }
function Key($h, $vk) { Post $h 0x100 $vk 1; Post $h 0x101 $vk 0xC0000001 }
function Visible($procId) { [HD]::List($procId) | Where-Object { $_ -match 'vis=True' } }
function Popups($procId) { Visible $procId | Where-Object { $_ -match '\| WinDevObject \|  \|' } | ForEach-Object { [IntPtr][long]($_ -split ' \| ')[0] } }
function WaitFor([scriptblock]$cond, [double]$sec) { $t0 = Get-Date; while (((Get-Date) - $t0).TotalSeconds -lt $sec) { $r = & $cond; if ($r) { return $r }; Start-Sleep -Milliseconds 250 }; return $null }

$files = @(Get-ChildItem $DataDir -Filter *.fic | Sort-Object Name)
if ($Tables.Count) { $files = @($files | Where-Object { $Tables -contains $_.BaseName }) }
$i = -1
foreach ($f in $files) {
  $i++; if ($i % $Workers -ne $Worker) { continue }
  $name = $f.BaseName; $base = Join-Path $OutDir $name; $xml = "$base.XML"
  if (Test-Path $xml) { continue }
  $t0 = Get-Date; $status = "?"; $procId = 0
  try {
    $pi = [HD]::Start("ClaudeWDMapExport", $WDMAP, "`"$($f.FullName)`""); $procId = $pi.pid
    $main = WaitFor { $h = [HD]::FindTop($procId, "WDMap - *"); if ($h -ne [IntPtr]::Zero) { $h } } 900
    if (-not $main) { throw "OPEN_TIMEOUT: " + ((Visible $procId) -join ' ; ') }
    Start-Sleep -Milliseconds 700
    $before = @(Popups $procId)
    Post $main 0x104 0x46 0x20210001; Post $main 0x105 0x46 0xE0210001          # Alt+F
    $p1 = WaitFor { $n = @(Popups $procId | Where-Object { $before -notcontains $_ }); if ($n.Count) { ,$n } } 5
    if (-not $p1) { throw "NO_MENU" }
    foreach ($h in $p1) { Key $h 0x45 }                                           # E = Export
    $p2 = WaitFor { $n = @(Popups $procId | Where-Object { $before -notcontains $_ -and $p1 -notcontains $_ }); if ($n.Count) { ,$n } } 5
    $target = if ($p2) { $p2 } else { $p1 }
    foreach ($h in $target) { Key $h 0x28; Key $h 0x28; Key $h 0x0D }             # DOWN DOWN ENTER = XML
    $dlg = WaitFor { $h = [HD]::FindTop($procId, "Select *"); if ($h -ne [IntPtr]::Zero) { $h } } 6
    if (-not $dlg) { throw "EMPTY_OR_NO_EXPORT" }                                  # export is greyed out on empty tables
    $edit = [HD]::FindChild($dlg, "Edit", 1001)
    $btn = [HD]::FindChild($dlg, "Button", 1)
    [void][HD]::SendMessage($edit, 0x00B1, [IntPtr]0, [IntPtr](-1))
    [void][HD]::SendMessage($edit, 0x0102, [IntPtr]8, [IntPtr]1)
    foreach ($ch in $base.ToCharArray()) { [void][HD]::SendMessage($edit, 0x0102, [IntPtr][int]$ch, [IntPtr]1) }
    Post $btn 0x00F5 0 0                                                           # Save
    # done when the confirmation box (a second "WDMap - <table>" window) appears
    $done = WaitFor { if ([HD]::FindTop($procId, "Confirm*") -ne [IntPtr]::Zero) { "CONFIRM" } elseif (@(Visible $procId | Where-Object { $_ -match '\| WDMap - ' }).Count -ge 2) { "OK" } } 3600
    if ($done -eq "CONFIRM") { throw "CONFIRM_OVERWRITE (path not taken)" }
    if (-not $done) { throw "EXPORT_TIMEOUT" }
    $status = "OK"
  } catch { $status = "$_" }
  finally { if ($procId) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue } }
  $rows = 0
  if (Test-Path $xml) { $rows = @(Select-String -Path $xml -Pattern "^\s*<$([regex]::Escape($name))>\s*$").Count }
  "$name`t$($f.Length)`t$status`t$rows`t$([int]((Get-Date) - $t0).TotalSeconds)" | Out-File -Append -Encoding utf8 $log
}
"DONE" | Out-File -Append -Encoding utf8 $log
