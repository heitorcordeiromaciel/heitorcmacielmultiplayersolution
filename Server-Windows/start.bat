@echo off
setlocal
set DIR=%~dp0
"%DIR%ruby\bin\ruby.exe" "%DIR%server.rb"
pause

