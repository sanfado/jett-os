#!/usr/bin/env bash
# =============================================================================
# build-base.sh — Construção da base do Jett OS
# =============================================================================
# Descrição:
#   Configura um Debian Minimal como fundação do Jett OS. Instala apenas o
#   necessário para rodar o Cage Kiosk com Wayland, remove pacotes supérfluos,
#   configura o boot automático do navegador via systemd e otimiza a rede.
#
# Uso:
#   sudo ./build-base.sh [--navegador NOME]
#
# Opções:
#   --navegador   Nome do navegador padrão a ser lançado pelo Cage
#                 Valores: brave | edge | thorium | opera-gx | firefox
#                 Padrão: firefox
#
# Idempotência:
#   O script verifica o estado atual antes de cada ação. É seguro executá-lo
#   múltiplas vezes sem efeitos colaterais indesejados.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# VARIÁVEIS GLOBAIS
# -----------------------------------------------------------------------------

NAVEGADOR_PADRAO="${NAVEGADOR_PADRAO:-firefox}"  # pode ser sobrescrito por --navegador
USUARIO_JETT="jett"                              # usuário kiosk do sistema
LOG_ARQUIVO="/var/log/jett-os-build.log"         # arquivo de log persistente
VERSAO_SCRIPT="1.0.0"

# Cores para saída no terminal
COR_RESET="\033[0m"
COR_VERDE="\033[1;32m"
COR_AMARELO="\033[1;33m"
COR_VERMELHO="\033[1;31m"
COR_CIANO="\033[1;36m"
COR_BRANCO="\033[1;37m"

# Pacotes essenciais para o Jett OS funcionar
PACOTES_INSTALAR=(
    # Wayland — servidor gráfico moderno, substitui X11
    "wayland-protocols"
    "libwayland-client0"
    "libwayland-server0"

    # Cage — compositor Wayland em modo kiosk (um app, tela cheia)
    "cage"

    # Fontes essenciais para renderização no navegador
    "fonts-noto"           # cobre unicode amplo, incluindo emoji
    "fonts-noto-color-emoji"

    # Áudio — PulseAudio para suporte de som no navegador
    "pulseaudio"
    "pulseaudio-utils"

    # Utilitários mínimos de sistema
    "dbus-user-session"    # necessário para sessão Wayland do usuário
    "xdg-utils"            # integração desktop mínima para navegadores
    "ca-certificates"      # certificados TLS/SSL
    "curl"                 # transferências HTTP (usado em scripts)
    "wget"                 # downloads (instalação de navegadores)
    "gnupg"                # verificação de chaves GPG dos repositórios
    "apt-transport-https"  # repositórios via HTTPS
)

# Pacotes desnecessários que podem vir no Debian Minimal — remover se presentes
PACOTES_REMOVER=(
    # Servidores de email
    "exim4" "exim4-base" "exim4-config" "exim4-daemon-light"
    # Utilitários de impressão
    "cups" "cups-client" "cups-common"
    # Bluetooth (não necessário para kiosk)
    "bluez" "bluetooth"
    # Gerenciadores de pacote alternativos
    "aptitude" "synaptic"
    # Jogos e demos
    "games-default"
    # Documentação desnecessária
    "man-db" "manpages"
    # Ferramentas de acessibilidade desktop (não aplicável em kiosk)
    "at-spi2-core" "at-spi2-common"
    # Serviços de localização
    "avahi-daemon" "avahi-autoipd"
    # Samba/compartilhamento de arquivos
    "samba-common" "samba-libs"
)

# -----------------------------------------------------------------------------
# FUNÇÕES DE LOG
# -----------------------------------------------------------------------------

# Inicializa o arquivo de log com cabeçalho da sessão
inicializar_log() {
    mkdir -p "$(dirname "$LOG_ARQUIVO")"
    {
        echo "======================================================="
        echo "  Jett OS — Build Base v${VERSAO_SCRIPT}"
        echo "  Data/Hora: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  Navegador padrão: ${NAVEGADOR_PADRAO}"
        echo "======================================================="
    } >> "$LOG_ARQUIVO"
}

# Exibe e registra mensagem de progresso (etapa principal)
log_etapa() {
    local mensagem="$1"
    local timestamp
    timestamp="$(date '+%H:%M:%S')"
    echo -e "${COR_CIANO}[${timestamp}] >>> ${mensagem}${COR_RESET}"
    echo "[${timestamp}] [ETAPA] ${mensagem}" >> "$LOG_ARQUIVO"
}

# Exibe e registra mensagem informativa
log_info() {
    local mensagem="$1"
    local timestamp
    timestamp="$(date '+%H:%M:%S')"
    echo -e "${COR_BRANCO}[${timestamp}]     ${mensagem}${COR_RESET}"
    echo "[${timestamp}] [INFO]  ${mensagem}" >> "$LOG_ARQUIVO"
}

# Exibe e registra mensagem de sucesso
log_ok() {
    local mensagem="$1"
    local timestamp
    timestamp="$(date '+%H:%M:%S')"
    echo -e "${COR_VERDE}[${timestamp}]  ✓  ${mensagem}${COR_RESET}"
    echo "[${timestamp}] [OK]    ${mensagem}" >> "$LOG_ARQUIVO"
}

# Exibe e registra aviso (não bloqueia execução)
log_aviso() {
    local mensagem="$1"
    local timestamp
    timestamp="$(date '+%H:%M:%S')"
    echo -e "${COR_AMARELO}[${timestamp}]  !  ${mensagem}${COR_RESET}"
    echo "[${timestamp}] [AVISO] ${mensagem}" >> "$LOG_ARQUIVO"
}

# Exibe erro, registra no log e encerra o script
log_erro() {
    local mensagem="$1"
    local timestamp
    timestamp="$(date '+%H:%M:%S')"
    echo -e "${COR_VERMELHO}[${timestamp}]  ✗  ERRO: ${mensagem}${COR_RESET}" >&2
    echo "[${timestamp}] [ERRO]  ${mensagem}" >> "$LOG_ARQUIVO"
    exit 1
}

# Imprime separador visual para organizar as seções no terminal
log_separador() {
    echo -e "${COR_CIANO}─────────────────────────────────────────────────${COR_RESET}"
}

# -----------------------------------------------------------------------------
# FUNÇÕES DE VERIFICAÇÃO
# -----------------------------------------------------------------------------

# Verifica se o script está sendo executado como root
verificar_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_erro "Este script precisa ser executado como root. Use: sudo ./build-base.sh"
    fi
}

# Verifica se o sistema é Debian ou derivado compatível
verificar_sistema() {
    if [[ ! -f /etc/debian_version ]]; then
        log_erro "Sistema não compatível. Este script requer Debian ou derivado (Ubuntu, etc.)."
    fi
    local versao_debian
    versao_debian=$(cat /etc/debian_version)
    log_info "Sistema detectado: Debian/derivado — versão ${versao_debian}"
}

# Verifica se um pacote está instalado
pacote_instalado() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# Verifica se um usuário existe no sistema
usuario_existe() {
    id "$1" &>/dev/null
}

# -----------------------------------------------------------------------------
# FUNÇÕES DE BUILD
# -----------------------------------------------------------------------------

# ETAPA 0: Processa argumentos da linha de comando
processar_argumentos() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --navegador)
                shift
                case "$1" in
                    brave|edge|thorium|opera-gx|firefox)
                        NAVEGADOR_PADRAO="$1"
                        ;;
                    *)
                        log_erro "Navegador inválido: '$1'. Use: brave | edge | thorium | opera-gx | firefox"
                        ;;
                esac
                ;;
            --help|-h)
                echo "Uso: sudo ./build-base.sh [--navegador NOME]"
                echo "Navegadores: brave | edge | thorium | opera-gx | firefox"
                exit 0
                ;;
            *)
                log_erro "Argumento desconhecido: '$1'. Use --help para ver as opções."
                ;;
        esac
        shift
    done
}

# ETAPA 1: Atualiza os repositórios e o sistema base
atualizar_sistema() {
    log_separador
    log_etapa "ETAPA 1/6 — Atualizando repositórios e sistema base"

    # Configura o APT para rodar sem interação humana
    export DEBIAN_FRONTEND=noninteractive

    log_info "Atualizando lista de pacotes..."
    apt-get update -qq >> "$LOG_ARQUIVO" 2>&1 \
        || log_erro "Falha ao atualizar lista de pacotes. Verifique sua conexão."

    log_info "Aplicando atualizações de segurança e sistema..."
    apt-get upgrade -y -qq >> "$LOG_ARQUIVO" 2>&1 \
        || log_erro "Falha ao atualizar pacotes do sistema."

    log_ok "Sistema base atualizado com sucesso."
}

# ETAPA 2: Remove pacotes desnecessários
remover_pacotes_desnecessarios() {
    log_separador
    log_etapa "ETAPA 2/6 — Removendo pacotes desnecessários"

    local removidos=0
    local nao_encontrados=0

    for pacote in "${PACOTES_REMOVER[@]}"; do
        if pacote_instalado "$pacote"; then
            log_info "Removendo: ${pacote}..."
            apt-get remove -y -qq "$pacote" >> "$LOG_ARQUIVO" 2>&1 \
                || log_aviso "Não foi possível remover: ${pacote}"
            (( removidos++ )) || true
        else
            (( nao_encontrados++ )) || true
        fi
    done

    # Remove dependências órfãs deixadas pelos pacotes removidos
    log_info "Limpando dependências órfãs..."
    apt-get autoremove -y -qq >> "$LOG_ARQUIVO" 2>&1

    # Limpa cache do APT para liberar espaço
    log_info "Limpando cache do APT..."
    apt-get clean -qq >> "$LOG_ARQUIVO" 2>&1

    log_ok "Remoção concluída: ${removidos} pacote(s) removido(s), ${nao_encontrados} já ausente(s)."
}

# ETAPA 3: Instala pacotes essenciais do Jett OS
instalar_pacotes_essenciais() {
    log_separador
    log_etapa "ETAPA 3/6 — Instalando pacotes essenciais (Wayland, Cage, fontes, áudio)"

    local instalados=0
    local ja_presentes=0

    for pacote in "${PACOTES_INSTALAR[@]}"; do
        if pacote_instalado "$pacote"; then
            log_info "Já instalado: ${pacote} — pulando."
            (( ja_presentes++ )) || true
        else
            log_info "Instalando: ${pacote}..."
            apt-get install -y -qq "$pacote" >> "$LOG_ARQUIVO" 2>&1 \
                || log_erro "Falha ao instalar: ${pacote}. Verifique o log em ${LOG_ARQUIVO}"
            (( instalados++ )) || true
        fi
    done

    log_ok "Instalação concluída: ${instalados} novo(s), ${ja_presentes} já presente(s)."
}

# ETAPA 4: Cria e configura o usuário kiosk 'jett'
configurar_usuario_jett() {
    log_separador
    log_etapa "ETAPA 4/6 — Configurando usuário kiosk '${USUARIO_JETT}'"

    # Cria o usuário se não existir
    if usuario_existe "$USUARIO_JETT"; then
        log_info "Usuário '${USUARIO_JETT}' já existe — verificando configurações."
    else
        log_info "Criando usuário '${USUARIO_JETT}' sem senha e sem shell interativo..."
        # --disabled-password: sem senha (login automático via getty)
        # --gecos: metadados do usuário (nome completo, etc.)
        # --shell: shell mínimo (não precisa de bash completo)
        useradd \
            --create-home \
            --shell /bin/bash \
            --comment "Jett OS Kiosk User" \
            --groups audio,video,input \
            "$USUARIO_JETT" >> "$LOG_ARQUIVO" 2>&1 \
            || log_erro "Falha ao criar usuário '${USUARIO_JETT}'."
        log_ok "Usuário '${USUARIO_JETT}' criado."
    fi

    # Garante que o usuário está nos grupos necessários para Wayland/áudio/vídeo
    local grupos_necessarios=("audio" "video" "input")
    for grupo in "${grupos_necessarios[@]}"; do
        if getent group "$grupo" > /dev/null 2>&1; then
            usermod -aG "$grupo" "$USUARIO_JETT" >> "$LOG_ARQUIVO" 2>&1 || true
            log_info "Usuário adicionado ao grupo: ${grupo}"
        else
            log_aviso "Grupo '${grupo}' não encontrado — pulando."
        fi
    done

    # Configura login automático via getty (console virtual tty1)
    local getty_override_dir="/etc/systemd/system/getty@tty1.service.d"
    local getty_override_file="${getty_override_dir}/autologin.conf"

    if [[ -f "$getty_override_file" ]]; then
        log_info "Login automático já configurado em ${getty_override_file} — verificando."
    else
        log_info "Configurando login automático no tty1..."
    fi

    mkdir -p "$getty_override_dir"
    # Override do serviço getty para logar automaticamente como 'jett'
    cat > "$getty_override_file" << EOF
# Jett OS — Login automático do usuário kiosk
# Gerado por: build-base.sh v${VERSAO_SCRIPT}
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${USUARIO_JETT} --noclear %I \$TERM
EOF
    log_ok "Login automático configurado em ${getty_override_file}."
}

# ETAPA 5: Configura o systemd para iniciar o Cage automaticamente
configurar_cage_autostart() {
    log_separador
    log_etapa "ETAPA 5/6 — Configurando Cage Kiosk como sessão automática via systemd"

    local home_jett="/home/${USUARIO_JETT}"
    local systemd_user_dir="${home_jett}/.config/systemd/user"
    local servico_cage="${systemd_user_dir}/cage-kiosk.service"
    local profile_jett="${home_jett}/.bash_profile"

    # Determina o comando do navegador conforme a escolha
    local cmd_navegador
    case "$NAVEGADOR_PADRAO" in
        brave)      cmd_navegador="brave-browser --kiosk" ;;
        edge)       cmd_navegador="microsoft-edge --kiosk --no-first-run" ;;
        thorium)    cmd_navegador="thorium-browser --kiosk" ;;
        opera-gx)   cmd_navegador="opera --kiosk" ;;
        firefox)    cmd_navegador="firefox --kiosk" ;;
        *)          cmd_navegador="firefox --kiosk" ;;
    esac

    log_info "Navegador padrão configurado: ${NAVEGADOR_PADRAO} → '${cmd_navegador}'"

    # Cria o diretório de serviços do usuário
    mkdir -p "$systemd_user_dir"

    # Cria o serviço systemd do usuário para o Cage
    cat > "$servico_cage" << EOF
# =============================================================================
# cage-kiosk.service — Jett OS Kiosk Session
# =============================================================================
# Inicia o Cage Kiosk Compositor com o navegador escolhido.
# Este serviço roda como usuário 'jett' (não root).
# Gerado por: build-base.sh v${VERSAO_SCRIPT}

[Unit]
Description=Jett OS — Cage Kiosk Session (${NAVEGADOR_PADRAO})
# Inicia apenas após o sistema de login estar pronto
After=default.target
# BUG B fix: conflito bidirecional — impede que os dois serviços subam juntos
Conflicts=brave-kiosk.service

[Service]
Type=simple

# Variáveis de ambiente necessárias para Wayland funcionar
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=WAYLAND_DISPLAY=wayland-1
Environment=MOZ_ENABLE_WAYLAND=1
Environment=GDK_BACKEND=wayland
Environment=QT_QPA_PLATFORM=wayland
Environment=CLUTTER_BACKEND=wayland
Environment=SDL_VIDEODRIVER=wayland

# BUG A fix: lê /etc/jett-os/navegador.conf para que edições manuais
# no arquivo reflitam no serviço sem precisar regerar o cage-kiosk.service.
# O '-' garante que a ausência do arquivo não seja erro fatal.
EnvironmentFile=-/etc/jett-os/navegador.conf

# Usa o comando do navegador.conf se disponível; cai no valor gerado no build
# se o arquivo ainda não existir (ex: primeira execução antes do install-browser)
ExecStart=/usr/bin/cage -- \${JETT_NAVEGADOR_CMD:-${cmd_navegador}}

# Reinicia automaticamente em caso de crash (proteção contra falha do navegador)
Restart=always
RestartSec=3

# Sem TTY alocada — roda na sessão gráfica Wayland
StandardInput=null

[Install]
WantedBy=default.target
EOF

    log_info "Serviço cage-kiosk.service criado em ${servico_cage}."

    # Habilita o serviço para o usuário 'jett'
    # loginctl enable-linger permite que serviços de usuário rodem sem sessão ativa
    log_info "Habilitando linger para o usuário '${USUARIO_JETT}'..."
    loginctl enable-linger "$USUARIO_JETT" >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "loginctl enable-linger falhou — o serviço pode não iniciar automaticamente."

    # Habilita o serviço no contexto do usuário
    log_info "Habilitando cage-kiosk.service para o usuário '${USUARIO_JETT}'..."
    su -l "$USUARIO_JETT" -c \
        "XDG_RUNTIME_DIR=/run/user/$(id -u "$USUARIO_JETT") systemctl --user enable cage-kiosk.service" \
        >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "Não foi possível habilitar via systemctl --user. Usando .bash_profile como fallback."

    # Fallback: inicia via .bash_profile se o systemd user daemon não estiver disponível
    # Isso garante que o Cage suba mesmo em ambientes sem lingering habilitado
    log_info "Configurando .bash_profile como fallback de inicialização..."
    cat > "$profile_jett" << 'PROFILE'
# =============================================================================
# .bash_profile — Jett OS Kiosk Auto-Start
# =============================================================================
# Fallback: inicia o Cage caso o systemd --user não tenha disparado o serviço.
# Roda apenas no tty1 para evitar conflitos em sessões SSH ou outros ttys.

if [[ -z "${WAYLAND_DISPLAY}" && -z "${DISPLAY}" && "$(tty)" == "/dev/tty1" ]]; then
    # Loga a inicialização para diagnóstico
    echo "[$(date '+%H:%M:%S')] Iniciando sessão Cage via .bash_profile" >> /tmp/jett-session.log

    # BUG C fix: verifica brave-kiosk primeiro (instalado pelo install-brave.sh),
    # depois cage-kiosk (serviço genérico do build-base.sh).
    # Antes desta correção, após install-brave.sh desabilitar cage-kiosk e
    # habilitar brave-kiosk, o fallback sempre caía no 'else' sem passar
    # pelo systemd — perdendo Restart=, journal e sandboxing.
    if systemctl --user is-enabled brave-kiosk.service &>/dev/null; then
        exec systemctl --user start brave-kiosk.service
    elif systemctl --user is-enabled cage-kiosk.service &>/dev/null; then
        exec systemctl --user start cage-kiosk.service
    else
        # Último recurso: chama o cage diretamente lendo o navegador ativo
        source /etc/jett-os/navegador.conf 2>/dev/null || JETT_NAVEGADOR_CMD="firefox --kiosk"
        exec /usr/bin/cage -- ${JETT_NAVEGADOR_CMD}
    fi
fi
PROFILE

    # Ajusta a propriedade dos arquivos criados para o usuário 'jett'
    chown -R "${USUARIO_JETT}:${USUARIO_JETT}" "$home_jett/.config" "$profile_jett"

    log_ok "Cage configurado para iniciar automaticamente com: '${cmd_navegador}'."
}

# ETAPA 6: Ativa TCP BBR e outras otimizações de rede via sysctl
configurar_rede_bbr() {
    log_separador
    log_etapa "ETAPA 6/6 — Configurando TCP BBR e otimizações de rede"

    local sysctl_jett="/etc/sysctl.d/99-jett-os.conf"

    # Verifica se as configurações já foram aplicadas anteriormente
    if [[ -f "$sysctl_jett" ]]; then
        log_info "Arquivo ${sysctl_jett} já existe — sobrescrevendo com configurações atualizadas."
    else
        log_info "Criando ${sysctl_jett}..."
    fi

    # Escreve as configurações de rede otimizadas para uso de navegador
    cat > "$sysctl_jett" << 'EOF'
# =============================================================================
# 99-jett-os.conf — Otimizações de rede do Jett OS
# =============================================================================
# Aplicadas automaticamente pelo systemd-sysctl no boot.
# Para aplicar imediatamente: sysctl --system

# --- TCP BBR (Bottleneck Bandwidth and Round-trip propagation time) ----------
# Algoritmo de controle de congestionamento desenvolvido pelo Google.
# Melhora significativamente throughput e latência em conexões modernas.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Buffers de socket (melhora streaming e downloads paralelos) -------------
# Tamanho máximo do buffer de recepção: 16 MB
net.core.rmem_max = 16777216
# Tamanho máximo do buffer de envio: 16 MB
net.core.wmem_max = 16777216
# Buffers TCP: mínimo, padrão, máximo
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# --- Otimizações TCP gerais ---------------------------------------------------
# Habilita timestamps TCP (melhora RTT e performance em conexões longas)
net.ipv4.tcp_timestamps = 1
# Habilita SACK (Selective Acknowledgment) para recuperação eficiente de perdas
net.ipv4.tcp_sack = 1
# Habilita Fast Open (reduz latência em conexões TCP frequentes)
net.ipv4.tcp_fastopen = 3
# Reduz tempo de espera para fechar conexões TIME_WAIT
net.ipv4.tcp_fin_timeout = 15
# Mantém conexões ativas por mais tempo (evita reconexões desnecessárias)
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# --- DNS e performance geral -------------------------------------------------
# Aumenta backlog de conexões pendentes (melhora performance do navegador)
net.core.somaxconn = 4096
# Aumenta fila de pacotes recebidos (evita drops em picos de tráfego)
net.core.netdev_max_backlog = 5000
EOF

    log_info "Configurações escritas em ${sysctl_jett}."

    # Aplica as configurações imediatamente sem necessidade de reboot
    log_info "Aplicando configurações via sysctl --system..."
    sysctl --system >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "sysctl --system retornou erro — verifique o log. As configurações serão aplicadas no próximo boot."

    # Verifica se o BBR foi ativado com sucesso
    local bbr_ativo
    bbr_ativo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "desconhecido")
    if [[ "$bbr_ativo" == "bbr" ]]; then
        log_ok "TCP BBR ativado com sucesso. Algoritmo em uso: ${bbr_ativo}"
    else
        log_aviso "TCP BBR não está ativo agora (valor atual: '${bbr_ativo}'). Será ativado no próximo boot."
        log_aviso "Verifique se o módulo 'tcp_bbr' está disponível: modprobe tcp_bbr"
    fi

    log_ok "Configurações de rede aplicadas."
}

# Salva a configuração do navegador em um arquivo central para outros scripts
salvar_config_navegador() {
    local config_dir="/etc/jett-os"
    local config_file="${config_dir}/navegador.conf"

    mkdir -p "$config_dir"
    cat > "$config_file" << EOF
# =============================================================================
# /etc/jett-os/navegador.conf — Configuração central do navegador Jett OS
# =============================================================================
# Gerado por: build-base.sh v${VERSAO_SCRIPT}
# Editável manualmente ou pelo launcher.

# Navegador ativo
JETT_NAVEGADOR="${NAVEGADOR_PADRAO}"

# Comando completo para o Cage (inclui flags de kiosk)
EOF

    case "$NAVEGADOR_PADRAO" in
        brave)      echo 'JETT_NAVEGADOR_CMD="brave-browser --kiosk"' >> "$config_file" ;;
        edge)       echo 'JETT_NAVEGADOR_CMD="microsoft-edge --kiosk --no-first-run"' >> "$config_file" ;;
        thorium)    echo 'JETT_NAVEGADOR_CMD="thorium-browser --kiosk"' >> "$config_file" ;;
        opera-gx)   echo 'JETT_NAVEGADOR_CMD="opera --kiosk"' >> "$config_file" ;;
        firefox)    echo 'JETT_NAVEGADOR_CMD="firefox --kiosk"' >> "$config_file" ;;
    esac

    log_info "Configuração do navegador salva em ${config_file}."
}

# Exibe resumo final do build
exibir_resumo() {
    log_separador
    echo ""
    echo -e "${COR_VERDE}╔══════════════════════════════════════════════════╗${COR_RESET}"
    echo -e "${COR_VERDE}║         Jett OS — Build Base Concluído!          ║${COR_RESET}"
    echo -e "${COR_VERDE}╚══════════════════════════════════════════════════╝${COR_RESET}"
    echo ""
    echo -e "  Navegador configurado : ${COR_CIANO}${NAVEGADOR_PADRAO}${COR_RESET}"
    echo -e "  Usuário kiosk         : ${COR_CIANO}${USUARIO_JETT}${COR_RESET}"
    echo -e "  Log completo          : ${COR_CIANO}${LOG_ARQUIVO}${COR_RESET}"
    echo -e "  Config do navegador   : ${COR_CIANO}/etc/jett-os/navegador.conf${COR_RESET}"
    echo ""
    echo -e "  ${COR_AMARELO}Próximos passos:${COR_RESET}"
    echo -e "    1. Instale o navegador escolhido (${NAVEGADOR_PADRAO})"
    echo -e "       → Execute: sudo ./install-browser.sh --navegador ${NAVEGADOR_PADRAO}"
    echo -e "    2. Reinicie o sistema para ativar todas as configurações"
    echo -e "       → Execute: sudo reboot"
    echo ""
    log_separador
}

# -----------------------------------------------------------------------------
# PONTO DE ENTRADA PRINCIPAL
# -----------------------------------------------------------------------------

main() {
    # Cabeçalho visual
    clear
    echo -e "${COR_CIANO}"
    echo "  ╦╔═╗╔╦╗╔╦╗  ╔═╗╔═╗"
    echo "  ║║╣  ║  ║   ║ ║╚═╗"
    echo " ╚╝╚═╝ ╩  ╩   ╚═╝╚═╝"
    echo -e "${COR_RESET}"
    echo -e "  ${COR_BRANCO}Build Base v${VERSAO_SCRIPT} — Construindo a fundação${COR_RESET}"
    echo ""

    # Processa argumentos antes de qualquer validação
    processar_argumentos "$@"

    # Inicializa o log
    inicializar_log

    # Verificações obrigatórias
    verificar_root
    verificar_sistema

    log_info "Iniciando build com navegador padrão: ${NAVEGADOR_PADRAO}"
    log_info "Log sendo salvo em: ${LOG_ARQUIVO}"
    echo ""

    # Executa as etapas em ordem
    atualizar_sistema
    remover_pacotes_desnecessarios
    instalar_pacotes_essenciais
    configurar_usuario_jett
    configurar_cage_autostart
    configurar_rede_bbr
    salvar_config_navegador

    # Resumo final
    exibir_resumo
}

# Executa o script passando todos os argumentos recebidos
main "$@"
