<#
.SYNOPSIS
    Migra historico completo de um path TFS (inclusive subpastas de branches) para Git.

.DESCRIPTION
    git tfs clone so funciona quando o path TFS e um branch raiz.
    Se seu projeto vive em $/Org/Area/MeuProjeto dentro de um branch maior,
    o git-tfs retorna poucos commits e para com "No other TFS branches found".

    Esse script contorna isso usando tf.exe diretamente para iterar
    changeset por changeset, independente da estrutura de branches TFS.

    Pode ser executado em qualquer PowerShell (nao requer Developer PowerShell do VS).
    Se nenhuma credencial for passada, o script testa a conexao e pede
    usuario/senha interativamente se necessario.

.PARAMETER TfsUrl
    URL do servidor TFS/Azure DevOps.
    Exemplo: "https://hq-tfs01.empresa.com/PlatformCollection"

.PARAMETER TfsPath
    Caminho do projeto no TFS.
    Exemplo: "$/Websites/SelfService/SettingsConfiguration"

.PARAMETER OutputPath
    Pasta onde o repositorio Git sera criado.
    Exemplo: "C:\backup\meu-repo"

.PARAMETER TfExe
    Caminho completo do TF.exe. Se omitido, o script tenta localizar automaticamente.

.PARAMETER AuthorsFile
    Caminho para arquivo de mapeamento de autores (opcional).
    Formato de cada linha: nometfs = Nome Completo <email@empresa.com>

.PARAMETER TfsUser
    Usuario para autenticacao no TFS (opcional).
    Formato: DOMINIO\usuario  ou  email@empresa.com
    Se omitido, o script testa sem credenciais primeiro e pede interativamente se necessario.

.PARAMETER TfsPassword
    Senha ou PAT Token (opcional).
    Se -TfsUser for informado e este for omitido, o script pedira interativamente.

.PARAMETER FromChangeset
    Numero do changeset inicial (opcional). Se omitido, busca o mais antigo automaticamente.

.PARAMETER ToChangeset
    Numero do changeset final (opcional). Se omitido, vai ate o mais recente.

.PARAMETER Resume
    Se informado, retoma uma migracao anterior interrompida.

.PARAMETER DryRun
    Lista os changesets que seriam migrados sem executar nenhuma alteracao.

.EXAMPLE
    # Uso basico - autentica automaticamente ou pede credenciais se necessario
    .\tfs-to-git.ps1 `
        -TfsUrl     "https://hq-tfs01.empresa.com/PlatformCollection" `
        -TfsPath    "$/Websites/SelfService/SettingsConfiguration" `
        -OutputPath "C:\backup\meu-repo"

.EXAMPLE
    # Com credenciais, arquivo de autores e changeset inicial
    .\tfs-to-git.ps1 `
        -TfsUrl        "https://hq-tfs01.empresa.com/PlatformCollection" `
        -TfsPath       "$/Websites/SelfService/SettingsConfiguration" `
        -OutputPath    "C:\backup\meu-repo" `
        -TfsUser       "DOMINIO\meu.usuario" `
        -AuthorsFile   "C:\backup\authors.txt" `
        -FromChangeset 9172

.EXAMPLE
    # Retomando migracao interrompida
    .\tfs-to-git.ps1 `
        -TfsUrl     "https://hq-tfs01.empresa.com/PlatformCollection" `
        -TfsPath    "$/Websites/SelfService/SettingsConfiguration" `
        -OutputPath "C:\backup\meu-repo" `
        -Resume

.EXAMPLE
    # Dry-run: lista changesets sem executar
    .\tfs-to-git.ps1 `
        -TfsUrl     "https://hq-tfs01.empresa.com/PlatformCollection" `
        -TfsPath    "$/Websites/SelfService/SettingsConfiguration" `
        -OutputPath "C:\backup\meu-repo" `
        -DryRun
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true,  HelpMessage = "URL do servidor TFS")]
    [string]$TfsUrl,

    [Parameter(Mandatory = $true,  HelpMessage = "Caminho do projeto no TFS")]
    [string]$TfsPath,

    [Parameter(Mandatory = $true,  HelpMessage = "Pasta de destino do repositorio Git")]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [string]$TfExe = "",

    [Parameter(Mandatory = $false, HelpMessage = "Arquivo de mapeamento: nometfs = Nome <email>")]
    [string]$AuthorsFile = "",

    [Parameter(Mandatory = $false, HelpMessage = "Usuario TFS: DOMINIO\\usuario ou email")]
    [string]$TfsUser = "",

    [Parameter(Mandatory = $false, HelpMessage = "Senha ou PAT Token")]
    [string]$TfsPassword = "",

    [Parameter(Mandatory = $false, HelpMessage = "Changeset inicial (0 = automatico)")]
    [int]$FromChangeset = 0,

    [Parameter(Mandatory = $false, HelpMessage = "Changeset final (0 = mais recente)")]
    [int]$ToChangeset = 0,

    [Parameter(Mandatory = $false, HelpMessage = "Retoma migracao anterior interrompida")]
    [switch]$Resume,

    [Parameter(Mandatory = $false, HelpMessage = "Lista changesets sem executar a migracao")]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# VARIAVEIS DE ESCOPO DO SCRIPT
# ============================================================
$script:LogFile     = $null
$script:TfExe       = $TfExe
$script:TfsUser     = $TfsUser
$script:TfsPassword = $TfsPassword

# ============================================================
# FUNCOES AUXILIARES
# ============================================================

function Write-Log {
    param([string]$Message, [string]$Color = "White", [switch]$NoFile)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line      = "[$timestamp] $Message"
    Write-Host $line -ForegroundColor $Color
    if (-not $NoFile -and $script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -ErrorAction SilentlyContinue
    }
}

function Find-TfExe {
    $candidates = @(
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe",
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe",
        "C:\Program Files (x86)\Microsoft Visual Studio\2017\Enterprise\Common7\IDE\TF.exe",
        "C:\Program Files (x86)\Microsoft Visual Studio\2017\Professional\Common7\IDE\TF.exe",
        "C:\Program Files (x86)\Microsoft Visual Studio 14.0\Common7\IDE\TF.exe"
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    $fromPath = Get-Command tf.exe -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }
    throw "TF.exe nao encontrado. Instale o Visual Studio com o componente 'Team Explorer'."
}

function Invoke-Tf {
    param([string[]]$Arguments)
    if ($script:TfsUser -ne "") {
        return & $script:TfExe @Arguments "/login:$($script:TfsUser),$($script:TfsPassword)" 2>&1
    }
    return & $script:TfExe @Arguments 2>&1
}

function Test-TfsAuth {
    param([string]$ServerUrl)
    $output = Invoke-Tf @("workspaces", "/server:$ServerUrl", "/noprompt")
    $str    = ($output | Out-String)
    return -not ($str -match "TF30063|not authorized|unauthorized|Access Denied")
}

function Request-TfsCredentials {
    param([string]$ServerUrl)

    Write-Host ""
    Write-Log "Autenticacao necessaria para: $ServerUrl" "Yellow" -NoFile
    Write-Host ""
    Write-Host "  Opcao 1 - Usuario de dominio : DOMINIO\usuario" -ForegroundColor Gray
    Write-Host "  Opcao 2 - Email              : usuario@empresa.com" -ForegroundColor Gray
    Write-Host "  Opcao 3 - PAT Token          : deixe usuario em branco, cole o token como senha" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Como gerar PAT Token no Azure DevOps:" -ForegroundColor Gray
    Write-Host "  User Settings -> Personal Access Tokens -> New Token" -ForegroundColor Gray
    Write-Host "  Permissoes: Code (Read) + Work Items (Read)" -ForegroundColor Gray
    Write-Host ""

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $script:TfsUser = Read-Host "Usuario TFS (tentativa $attempt/3)"
        $securePwd      = Read-Host "Senha ou PAT Token" -AsSecureString
        $script:TfsPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                  [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))

        Write-Log "Validando credenciais..." "Cyan"

        if (Test-TfsAuth -ServerUrl $ServerUrl) {
            Write-Log "Autenticado com sucesso: $($script:TfsUser)" "Green"
            return $true
        }

        Write-Log "Credenciais invalidas ou sem permissao." "Red"
        if ($attempt -lt 3) { Write-Host "" }
    }

    return $false
}

function Read-AuthorsFile {
    param([string]$Path)
    $map = @{}
    if (-not $Path -or -not (Test-Path $Path)) { return $map }
    foreach ($line in Get-Content $Path) {
        $line = $line.ToString().Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { continue }
        if ($line -match "^(.+?)\s*=\s*(.+?)\s*<(.+?)>") {
            $map[$matches[1].Trim()] = @{ Name = $matches[2].Trim(); Email = $matches[3].Trim() }
        }
    }
    return $map
}

function Resolve-Author {
    param([string]$RawName, [hashtable]$AuthorsMap)
    if ($AuthorsMap.ContainsKey($RawName)) { return $AuthorsMap[$RawName] }
    $email = ($RawName.ToLower() -replace "[^a-z0-9]", ".") -replace "\.{2,}", "."
    $email = $email.Trim(".") + "@unknown.com"
    return @{ Name = $RawName; Email = $email }
}

# Converte data no formato TFS (locale-dependente) para ISO 8601 aceito pelo Git.
# Retorna string vazia se nao conseguir converter — Git usara data atual nesse caso.
function Convert-TfsDateToGit {
    param([string]$DateStr)
    if (-not $DateStr) { return "" }

    $cultures = @(
        [System.Globalization.CultureInfo]::CurrentCulture,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.CultureInfo]::new("en-US"),
        [System.Globalization.CultureInfo]::new("pt-BR")
    )
    foreach ($culture in $cultures) {
        try {
            $dt = [datetime]::Parse($DateStr, $culture)
            return $dt.ToString("yyyy-MM-ddTHH:mm:ss")
        } catch { }
    }

    Write-Log "AVISO: formato de data desconhecido '$DateStr' — data atual sera usada no commit." "Yellow"
    return ""
}

function Get-TfsHistory {
    param([string]$ServerUrl, [string]$ServerPath, [int]$From, [int]$To)

    Write-Log "Consultando historico TFS (pode levar alguns minutos)..." "Cyan"

    $tfArgs = @(
        "history", $ServerPath,
        "/recursive", "/sort:ascending",
        "/noprompt", "/server:$ServerUrl",
        "/format:detailed"
    )
    if ($From -gt 0 -and $To -gt 0) { $tfArgs += "/version:C$From~C$To" }
    elseif ($From -gt 0)            { $tfArgs += "/version:C$From~T"    }
    elseif ($To   -gt 0)            { $tfArgs += "/version:C1~C$To"     }

    $output     = Invoke-Tf $tfArgs
    $changesets = @()
    $current    = $null
    $inComment  = $false

    foreach ($line in $output) {
        $trimmed = $line.ToString().Trim()

        if ($trimmed -match "^Changeset:\s+(\d+)") {
            if ($null -ne $current) { $changesets += $current }
            $current   = @{ CS = [int]$matches[1]; User = "Unknown"; Date = ""; Comment = "" }
            $inComment = $false
            continue
        }
        if ($null -eq $current) { continue }

        if ($trimmed -match "^User:\s+(.+)")            { $current.User = $matches[1].Trim(); $inComment = $false; continue }
        if ($trimmed -match "^Date:\s+(.+)")            { $current.Date = $matches[1].Trim(); $inComment = $false; continue }
        if ($trimmed -eq "Comment:")                    { $inComment = $true;  continue }
        if ($trimmed -match "^Items:|^Check-in Notes:") { $inComment = $false; continue }

        if ($inComment -and $trimmed -ne "") {
            $current.Comment += if ($current.Comment -ne "") { " $trimmed" } else { $trimmed }
        }
    }

    if ($null -ne $current) { $changesets += $current }
    return $changesets
}

# ============================================================
# INICIO
# ============================================================

Write-Host ""
Write-Host "=================================================" -ForegroundColor Magenta
Write-Host "         TFS -> Git Migration Tool              " -ForegroundColor Magenta
Write-Host "=================================================" -ForegroundColor Magenta
if ($DryRun) {
    Write-Host "              [ MODO DRY-RUN ]                  " -ForegroundColor Yellow
}
Write-Host ""

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$script:LogFile = Join-Path $OutputPath "migration.log"
$ProgressFile   = Join-Path $OutputPath ".tfs-migration-progress"
$TempMap        = Join-Path $env:TEMP ("tfs_mig_" + [System.Guid]::NewGuid().ToString("N").Substring(0, 12))

# --- Localiza TF.exe ---
if ($script:TfExe -eq "" -or -not (Test-Path $script:TfExe)) {
    Write-Log "Localizando TF.exe automaticamente..." "Cyan"
    $script:TfExe = Find-TfExe
}
Write-Log "TF.exe: $($script:TfExe)" "Gray"

# ============================================================
# AUTENTICACAO
# ============================================================

Write-Log "Testando conexao com $TfsUrl ..." "Cyan"

$authenticated = Test-TfsAuth -ServerUrl $TfsUrl

if (-not $authenticated) {
    if ($script:TfsUser -ne "") {
        Write-Log "Credenciais informadas invalidas. Solicitando novamente." "Red"
        $script:TfsUser     = ""
        $script:TfsPassword = ""
    }
    $authenticated = Request-TfsCredentials -ServerUrl $TfsUrl
    if (-not $authenticated) {
        Write-Log "ERRO FATAL: Nao foi possivel autenticar apos 3 tentativas. Encerrando." "Red"
        exit 1
    }
} else {
    Write-Log "Conexao OK." "Green"
}

# ============================================================
# AUTORES
# ============================================================

$AuthorsMap = Read-AuthorsFile -Path $AuthorsFile
if ($AuthorsMap.Count -gt 0) {
    Write-Log "Autores mapeados via arquivo: $($AuthorsMap.Count)" "Gray"
} else {
    Write-Log "Sem arquivo de autores — emails gerados automaticamente a partir dos nomes TFS." "Yellow"
}

# ============================================================
# INICIALIZA GIT
# ============================================================

Set-Location $OutputPath

if ($Resume -and (Test-Path (Join-Path $OutputPath ".git"))) {
    Write-Log "Modo RESUME ativado." "Yellow"
} elseif (-not $DryRun) {
    if (Test-Path (Join-Path $OutputPath ".git")) {
        Write-Log "ERRO: Ja existe um repositorio Git em $OutputPath" "Red"
        Write-Log "Use -Resume para continuar ou escolha outra pasta." "Yellow"
        exit 1
    }
    Write-Log "Inicializando repositorio Git..." "Cyan"
    git init | Out-Null
    git commit --allow-empty -m "chore: init repository" | Out-Null
}

# ============================================================
# BUSCA CHANGESETS
# ============================================================

$changesets = Get-TfsHistory -ServerUrl $TfsUrl -ServerPath $TfsPath `
                             -From $FromChangeset -To $ToChangeset

if ($changesets.Count -eq 0) {
    Write-Log "ERRO: Nenhum changeset encontrado. Verifique o TfsPath e as permissoes." "Red"
    exit 1
}
Write-Log "Total de changesets encontrados: $($changesets.Count)" "Green"

# --- Dry-run: apenas exibe e sai ---
if ($DryRun) {
    Write-Host ""
    Write-Host "Changesets que seriam migrados:" -ForegroundColor Yellow
    foreach ($cs in $changesets) {
        $preview = if ($cs.Comment -ne "") { $cs.Comment } else { "(sem comentario)" }
        Write-Host ("  C{0,-8} {1,-20} {2,-22} {3}" -f $cs.CS, $cs.User, $cs.Date, $preview) -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "Nenhuma alteracao realizada (dry-run)." -ForegroundColor Yellow
    exit 0
}

# ============================================================
# RESUME
# ============================================================

$lastDoneCS = 0
if ($Resume -and (Test-Path $ProgressFile)) {
    $lastDoneCS = [int](Get-Content $ProgressFile -Raw).Trim()
    Write-Log "Ultimo changeset ja processado: C$lastDoneCS" "Yellow"
}

# ============================================================
# WORKSPACE TFS + LOOP PRINCIPAL
# ============================================================

$workspace        = "MigrationWS_" + [System.Guid]::NewGuid().ToString("N").Substring(0, 8)
$workspaceCreated = $false
$total            = $changesets.Count
$i                = 0
$skipped          = 0
$errors           = 0
$done             = 0

New-Item -ItemType Directory -Force -Path $TempMap | Out-Null

Write-Log "Criando workspace TFS temporario: $workspace" "Cyan"

try {
    Invoke-Tf @("workspace", "/new", $workspace, "/server:$TfsUrl", "/noprompt") | Out-Null
    $workspaceCreated = $true
    Invoke-Tf @("workfold", "/map", $TfsPath, $TempMap, "/workspace:$workspace", "/server:$TfsUrl", "/noprompt") | Out-Null

    Write-Log "Iniciando migracao de $total changesets..." "Magenta"

    foreach ($cs in $changesets) {
        $i++
        $csNum   = $cs.CS
        $comment = if ($cs.Comment -ne "") { $cs.Comment } else { "Changeset $csNum" }

        if ($csNum -le $lastDoneCS) {
            $skipped++
            continue
        }

        $author  = Resolve-Author -RawName $cs.User -AuthorsMap $AuthorsMap
        $gitDate = Convert-TfsDateToGit -DateStr $cs.Date
        $percent = [math]::Round(($i / $total) * 100, 1)
        $display = "[$i/$total] C$csNum - $($cs.User) - $comment"

        Write-Progress `
            -Activity        "Migrando TFS para Git ($percent%)" `
            -Status          $display `
            -PercentComplete $percent

        Write-Log $display "Yellow"

        try {
            # Downloads incrementais: sem /overwrite o TFS workspace rastreia versoes
            # e baixa apenas o delta entre o changeset anterior e o atual.
            Invoke-Tf @("get", $TempMap, "/version:C$csNum", "/recursive", "/noprompt") | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "tf get retornou exit code $LASTEXITCODE para C$csNum"
            }

            # /MIR propaga deletes; exit codes 0-7 sao sucesso no robocopy
            $null = robocopy $TempMap $OutputPath /MIR /XD ".git" /XF "*.vspscc" "*.vssscc" `
                             /NFL /NDL /NJH /NJS /nc /ns /np
            if ($LASTEXITCODE -ge 8) {
                throw "robocopy falhou (exit code $LASTEXITCODE) no changeset C$csNum"
            }

            Set-Location $OutputPath
            git add -A 2>&1 | Out-Null

            $env:GIT_AUTHOR_NAME     = $author.Name
            $env:GIT_AUTHOR_EMAIL    = $author.Email
            $env:GIT_COMMITTER_NAME  = $author.Name
            $env:GIT_COMMITTER_EMAIL = $author.Email
            if ($gitDate) {
                $env:GIT_AUTHOR_DATE    = $gitDate
                $env:GIT_COMMITTER_DATE = $gitDate
            }

            $commitMsg = "C${csNum}: $comment"
            git commit -m $commitMsg --allow-empty 2>&1 | Out-Null

            $csNum | Set-Content $ProgressFile
            $done++
            Write-Log "  -> OK: $commitMsg" "Green"

        } catch {
            $errors++
            Write-Log "  -> ERRO em C${csNum}: $_" "Red"
            Write-Log "     Continuando com o proximo changeset..." "Yellow"
        } finally {
            # Limpa env vars apos cada commit para nao contaminar iteracoes seguintes
            Remove-Item Env:GIT_AUTHOR_NAME     -ErrorAction SilentlyContinue
            Remove-Item Env:GIT_AUTHOR_EMAIL    -ErrorAction SilentlyContinue
            Remove-Item Env:GIT_AUTHOR_DATE     -ErrorAction SilentlyContinue
            Remove-Item Env:GIT_COMMITTER_NAME  -ErrorAction SilentlyContinue
            Remove-Item Env:GIT_COMMITTER_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:GIT_COMMITTER_DATE  -ErrorAction SilentlyContinue
        }
    }

} finally {
    Write-Progress -Activity "Migrando TFS para Git" -Completed

    if ($workspaceCreated) {
        Write-Log "Limpando workspace TFS..." "Cyan"
        try { Invoke-Tf @("workfold", "/unmap", $TempMap, "/workspace:$workspace", "/server:$TfsUrl", "/noprompt") | Out-Null } catch {}
        try { Invoke-Tf @("workspace", "/delete", $workspace, "/server:$TfsUrl", "/noprompt") | Out-Null } catch {}
    }
    if (Test-Path $TempMap) { Remove-Item -Recurse -Force $TempMap -ErrorAction SilentlyContinue }

    # Garantia extra caso o loop tenha abortado antes do inner finally
    Remove-Item Env:GIT_AUTHOR_NAME     -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_AUTHOR_EMAIL    -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_AUTHOR_DATE     -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_COMMITTER_NAME  -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_COMMITTER_EMAIL -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_COMMITTER_DATE  -ErrorAction SilentlyContinue
}

# ============================================================
# RELATORIO FINAL
# ============================================================

Set-Location $OutputPath
$totalCommits = (git log --oneline | Measure-Object).Count
$authors      = git log --pretty="%an <%ae>" | Sort-Object -Unique

if ($errors -eq 0 -and (Test-Path $ProgressFile)) {
    Remove-Item $ProgressFile -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=================================================" -ForegroundColor Magenta
Write-Host "           MIGRACAO CONCLUIDA                   " -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Magenta
Write-Log "Changesets encontrados : $total"        "White" -NoFile
Write-Log "Commits criados        : $done"         "Green" -NoFile
Write-Log "Pulados (resume)       : $skipped"      "Gray"  -NoFile
Write-Log "Erros                  : $errors" $(if ($errors -gt 0) { "Red" } else { "Gray" }) -NoFile
Write-Log "Total commits no Git   : $totalCommits" "Cyan"  -NoFile
Write-Host ""
Write-Log "Autores no historico Git:" "White" -NoFile
foreach ($a in $authors) { Write-Host "  $a" -ForegroundColor Cyan }
Write-Host ""
Write-Log "Log completo: $script:LogFile" "Gray" -NoFile
Write-Host ""
Write-Host "Proximos passos:" -ForegroundColor Magenta
Write-Host "  git remote add origin https://github.com/sua-org/seu-repo.git"
Write-Host "  git push origin master --force"
Write-Host ""

if ($errors -gt 0) {
    Write-Host "ATENCAO: $errors changeset(s) com erro. Veja o migration.log para detalhes." -ForegroundColor Red
    Write-Host "         Use -Resume para reprocessar os changesets com falha." -ForegroundColor Yellow
    Write-Host ""
}
