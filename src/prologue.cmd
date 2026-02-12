@setlocal & set "s=%~f0" & set "a=%*" & pwsh -nop -ep Bypass -c "Add-Type -Ty ((gc $env:s -raw)-split'//CS_BEGIN')[2]; exit [P]::Entry($env:a);" & exit /b %ERRORLEVEL%

//CS_BEGIN
// Everything below this line is C# code.
