#!/usr/bin/env bash
# =============================================================================
# install-brave.sh — Instalação e configuração do Brave Browser no Jett OS
# =============================================================================
# Descrição:
#   Instala o Brave Browser via repositório oficial Debian (.deb), configura
#   o Cage Kiosk para abri-lo com as flags otimizadas para uso em kiosk, e
#   ativa o serviço systemd de inicialização automática.
#
# Uso:
#   sudo ./install-brave.sh [--url URL_INICIAL]
#
# Opções:
#   --url   URL que o Brave abrirá ao iniciar (padrão: about:blank)
#
# Idempotência:
#   Seguro de executar múltiplas vezes. Verifica cada estado antes de agir.
#   Se o Brave já estiver instalado, apenas atualiza as configurações.
#
# Pré-requisitos:
#   - build-base.sh executado com sucesso
#   - Usuário 'jett' existente
#   - Conexão com a internet
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# VARIÁVEIS GLOBAIS
# -----------------------------------------------------------------------------

USUARIO_JETT="jett"
LOG_ARQUIVO="/var/log/jett-os-build.log"
VERSAO_SCRIPT="1.0.0"

# URL inicial do Brave (pode ser sobrescrita por --url)
BRAVE_URL_INICIAL="${BRAVE_URL_INICIAL:-about:blank}"

# Diretório raiz do projeto (dois níveis acima deste script: build/ -> raiz)
PROJETO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Caminhos importantes
CONFIG_DIR="${PROJETO_DIR}/config"                  # /config do projeto
CONFIG_JETT="/etc/jett-os"                          # config central no sistema
SERVICO_DESTINO="/etc/systemd/system"               # destino dos serviços systemd

# Repositório oficial do Brave
BRAVE_REPO_URL="https://brave-browser-apt-release.s3.brave.com"
BRAVE_GPG_URL="https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg"
BRAVE_GPG_DEST="/usr/share/keyrings/brave-browser-archive-keyring.gpg"
BRAVE_LIST_FILE="/etc/apt/sources.list.d/brave-browser-release.list"

# Perfil de configuração do Brave — define JETT_BRAVE_FLAGS (array) e
# JETT_BRAVE_FLAGS_STR (string). Fonte única de verdade para as flags.
PERFIL_CONF="${PROJETO_DIR}/config/browsers/brave.conf"

# Cores para saída no terminal (padrão Jett OS)
COR_RESET="\033[0m"
COR_VERDE="\033[1;32m"
COR_AMARELO="\033[1;33m"
COR_VERMELHO="\033[1;31m"
COR_CIANO="\033[1;36m"
COR_BRANCO="\033[1;37m"

# -----------------------------------------------------------------------------
# FUNÇÕES DE LOG (padrão Jett OS)
# -----------------------------------------------------------------------------

inicializar_log() {
    mkdir -p "$(dirname "$LOG_ARQUIVO")"
    {
        echo "-------------------------------------------------------"
        echo "  install-brave.sh v${VERSAO_SCRIPT} — $(date '+%Y-%m-%d %H:%M:%S')"
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
        log_erro "Este script precisa ser executado como root. Use: sudo ./install-brave.sh"
    fi
}

verificar_base_instalada() {
    # Garante que o build-base.sh foi executado antes deste script
    if ! id "$USUARIO_JETT" &>/dev/null; then
        log_erro "Usuário '${USUARIO_JETT}' não encontrado. Execute build-base.sh primeiro."
    fi
    if ! command -v cage &>/dev/null; then
        log_erro "Cage não encontrado. Execute build-base.sh primeiro."
    fi
    log_ok "Pré-requisitos verificados: usuário '${USUARIO_JETT}' e Cage presentes."
}

verificar_conexao() {
    log_info "Verificando conexão com a internet..."
    if ! curl -sf --max-time 10 "https://brave.com" -o /dev/null; then
        log_erro "Sem conexão com a internet. O Brave requer download do repositório oficial."
    fi
    log_ok "Conexão com a internet confirmada."
}

pacote_instalado() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# Retorna a versão instalada do Brave, ou "não instalado"
versao_brave() {
    if pacote_instalado "brave-browser"; then
        brave-browser --version 2>/dev/null | awk '{print $NF}' || echo "instalado"
    else
        echo "não instalado"
    fi
}

# -----------------------------------------------------------------------------
# FUNÇÕES DE INSTALAÇÃO
# -----------------------------------------------------------------------------

# ETAPA 1: Adiciona o repositório oficial do Brave
adicionar_repositorio_brave() {
    log_separador
    log_etapa "ETAPA 1/4 — Adicionando repositório oficial do Brave"

    # Verifica se a chave GPG já está presente
    if [[ -f "$BRAVE_GPG_DEST" ]]; then
        log_info "Chave GPG do Brave já presente em ${BRAVE_GPG_DEST} — pulando download."
    else
        log_info "Baixando chave GPG do repositório Brave..."
        curl -fsSL "$BRAVE_GPG_URL" \
            -o "$BRAVE_GPG_DEST" \
            >> "$LOG_ARQUIVO" 2>&1 \
            || log_erro "Falha ao baixar a chave GPG do Brave. URL: ${BRAVE_GPG_URL}"

        # Verifica se o arquivo baixado é uma chave GPG válida
        if ! file "$BRAVE_GPG_DEST" | grep -q "GPG\|PGP\|data"; then
            rm -f "$BRAVE_GPG_DEST"
            log_erro "Arquivo baixado não é uma chave GPG válida. Abortando por segurança."
        fi
        log_ok "Chave GPG baixada e validada."
    fi

    # Verifica se o repositório já está configurado
    if [[ -f "$BRAVE_LIST_FILE" ]]; then
        log_info "Repositório Brave já configurado em ${BRAVE_LIST_FILE} — pulando."
    else
        log_info "Adicionando repositório Brave ao APT..."
        echo "deb [signed-by=${BRAVE_GPG_DEST} arch=amd64] ${BRAVE_REPO_URL}/ stable main" \
            > "$BRAVE_LIST_FILE" \
            || log_erro "Falha ao criar ${BRAVE_LIST_FILE}."
        log_ok "Repositório adicionado: ${BRAVE_LIST_FILE}"
    fi

    # Atualiza a lista de pacotes para incluir o repositório recém-adicionado
    log_info "Atualizando lista de pacotes do APT..."
    apt-get update -qq >> "$LOG_ARQUIVO" 2>&1 \
        || log_erro "Falha ao atualizar lista de pacotes."

    log_ok "Repositório oficial do Brave configurado com sucesso."
}

# ETAPA 2: Instala o Brave Browser
instalar_brave() {
    log_separador
    log_etapa "ETAPA 2/4 — Instalando Brave Browser"

    local versao_atual
    versao_atual="$(versao_brave)"

    if pacote_instalado "brave-browser"; then
        log_info "Brave já instalado (versão: ${versao_atual}) — verificando atualizações."
        apt-get install -y -qq --only-upgrade brave-browser >> "$LOG_ARQUIVO" 2>&1 \
            || log_aviso "Não foi possível atualizar o Brave. Mantendo versão atual."
        local versao_nova
        versao_nova="$(versao_brave)"
        if [[ "$versao_atual" != "$versao_nova" ]]; then
            log_ok "Brave atualizado: ${versao_atual} → ${versao_nova}"
        else
            log_ok "Brave já está na versão mais recente: ${versao_atual}"
        fi
    else
        log_info "Instalando brave-browser (isso pode demorar alguns minutos)..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq brave-browser \
            >> "$LOG_ARQUIVO" 2>&1 \
            || log_erro "Falha ao instalar o brave-browser. Verifique o log em ${LOG_ARQUIVO}"

        local versao_instalada
        versao_instalada="$(versao_brave)"
        log_ok "Brave Browser instalado com sucesso (versão: ${versao_instalada})."
    fi

    # Confirma que o binário existe e é executável
    if [[ ! -x "$(command -v brave-browser)" ]]; then
        log_erro "Binário 'brave-browser' não encontrado após instalação. Verifique o log."
    fi
    log_info "Binário do Brave: $(command -v brave-browser)"
}

# ETAPA 3: Gera os arquivos de configuração do serviço kiosk
configurar_brave_kiosk() {
    log_separador
    log_etapa "ETAPA 3/4 — Configurando Brave em modo kiosk para o Cage"

    # Carrega as flags do perfil de configuração do Brave
    # Exporta: JETT_BRAVE_FLAGS (array) e JETT_BRAVE_FLAGS_STR (string)
    source "$PERFIL_CONF" \
        || log_erro "Falha ao carregar perfil do Brave em ${PERFIL_CONF}"
    local flags_str="${JETT_BRAVE_FLAGS_STR}"

    local home_jett="/home/${USUARIO_JETT}"
    local systemd_user_dir="${home_jett}/.config/systemd/user"

    mkdir -p "$systemd_user_dir"
    mkdir -p "$CONFIG_DIR"

    # -------------------------------------------------------------------------
    # Arquivo 1: Serviço systemd do usuário (em ~/.config/systemd/user/)
    # Este serviço é gerenciado pelo systemd --user do usuário 'jett'.
    # -------------------------------------------------------------------------
    local servico_user="${systemd_user_dir}/brave-kiosk.service"

    log_info "Criando serviço systemd de usuário: ${servico_user}"
    cat > "$servico_user" << EOF
# =============================================================================
# brave-kiosk.service — Serviço do usuário para Brave Kiosk no Jett OS
# =============================================================================
# Localização: ~/.config/systemd/user/brave-kiosk.service
# Gerenciado por: systemd --user (usuário '${USUARIO_JETT}')
#
# Para gerenciar manualmente:
#   systemctl --user start brave-kiosk
#   systemctl --user stop brave-kiosk
#   systemctl --user status brave-kiosk
# =============================================================================

[Unit]
Description=Jett OS — Brave Browser Kiosk via Cage
# Garante que a sessão do usuário esteja completamente iniciada
After=default.target
# Substitui o serviço genérico de kiosk configurado pelo build-base.sh
Conflicts=cage-kiosk.service

[Service]
Type=simple

# --- Variáveis de ambiente para sessão Wayland nativa -----------------------
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=WAYLAND_DISPLAY=wayland-1
# Força o Brave (Chromium) a usar o backend Wayland em vez de XWayland
Environment=OZONE_PLATFORM=wayland
# Habilita aceleração de hardware via VA-API (Intel/AMD Mesa)
Environment=LIBVA_DRIVER_NAME=iHD
# Diretório de perfil do Brave para o usuário kiosk
Environment=BRAVE_PROFILE_DIR=/home/${USUARIO_JETT}/.config/BraveSoftware/Brave-Browser

# --- Comando principal -------------------------------------------------------
# Cage inicia o Wayland compositor e abre o Brave em tela cheia.
# A URL inicial pode ser sobrescrita em /etc/jett-os/brave.conf
ExecStart=/usr/bin/cage -- /usr/bin/brave-browser \\
    ${flags_str// / \\
    } \\
    "${BRAVE_URL_INICIAL}"

# --- Comportamento em caso de falha -----------------------------------------
# Reinicia automaticamente se o Brave ou o Cage travarem
Restart=always
RestartSec=3
# Aguarda até 10s antes de considerar falha no início
TimeoutStartSec=10

# --- Saída -------------------------------------------------------------------
StandardOutput=journal
StandardError=journal
SyslogIdentifier=jett-brave-kiosk

[Install]
WantedBy=default.target
EOF

    # -------------------------------------------------------------------------
    # Arquivo 2: Serviço systemd do sistema (em /etc/systemd/system/)
    # Cópia para uso como serviço de sistema — instalada pelo install-brave.sh.
    # Também é a cópia que fica em /config/ no repositório do projeto.
    # -------------------------------------------------------------------------
    local servico_projeto="${CONFIG_DIR}/brave-kiosk.service"
    local servico_sistema="${SERVICO_DESTINO}/brave-kiosk.service"

    log_info "Criando serviço systemd de sistema: ${servico_projeto}"
    cat > "$servico_projeto" << EOF
# =============================================================================
# brave-kiosk.service — Serviço do sistema para Brave Kiosk no Jett OS
# =============================================================================
# Localização: /etc/systemd/system/brave-kiosk.service
# Gerenciado por: systemd (sistema, root)
#
# Este serviço inicia o Cage + Brave como usuário '${USUARIO_JETT}' no boot.
# Útil quando o lingering de usuário não está disponível.
#
# Para gerenciar manualmente:
#   systemctl start brave-kiosk
#   systemctl stop brave-kiosk
#   systemctl status brave-kiosk
# =============================================================================

[Unit]
Description=Jett OS — Brave Browser Kiosk (serviço de sistema)
# Inicia após a rede e o multi-user target estarem prontos
After=network.target multi-user.target systemd-user-sessions.service
# O sistema de arquivos /home deve estar montado
RequiresMountsFor=/home

[Service]
Type=simple

# Executa como usuário 'jett' — nunca como root
User=${USUARIO_JETT}
Group=${USUARIO_JETT}

# --- Variáveis de ambiente para sessão Wayland do usuário -------------------
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u "${USUARIO_JETT}" 2>/dev/null || echo "1000")
Environment=WAYLAND_DISPLAY=wayland-1
Environment=OZONE_PLATFORM=wayland
Environment=LIBVA_DRIVER_NAME=iHD
Environment=HOME=/home/${USUARIO_JETT}
Environment=USER=${USUARIO_JETT}

# --- Carrega configurações customizadas se existirem ------------------------
EnvironmentFile=-/etc/jett-os/brave.conf

# --- Comando principal -------------------------------------------------------
ExecStart=/usr/bin/cage -- /usr/bin/brave-browser \\
    ${flags_str// / \\
    } \\
    \${JETT_BRAVE_URL:-${BRAVE_URL_INICIAL}}

# --- Comportamento em caso de falha -----------------------------------------
Restart=always
RestartSec=3
TimeoutStartSec=15

# --- Saída -------------------------------------------------------------------
StandardOutput=journal
StandardError=journal
SyslogIdentifier=jett-brave-kiosk

[Install]
WantedBy=multi-user.target
EOF

    # Instala o serviço no sistema e copia para /etc/systemd/system/
    log_info "Instalando serviço no sistema: ${servico_sistema}"
    cp "$servico_projeto" "$servico_sistema" \
        || log_erro "Falha ao copiar o serviço para ${servico_sistema}."

    # Ajusta propriedade do serviço de usuário
    chown -R "${USUARIO_JETT}:${USUARIO_JETT}" "$systemd_user_dir"

    log_ok "Arquivos de serviço criados:"
    log_info "  → Usuário : ${servico_user}"
    log_info "  → Projeto : ${servico_projeto}"
    log_info "  → Sistema : ${servico_sistema}"
}

# ETAPA 4: Ativa os serviços e atualiza a configuração central
ativar_servicos_brave() {
    log_separador
    log_etapa "ETAPA 4/4 — Ativando serviços e atualizando configuração central"

    # Recarrega o daemon do systemd para reconhecer o novo serviço
    log_info "Recarregando daemon do systemd..."
    systemctl daemon-reload >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "systemctl daemon-reload falhou — pode ser necessário reiniciar."

    # Habilita o serviço de sistema para iniciar no boot
    log_info "Habilitando brave-kiosk.service no boot..."
    systemctl enable brave-kiosk.service >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "Não foi possível habilitar brave-kiosk.service via systemctl."

    # Habilita o serviço do usuário 'jett'
    log_info "Habilitando serviço do usuário '${USUARIO_JETT}'..."
    su -l "$USUARIO_JETT" -c \
        "XDG_RUNTIME_DIR=/run/user/$(id -u "$USUARIO_JETT") systemctl --user enable brave-kiosk.service" \
        >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "Não foi possível habilitar serviço --user. O fallback via .bash_profile continuará ativo."

    # Desabilita o serviço genérico cage-kiosk.service do build-base.sh
    # pois o brave-kiosk.service declara Conflicts= com ele
    if systemctl is-enabled cage-kiosk.service &>/dev/null; then
        log_info "Desabilitando cage-kiosk.service genérico (substituído por brave-kiosk.service)..."
        systemctl disable cage-kiosk.service >> "$LOG_ARQUIVO" 2>&1 || true
    fi

    # Carrega as flags do perfil para gravar no runtime conf
    source "$PERFIL_CONF" \
        || log_erro "Falha ao carregar perfil do Brave em ${PERFIL_CONF}"

    # Atualiza /etc/jett-os/navegador.conf com o Brave como navegador ativo
    log_info "Atualizando configuração central do navegador..."
    mkdir -p "$CONFIG_JETT"
    cat > "${CONFIG_JETT}/navegador.conf" << EOF
# /etc/jett-os/navegador.conf — Gerado por install-brave.sh v${VERSAO_SCRIPT}
JETT_NAVEGADOR="brave"
JETT_NAVEGADOR_CMD="brave-browser ${JETT_BRAVE_FLAGS_STR} ${BRAVE_URL_INICIAL}"
EOF

    # Cria arquivo de configuração runtime do Brave.
    # Lido pelo brave-kiosk.service (EnvironmentFile=) e pelo jett-switch.sh.
    cat > "${CONFIG_JETT}/brave.conf" << EOF
# =============================================================================
# /etc/jett-os/brave.conf — Configuração de runtime do Brave no Jett OS
# =============================================================================
# Gerado por install-brave.sh v${VERSAO_SCRIPT} em $(date '+%Y-%m-%d %H:%M:%S')
# Lido por: brave-kiosk.service (EnvironmentFile=), jett-switch.sh
#
# Edite JETT_BRAVE_URL para mudar a URL sem re-executar o script de instalação.
# Não altere JETT_BRAVE_FLAGS_STR manualmente — re-execute install-brave.sh.

# URL que o Brave abre ao iniciar
JETT_BRAVE_URL="${BRAVE_URL_INICIAL}"

# Perfil de dados do Brave (não altere sem necessidade)
JETT_BRAVE_PROFILE="/home/${USUARIO_JETT}/.config/BraveSoftware/Brave-Browser"

# Flags kiosk do Brave — geradas a partir de config/browsers/brave.conf
JETT_BRAVE_FLAGS_STR="${JETT_BRAVE_FLAGS_STR}"
EOF

    # Registra o Brave em navegadores-instalados.conf
    local versao_instalada
    versao_instalada="$(versao_brave)"
    local binario_path
    binario_path="$(command -v brave-browser || echo "/usr/bin/brave-browser")"
    registrar_navegador "BRAVE" "$versao_instalada" "$binario_path"

    log_ok "Configuração central atualizada: ${CONFIG_JETT}/navegador.conf"
    log_ok "Configuração de runtime do Brave: ${CONFIG_JETT}/brave.conf"
}

# -----------------------------------------------------------------------------
# FUNÇÃO COMPARTILHADA: Registra navegador em navegadores-instalados.conf
# -----------------------------------------------------------------------------

registrar_navegador() {
    local id_upper="$1"   # Ex: "BRAVE"
    local versao="$2"     # Ex: "1.60.114"
    local binario="$3"    # Ex: "/usr/bin/brave-browser"
    local conf="${CONFIG_JETT}/navegadores-instalados.conf"

    mkdir -p "${CONFIG_JETT}"

    # Cria o arquivo com cabeçalho se não existir
    if [[ ! -f "$conf" ]]; then
        printf "# /etc/jett-os/navegadores-instalados.conf\n# Registro de navegadores instalados no Jett OS\n# Atualizado automaticamente pelos scripts de instalação\n# NÃO edite manualmente — use os scripts de instalação\n\n" \
            > "$conf"
    fi

    # Remove entradas antigas para este navegador (idempotência)
    sed -i "/^JETT_${id_upper}_/d" "$conf"
    # Remove linhas em branco duplas residuais
    sed -i '/^$/N;/^\n$/d' "$conf"

    # Adiciona entradas atualizadas
    printf "\nJETT_%s_INSTALADO=true\nJETT_%s_VERSAO=\"%s\"\nJETT_%s_BINARIO=\"%s\"\n" \
        "$id_upper" \
        "$id_upper" "$versao" \
        "$id_upper" "$binario" \
        >> "$conf"

    log_ok "Navegador registrado: JETT_${id_upper}_INSTALADO=true (versão: ${versao})"
}

# Exibe resumo final
exibir_resumo() {
    log_separador
    echo ""
    echo -e "${COR_VERDE}╔══════════════════════════════════════════════════╗${COR_RESET}"
    echo -e "${COR_VERDE}║     Brave Browser instalado e configurado!       ║${COR_RESET}"
    echo -e "${COR_VERDE}╚══════════════════════════════════════════════════╝${COR_RESET}"
    echo ""
    echo -e "  Versão instalada  : ${COR_CIANO}$(versao_brave)${COR_RESET}"
    echo -e "  URL inicial       : ${COR_CIANO}${BRAVE_URL_INICIAL}${COR_RESET}"
    echo -e "  Serviço (sistema) : ${COR_CIANO}brave-kiosk.service${COR_RESET}"
    echo -e "  Config Brave      : ${COR_CIANO}${CONFIG_JETT}/brave.conf${COR_RESET}"
    echo -e "  Registro          : ${COR_CIANO}${CONFIG_JETT}/navegadores-instalados.conf${COR_RESET}"
    echo -e "  Log completo      : ${COR_CIANO}${LOG_ARQUIVO}${COR_RESET}"
    echo ""
    source "$PERFIL_CONF" 2>/dev/null || true
    echo -e "  ${COR_AMARELO}Flags ativas do Brave (de config/browsers/brave.conf):${COR_RESET}"
    for flag in "${JETT_BRAVE_FLAGS[@]:-}"; do
        echo -e "    ${COR_BRANCO}${flag}${COR_RESET}"
    done
    echo ""
    echo -e "  ${COR_AMARELO}Próximos passos:${COR_RESET}"
    echo -e "    1. Reinicie para testar o boot automático:"
    echo -e "       ${COR_CIANO}sudo reboot${COR_RESET}"
    echo -e "    2. Ou inicie o serviço agora (requer sessão gráfica ativa):"
    echo -e "       ${COR_CIANO}sudo systemctl start brave-kiosk.service${COR_RESET}"
    echo -e "    3. Para mudar a URL inicial, edite:"
    echo -e "       ${COR_CIANO}sudo nano ${CONFIG_JETT}/brave.conf${COR_RESET}"
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
                BRAVE_URL_INICIAL="$1"
                ;;
            --help|-h)
                echo "Uso: sudo ./install-brave.sh [--url URL]"
                echo ""
                echo "Opções:"
                echo "  --url URL   URL que o Brave abrirá no boot (padrão: about:blank)"
                echo ""
                echo "Exemplos:"
                echo "  sudo ./install-brave.sh"
                echo "  sudo ./install-brave.sh --url https://meusite.com"
                exit 0
                ;;
            *)
                log_erro "Argumento desconhecido: '$1'. Use --help para ver as opções."
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
    echo "  ██████╗ ██████╗  █████╗ ██╗   ██╗███████╗"
    echo "  ██╔══██╗██╔══██╗██╔══██╗██║   ██║██╔════╝"
    echo "  ██████╔╝██████╔╝███████║██║   ██║█████╗  "
    echo "  ██╔══██╗██╔══██╗██╔══██║╚██╗ ██╔╝██╔══╝  "
    echo "  ██████╔╝██║  ██║██║  ██║ ╚████╔╝ ███████╗"
    echo "  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝"
    echo -e "${COR_RESET}"
    echo -e "  ${COR_BRANCO}Instalação do Brave Browser — Jett OS v${VERSAO_SCRIPT}${COR_RESET}"
    echo ""

    processar_argumentos "$@"
    inicializar_log

    verificar_root
    verificar_base_instalada
    verificar_conexao

    log_info "URL inicial configurada: ${BRAVE_URL_INICIAL}"
    echo ""

    adicionar_repositorio_brave
    instalar_brave
    configurar_brave_kiosk
    ativar_servicos_brave
    exibir_resumo
}

main "$@"
