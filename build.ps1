param($V)
$NASM = "$env:LOCALAPPDATA\nasm\nasm-2.16.03\nasm.exe"
$dir = 'C:\src\myos'
& $NASM -f bin "$dir\src\boot\boot.asm" -o "$dir\build\boot.bin"
& $NASM -f bin "$dir\src\kernel\kernel.asm" -o "$dir\build\kernel.bin"
$b = [byte[]](Get-Content "$dir\build\boot.bin" -Encoding Byte)
$k = [byte[]](Get-Content "$dir\build\kernel.bin" -Encoding Byte)
$pad = 1474560 - $b.Count - $k.Count
$all = [byte[]]($b + $k + [byte[]]::new($pad))
Set-Content "$dir\build\myos-v$V.img" -Value $all -Encoding Byte
$vmx = Get-Content "$dir\vm\myos.vmx"
$vmx = $vmx -replace 'floppy0\.fileName = .*', ('floppy0.fileName = "C:\src\myos\build\myos-v' + $V + '.img"')
Set-Content "$dir\vm\myos.vmx" -Value $vmx
Write-Host "built myos-v$V.img ($($all.Count) bytes; boot $($b.Count) + kernel $($k.Count))"
