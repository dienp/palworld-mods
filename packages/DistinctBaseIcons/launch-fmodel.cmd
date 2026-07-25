@echo off
setlocal
set "DOTNET_ROOT=%~dp0..\..\tools\dotnet"
set "DOTNET_ROOT_X64=%~dp0..\..\tools\dotnet"
set "DOTNET_MULTILEVEL_LOOKUP=0"
"%~dp0..\..\tools\FModel\FModel.exe"
