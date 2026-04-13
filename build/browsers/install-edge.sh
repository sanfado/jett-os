#!/usr/bin/env bash
# =============================================================================
# install-edge.sh — Instalação e configuração do Microsoft Edge no Jett OS
# =============================================================================
# Descrição:
#   Instala o Microsoft Edge Stable via repositório oficial da Microsoft para
#   Linux, configura o serviço kiosk systemd com flags otimizadas e registra
#   o navegador em /etc/jett-os/navegadores-instalados.conf.
#
# Uso:
#   sudo ./install-edge.sh [opções]
#
# Opções:
#   --url URL        URL que o Edge abrirá ao iniciar (padrão: about:blank)
#   --set-default    Define o Edge como navegador ativo (atualiza navegador.conf)
#   --help           Exibe esta ajuda
#
# Idempotência:
#   Seguro de executar múltiplas vezes. Se o Edge já estiver instalado,
#   verifica atualizações e regenera os arquivos de configuração.
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
NOME_NAVEGADOR="edge"
NOME_EXIBICAO="Microsoft Edge"

# URL inicial (pode ser sobrescrita por --url)
EDGE_URL_INICIAL="${EDGE_URL_INICIAL:-about:blank}"

# Define Edge como navegador padrão ao instalar? (sobrescrito por --set-default)
DEFINIR_PADRAO=false

# Diretório raiz do projeto (dois níveis acima: build/browsers/ → raiz)
PROJETO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Caminhos importantes
CONFIG_DIR="${PROJETO_DIR}/config"
CONFIG_JETT="/etc/jett-os"
SERVICO_DESTINO="/etc/systemd/system"

# Repositório oficial Microsoft para Linux
EDGE_GPG_URL="https://packages.microsoft.com/keys/microsoft.asc"
EDGE_GPG_DEST="/usr/share/keyrings/microsoft-edge-archive-keyring.gpg"
EDGE_LIST_FILE="/etc/apt/sources.list.d/microsoft-edge.list"
EDGE_REPO_URL="https://packages.microsoft.com/repos/edge"

# Flags de kiosk e Wayland carregadas do perfil técnico centralizado.
# Fonte canônica: config/browsers/edge.conf (define JETT_EDGE_FLAGS e JETT_EDGE_FLAGS_STR).
# BUG A fix: não duplicar flags aqui — source do perfil garante consistência.
PERFIL_CONF="${PROJETO_DIR}/config/browsers/edge.conf"

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
        echo "  install-edge.sh v${VERSAO_SCRIPT} — $(date '+%Y-%m-%d %H:%M:%S')"
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
        echo -e "\033[1;31m[ERRO] Execute como root: sudo ./install-edge.sh\033[0m" >&2
        exit 1
    fi
}

verificar_base_instalada() {
    if ! id "$USUARIO_JETT" &>/dev/null; then
        log_erro "Usuário '${USUARIO_JETT}' não encontrado. Execute build-base.sh primeiro."
    fi
    log_ok "Pré-requisito verificado: usuário '${USUARIO_JETT}' presente."
}

verificar_conexao() {
    log_info "Verificando conexão com microsoft.com..."
    if ! curl -sf --max-time 15 "https://packages.microsoft.com" -o /dev/null; then
        log_erro "Sem acesso a packages.microsoft.com. Verifique a conexão com a internet."
    fi
    log_ok "Conexão confirmada."
}

pacote_instalado() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

versao_edge() {
    if pacote_instalado "microsoft-edge-stable"; then
        microsoft-edge-stable --version 2>/dev/null | awk '{print $NF}' || echo "instalado"
    else
        echo "não instalado"
    fi
}

# -----------------------------------------------------------------------------
# ETAPA 1: Adiciona o repositório oficial da Microsoft
# -----------------------------------------------------------------------------

adicionar_repositorio_edge() {
    log_separador
    log_etapa "ETAPA 1/4 — Adicionando repositório oficial Microsoft"

    # Verifica/baixa a chave GPG da Microsoft
    if [[ -f "$EDGE_GPG_DEST" ]]; then
        log_info "Chave GPG da Microsoft já presente em ${EDGE_GPG_DEST} — pulando."
    else
        log_info "Baixando chave GPG da Microsoft..."
        curl -fsSL "$EDGE_GPG_URL" \
            | gpg --dearmor \
            > "$EDGE_GPG_DEST" \
            2>> "$LOG_ARQUIVO" \
            || log_erro "Falha ao baixar/converter chave GPG da Microsoft."

        # Valida que é um arquivo de chave GPG binária
        if ! file "$EDGE_GPG_DEST" | grep -q "GPG\|PGP\|data"; then
            rm -f "$EDGE_GPG_DEST"
            log_erro "Arquivo baixado não é uma chave GPG válida. Abortando."
        fi
        log_ok "Chave GPG baixada e convertida para formato binário."
    fi

    # Verifica/cria o arquivo de repositório APT
    if [[ -f "$EDGE_LIST_FILE" ]]; then
        log_info "Repositório Edge já configurado em ${EDGE_LIST_FILE} — pulando."
    else
        log_info "Adicionando repositório Edge ao APT..."
        printf "deb [arch=amd64 signed-by=%s] %s stable main\n" \
            "$EDGE_GPG_DEST" "$EDGE_REPO_URL" \
            > "$EDGE_LIST_FILE" \
            || log_erro "Falha ao criar ${EDGE_LIST_FILE}."
        log_ok "Repositório adicionado: ${EDGE_LIST_FILE}"
    fi

    log_info "Atualizando lista de pacotes..."
    apt-get update -qq >> "$LOG_ARQUIVO" 2>&1 \
        || log_erro "Falha ao atualizar lista de pacotes."

    log_ok "Repositório oficial Microsoft configurado."
}

# -----------------------------------------------------------------------------
# ETAPA 2: Instala o Microsoft Edge
# -----------------------------------------------------------------------------

instalar_edge() {
    log_separador
    log_etapa "ETAPA 2/4 — Instalando Microsoft Edge Stable"

    local versao_atual
    versao_atual="$(versao_edge)"

    if pacote_instalado "microsoft-edge-stable"; then
        log_info "Edge já instalado (versão: ${versao_atual}) — verificando atualizações."
        apt-get install -y -qq --only-upgrade microsoft-edge-stable >> "$LOG_ARQUIVO" 2>&1 \
            || log_aviso "Não foi possível atualizar o Edge. Mantendo versão atual."
        local versao_nova
        versao_nova="$(versao_edge)"
        if [[ "$versao_atual" != "$versao_nova" ]]; then
            log_ok "Edge atualizado: ${versao_atual} → ${versao_nova}"
        else
            log_ok "Edge já está na versão mais recente: ${versao_atual}"
        fi
    else
        log_info "Instalando microsoft-edge-stable (isso pode demorar alguns minutos)..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq microsoft-edge-stable \
            >> "$LOG_ARQUIVO" 2>&1 \
            || log_erro "Falha ao instalar microsoft-edge-stable. Veja: ${LOG_ARQUIVO}"

        local versao_instalada
        versao_instalada="$(versao_edge)"
        log_ok "Microsoft Edge instalado com sucesso (versão: ${versao_instalada})."
    fi

    if [[ ! -x "$(command -v microsoft-edge-stable)" ]]; then
        log_erro "Binário 'microsoft-edge-stable' não encontrado após instalação."
    fi
    log_info "Binário: $(command -v microsoft-edge-stable)"
}

# -----------------------------------------------------------------------------
# ETAPA 3: Gera os arquivos de serviço kiosk
# -----------------------------------------------------------------------------

configurar_edge_kiosk() {
    log_separador
    log_etapa "ETAPA 3/4 — Configurando Microsoft Edge em modo kiosk"

    # Carrega o perfil de flags técnicas (define JETT_EDGE_FLAGS_STR)
    # BUG A fix: flags vêm do perfil, não de array local
    if [[ -f "$PERFIL_CONF" ]]; then
        # shellcheck source=config/browsers/edge.conf
        source "$PERFIL_CONF"
    else
        log_erro "Perfil de flags não encontrado: ${PERFIL_CONF}. Execute a partir da raiz do projeto."
    fi

    local flags_str="${JETT_EDGE_FLAGS_STR}"

    local home_jett="/home/${USUARIO_JETT}"
    local systemd_user_dir="${home_jett}/.config/systemd/user"
    local uid_jett
    uid_jett="$(id -u "${USUARIO_JETT}" 2>/dev/null || echo "1000")"

    mkdir -p "$systemd_user_dir"
    mkdir -p "$CONFIG_DIR"

    # ── Serviço de usuário (~/.config/systemd/user/edge-kiosk.service) ────────
    local servico_user="${systemd_user_dir}/edge-kiosk.service"
    log_info "Criando serviço de usuário: ${servico_user}"

    cat > "$servico_user" << EOF
# =============================================================================
# edge-kiosk.service — Serviço de usuário para Microsoft Edge Kiosk
# =============================================================================
# Localização: ~/.config/systemd/user/edge-kiosk.service
# Gerenciado por: systemctl --user (usuário '${USUARIO_JETT}')
#
# Uso:
#   systemctl --user start edge-kiosk
#   systemctl --user stop  edge-kiosk
#   systemctl --user status edge-kiosk
# =============================================================================

[Unit]
Description=Jett OS — Microsoft Edge Kiosk via Cage
After=default.target
# Exclusão mútua: apenas um compositor/browser kiosk por vez
Conflicts=cage-kiosk.service brave-kiosk.service thorium-kiosk.service opera-kiosk.service firefox-kiosk.service

[Service]
Type=simple

Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=WAYLAND_DISPLAY=wayland-1
Environment=OZONE_PLATFORM=wayland
Environment=GDK_BACKEND=wayland
# VA-API para decodificação de vídeo por hardware
Environment=LIBVA_DRIVER_NAME=iHD

ExecStart=/usr/bin/cage -- /usr/bin/microsoft-edge-stable \\
    ${flags_str// / \\
    } \\
    "${EDGE_URL_INICIAL}"

Restart=always
RestartSec=3
TimeoutStartSec=15

StandardOutput=journal
StandardError=journal
SyslogIdentifier=jett-edge-kiosk

[Install]
WantedBy=default.target
EOF

    # ── Serviço de sistema (/etc/systemd/system/edge-kiosk.service) ───────────
    local servico_projeto="${CONFIG_DIR}/edge-kiosk.service"
    local servico_sistema="${SERVICO_DESTINO}/edge-kiosk.service"

    log_info "Criando serviço de sistema: ${servico_projeto}"

    cat > "$servico_projeto" << EOF
# =============================================================================
# edge-kiosk.service — Serviço de sistema para Microsoft Edge Kiosk
# =============================================================================
# Localização: /etc/systemd/system/edge-kiosk.service
# Instalado por: build/browsers/install-edge.sh
#
# Inicia o Cage + Microsoft Edge como usuário '${USUARIO_JETT}' no boot.
#
# Uso:
#   sudo systemctl start  edge-kiosk
#   sudo systemctl stop   edge-kiosk
#   sudo systemctl status edge-kiosk
#   journalctl -u edge-kiosk -f
# =============================================================================

[Unit]
Description=Jett OS — Microsoft Edge Kiosk (serviço de sistema)
After=network.target multi-user.target systemd-user-sessions.service
RequiresMountsFor=/home
# Exclusão mútua com outros kiosks e com o Sway (que gerencia o browser diretamente)
Conflicts=cage-kiosk.service brave-kiosk.service thorium-kiosk.service opera-kiosk.service firefox-kiosk.service

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

# Carrega URL personalizada se definida
EnvironmentFile=-/etc/jett-os/edge.conf

# Aguarda DRM/KMS antes de iniciar o compositor
ExecStartPre=/bin/bash -c 'until ls /dev/dri/card* &>/dev/null; do sleep 0.3; done'
ExecStartPre=/bin/bash -c 'mkdir -p /run/user/${uid_jett} && chown ${USUARIO_JETT}:${USUARIO_JETT} /run/user/${uid_jett} && chmod 700 /run/user/${uid_jett}'

ExecStart=/usr/bin/cage -- /usr/bin/microsoft-edge-stable \\
    ${flags_str// / \\
    } \\
    \${JETT_EDGE_URL:-${EDGE_URL_INICIAL}}

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
SyslogIdentifier=jett-edge-kiosk

[Install]
WantedBy=multi-user.target
EOF

    # Instala o serviço no sistema
    log_info "Instalando serviço: ${servico_sistema}"
    cp "$servico_projeto" "$servico_sistema" \
        || log_erro "Falha ao copiar serviço para ${servico_sistema}."

    # Ajusta propriedade do diretório do usuário
    chown -R "${USUARIO_JETT}:${USUARIO_JETT}" "$systemd_user_dir"

    log_ok "Arquivos de serviço criados:"
    log_info "  → Usuário : ${servico_user}"
    log_info "  → Projeto : ${servico_projeto}"
    log_info "  → Sistema : ${servico_sistema}"
}

# -----------------------------------------------------------------------------
# ETAPA 4: Ativa serviços e registra o navegador
# -----------------------------------------------------------------------------

ativar_e_registrar_edge() {
    log_separador
    log_etapa "ETAPA 4/4 — Registrando Microsoft Edge no Jett OS"

    # Recarrega o daemon do systemd
    log_info "Recarregando daemon do systemd..."
    systemctl daemon-reload >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "daemon-reload falhou — reinicie para aplicar o serviço."

    # Habilita o serviço de sistema (não o inicia — apenas garante que está disponível)
    log_info "Habilitando edge-kiosk.service..."
    systemctl enable edge-kiosk.service >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "Não foi possível habilitar edge-kiosk.service."

    # Habilita o serviço de usuário
    log_info "Habilitando serviço do usuário '${USUARIO_JETT}'..."
    su -l "$USUARIO_JETT" -c \
        "XDG_RUNTIME_DIR=/run/user/$(id -u "$USUARIO_JETT") systemctl --user enable edge-kiosk.service" \
        >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "Não foi possível habilitar edge-kiosk.service --user."

    # Cria/atualiza arquivo de configuração runtime do Edge.
    # BUG A fix: inclui JETT_EDGE_FLAGS_STR para que o jett-switch.sh leia
    # as flags corretas (com --ms-clarity-boost etc.) ao trocar de navegador.
    mkdir -p "$CONFIG_JETT"
    cat > "${CONFIG_JETT}/edge.conf" << EDGECONF
# /etc/jett-os/edge.conf — Configuração do Microsoft Edge no Jett OS
# Gerado por install-edge.sh v${VERSAO_SCRIPT}. Não edite manualmente.
# Lido como EnvironmentFile pelo edge-kiosk.service e por jett-switch.sh.

# URL que o Edge abre ao iniciar
JETT_EDGE_URL="${EDGE_URL_INICIAL}"

# Flags técnicas de integração (fonte: config/browsers/edge.conf)
# Usadas pelo jett-switch.sh ao trocar para Edge via Super+B
JETT_EDGE_FLAGS_STR="${JETT_EDGE_FLAGS_STR}"
EDGECONF
    log_ok "Arquivo de configuração criado/atualizado: ${CONFIG_JETT}/edge.conf"

    # Registra em navegadores-instalados.conf
    local versao_edge_inst
    versao_edge_inst="$(versao_edge)"
    registrar_navegador "EDGE" "$versao_edge_inst" "$(command -v microsoft-edge-stable)"

    # Define como navegador padrão se --set-default foi passado
    if [[ "$DEFINIR_PADRAO" == "true" ]]; then
        log_info "Definindo Edge como navegador ativo em navegador.conf..."
        # Usa JETT_EDGE_FLAGS_STR (do source do perfil feito em configurar_edge_kiosk)
        printf "# /etc/jett-os/navegador.conf\n# Gerado por install-edge.sh v%s\nJETT_NAVEGADOR=\"edge\"\nJETT_NAVEGADOR_CMD=\"microsoft-edge-stable %s %s\"\n" \
            "$VERSAO_SCRIPT" "${JETT_EDGE_FLAGS_STR}" "${EDGE_URL_INICIAL}" \
            > "${CONFIG_JETT}/navegador.conf"
        log_ok "Edge definido como navegador ativo."
    fi
}

# -----------------------------------------------------------------------------
# FUNÇÃO COMPARTILHADA: Registra navegador em navegadores-instalados.conf
# -----------------------------------------------------------------------------

registrar_navegador() {
    local id_upper="$1"   # Ex: "EDGE"
    local versao="$2"     # Ex: "124.0.2478.51"
    local binario="$3"    # Ex: "/usr/bin/microsoft-edge-stable"
    local conf="${CONFIG_JETT}/navegadores-instalados.conf"

    mkdir -p "${CONFIG_JETT}"

    # Cria o arquivo com cabeçalho se não existir
    if [[ ! -f "$conf" ]]; then
        printf "# /etc/jett-os/navegadores-instalados.conf\n# Registro de navegadores instalados no Jett OS\n# Atualizado automaticamente pelos scripts de instalação\n# NÃO edite manualmente — use os scripts de instalação\n\n" \
            > "$conf"
    fi

    # Remove entradas antigas para este navegador (idempotência)
    sed -i "/^JETT_${id_upper}_/d" "$conf"
    # Remove linha em branco dupla residual
    sed -i '/^$/N;/^\n$/d' "$conf"

    # Adiciona entradas atualizadas
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
    echo -e "${COR_VERDE}║   Microsoft Edge instalado e configurado!        ║${COR_RESET}"
    echo -e "${COR_VERDE}╚══════════════════════════════════════════════════╝${COR_RESET}"
    echo ""
    echo -e "  Versão instalada  : ${COR_CIANO}$(versao_edge)${COR_RESET}"
    echo -e "  URL inicial       : ${COR_CIANO}${EDGE_URL_INICIAL}${COR_RESET}"
    echo -e "  Serviço kiosk     : ${COR_CIANO}edge-kiosk.service${COR_RESET}"
    echo -e "  Config Edge       : ${COR_CIANO}${CONFIG_JETT}/edge.conf${COR_RESET}"
    echo -e "  Registro          : ${COR_CIANO}${CONFIG_JETT}/navegadores-instalados.conf${COR_RESET}"
    echo -e "  Log completo      : ${COR_CIANO}${LOG_ARQUIVO}${COR_RESET}"
    echo ""
    echo -e "  ${COR_AMARELO}Flags ativas:${COR_RESET}"
    for flag in "${EDGE_FLAGS[@]}"; do
        echo -e "    ${COR_BRANCO}${flag}${COR_RESET}"
    done
    echo ""
    echo -e "  ${COR_AMARELO}Para ativar o Edge como navegador padrão:${COR_RESET}"
    echo -e "    ${COR_CIANO}sudo ./install-edge.sh --set-default${COR_RESET}"
    echo -e "  ${COR_AMARELO}Ou via GRUB: selecione 'Microsoft Edge' no menu de boot${COR_RESET}"
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
                EDGE_URL_INICIAL="$1"
                ;;
            --set-default)
                DEFINIR_PADRAO=true
                ;;
            --help|-h)
                echo "Uso: sudo ./install-edge.sh [--url URL] [--set-default]"
                echo ""
                echo "Opções:"
                echo "  --url URL       URL inicial do Edge (padrão: about:blank)"
                echo "  --set-default   Define o Edge como navegador ativo no Jett OS"
                echo ""
                echo "Exemplos:"
                echo "  sudo ./install-edge.sh"
                echo "  sudo ./install-edge.sh --url https://meusite.com --set-default"
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
    echo "  ███████╗██████╗  ██████╗ ███████╗"
    echo "  ██╔════╝██╔══██╗██╔════╝ ██╔════╝"
    echo "  █████╗  ██║  ██║██║  ███╗█████╗  "
    echo "  ██╔══╝  ██║  ██║██║   ██║██╔══╝  "
    echo "  ███████╗██████╔╝╚██████╔╝███████╗"
    echo "  ╚══════╝╚═════╝  ╚═════╝ ╚══════╝"
    echo -e "${COR_RESET}"
    echo -e "  ${COR_BRANCO}Instalação do Microsoft Edge — Jett OS v${VERSAO_SCRIPT}${COR_RESET}"
    echo ""

    processar_argumentos "$@"
    verificar_root
    inicializar_log
    verificar_base_instalada
    verificar_conexao

    log_info "URL inicial: ${EDGE_URL_INICIAL}"
    log_info "Definir como padrão: ${DEFINIR_PADRAO}"
    echo ""

    adicionar_repositorio_edge
    instalar_edge
    configurar_edge_kiosk
    ativar_e_registrar_edge
    exibir_resumo
}

main "$@"
