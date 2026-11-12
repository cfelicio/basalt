@echo off
rem Basalt for Windows. The first run sets up Python, gets the engine, helps choose a model, writes the
rem settings and starts the server. Running it again starts the server. An NVIDIA driver for a Blackwell
rem card (RTX 50 series, RTX PRO Blackwell) is all that has to be installed on the machine.
rem   START-HERE.bat --plan    print every step and change nothing
rem   START-HERE.bat --yes     take the shown default for every question
rem   START-HERE.bat --config <file>  serve with an existing configuration file
setlocal
rem Python reads and writes text as UTF-8 and not in the machine's code page, so a folder or user name with
rem accents, Cyrillic or CJK characters survives (a model path typed by a user arrives the same way).
set "PYTHONUTF8=1"
title Basalt
cd /d "%~dp0"

rem The private environment this folder made: reuse it, so nothing is installed twice.
if exist ".venv\Scripts\python.exe" goto run

call :findpy
if defined PY goto venv
echo.
echo  Python 3.10 or newer is not installed. Installing Python 3.12 for your user account ...
where winget >nul 2>nul
if errorlevel 1 goto pyorg
winget install -e --id Python.Python.3.12 --scope user --silent --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
call :findpy
if defined PY goto venv
:pyorg
echo  Downloading the Python installer from python.org ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; Invoke-WebRequest -UseBasicParsing https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe -OutFile \"$env:TEMP\basalt-python-setup.exe\""
if exist "%TEMP%\basalt-python-setup.exe" "%TEMP%\basalt-python-setup.exe" /quiet InstallAllUsers=0 PrependPath=1 Include_launcher=1 Include_test=0
call :findpy
if defined PY goto venv
echo.
echo  Python could not be installed automatically.
echo  Install 64-bit Python 3.12 from https://www.python.org/downloads/ and tick "Add python.exe to PATH",
echo  then double-click START-HERE.bat again.
pause
exit /b 1

:venv
rem A private environment in this folder: nothing is installed into the system Python.
%PY% -m venv .venv
if exist ".venv\Scripts\python.exe" goto run
echo  Could not create the Python environment in .venv
pause
exit /b 1

:run
".venv\Scripts\python.exe" tools\windows\setup_basalt.py %*
if errorlevel 1 pause
exit /b

:findpy
rem the py launcher first, then python on PATH (not the Microsoft Store stub), then the usual per-user folders
set "PY="
py -3 -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) and sys.maxsize > 2**32 else 1)" >nul 2>nul
if not errorlevel 1 set "PY=py -3" & goto :eof
python -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) and sys.maxsize > 2**32 else 1)" >nul 2>nul
if not errorlevel 1 set "PY=python" & goto :eof
for %%V in (313 312 311 310) do if exist "%LOCALAPPDATA%\Programs\Python\Python%%V\python.exe" set "PY="%LOCALAPPDATA%\Programs\Python\Python%%V\python.exe"" & goto :eof
goto :eof
