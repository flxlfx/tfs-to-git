@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul

echo.
echo =================================================
echo          TFS -^> Git Migration Tool
echo =================================================
echo.

:: ============================================================
:: VARIAVEIS DE AMBIENTE
:: Defina aqui ou exporte antes de rodar o .bat
:: Exemplos:
::   set TFS_URL=https://tfs.mycompany.com/DefaultCollection
::   set TFS_PATH=$/Apps/BackOffice/OrderService
::   set OUTPUT_PATH=C:\migration\order-service
:: ============================================================

:: --- Obrigatorias ---
if "%TFS_URL%"==""      set TFS_URL=https://tfs.mycompany.com/DefaultCollection
if "%TFS_PATH%"==""     set TFS_PATH=$/Apps/BackOffice/OrderService
if "%OUTPUT_PATH%"==""  set OUTPUT_PATH=C:\migration\order-service

:: --- Opcionais ---
:: TFS_USER       -> usuario TFS (DOMINIO\usuario ou email)
:: TFS_PASSWORD   -> senha ou PAT Token
:: AUTHORS_FILE   -> caminho do arquivo authors.txt
:: FROM_CHANGESET -> numero do changeset inicial
:: TO_CHANGESET   -> numero do changeset final
:: RESUME         -> se "true", retoma migracao interrompida
:: DRY_RUN        -> se "true", lista changesets sem executar

:: ============================================================
:: LOCALIZA O SCRIPT .PS1 (mesma pasta do .bat)
:: ============================================================

set "SCRIPT_DIR=%~dp0"
set "PS1_FILE=%SCRIPT_DIR%tfs-to-git.ps1"

if not exist "%PS1_FILE%" (
    echo [ERRO] Arquivo nao encontrado: %PS1_FILE%
    echo Certifique-se de que o tfs-to-git.ps1 esta na mesma pasta que este .bat
    echo.
    pause
    exit /b 1
)

:: ============================================================
:: EXIBE CONFIGURACAO ATUAL
:: ============================================================

echo Configuracao:
echo   TFS_URL      = %TFS_URL%
echo   TFS_PATH     = %TFS_PATH%
echo   OUTPUT_PATH  = %OUTPUT_PATH%

if not "%TFS_USER%"==""       echo   TFS_USER     = %TFS_USER%
if not "%TFS_PASSWORD%"==""   echo   TFS_PASSWORD = ********
if not "%AUTHORS_FILE%"==""   echo   AUTHORS_FILE = %AUTHORS_FILE%
if not "%FROM_CHANGESET%"=="" echo   FROM_CS      = %FROM_CHANGESET%
if not "%TO_CHANGESET%"==""   echo   TO_CS        = %TO_CHANGESET%
if "%RESUME%"=="true"         echo   RESUME       = true
if "%DRY_RUN%"=="true"        echo   DRY_RUN      = true
echo.

:: ============================================================
:: MONTA OS ARGUMENTOS DO POWERSHELL DINAMICAMENTE
:: ============================================================

set PS_ARGS=-TfsUrl "%TFS_URL%" -TfsPath "%TFS_PATH%" -OutputPath "%OUTPUT_PATH%"

if not "%TFS_USER%"==""      set PS_ARGS=%PS_ARGS% -TfsUser "%TFS_USER%"
if not "%TFS_PASSWORD%"==""  set PS_ARGS=%PS_ARGS% -TfsPassword "%TFS_PASSWORD%"
if not "%AUTHORS_FILE%"==""  set PS_ARGS=%PS_ARGS% -AuthorsFile "%AUTHORS_FILE%"
if not "%FROM_CHANGESET%"="" set PS_ARGS=%PS_ARGS% -FromChangeset %FROM_CHANGESET%
if not "%TO_CHANGESET%"==""  set PS_ARGS=%PS_ARGS% -ToChangeset %TO_CHANGESET%
if "%RESUME%"=="true"        set PS_ARGS=%PS_ARGS% -Resume
if "%DRY_RUN%"=="true"       set PS_ARGS=%PS_ARGS% -DryRun

:: ============================================================
:: EXECUTA
:: ============================================================

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1_FILE%" %PS_ARGS%

set EXIT_CODE=%ERRORLEVEL%

echo.
if %EXIT_CODE%==0 (
    echo Concluido com sucesso.
) else (
    echo Encerrado com codigo de erro: %EXIT_CODE%
)

echo.
pause
exit /b %EXIT_CODE%
