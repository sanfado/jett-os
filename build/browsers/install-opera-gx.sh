#!/usr/bin/env bash
# =============================================================================
# install-opera-gx.sh — Instalação e configuração do Opera GX no Jett OS
# =============================================================================
# Descrição:
#   Instala o Opera GX via repositório oficial da Opera para Linux (deb.opera.com).
#   Pacote: opera-gx-stable, repositório exclusivo https://deb.opera.com/opera-gx-stable/
#
# Referência:
#   opera.com/pt-br/gx/linux — página oficial do Opera GX para Linux
#
# Uso:
#   sudo ./install-opera-gx.sh [opções]
#
# Opções:
#   --url URL         URL que o Opera GX abrirá ao iniciar (padrão: about:blank)
#   --set-default     Define o Opera GX como navegador ativo
#   --help            Exibe esta ajuda
#
# Idempotência:
#   Seguro de executar múltiplas vezes. Se já instalado, verifica atualizações
#   e regenera os arquivos de configuração.
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
NOME_NAVEGADOR="opera-gx"
NOME_EXIBICAO="Opera GX"

# URL inicial
OPERA_URL_INICIAL="${OPERA_URL_INICIAL:-about:blank}"

# Define Opera GX como padrão ao instalar?
DEFINIR_PADRAO=false

# Nome do pacote e binário do Opera GX para Linux
OPERA_PACOTE="opera-gx-stable"
OPERA_BINARIO="opera"

# Diretório raiz do projeto (dois níveis acima: build/browsers/ → raiz)
PROJETO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CONFIG_DIR="${PROJETO_DIR}/config"
CONFIG_JETT="/etc/jett-os"
SERVICO_DESTINO="/etc/systemd/system"

# Repositório oficial Opera GX
# Chave e entrada APT conforme documentação oficial em deb.opera.com/opera-gx-stable/
OPERA_GPG_URL="https://deb.opera.com/archive.key"
OPERA_GPG_DEST="/usr/share/keyrings/opera-browser.gpg"
OPERA_LIST_FILE="/etc/apt/sources.list.d/opera-archive.list"
OPERA_REPO_URL="https://deb.opera.com/opera-gx-stable/"

# Flags de kiosk e Wayland carregadas do perfil técnico centralizado.
# Fonte canônica: config/browsers/opera-gx.conf (define JETT_OPERA_FLAGS_STR).
# BUG A fix: não duplicar flags aqui — source do perfil garante consistência.
PERFIL_CONF="${PROJETO_DIR}/config/browsers/opera-gx.conf"

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
        echo "  install-opera-gx.sh v${VERSAO_SCRIPT} — $(date '+%Y-%m-%d %H:%M:%S')"
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
        log_erro "Execute como root: sudo ./install-opera-gx.sh"
    fi
}

verificar_base_instalada() {
    if ! id "$USUARIO_JETT" &>/dev/null; then
        log_erro "Usuário '${USUARIO_JETT}' não encontrado. Execute build-base.sh primeiro."
    fi
    log_ok "Pré-requisito verificado: usuário '${USUARIO_JETT}' presente."
}

verificar_conexao() {
    log_info "Verificando acesso a deb.opera.com..."
    if ! curl -sf --max-time 15 "https://deb.opera.com" -o /dev/null; then
        log_erro "Sem acesso a deb.opera.com. Verifique a conexão."
    fi
    log_ok "Acesso ao repositório Opera confirmado."
}

pacote_instalado() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

versao_opera() {
    if command -v opera &>/dev/null; then
        opera --version 2>/dev/null | awk '{print $NF}' || \
        dpkg-query -W -f='${Version}' "${OPERA_PACOTE:-opera-stable}" 2>/dev/null || \
        echo "instalado"
    else
        echo "não instalado"
    fi
}

# -----------------------------------------------------------------------------
# ETAPA 1: Adiciona o repositório oficial Opera GX
# -----------------------------------------------------------------------------

adicionar_repositorio_opera() {
    log_separador
    log_etapa "ETAPA 1/4 — Adicionando repositório oficial Opera GX"

    # Verifica/baixa a chave GPG da Opera
    # A chave chega em formato PEM (ASCII armored) e é convertida para binário GPG
    if [[ -f "$OPERA_GPG_DEST" ]]; then
        log_info "Chave GPG da Opera já presente em ${OPERA_GPG_DEST} — pulando."
    else
        log_info "Baixando e convertendo chave GPG da Opera..."
        curl -fsSL "$OPERA_GPG_URL" \
            | gpg --dearmor \
            > "$OPERA_GPG_DEST" \
            2>> "$LOG_ARQUIVO" \
            || log_erro "Falha ao baixar/converter chave GPG da Opera."

        if ! file "$OPERA_GPG_DEST" | grep -q "GPG\|PGP\|data"; then
            rm -f "$OPERA_GPG_DEST"
            log_erro "Arquivo de chave GPG inválido. Abortando."
        fi
        log_ok "Chave GPG da Opera baixada e convertida: ${OPERA_GPG_DEST}"
    fi

    # Verifica/cria o arquivo de repositório APT
    # Entrada exata conforme documentação oficial do Opera GX para Linux
    if [[ -f "$OPERA_LIST_FILE" ]]; then
        log_info "Repositório Opera GX já configurado em ${OPERA_LIST_FILE} — pulando."
    else
        log_info "Adicionando repositório Opera GX ao APT..."
        printf "deb [signed-by=%s] %s stable non-free\n" \
            "$OPERA_GPG_DEST" "$OPERA_REPO_URL" \
            > "$OPERA_LIST_FILE" \
            || log_erro "Falha ao criar ${OPERA_LIST_FILE}."
        log_ok "Repositório Opera GX adicionado: ${OPERA_LIST_FILE}"
    fi

    log_info "Atualizando lista de pacotes..."
    apt-get update -qq >> "$LOG_ARQUIVO" 2>&1 \
        || log_erro "Falha ao atualizar lista de pacotes."

    log_ok "Repositório oficial Opera GX configurado. Pacote: ${OPERA_PACOTE}"
}

# -----------------------------------------------------------------------------
# ETAPA 2: Instala o Opera GX
# -----------------------------------------------------------------------------

instalar_opera() {
    log_separador
    log_etapa "ETAPA 2/4 — Instalando ${NOME_EXIBICAO} (pacote: ${OPERA_PACOTE})"

    local versao_atual
    versao_atual="$(versao_opera)"

    if pacote_instalado "$OPERA_PACOTE"; then
        log_info "Opera já instalado (versão: ${versao_atual}) — verificando atualizações."
        apt-get install -y -qq --only-upgrade "$OPERA_PACOTE" >> "$LOG_ARQUIVO" 2>&1 \
            || log_aviso "Não foi possível atualizar. Mantendo versão atual."
        local versao_nova
        versao_nova="$(versao_opera)"
        if [[ "$versao_atual" != "$versao_nova" ]]; then
            log_ok "Opera atualizado: ${versao_atual} → ${versao_nova}"
        else
            log_ok "Opera já está na versão mais recente: ${versao_atual}"
        fi
    else
        log_info "Instalando ${OPERA_PACOTE} (isso pode demorar alguns minutos)..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$OPERA_PACOTE" \
            >> "$LOG_ARQUIVO" 2>&1 \
            || log_erro "Falha ao instalar ${OPERA_PACOTE}. Veja: ${LOG_ARQUIVO}"

        local versao_instalada
        versao_instalada="$(versao_opera)"
        log_ok "${NOME_EXIBICAO} instalado (versão: ${versao_instalada})."
    fi

    if ! command -v opera &>/dev/null; then
        log_erro "Binário 'opera' não encontrado após instalação."
    fi
    log_info "Binário: $(command -v opera)"
}

# -----------------------------------------------------------------------------
# ETAPA 3: Gera os arquivos de serviço kiosk
# -----------------------------------------------------------------------------

configurar_opera_kiosk() {
    log_separador
    log_etapa "ETAPA 3/4 — Configurando ${NOME_EXIBICAO} em modo kiosk"

    # Carrega o perfil de flags técnicas (define JETT_OPERA_FLAGS_STR)
    # BUG A fix: flags vêm do perfil, não de array local
    if [[ -f "$PERFIL_CONF" ]]; then
        # shellcheck source=config/browsers/opera-gx.conf
        source "$PERFIL_CONF"
    else
        log_erro "Perfil de flags não encontrado: ${PERFIL_CONF}."
    fi

    local flags_str="${JETT_OPERA_FLAGS_STR}"

    local home_jett="/home/${USUARIO_JETT}"
    local systemd_user_dir="${home_jett}/.config/systemd/user"
    local uid_jett
    uid_jett="$(id -u "${USUARIO_JETT}" 2>/dev/null || echo "1000")"

    mkdir -p "$systemd_user_dir"
    mkdir -p "$CONFIG_DIR"

    # ── Serviço de usuário ─────────────────────────────────────────────────────
    local servico_user="${systemd_user_dir}/opera-kiosk.service"
    log_info "Criando serviço de usuário: ${servico_user}"

    cat > "$servico_user" << EOF
# =============================================================================
# opera-kiosk.service — Serviço de usuário para Opera GX Kiosk
# =============================================================================
# Localização: ~/.config/systemd/user/opera-kiosk.service
# Pacote: ${OPERA_PACOTE}  |  Binário: /usr/bin/opera
#
# Uso:
#   systemctl --user start  opera-kiosk
#   systemctl --user stop   opera-kiosk
#   systemctl --user status opera-kiosk
# =============================================================================

[Unit]
Description=Jett OS — Opera GX Kiosk via Cage
After=default.target
Conflicts=cage-kiosk.service brave-kiosk.service edge-kiosk.service thorium-kiosk.service firefox-kiosk.service

[Service]
Type=simple

Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=WAYLAND_DISPLAY=wayland-1
Environment=OZONE_PLATFORM=wayland
Environment=GDK_BACKEND=wayland
Environment=LIBVA_DRIVER_NAME=iHD

ExecStart=/usr/bin/cage -- /usr/bin/opera \\
    ${flags_str// / \\
    } \\
    "${OPERA_URL_INICIAL}"

Restart=always
RestartSec=3
TimeoutStartSec=15

StandardOutput=journal
StandardError=journal
SyslogIdentifier=jett-opera-kiosk

[Install]
WantedBy=default.target
EOF

    # ── Serviço de sistema ─────────────────────────────────────────────────────
    local servico_projeto="${CONFIG_DIR}/opera-kiosk.service"
    local servico_sistema="${SERVICO_DESTINO}/opera-kiosk.service"

    log_info "Criando serviço de sistema: ${servico_projeto}"

    cat > "$servico_projeto" << EOF
# =============================================================================
# opera-kiosk.service — Serviço de sistema para Opera GX Kiosk
# =============================================================================
# Localização: /etc/systemd/system/opera-kiosk.service
# Instalado por: build/browsers/install-opera-gx.sh
# Pacote: ${OPERA_PACOTE}  |  Binário: /usr/bin/opera
#
# Uso:
#   sudo systemctl start  opera-kiosk
#   sudo systemctl stop   opera-kiosk
#   sudo systemctl status opera-kiosk
#   journalctl -u opera-kiosk -f
# =============================================================================

[Unit]
Description=Jett OS — Opera GX Kiosk (serviço de sistema)
After=network.target multi-user.target systemd-user-sessions.service
RequiresMountsFor=/home
Conflicts=cage-kiosk.service brave-kiosk.service edge-kiosk.service thorium-kiosk.service firefox-kiosk.service

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

EnvironmentFile=-/etc/jett-os/opera.conf

ExecStartPre=/bin/bash -c 'until ls /dev/dri/card* &>/dev/null; do sleep 0.3; done'
ExecStartPre=/bin/bash -c 'mkdir -p /run/user/${uid_jett} && chown ${USUARIO_JETT}:${USUARIO_JETT} /run/user/${uid_jett} && chmod 700 /run/user/${uid_jett}'

ExecStart=/usr/bin/cage -- /usr/bin/opera \\
    ${flags_str// / \\
    } \\
    \${JETT_OPERA_URL:-${OPERA_URL_INICIAL}}

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
SyslogIdentifier=jett-opera-kiosk

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

ativar_e_registrar_opera() {
    log_separador
    log_etapa "ETAPA 4/4 — Registrando Opera GX no Jett OS"

    log_info "Recarregando daemon do systemd..."
    systemctl daemon-reload >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "daemon-reload falhou."

    log_info "Habilitando opera-kiosk.service..."
    systemctl enable opera-kiosk.service >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "Não foi possível habilitar opera-kiosk.service."

    log_info "Habilitando serviço do usuário '${USUARIO_JETT}'..."
    su -l "$USUARIO_JETT" -c \
        "XDG_RUNTIME_DIR=/run/user/$(id -u "$USUARIO_JETT") systemctl --user enable opera-kiosk.service" \
        >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "Não foi possível habilitar opera-kiosk.service --user."

    # Cria arquivo de configuração específico do Opera
    # Cria/atualiza opera.conf com flags para uso pelo jett-switch.sh em runtime.
    # BUG A fix: inclui JETT_OPERA_FLAGS_STR para troca correta pelo jett-switch.sh.
    mkdir -p "$CONFIG_JETT"
    cat > "${CONFIG_JETT}/opera.conf" << OPERACONF
# /etc/jett-os/opera.conf — Configuração do Opera GX no Jett OS
# Gerado por install-opera-gx.sh v${VERSAO_SCRIPT}. Não edite manualmente.
# Lido como EnvironmentFile pelo opera-kiosk.service e por jett-switch.sh.

# URL que o Opera abre ao iniciar
JETT_OPERA_URL="${OPERA_URL_INICIAL}"

# Pacote instalado
JETT_OPERA_PACOTE="${OPERA_PACOTE}"

# Flags técnicas de integração (fonte: config/browsers/opera-gx.conf)
# Usadas pelo jett-switch.sh ao trocar para Opera GX via Super+B
JETT_OPERA_FLAGS_STR="${JETT_OPERA_FLAGS_STR}"
OPERACONF
    log_ok "Arquivo de configuração criado/atualizado: ${CONFIG_JETT}/opera.conf"

    # Registra em navegadores-instalados.conf
    # Usa "OPERA_GX" como identificador para clareza
    local versao_inst
    versao_inst="$(versao_opera)"
    registrar_navegador "OPERA_GX" "$versao_inst" "$(command -v opera)"

    # Define como navegador padrão se --set-default foi passado
    if [[ "$DEFINIR_PADRAO" == "true" ]]; then
        log_info "Definindo Opera GX como navegador ativo..."
        printf "# /etc/jett-os/navegador.conf\n# Gerado por install-opera-gx.sh v%s\nJETT_NAVEGADOR=\"opera-gx\"\nJETT_NAVEGADOR_CMD=\"opera %s %s\"\n" \
            "$VERSAO_SCRIPT" "${JETT_OPERA_FLAGS_STR}" "${OPERA_URL_INICIAL}" \
            > "${CONFIG_JETT}/navegador.conf"
        log_ok "Opera GX definido como navegador ativo."
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
    echo -e "${COR_VERDE}║      Opera GX instalado e configurado!           ║${COR_RESET}"
    echo -e "${COR_VERDE}╚══════════════════════════════════════════════════╝${COR_RESET}"
    echo ""
    echo -e "  Versão instalada  : ${COR_CIANO}$(versao_opera)${COR_RESET}"
    echo -e "  Pacote            : ${COR_CIANO}${OPERA_PACOTE}${COR_RESET}"
    echo -e "  Repositório       : ${COR_CIANO}${OPERA_REPO_URL}${COR_RESET}"
    echo -e "  Binário           : ${COR_CIANO}/usr/bin/opera${COR_RESET}"
    echo -e "  URL inicial       : ${COR_CIANO}${OPERA_URL_INICIAL}${COR_RESET}"
    echo -e "  Serviço kiosk     : ${COR_CIANO}opera-kiosk.service${COR_RESET}"
    echo -e "  Config Opera      : ${COR_CIANO}${CONFIG_JETT}/opera.conf${COR_RESET}"
    echo -e "  Registro          : ${COR_CIANO}${CONFIG_JETT}/navegadores-instalados.conf${COR_RESET}"
    echo -e "  Log completo      : ${COR_CIANO}${LOG_ARQUIVO}${COR_RESET}"
    echo ""
    echo -e "  ${COR_AMARELO}Para ativar o Opera GX como navegador padrão:${COR_RESET}"
    echo -e "    ${COR_CIANO}sudo ./install-opera-gx.sh --set-default${COR_RESET}"
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
                OPERA_URL_INICIAL="$1"
                ;;
            --set-default)
                DEFINIR_PADRAO=true
                ;;
            --help|-h)
                echo "Uso: sudo ./install-opera-gx.sh [--url URL] [--set-default]"
                echo ""
                echo "Opções:"
                echo "  --url URL       URL inicial (padrão: about:blank)"
                echo "  --set-default   Define o Opera GX como navegador ativo"
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
    echo "   ██████╗ ██████╗ ███████╗██████╗  █████╗     ██████╗ ██╗  ██╗"
    echo "  ██╔═══██╗██╔══██╗██╔════╝██╔══██╗██╔══██╗   ██╔════╝ ╚██╗██╔╝"
    echo "  ██║   ██║██████╔╝█████╗  ██████╔╝███████║   ██║  ███╗ ╚███╔╝ "
    echo "  ██║   ██║██╔═══╝ ██╔══╝  ██╔══██╗██╔══██║   ██║   ██║ ██╔██╗ "
    echo "  ╚██████╔╝██║     ███████╗██║  ██║██║  ██║   ╚██████╔╝██╔╝ ██╗"
    echo "   ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝    ╚═════╝ ╚═╝  ╚═╝"
    echo -e "${COR_RESET}"
    echo -e "  ${COR_BRANCO}Instalação do Opera GX — Jett OS v${VERSAO_SCRIPT}${COR_RESET}"
    echo ""

    processar_argumentos "$@"
    inicializar_log

    verificar_root
    verificar_base_instalada
    verificar_conexao

    log_info "URL inicial: ${OPERA_URL_INICIAL}"
    log_info "Definir como padrão: ${DEFINIR_PADRAO}"
    echo ""

    adicionar_repositorio_opera
    instalar_opera
    configurar_opera_kiosk
    ativar_e_registrar_opera
    exibir_resumo
}

main "$@"
