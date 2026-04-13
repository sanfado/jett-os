# Versionamento do Jett OS

## Esquema

O Jett OS usa [Semantic Versioning](https://semver.org/) com sufixos de estágio:

| Versão | Estágio | Significado |
|--------|---------|-------------|
| `v0.x.x-alpha` | Desenvolvimento | Funcionalidades instáveis, API em mudança |
| `v1.0.0-beta`  | Beta | ISO funcional, pronto para testes |
| `v1.0.0`       | Estável | Release de produção |

Exemplos: `v0.3.0-alpha`, `v0.9.0-beta`, `v1.0.0`, `v1.2.3`

## Arquivo de versão instalada

O arquivo `/etc/jett-os/versao.conf` define a versão em execução no sistema:

```bash
# /etc/jett-os/versao.conf
JETT_VERSAO="v0.3.0-alpha"
```

Este arquivo é lido pelo `jett-bridge` (`system version`) e pelo `jett-updater`
para comparar com a versão mais recente disponível no GitHub.

## Publicar uma nova release (GitHub)

Para que o `jett-updater` detecte a atualização automaticamente:

1. Atualizar `JETT_VERSAO` em `versao.conf` no repositório
2. Criar a tag no git:
   ```bash
   git tag -a v0.4.0-alpha -m "Jett OS v0.4.0-alpha"
   git push origin v0.4.0-alpha
   ```
3. Criar a release no GitHub com o mesmo `tag_name`:
   - Acessar **Releases > Draft a new release**
   - Selecionar a tag criada
   - Preencher título e notas
   - Publicar

O `jett-updater` usa a API `GET /repos/sanfado/jett-os/releases/latest`
e compara o campo `tag_name` com `JETT_VERSAO` do sistema instalado.

## Lógica de detecção de atualização

O daemon `jett-updater.sh` verifica dois tipos de atualização:

### 1. Pacotes Debian
```bash
apt-get update -qq
apt list --upgradable 2>/dev/null | grep -vc '^Listing\.\.\.'
```
Qualquer pacote atualizável resulta em `"debian": N` (N > 0) no JSON de status.

### 2. Nova versão do Jett OS
```bash
curl https://api.github.com/repos/sanfado/jett-os/releases/latest
# Extrai tag_name e compara com JETT_VERSAO de /etc/jett-os/versao.conf
```
Se `tag_name != JETT_VERSAO` (qualquer diferença), `"jett_os": true` no JSON.

### Arquivo de status
O arquivo `/tmp/jett-updates-available.json` é escrito atomicamente a cada 6h:

```json
{
  "debian": 3,
  "jett_os": true,
  "jett_versao_atual": "v0.3.0-alpha",
  "jett_versao_nova": "v0.4.0-alpha",
  "timestamp": 1736000000
}
```

## Cadeia de notificação

```
jett-updater.sh (6h loop)
  └─→ escreve /tmp/jett-updates-available.json
  └─→ POST /api/updates/notify  →  jett-ui-server.py (confirma)
        ↕
  GET /api/updates/status  ←  nav.html (polling 60s)
        ↓ d.debian > 0 || d.jett_os
  #dot-update visível (ponto laranja no ⚙)
        ↓ usuário clica ⚙
  POST /api/window/open { url: "http://127.0.0.1:1312/menu#sistema" }
        ↓
  menu.html carrega, hash === '#sistema'
  → scrollIntoView(#secao-sistema) + animação piscar-atencao (2.5s)
```
