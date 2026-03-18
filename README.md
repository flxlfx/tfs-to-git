# tfs-to-git

Migra o histórico completo de um path TFS — inclusive subpastas de branches — para Git,
preservando autores, datas e mensagens de commit originais.

Funciona em **qualquer PowerShell** (não requer o Developer PowerShell do Visual Studio).

---

## O problema que esse script resolve

Se você tentar migrar um projeto TFS com `git tfs clone` e o path **não for um branch raiz**, o resultado será algo como:

```
Fetching from TFS remote 'default'...
C9172 = f9a418609c6f44a5f456b8f71ca202da28071fa6
C9176 = f874309f8c9dd32bb3d5123925e8254bf23afa56
No other Tfs branches found.
```

Dois commits. Fim. Mesmo que o projeto tenha centenas ou milhares de changesets.

### Por que isso acontece?

O `git tfs` foi projetado para trabalhar com a **estrutura de branches do TFS**.
Quando o path é uma subpasta dentro de um branch maior
(ex: `$/Apps/BackOffice/OrderService` dentro de `$/Apps`),
o git-tfs identifica apenas o ponto onde esse path foi registrado como branch e para.

### Como esse script resolve

Usa o `tf.exe` diretamente para iterar **changeset por changeset** pelo path,
sem depender da hierarquia de branches do TFS.

```
tf.exe   →  lista todos os changesets do path (qualquer subpasta)
         →  baixa o snapshot incremental de cada versão
robocopy →  espelha os arquivos no repo local (inclusive arquivos deletados)
git      →  cria um commit por changeset com autor e data originais
```

---

## Pré-requisitos

- Windows com **PowerShell 5.1+**
- **Visual Studio** (qualquer edição, 2017/2019/2022) com o componente **Team Explorer** instalado
- Acesso de leitura ao servidor TFS / Azure DevOps

---

## Instalação

Sem instalação. Basta baixar o script:

```powershell
git clone https://github.com/flxlfx/tfs-to-git.git
```

Permitir execução de scripts locais (se necessário):

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

---

## Casos de uso

### Caso 1 — Migração simples, autenticação automática

**Quando usar:** máquina já autenticada no TFS (Developer PowerShell do VS ou credenciais do Windows salvas).

```powershell
.\tfs-to-git.ps1 `
  -TfsUrl     "https://tfs.mycompany.com/DefaultCollection" `
  -TfsPath    "$/Apps/BackOffice/OrderService" `
  -OutputPath "C:\migration\order-service"
```

O script testa a conexão. Se estiver autenticado, começa imediatamente. Se não estiver, pede usuário e senha no terminal.

---

### Caso 2 — Antes de migrar: validar sem executar nada (`-DryRun`)

**Quando usar:** primeira vez que você roda o script em um projeto. Confirma que o path está correto, quantos changesets existem e quem são os autores — sem criar nenhum arquivo ou commit.

```powershell
.\tfs-to-git.ps1 `
  -TfsUrl     "https://tfs.mycompany.com/DefaultCollection" `
  -TfsPath    "$/Apps/BackOffice/OrderService" `
  -OutputPath "C:\migration\order-service" `
  -DryRun
```

Saída esperada:

```
Changesets que seriam migrados:
  C3201    jdoe                 3/10/2019 9:00:00    Initial commit
  C3205    asmith               3/11/2019 14:22:11   Add base project structure
  C3218    jdoe                 3/14/2019 10:05:33   Configure CI pipeline
  ...

Nenhuma alteracao realizada (dry-run).
```

Use o dry-run para:
- Confirmar que o `-TfsPath` está correto
- Ver o total de changesets e estimar o tempo (veja tabela de tempo abaixo)
- Descobrir os nomes exatos dos usuários TFS para montar o `authors.txt`

---

### Caso 3 — Autenticação com usuário de domínio

**Quando usar:** rede corporativa com Active Directory. Você sabe o usuário e senha do domínio.

```powershell
.\tfs-to-git.ps1 `
  -TfsUrl      "https://tfs.mycompany.com/DefaultCollection" `
  -TfsPath     "$/Apps/BackOffice/OrderService" `
  -OutputPath  "C:\migration\order-service" `
  -TfsUser     "CORP\john.doe" `
  -TfsPassword "minha-senha"
```

---

### Caso 4 — Autenticação com PAT Token (Azure DevOps)

**Quando usar:** Azure DevOps na nuvem (`dev.azure.com`), ou quando a senha de domínio não funciona.

Gere o token em: **Azure DevOps → User Settings → Personal Access Tokens → New Token**
Permissões mínimas: `Code (Read)` + `Work Items (Read)`

```powershell
.\tfs-to-git.ps1 `
  -TfsUrl      "https://myorg.visualstudio.com/DefaultCollection" `
  -TfsPath     "$/Apps/BackOffice/OrderService" `
  -OutputPath  "C:\migration\order-service" `
  -TfsUser     "john.doe@mycompany.com" `
  -TfsPassword "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

---

### Caso 5 — Migração com mapeamento de autores

**Quando usar:** o TFS usa logins curtos (`jdoe`, `CORP\jdoe`) e você quer que o Git tenha nomes e emails reais. Sem isso, os commits ficam com `jdoe@unknown.com`.

**Passo 1:** rode o dry-run (Caso 2) e anote os nomes que aparecem na coluna `User`.

**Passo 2:** crie o arquivo `authors.txt`:

```
# nome_no_tfs = Nome Completo <email@empresa.com>
jdoe         = John Doe       <john.doe@mycompany.com>
asmith       = Alice Smith    <alice.smith@mycompany.com>
rjohnson     = Robert Johnson <robert.johnson@mycompany.com>
CORP\mwilliams = Mary Williams <mary.williams@mycompany.com>
```

> O valor à esquerda do `=` deve ser **exatamente** o que aparece no campo `User` do TFS.

**Passo 3:** rode a migração com `-AuthorsFile`:

```powershell
.\tfs-to-git.ps1 `
  -TfsUrl      "https://tfs.mycompany.com/DefaultCollection" `
  -TfsPath     "$/Apps/BackOffice/OrderService" `
  -OutputPath  "C:\migration\order-service" `
  -AuthorsFile "C:\migration\authors.txt"
```

---

### Caso 6 — Migrar apenas um intervalo de changesets

**Quando usar:** você quer trazer só o histórico a partir de uma data específica, ou testar com um subconjunto pequeno antes de rodar tudo.

Primeiro, descubra o número do changeset inicial:

```powershell
tf history "$/Apps/BackOffice/OrderService" `
  /recursive /sort:ascending /noprompt `
  /collection:https://tfs.mycompany.com/DefaultCollection `
  /format:brief | Select-Object -First 10
```

Saída:

```
Changeset  User          Date        Comment
---------  ------------  ----------  -----------------------
3201       jdoe          3/10/2019   Initial commit
3205       asmith        3/11/2019   Add base project structure
3218       jdoe          3/14/2019   Configure CI pipeline
```

Depois rode com `-FromChangeset` e/ou `-ToChangeset`:

```powershell
# Apenas a partir do C3201
.\tfs-to-git.ps1 `
  -TfsUrl        "https://tfs.mycompany.com/DefaultCollection" `
  -TfsPath       "$/Apps/BackOffice/OrderService" `
  -OutputPath    "C:\migration\order-service" `
  -FromChangeset 3201

# Apenas até o C4000 (útil para testar)
.\tfs-to-git.ps1 `
  -TfsUrl      "https://tfs.mycompany.com/DefaultCollection" `
  -TfsPath     "$/Apps/BackOffice/OrderService" `
  -OutputPath  "C:\migration\order-service-test" `
  -ToChangeset 4000

# Intervalo fechado
.\tfs-to-git.ps1 `
  -TfsUrl        "https://tfs.mycompany.com/DefaultCollection" `
  -TfsPath       "$/Apps/BackOffice/OrderService" `
  -OutputPath    "C:\migration\order-service" `
  -FromChangeset 3201 `
  -ToChangeset   5000
```

---

### Caso 7 — Retomar uma migração interrompida (`-Resume`)

**Quando usar:** o script foi interrompido por queda de rede, energia ou `Ctrl+C`. O repositório Git já existe parcialmente na pasta de destino.

```powershell
.\tfs-to-git.ps1 `
  -TfsUrl     "https://tfs.mycompany.com/DefaultCollection" `
  -TfsPath    "$/Apps/BackOffice/OrderService" `
  -OutputPath "C:\migration\order-service" `
  -Resume
```

O arquivo `.tfs-migration-progress` dentro de `OutputPath` guarda o último changeset processado com sucesso. O script pula tudo que já foi feito e continua de onde parou.

> Se a migração terminar sem erros, esse arquivo é apagado automaticamente.

---

### Caso 8 — Migração completa, produção

**Quando usar:** migração definitiva para o GitHub/GitLab/Azure DevOps Git, com todos os recursos combinados.

```powershell
# 1. Dry-run para validar
.\tfs-to-git.ps1 `
  -TfsUrl      "https://tfs.mycompany.com/DefaultCollection" `
  -TfsPath     "$/Apps/BackOffice/OrderService" `
  -OutputPath  "C:\migration\order-service" `
  -TfsUser     "CORP\john.doe" `
  -TfsPassword "minha-senha" `
  -AuthorsFile "C:\migration\authors.txt" `
  -DryRun

# 2. Migração real
.\tfs-to-git.ps1 `
  -TfsUrl        "https://tfs.mycompany.com/DefaultCollection" `
  -TfsPath       "$/Apps/BackOffice/OrderService" `
  -OutputPath    "C:\migration\order-service" `
  -TfsUser       "CORP\john.doe" `
  -TfsPassword   "minha-senha" `
  -AuthorsFile   "C:\migration\authors.txt" `
  -FromChangeset 3201

# 3. Push para o remoto
cd C:\migration\order-service
git log --oneline | Measure-Object          # confirma total de commits
git log --pretty="%an <%ae>" | Sort -Unique # confirma autores

git remote add origin https://github.com/flxlfx/order-service.git
git push origin master --force
```

---

### Caso 9 — Usando o `.bat` (sem abrir PowerShell)

**Quando usar:** máquina de outra pessoa ou ambiente onde abrir PowerShell é inconveniente. Basta editar as variáveis no topo do `.bat` e dar duplo clique.

Edite `tfs-to-git.bat` definindo as variáveis antes de rodar:

```bat
set TFS_URL=https://tfs.mycompany.com/DefaultCollection
set TFS_PATH=$/Apps/BackOffice/OrderService
set OUTPUT_PATH=C:\migration\order-service
set TFS_USER=CORP\john.doe
set TFS_PASSWORD=minha-senha
set AUTHORS_FILE=C:\migration\authors.txt
set FROM_CHANGESET=3201
```

Ou exporte as variáveis no `cmd` antes de chamar o `.bat`:

```bat
set TFS_URL=https://tfs.mycompany.com/DefaultCollection
set TFS_PATH=$/Apps/BackOffice/OrderService
set OUTPUT_PATH=C:\migration\order-service
tfs-to-git.bat
```

Para dry-run via `.bat`:

```bat
set DRY_RUN=true
tfs-to-git.bat
```

Para retomar via `.bat`:

```bat
set RESUME=true
tfs-to-git.bat
```

---

## Parâmetros

| Parâmetro | Obrigatório | Descrição |
|---|---|---|
| `-TfsUrl` | ✅ | URL do servidor TFS ou Azure DevOps |
| `-TfsPath` | ✅ | Caminho do projeto no TFS |
| `-OutputPath` | ✅ | Pasta de destino do repositório Git |
| `-TfExe` | ❌ | Caminho do TF.exe (detectado automaticamente se omitido) |
| `-AuthorsFile` | ❌ | Arquivo de mapeamento de autores |
| `-TfsUser` | ❌ | Usuário TFS (pedido interativamente se necessário) |
| `-TfsPassword` | ❌ | Senha ou PAT Token |
| `-FromChangeset` | ❌ | Changeset inicial (padrão: mais antigo) |
| `-ToChangeset` | ❌ | Changeset final (padrão: mais recente) |
| `-Resume` | ❌ | Retoma uma migração anterior interrompida |
| `-DryRun` | ❌ | Lista os changesets sem executar nada |

---

## Arquivos gerados pelo script

| Arquivo | Descrição |
|---|---|
| `migration.log` | Log completo com timestamp de cada operação |
| `.tfs-migration-progress` | Último changeset processado com sucesso (usado pelo `-Resume`). Removido automaticamente ao final sem erros. |

---

## Tempo estimado

| Changesets | Tempo aproximado |
|---|---|
| ~100 | 5–15 minutos |
| ~500 | 1–2 horas |
| ~1.000 | 2–4 horas |
| ~5.000 | 1–2 dias |

O tempo varia conforme velocidade da rede e tamanho dos arquivos. Para históricos grandes, deixe o script rodando em segundo plano.

---

## Corrigindo autores após a migração com git-filter-repo

Use esse fluxo quando a migração já foi feita mas os autores ficaram errados
(emails `@unknown.com`, nomes de login curtos, etc.) e você precisa reescrever
o histórico sem refazer tudo do zero.

### Instalação do git-filter-repo

```bash
pip install git-filter-repo
```

> Requer Python 3.x. Verifique com `git filter-repo --version`.

---

### Caso A — Trocar um email específico

```bash
git filter-repo \
  --email-callback 'return email.replace(b"jdoe@unknown.com", b"john.doe@mycompany.com")'
```

---

### Caso B — Trocar vários emails de uma vez com um arquivo de mapeamento

Crie o arquivo `mailmap.txt` (um mapeamento por linha):

```
john.doe@mycompany.com <jdoe@unknown.com>
alice.smith@mycompany.com <asmith@unknown.com>
robert.johnson@mycompany.com <rjohnson@unknown.com>
mary.williams@mycompany.com <CORP\mwilliams@unknown.com>
```

Aplique:

```bash
git filter-repo --mailmap mailmap.txt
```

---

### Caso C — Trocar nome e email ao mesmo tempo

```bash
git filter-repo \
  --name-callback  'return name.replace(b"jdoe", b"John Doe")' \
  --email-callback 'return email.replace(b"jdoe@unknown.com", b"john.doe@mycompany.com")'
```

Ou via `mailmap.txt` com nome e email combinados:

```
John Doe <john.doe@mycompany.com> <jdoe@unknown.com>
Alice Smith <alice.smith@mycompany.com> <asmith@unknown.com>
```

```bash
git filter-repo --mailmap mailmap.txt
```

---

### Caso D — Trocar apenas para commits de um autor específico

```bash
git filter-repo --commit-callback '
if commit.author_email == b"jdoe@unknown.com":
    commit.author_name  = b"John Doe"
    commit.author_email = b"john.doe@mycompany.com"
    commit.committer_name  = b"John Doe"
    commit.committer_email = b"john.doe@mycompany.com"
'
```

---

### Verificando o resultado

```bash
# Lista autores e emails únicos no histórico
git log --pretty="%an <%ae>" | sort -u

# Confirma que não sobrou nenhum @unknown.com
git log --pretty="%ae" | sort -u | grep unknown
```

---

### Fazendo push após reescrita

O `git filter-repo` reescreve os hashes de todos os commits. É necessário force push:

```bash
git remote add origin https://github.com/flxlfx/order-service.git
git push origin master --force
```

> **Atenção:** se outras pessoas já clonaram o repositório, elas precisarão descartar
> a cópia local e clonar novamente — force push reescreve o histórico público.

---

## Quando esse script NÃO é necessário

Se o seu path TFS **é** um branch raiz (ex: `$/OrderService`), o `git tfs clone` padrão funciona:

```powershell
git tfs clone "https://tfs.mycompany.com/DefaultCollection" "$/OrderService" . --branches=all
```

Use este script apenas quando o `git tfs clone` retornar muito poucos commits e exibir `No other TFS branches found`.

---

## Contribuições

PRs são bem-vindos. Áreas de melhoria identificadas:

- Suporte a autenticação via certificado client
- Exportação no formato `git fast-import` (mais rápido para históricos acima de 5.000 changesets)
- Suporte a múltiplos paths em uma única execução

---

## Licença

MIT
