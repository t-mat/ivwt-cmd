$root = Join-Path -Path $PSScriptRoot -ChildPath ".."
Get-Content $root/src/prologue.cmd, $root/src/ivwt.cs | Set-Content $root/ivwt.cmd
