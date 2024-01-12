@echo off

REM Install or uninstall or start or stop the Crystal Windows Service Example

SET service_path=%~dp0
SET service_exe=%service_path%example.exe
SET service_name=crystal-win32svc-example
SET service_display_name=Crystal Windows Service Example
SET service_description=Provides an example Windows service written in Crystal lang
SET service_start=demand
SET action=%1

if "%action%"=="install" (
  @echo Install service: %service_name%
  sc create %service_name% binPath= "%service_exe%"
  sc config %service_name% start= %service_start%
  sc config %service_name% DisplayName= "%service_display_name%"
  sc description %service_name% "%service_description%"
) else if "%action%"=="uninstall" (
  @echo Uninstall service: %service_name%
  sc stop %service_name%
  sc delete %service_name%
) else if "%action%"=="start" (
  sc start %service_name%
) else if "%action%"=="stop" (
  sc stop %service_name%
) else (
  @echo Usage: %0 [action] where [action] = install or uninstall or start or stop
)
