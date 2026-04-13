#!/usr/bin/env bash
# =============================================================================
# install-thorium.sh — Instalação e configuração do Thorium Browser no Jett OS
# =============================================================================
# Descrição:
#   Instala o Thorium Browser (fork do Chromium otimizado para x86_64) via
#   release mais recente do GitHub do projeto Alex313031/Thorium (amd64).
#   Configura o serviço kiosk systemd e registra em navegadores-instalados.conf.
#
# Método de instalação:
#   Diferente de Edge/Brave/Firefox, o Thorium não tem repositório APT próprio.
#   Este script:
#     1. Consulta a API do GitHub para obter a URL do .deb mais recente (amd64)
#     2. Baixa o .deb para /tmp
#     3. Instala via dpkg -i
#     4. Limpa o arquivo temporário
#
# Uso:
#   sudo ./install-thorium.sh [opções]
#
# Opções:
#   --url URL         URL que o Thorium abrirá ao iniciar (padrão: about:blank)
#   --avx             Instala build AVX (mais rápido em CPUs modernas, padrão)
#   --avx2            Instala build AVX2 (requer CPU com suporte a AVX2)
#   --sse4            Instala build SSE4 (máxima compatibilidade)
#   --set-default     Define o Thorium como navegador ativo
#   --help            Exibe esta ajuda
#
# Idempotência:
#   Se o Thorium já estiver instalado na versão mais recente, pula o download.
#   Sempre regenera os arquivos de configuração.
#
# Pré-requisitos:
#   - build-base.sh executado com sucesso
#   - Usuário 'jett' existente
#   - curl e jq (ou python3) disponíveis
#   - Conexão com a internet e acesso ao GitHub
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# VARIÁVEIS GLOBAIS
# -----------------------------------------------------------------------------

USUARIO_JETT="jett"
LOG_ARQUIVO="/var/log/jett-os-build.log"
VERSAO_SCRIPT="1.0.0"
NOME_NAVEGADOR="thorium"
NOME_EXIBICAO="Thorium Browser"

# URL inicial (pode ser sobrescrita por --url)
THORIUM_URL_INICIAL="${THORIUM_URL_INICIAL:-about:blank}"

# Variante de build (avx = padrão para hardware moderno, sse4 = máxima compatibilidade)
# avx: requer suporte a AVX (Intel Sandy Bridge 2011+ / AMD Bulldozer 2011+)
# avx2: requer suporte a AVX2 (Intel Haswell 2013+ / AMD Excavator 2015+)
# sse4: compatibilidade máxima (qualquer x86_64 moderno)
THORIUM_VARIANTE="${THORIUM_VARIANTE:-avx}"

# Define Thorium como padrão ao instalar?
DEFINIR_PADRAO=false

# Diretório raiz do projeto (dois níveis acima: build/browsers/ → raiz)
PROJETO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CONFIG_DIR="${PROJETO_DIR}/config"
CONFIG_JETT="/etc/jett-os"
SERVICO_DESTINO="/etc/systemd/system"

# GitHub API para releases do Thorium
THORIUM_GITHUB_API="https://api.github.com/repos/Alex313031/Thorium/releases/latest"

# Diretório temporário para download
THORIUM_TMP_DIR="/tmp/jett-thorium-install"

# Flags de kiosk e GPU carregadas do perfil técnico centralizado.
# Fonte canônica: config/browsers/thorium.conf (define JETT_THORIUM_FLAGS_STR).
# BUG A fix: inclui --enable-gpu-rasterization, --enable-zero-copy,
# --ignore-gpu-blocklist, --disable-gpu-driver-bug-workarounds e
# --disable-features=UseChromeOSDirectVideoDecoder que estavam ausentes.
PERFIL_CONF="${PROJETO_DIR}/config/browsers/thorium.conf"

# Cores para saída no terminal
COR_RESET="\033[0m"
COR_VERDE="\033[1;32m"
COR_AMARELO="\033[1;33m"
COR_VERMELHO="\033[1;31m"
COR_CIANO="\033[1;36m"
COR_BRANCO="\033[1;37m"

# -----------------------------------------------------------------------------
# FUNÇÕES DE LOG
# -----------------------------------------------------------------------------

inicializar_log() {
    mkdir -p "$(dirname "$LOG_ARQUIVO")"
    {
        echo "-------------------------------------------------------"
        echo "  install-thorium.sh v${VERSAO_SCRIPT} — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "-------------------------------------------------------"
    } >> "$LOG_ARQUIVO"
}

log_etapa() {
    local msg="$1"
    local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_CIANO}[${ts}] >>> ${msg}${COR_RESET}"
    echo "[${ts}] [ETAPA] ${msg}" >> "$LOG_ARQUIVO"
}

log_info() {
    local msg="$1"
    local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_BRANCO}[${ts}]     ${msg}${COR_RESET}"
    echo "[${ts}] [INFO]  ${msg}" >> "$LOG_ARQUIVO"
}

log_ok() {
    local msg="$1"
    local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_VERDE}[${ts}]  ✓  ${msg}${COR_RESET}"
    echo "[${ts}] [OK]    ${msg}" >> "$LOG_ARQUIVO"
}

log_aviso() {
    local msg="$1"
    local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_AMARELO}[${ts}]  !  ${msg}${COR_RESET}"
    echo "[${ts}] [AVISO] ${msg}" >> "$LOG_ARQUIVO"
}

log_erro() {
    local msg="$1"
    local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_VERMELHO}[${ts}]  ✗  ERRO: ${msg}${COR_RESET}" >&2
    echo "[${ts}] [ERRO]  ${msg}" >> "$LOG_ARQUIVO"
    exit 1
}

log_separador() {
    echo -e "${COR_CIANO}─────────────────────────────────────────────────${COR_RESET}"
}

# -----------------------------------------------------------------------------
# FUNÇÕES DE VERIFICAÇÃO
# -----------------------------------------------------------------------------

verificar_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "\033[1;31m[ERRO] Execute como root: sudo ./install-thorium.sh\033[0m" >&2
        exit 1
    fi
}

verificar_base_instalada() {
    if ! id "$USUARIO_JETT" &>/dev/null; then
        log_erro "Usuário '${USUARIO_JETT}' não encontrado. Execute build-base.sh primeiro."
    fi
    log_ok "Pré-requisito verificado: usuário '${USUARIO_JETT}' presente."
}

verificar_dependencias() {
    # Verifica que curl está disponível (necessário para consultar a API do GitHub)
    if ! command -v curl &>/dev/null; then
        log_info "curl não encontrado. Instalando..."
        apt-get install -y -qq curl >> "$LOG_ARQUIVO" 2>&1 \
            || log_erro "Falha ao instalar curl."
    fi
    # jq facilita o parsing do JSON da API do GitHub
    if ! command -v jq &>/dev/null; then
        log_info "jq não encontrado. Instalando (necessário para parsing da API GitHub)..."
        apt-get install -y -qq jq >> "$LOG_ARQUIVO" 2>&1 \
            || log_aviso "jq não disponível — usando fallback com grep/sed."
    fi
    log_ok "Dependências verificadas."
}

verificar_conexao() {
    log_info "Verificando acesso à API do GitHub..."
    if ! curl -sf --max-time 15 "https://api.github.com" -o /dev/null; then
        log_erro "Sem acesso à API do GitHub. Verifique a conexão."
    fi
    log_ok "Acesso ao GitHub confirmado."
}

pacote_instalado() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

versao_thorium() {
    if pacote_instalado "thorium-browser"; then
        thorium-browser --version 2>/dev/null | awk '{print $NF}' || \
        dpkg-query -W -f='${Version}' thorium-browser 2>/dev/null || \
        echo "instalado"
    else
        echo "não instalado"
    fi
}

# -----------------------------------------------------------------------------
# ETAPA 1: Obtém URL do .deb mais recente no GitHub
# -----------------------------------------------------------------------------

obter_url_deb_thorium() {
    log_separador
    log_etapa "ETAPA 1/4 — Obtendo release mais recente do Thorium (GitHub)"

    log_info "Consultando API do GitHub: Alex313031/Thorium..."
    local release_json
    release_json="$(curl -fsSL --max-time 30 "$THORIUM_GITHUB_API" 2>> "$LOG_ARQUIVO")" \
        || log_erro "Falha ao consultar API do GitHub. Verifique a conexão e tente novamente."

    # Extrai a versão do release
    local versao_release=""
    if command -v jq &>/dev/null; then
        versao_release="$(echo "$release_json" | jq -r '.tag_name' 2>/dev/null || true)"
        versao_release="${versao_release#v}"  # Remove prefixo 'v' se houver
    else
        versao_release="$(echo "$release_json" | grep '"tag_name"' | sed 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/')"
    fi
    log_info "Versão mais recente do Thorium no GitHub: ${versao_release:-desconhecida}"

    # Verifica se a versão já está instalada (idempotência de versão)
    local versao_instalada
    versao_instalada="$(versao_thorium)"
    if [[ "$versao_instalada" != "não instalado" && -n "$versao_release" ]]; then
        # Compara versão instalada com a do release (ignora sufixos de build)
        local versao_instalada_limpa="${versao_instalada%%~*}"
        if [[ "$versao_instalada_limpa" == *"${versao_release}"* || \
              "$versao_release" == *"${versao_instalada_limpa}"* ]]; then
            log_ok "Thorium já está na versão mais recente (${versao_instalada}). Pulando download."
            # Mesmo sem baixar, continuamos para regenerar os arquivos de configuração
            THORIUM_DEB_URL=""
            return 0
        fi
    fi

    # Determina o padrão de busca baseado na variante escolhida
    local padrao_busca
    case "$THORIUM_VARIANTE" in
        avx2)
            # Build AVX2: arquivos nomeados com _AVX2_amd64.deb
            padrao_busca="_AVX2_amd64\.deb"
            log_info "Variante selecionada: AVX2 (requer CPU Intel Haswell 2013+ / AMD Excavator 2015+)"
            ;;
        sse4)
            # Build SSE4: máxima compatibilidade, arquivos sem sufixo AVX
            padrao_busca="_SSE4_amd64\.deb"
            # Se não houver SSE4 explícito, usa o padrão sem sufixo
            log_info "Variante selecionada: SSE4 (máxima compatibilidade x86_64)"
            ;;
        avx|*)
            # Build AVX: padrão — bom equilíbrio entre performance e compatibilidade
            # Arquivos nomeados: thorium-browser_X.Y.Z_amd64.deb (sem sufixo de variante)
            # OU thorium-browser_X.Y.Z_AVX_amd64.deb
            padrao_busca="_amd64\.deb"
            log_info "Variante selecionada: AVX (padrão — Intel Sandy Bridge 2011+ / AMD Bulldozer 2011+)"
            ;;
    esac

    # Extrai URLs de download do JSON
    local todas_urls
    if command -v jq &>/dev/null; then
        todas_urls="$(echo "$release_json" | jq -r '.assets[].browser_download_url' 2>/dev/null || true)"
    else
        todas_urls="$(echo "$release_json" | grep '"browser_download_url"' | cut -d'"' -f4)"
    fi

    if [[ -z "$todas_urls" ]]; then
        log_erro "Nenhuma URL de download encontrada na resposta da API do GitHub."
    fi

    # Filtra para encontrar o .deb correto para a variante escolhida
    THORIUM_DEB_URL=""
    case "$THORIUM_VARIANTE" in
        avx2)
            THORIUM_DEB_URL="$(echo "$todas_urls" | grep -i "_AVX2_amd64\.deb" | head -1 || true)"
            ;;
        sse4)
            THORIUM_DEB_URL="$(echo "$todas_urls" | grep -i "_SSE4_amd64\.deb" | head -1 || true)"
            # Fallback: sem sufixo (versão padrão pode cobrir SSE4)
            if [[ -z "$THORIUM_DEB_URL" ]]; then
                THORIUM_DEB_URL="$(echo "$todas_urls" | grep "_amd64\.deb" | grep -iv "AVX\|ARM\|mac\|win" | head -1 || true)"
            fi
            ;;
        avx|*)
            # Prefere explicitamente _AVX_amd64.deb, cai para _amd64.deb sem sufixo
            THORIUM_DEB_URL="$(echo "$todas_urls" | grep -i "[_-]AVX[_-]amd64\.deb\|[_-]avx[_-]amd64\.deb" | grep -iv "AVX2" | head -1 || true)"
            if [[ -z "$THORIUM_DEB_URL" ]]; then
                # .deb padrão sem sufixo de variante (exclui ARM, AVX2, Windows, macOS)
                THORIUM_DEB_URL="$(echo "$todas_urls" | grep "_amd64\.deb" | grep -iv "AVX2\|ARM\|arm64\|win\|mac\|snap\|rpm" | head -1 || true)"
            fi
            ;;
    esac

    if [[ -z "$THORIUM_DEB_URL" ]]; then
        log_erro "Não foi possível encontrar .deb amd64 (variante: ${THORIUM_VARIANTE}) no release do GitHub."
    fi

    log_ok "URL do .deb encontrada: ${THORIUM_DEB_URL}"
    log_info "Versão a instalar: ${versao_release}"
}

# -----------------------------------------------------------------------------
# ETAPA 2: Baixa e instala o Thorium
# -----------------------------------------------------------------------------

instalar_thorium() {
    log_separador
    log_etapa "ETAPA 2/4 — Instalando Thorium Browser"

    # Se a versão já está instalada (THORIUM_DEB_URL vazio), apenas confirma
    if [[ -z "${THORIUM_DEB_URL:-}" ]]; then
        log_ok "Thorium já está na versão mais recente. Pulando instalação."
        if ! command -v thorium-browser &>/dev/null; then
            log_erro "Thorium não encontrado no PATH apesar de dpkg reportar instalado."
        fi
        log_info "Binário: $(command -v thorium-browser)"
        return 0
    fi

    # Cria diretório temporário para o download
    mkdir -p "$THORIUM_TMP_DIR"
    local deb_filename
    deb_filename="$(basename "$THORIUM_DEB_URL")"
    local deb_path="${THORIUM_TMP_DIR}/${deb_filename}"

    log_info "Baixando ${deb_filename}..."
    log_info "URL: ${THORIUM_DEB_URL}"

    # Download com barra de progresso
    curl -fL \
        --progress-bar \
        --max-time 300 \
        "$THORIUM_DEB_URL" \
        -o "$deb_path" \
        2>> "$LOG_ARQUIVO" \
        || log_erro "Falha no download do Thorium. URL: ${THORIUM_DEB_URL}"

    # Verifica integridade básica do arquivo baixado
    if [[ ! -s "$deb_path" ]]; then
        log_erro "Arquivo baixado está vazio: ${deb_path}"
    fi

    local tamanho_mb
    tamanho_mb="$(du -m "$deb_path" | awk '{print $1}')"
    log_info "Arquivo baixado: ${deb_path} (${tamanho_mb} MB)"

    # Instala via dpkg (não usa apt para não precisar de repositório)
    log_info "Instalando pacote via dpkg..."
    dpkg -i "$deb_path" >> "$LOG_ARQUIVO" 2>&1 || {
        # Resolve dependências quebradas automaticamente
        log_aviso "dpkg reportou dependências faltando — executando apt-get install -f..."
        apt-get install -f -y -qq >> "$LOG_ARQUIVO" 2>&1 \
            || log_erro "Falha ao resolver dependências do Thorium."
    }

    # Limpa arquivo temporário
    rm -f "$deb_path"
    rmdir "$THORIUM_TMP_DIR" 2>/dev/null || true
    log_info "Arquivo temporário removido."

    # Confirma instalação
    if ! command -v thorium-browser &>/dev/null; then
        log_erro "Binário 'thorium-browser' não encontrado após instalação."
    fi

    local versao_instalada
    versao_instalada="$(versao_thorium)"
    log_ok "Thorium Browser instalado (versão: ${versao_instalada}, variante: ${THORIUM_VARIANTE})."
    log_info "Binário: $(command -v thorium-browser)"
}

# -----------------------------------------------------------------------------
# ETAPA 3: Gera os arquivos de serviço kiosk
# -----------------------------------------------------------------------------

configurar_thorium_kiosk() {
    log_separador
    log_etapa "ETAPA 3/4 — Configurando Thorium Browser em modo kiosk"

    # Carrega o perfil de flags técnicas (define JETT_THORIUM_FLAGS_STR)
    # BUG A fix: flags GPU do Thorium vêm do perfil, não de array local
    if [[ -f "$PERFIL_CONF" ]]; then
        # shellcheck source=config/browsers/thorium.conf
        source "$PERFIL_CONF"
    else
        log_erro "Perfil de flags não encontrado: ${PERFIL_CONF}."
    fi

    local flags_str="${JETT_THORIUM_FLAGS_STR}"

    local home_jett="/home/${USUARIO_JETT}"
    local systemd_user_dir="${home_jett}/.config/systemd/user"
    local uid_jett
    uid_jett="$(id -u "${USUARIO_JETT}" 2>/dev/null || echo "1000")"

    mkdir -p "$systemd_user_dir"
    mkdir -p "$CONFIG_DIR"

    # ── Serviço de usuário ─────────────────────────────────────────────────────
    local servico_user="${systemd_user_dir}/thorium-kiosk.service"
    log_info "Criando serviço de usuário: ${servico_user}"

    cat > "$servico_user" << EOF
# =============================================================================
# thorium-kiosk.service — Serviço de usuário para Thorium Browser Kiosk
# =============================================================================
# Localização: ~/.config/systemd/user/thorium-kiosk.service
#
# Uso:
#   systemctl --user start  thorium-kiosk
#   systemctl --user stop   thorium-kiosk
#   systemctl --user status thorium-kiosk
# =============================================================================

[Unit]
Description=Jett OS — Thorium Browser Kiosk via Cage
After=default.target
Conflicts=cage-kiosk.service brave-kiosk.service edge-kiosk.service opera-kiosk.service firefox-kiosk.service

[Service]
Type=simple

Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=WAYLAND_DISPLAY=wayland-1
Environment=OZONE_PLATFORM=wayland
Environment=GDK_BACKEND=wayland
# VA-API para decodificação de vídeo por hardware
Environment=LIBVA_DRIVER_NAME=iHD

ExecStart=/usr/bin/cage -- /usr/bin/thorium-browser \\
    ${flags_str// / \\
    } \\
    "${THORIUM_URL_INICIAL}"

Restart=always
RestartSec=3
TimeoutStartSec=15

StandardOutput=journal
StandardError=journal
SyslogIdentifier=jett-thorium-kiosk

[Install]
WantedBy=default.target
EOF

    # ── Serviço de sistema ─────────────────────────────────────────────────────
    local servico_projeto="${CONFIG_DIR}/thorium-kiosk.service"
    local servico_sistema="${SERVICO_DESTINO}/thorium-kiosk.service"

    log_info "Criando serviço de sistema: ${servico_projeto}"

    cat > "$servico_projeto" << EOF
# =============================================================================
# thorium-kiosk.service — Serviço de sistema para Thorium Browser Kiosk
# =============================================================================
# Localização: /etc/systemd/system/thorium-kiosk.service
# Instalado por: build/browsers/install-thorium.sh
#
# Thorium é um fork do Chromium otimizado para x86_64 (variante: ${THORIUM_VARIANTE}).
# As flags de GPU (gpu-rasterization, zero-copy) aproveitam os patches do Thorium.
#
# Uso:
#   sudo systemctl start  thorium-kiosk
#   sudo systemctl stop   thorium-kiosk
#   sudo systemctl status thorium-kiosk
#   journalctl -u thorium-kiosk -f
# =============================================================================

[Unit]
Description=Jett OS — Thorium Browser Kiosk (serviço de sistema)
After=network.target multi-user.target systemd-user-sessions.service
RequiresMountsFor=/home
Conflicts=cage-kiosk.service brave-kiosk.service edge-kiosk.service opera-kiosk.service firefox-kiosk.service

[Service]
Type=simple

User=${USUARIO_JETT}
Group=${USUARIO_JETT}

Environment=XDG_RUNTIME_DIR=/run/user/${uid_jett}
Environment=WAYLAND_DISPLAY=wayland-1
Environment=OZONE_PLATFORM=wayland
Environment=GDK_BACKEND=wayland
Environment=LIBVA_DRIVER_NAME=iHD
Environment=HOME=/home/${USUARIO_JETT}
Environment=USER=${USUARIO_JETT}

EnvironmentFile=-/etc/jett-os/thorium.conf

ExecStartPre=/bin/bash -c 'until ls /dev/dri/card* &>/dev/null; do sleep 0.3; done'
ExecStartPre=/bin/bash -c 'mkdir -p /run/user/${uid_jett} && chown ${USUARIO_JETT}:${USUARIO_JETT} /run/user/${uid_jett} && chmod 700 /run/user/${uid_jett}'

ExecStart=/usr/bin/cage -- /usr/bin/thorium-browser \\
    ${flags_str// / \\
    } \\
    \${JETT_THORIUM_URL:-${THORIUM_URL_INICIAL}}

Restart=always
RestartSec=3
TimeoutStartSec=20
KillMode=control-group
KillSignal=SIGTERM
TimeoutStopSec=10

ProtectSystem=strict
ReadWritePaths=/home/${USUARIO_JETT} /tmp /run/user/${uid_jett} /var/log /etc/jett-os

StandardOutput=journal
StandardError=journal
SyslogIdentifier=jett-thorium-kiosk

[Install]
WantedBy=multi-user.target
EOF

    log_info "Instalando serviço: ${servico_sistema}"
    cp "$servico_projeto" "$servico_sistema" \
        || log_erro "Falha ao copiar serviço para ${servico_sistema}."

    chown -R "${USUARIO_JETT}:${USUARIO_JETT}" "$systemd_user_dir"

    log_ok "Arquivos de serviço criados:"
    log_info "  → Usuário : ${servico_user}"
    log_info "  → Projeto : ${servico_projeto}"
    log_info "  → Sistema : ${servico_sistema}"
}

# -----------------------------------------------------------------------------
# ETAPA 4: Ativa serviços e registra o navegador
# -----------------------------------------------------------------------------

ativar_e_registrar_thorium() {
    log_separador
    log_etapa "ETAPA 4/4 — Registrando Thorium Browser no Jett OS"

    log_info "Recarregando daemon do systemd..."
    systemctl daemon-reload >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "daemon-reload falhou."

    log_info "Habilitando thorium-kiosk.service..."
    systemctl enable thorium-kiosk.service >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "Não foi possível habilitar thorium-kiosk.service."

    log_info "Habilitando serviço do usuário '${USUARIO_JETT}'..."
    su -l "$USUARIO_JETT" -c \
        "XDG_RUNTIME_DIR=/run/user/$(id -u "$USUARIO_JETT") systemctl --user enable thorium-kiosk.service" \
        >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "Não foi possível habilitar thorium-kiosk.service --user."

    # Cria arquivo de configuração específico do Thorium
    # Cria/atualiza thorium.conf com flags para uso pelo jett-switch.sh em runtime.
    # BUG A fix: inclui JETT_THORIUM_FLAGS_STR com flags GPU do Thorium.
    mkdir -p "$CONFIG_JETT"
    cat > "${CONFIG_JETT}/thorium.conf" << THORIUMCONF
# /etc/jett-os/thorium.conf — Configuração do Thorium Browser no Jett OS
# Gerado por install-thorium.sh v${VERSAO_SCRIPT}. Não edite manualmente.
# Lido como EnvironmentFile pelo thorium-kiosk.service e por jett-switch.sh.

# URL que o Thorium abre ao iniciar
JETT_THORIUM_URL="${THORIUM_URL_INICIAL}"

# Variante de build instalada
JETT_THORIUM_VARIANTE="${THORIUM_VARIANTE}"

# Flags técnicas de integração (fonte: config/browsers/thorium.conf)
# Usadas pelo jett-switch.sh ao trocar para Thorium via Super+B
JETT_THORIUM_FLAGS_STR="${JETT_THORIUM_FLAGS_STR}"
THORIUMCONF
    log_ok "Arquivo de configuração criado/atualizado: ${CONFIG_JETT}/thorium.conf"

    # Registra em navegadores-instalados.conf
    local versao_inst
    versao_inst="$(versao_thorium)"
    registrar_navegador "THORIUM" "$versao_inst" "$(command -v thorium-browser)"

    # Define como navegador padrão se --set-default foi passado
    if [[ "$DEFINIR_PADRAO" == "true" ]]; then
        log_info "Definindo Thorium como navegador ativo..."
        printf "# /etc/jett-os/navegador.conf\n# Gerado por install-thorium.sh v%s\nJETT_NAVEGADOR=\"thorium\"\nJETT_NAVEGADOR_CMD=\"thorium-browser %s %s\"\n" \
            "$VERSAO_SCRIPT" "${JETT_THORIUM_FLAGS_STR}" "${THORIUM_URL_INICIAL}" \
            > "${CONFIG_JETT}/navegador.conf"
        log_ok "Thorium definido como navegador ativo."
    fi
}

# -----------------------------------------------------------------------------
# FUNÇÃO COMPARTILHADA: Registra navegador em navegadores-instalados.conf
# -----------------------------------------------------------------------------

registrar_navegador() {
    local id_upper="$1"
    local versao="$2"
    local binario="$3"
    local conf="${CONFIG_JETT}/navegadores-instalados.conf"

    mkdir -p "${CONFIG_JETT}"

    if [[ ! -f "$conf" ]]; then
        printf "# /etc/jett-os/navegadores-instalados.conf\n# Registro de navegadores instalados no Jett OS\n# Atualizado automaticamente pelos scripts de instalação\n# NÃO edite manualmente — use os scripts de instalação\n\n" \
            > "$conf"
    fi

    sed -i "/^JETT_${id_upper}_/d" "$conf"
    sed -i '/^$/N;/^\n$/d' "$conf"

    printf "\nJETT_%s_INSTALADO=true\nJETT_%s_VERSAO=\"%s\"\nJETT_%s_BINARIO=\"%s\"\n" \
        "$id_upper" \
        "$id_upper" "$versao" \
        "$id_upper" "$binario" \
        >> "$conf"

    log_ok "Navegador registrado: JETT_${id_upper}_INSTALADO=true (versão: ${versao})"
}

# -----------------------------------------------------------------------------
# RESUMO FINAL
# -----------------------------------------------------------------------------

exibir_resumo() {
    log_separador
    echo ""
    echo -e "${COR_VERDE}╔══════════════════════════════════════════════════╗${COR_RESET}"
    echo -e "${COR_VERDE}║     Thorium Browser instalado e configurado!     ║${COR_RESET}"
    echo -e "${COR_VERDE}╚══════════════════════════════════════════════════╝${COR_RESET}"
    echo ""
    echo -e "  Versão instalada  : ${COR_CIANO}$(versao_thorium)${COR_RESET}"
    echo -e "  Variante de build : ${COR_CIANO}${THORIUM_VARIANTE^^}${COR_RESET}"
    echo -e "  URL inicial       : ${COR_CIANO}${THORIUM_URL_INICIAL}${COR_RESET}"
    echo -e "  Serviço kiosk     : ${COR_CIANO}thorium-kiosk.service${COR_RESET}"
    echo -e "  Config Thorium    : ${COR_CIANO}${CONFIG_JETT}/thorium.conf${COR_RESET}"
    echo -e "  Registro          : ${COR_CIANO}${CONFIG_JETT}/navegadores-instalados.conf${COR_RESET}"
    echo -e "  Log completo      : ${COR_CIANO}${LOG_ARQUIVO}${COR_RESET}"
    echo ""
    echo -e "  ${COR_AMARELO}Nota sobre variantes de build:${COR_RESET}"
    echo -e "    ${COR_BRANCO}sse4${COR_RESET} — máxima compatibilidade (qualquer x86_64 moderno)"
    echo -e "    ${COR_BRANCO}avx ${COR_RESET} — padrão: Intel Sandy Bridge 2011+ / AMD Bulldozer 2011+"
    echo -e "    ${COR_BRANCO}avx2${COR_RESET} — mais rápido: Intel Haswell 2013+ / AMD Excavator 2015+"
    echo ""
    echo -e "  ${COR_AMARELO}Para ativar o Thorium como navegador padrão:${COR_RESET}"
    echo -e "    ${COR_CIANO}sudo ./install-thorium.sh --set-default${COR_RESET}"
    echo ""
    log_separador
}

# -----------------------------------------------------------------------------
# PROCESSAMENTO DE ARGUMENTOS
# -----------------------------------------------------------------------------

processar_argumentos() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)
                shift
                THORIUM_URL_INICIAL="$1"
                ;;
            --avx)
                THORIUM_VARIANTE="avx"
                ;;
            --avx2)
                THORIUM_VARIANTE="avx2"
                ;;
            --sse4)
                THORIUM_VARIANTE="sse4"
                ;;
            --set-default)
                DEFINIR_PADRAO=true
                ;;
            --help|-h)
                echo "Uso: sudo ./install-thorium.sh [opções]"
                echo ""
                echo "Opções:"
                echo "  --url URL    URL inicial (padrão: about:blank)"
                echo "  --avx        Build AVX (padrão — Intel Sandy Bridge+ / AMD Bulldozer+)"
                echo "  --avx2       Build AVX2 (Intel Haswell+ / AMD Excavator+)"
                echo "  --sse4       Build SSE4 (máxima compatibilidade)"
                echo "  --set-default  Define o Thorium como navegador ativo"
                exit 0
                ;;
            *)
                log_erro "Argumento desconhecido: '$1'. Use --help."
                ;;
        esac
        shift
    done
}

# -----------------------------------------------------------------------------
# PONTO DE ENTRADA PRINCIPAL
# -----------------------------------------------------------------------------

main() {
    clear
    echo -e "${COR_CIANO}"
    echo "  ████████╗██╗  ██╗ ██████╗ ██████╗ ██╗██╗   ██╗███╗   ███╗"
    echo "  ╚══██╔══╝██║  ██║██╔═══██╗██╔══██╗██║██║   ██║████╗ ████║"
    echo "     ██║   ███████║██║   ██║██████╔╝██║██║   ██║██╔████╔██║"
    echo "     ██║   ██╔══██║██║   ██║██╔══██╗██║██║   ██║██║╚██╔╝██║"
    echo "     ██║   ██║  ██║╚██████╔╝██║  ██║██║╚██████╔╝██║ ╚═╝ ██║"
    echo "     ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝ ╚═════╝ ╚═╝     ╚═╝"
    echo -e "${COR_RESET}"
    echo -e "  ${COR_BRANCO}Instalação do Thorium Browser — Jett OS v${VERSAO_SCRIPT}${COR_RESET}"
    echo ""

    processar_argumentos "$@"
    verificar_root
    inicializar_log
    verificar_base_instalada
    verificar_dependencias
    verificar_conexao

    log_info "URL inicial: ${THORIUM_URL_INICIAL}"
    log_info "Variante: ${THORIUM_VARIANTE}"
    log_info "Definir como padrão: ${DEFINIR_PADRAO}"
    echo ""

    obter_url_deb_thorium
    instalar_thorium
    configurar_thorium_kiosk
    ativar_e_registrar_thorium
    exibir_resumo
}

main "$@"
