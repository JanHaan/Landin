# Landin for Visual Studio

Visual Studio's TextMate language service can load the same generated grammar
as VS Code. Run `install.ps1` in PowerShell to copy it under the current
user's `.vs/Extensions/Landin/Syntaxes` directory, then reopen affected files
or restart Visual Studio. The grammar itself carries the `.ldn` association
and `source.landin` scope.
