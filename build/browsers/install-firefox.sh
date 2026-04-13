#!/usr/bin/env bash
# =============================================================================
# install-firefox.sh — Instalação e configuração do Firefox no Jett OS
# =============================================================================
# Descrição:
#   Instala o Firefox via repositório oficial da Mozilla para Debian/Ubuntu.
#   NÃO usa o snap (snap não está disponível no Jett OS — sistema mínimo).
#   NÃO usa o firefox-esr do repositório Debian (versão mais antiga).
#
# Método:
#   Repositório oficial Mozilla APT: packages.mozilla.org/apt
#   Provê o Firefox mais recente (canal stable) como pacote .deb nativo.
#
# Particularidade do Firefox no Wayland:
#   Diferente de navegadores Chromium-based, o Firefox usa variáveis de ambiente
#   para ativar o backend Wayland, não flags de linha de comando:
#     MOZ_ENABLE_WAYLAND=1  — força backend Wayland (sem XWayland)
#
#   Este script cria o wrapper /usr/local/bin/jett-firefox-kiosk que
#   exporta essa variável e chama firefox --kiosk, garantindo que todos
#   os caminhos do Jett OS (jett-switch.sh, sway exec, navegador.conf)
#   usem Wayland corretamente.
#
# Uso:
#   sudo ./install-firefox.sh [opções]
#
# Opções:
#   --url URL         URL que o Firefox abrirá ao iniciar (padrão: about:blank)
#   --esr             Instala o Firefox ESR (Long Term Support) em vez do Stable
#   --set-default     Define o Firefox como navegador ativo
#   --help            Exibe esta ajuda
#
# Idempotência:
#   Seguro de executar múltiplas vezes. Regenera o wrapper e as configurações.
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
NOME_NAVEGADOR="firefox"
NOME_EXIBICAO="Firefox"

# URL inicial
FIREFOX_URL_INICIAL="${FIREFOX_URL_INICIAL:-about:blank}"

# Canal de instalação: "stable" ou "esr"
FIREFOX_CANAL="${FIREFOX_CANAL:-stable}"

# Define Firefox como padrão ao instalar?
DEFINIR_PADRAO=false

# Caminho do wrapper criado por este script
# O wrapper garante MOZ_ENABLE_WAYLAND=1 em todos os contextos de chamada
FIREFOX_WRAPPER="/usr/local/bin/jett-firefox-kiosk"

# Diretório raiz do projeto (dois níveis acima: build/browsers/ → raiz)
PROJETO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CONFIG_DIR="${PROJETO_DIR}/config"
CONFIG_JETT="/etc/jett-os"
SERVICO_DESTINO="/etc/systemd/system"

# Repositório oficial Mozilla
MOZILLA_GPG_URL="https://packages.mozilla.org/apt/repo-signing-key.gpg"
MOZILLA_GPG_DEST="/usr/share/keyrings/mozilla-firefox-archive-keyring.gpg"
MOZILLA_LIST_FILE="/etc/apt/sources.list.d/mozilla-firefox.list"
MOZILLA_REPO_URL="https://packages.mozilla.org/apt"
# Preferência APT: garante que 'apt install firefox' usa o repo Mozilla e não o Debian
MOZILLA_PREF_FILE="/etc/apt/preferences.d/mozilla-firefox"

# Flags e variáveis de ambiente carregadas do perfil técnico centralizado.
# Fonte canônica: config/browsers/firefox.conf
# Define: MOZ_ENABLE_WAYLAND, JETT_FIREFOX_FLAGS_STR, JETT_FIREFOX_USERJS
# BUG A fix: não duplicar flags/env aqui.
# BUG B fix: JETT_FIREFOX_USERJS do perfil será escrito como user.js no perfil kiosk.
PERFIL_CONF="${PROJETO_DIR}/config/browsers/firefox.conf"

# Diretório do perfil kiosk do Firefox (criado por criar_wrapper_firefox)
FIREFOX_PERFIL_DIR="/home/${USUARIO_JETT:-jett}/.mozilla/firefox/jett-kiosk"

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
        echo "  install-firefox.sh v${VERSAO_SCRIPT} — $(date '+%Y-%m-%d %H:%M:%S')"
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
        echo -e "\033[1;31m[ERRO] Execute como root: sudo ./install-firefox.sh\033[0m" >&2
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
    log_info "Verificando acesso a packages.mozilla.org..."
    if ! curl -sf --max-time 15 "https://packages.mozilla.org" -o /dev/null; then
        log_erro "Sem acesso a packages.mozilla.org. Verifique a conexão."
    fi
    log_ok "Acesso ao repositório Mozilla confirmado."
}

pacote_instalado() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

versao_firefox() {
    if command -v firefox &>/dev/null; then
        firefox --version 2>/dev/null | awk '{print $NF}' || echo "instalado"
    else
        echo "não instalado"
    fi
}

nome_pacote_firefox() {
    # Retorna o nome do pacote APT baseado no canal escolhido
    if [[ "$FIREFOX_CANAL" == "esr" ]]; then
        echo "firefox-esr"
    else
        echo "firefox"
    fi
}

# -----------------------------------------------------------------------------
# ETAPA 1: Adiciona o repositório oficial Mozilla
# -----------------------------------------------------------------------------

adicionar_repositorio_mozilla() {
    log_separador
    log_etapa "ETAPA 1/4 — Adicionando repositório oficial Mozilla"

    log_info "Canal selecionado: ${FIREFOX_CANAL} ($(nome_pacote_firefox))"

    # Verifica/baixa a chave GPG da Mozilla
    if [[ -f "$MOZILLA_GPG_DEST" ]]; then
        log_info "Chave GPG da Mozilla já presente — pulando download."
    else
        log_info "Baixando chave GPG da Mozilla..."
        curl -fsSL "$MOZILLA_GPG_URL" \
            > "$MOZILLA_GPG_DEST" \
            2>> "$LOG_ARQUIVO" \
            || log_erro "Falha ao baixar chave GPG da Mozilla."

        # A chave do Mozilla já vem em formato binário (não precisa de gpg --dearmor)
        if ! file "$MOZILLA_GPG_DEST" | grep -q "GPG\|PGP\|data"; then
            rm -f "$MOZILLA_GPG_DEST"
            log_erro "Arquivo de chave GPG inválido. Abortando."
        fi
        log_ok "Chave GPG Mozilla baixada."
    fi

    # Verifica/cria o arquivo de repositório APT
    if [[ -f "$MOZILLA_LIST_FILE" ]]; then
        log_info "Repositório Mozilla já configurado — pulando."
    else
        log_info "Adicionando repositório Mozilla ao APT..."
        printf "deb [arch=amd64 signed-by=%s] %s mozilla main\n" \
            "$MOZILLA_GPG_DEST" "$MOZILLA_REPO_URL" \
            > "$MOZILLA_LIST_FILE" \
            || log_erro "Falha ao criar ${MOZILLA_LIST_FILE}."
        log_ok "Repositório Mozilla adicionado: ${MOZILLA_LIST_FILE}"
    fi

    # Cria/atualiza arquivo de preferências APT
    # Necessário para que 'firefox' resolva para o pacote Mozilla e não o Debian.
    # O Debian distribui firefox-esr; sem esta preferência, o APT pode
    # resolver 'firefox' para o wrapper snap do Ubuntu ou o firefox-esr do Debian.
    if [[ ! -f "$MOZILLA_PREF_FILE" ]]; then
        log_info "Criando preferência APT para pacotes Mozilla..."
        cat > "$MOZILLA_PREF_FILE" << 'PREF'
# Preferência APT para o repositório Mozilla
# Garante que 'apt install firefox' usa o pacote da Mozilla, não do Debian/Ubuntu
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1001
PREF
        log_ok "Preferência APT criada: ${MOZILLA_PREF_FILE}"
    else
        log_info "Preferência APT já existe — mantendo."
    fi

    log_info "Atualizando lista de pacotes..."
    apt-get update -qq >> "$LOG_ARQUIVO" 2>&1 \
        || log_erro "Falha ao atualizar lista de pacotes."

    log_ok "Repositório Mozilla configurado."
}

# -----------------------------------------------------------------------------
# ETAPA 2: Instala o Firefox
# -----------------------------------------------------------------------------

instalar_firefox() {
    log_separador
    log_etapa "ETAPA 2/4 — Instalando Firefox (canal: ${FIREFOX_CANAL})"

    local pacote
    pacote="$(nome_pacote_firefox)"
    local versao_atual
    versao_atual="$(versao_firefox)"

    # Remove firefox-esr do Debian se presente (evita conflito com o da Mozilla)
    if pacote_instalado "firefox-esr" && [[ "$FIREFOX_CANAL" != "esr" ]]; then
        log_info "Removendo firefox-esr do Debian para evitar conflito com Mozilla..."
        apt-get remove -y -qq firefox-esr >> "$LOG_ARQUIVO" 2>&1 || true
    fi

    if pacote_instalado "$pacote"; then
        log_info "${pacote} já instalado (versão: ${versao_atual}) — verificando atualizações."
        apt-get install -y -qq --only-upgrade "$pacote" >> "$LOG_ARQUIVO" 2>&1 \
            || log_aviso "Não foi possível atualizar. Mantendo versão atual."
        local versao_nova
        versao_nova="$(versao_firefox)"
        if [[ "$versao_atual" != "$versao_nova" ]]; then
            log_ok "Firefox atualizado: ${versao_atual} → ${versao_nova}"
        else
            log_ok "Firefox já está na versão mais recente: ${versao_atual}"
        fi
    else
        log_info "Instalando ${pacote} (isso pode demorar alguns minutos)..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pacote" \
            >> "$LOG_ARQUIVO" 2>&1 \
            || log_erro "Falha ao instalar ${pacote}. Veja: ${LOG_ARQUIVO}"

        local versao_instalada
        versao_instalada="$(versao_firefox)"
        log_ok "Firefox instalado (versão: ${versao_instalada}, canal: ${FIREFOX_CANAL})."
    fi

    if ! command -v firefox &>/dev/null; then
        log_erro "Binário 'firefox' não encontrado após instalação."
    fi
    log_info "Binário: $(command -v firefox)"
}

# -----------------------------------------------------------------------------
# ETAPA 2.5: Cria o wrapper jett-firefox-kiosk
# -----------------------------------------------------------------------------
# O wrapper é necessário porque o Firefox usa MOZ_ENABLE_WAYLAND=1 como
# variável de ambiente para ativar o backend Wayland, não uma flag CLI.
# Ao empacotar tudo em um script wrapper, os outros componentes do Jett OS
# (jett-switch.sh, sway config exec, navegador.conf) podem simplesmente
# chamar 'jett-firefox-kiosk' sem conhecer os detalhes de configuração do Firefox.

criar_wrapper_firefox() {
    log_separador
    log_etapa "ETAPA 2.5/4 — Criando wrapper Wayland + perfil kiosk para Firefox"

    # Carrega o perfil de flags e variáveis de ambiente do Firefox
    # BUG A fix: env vars (MOZ_*) e JETT_FIREFOX_USERJS vêm do perfil
    if [[ -f "$PERFIL_CONF" ]]; then
        # shellcheck source=config/browsers/firefox.conf
        source "$PERFIL_CONF"
    else
        log_erro "Perfil de flags não encontrado: ${PERFIL_CONF}."
    fi

    # ── Fix 1 + 2: estrutura completa de perfis do Firefox ───────────────────
    # O Firefox precisa de profiles.ini para conhecer seus perfis antes do
    # primeiro boot. Sem ele, cria um perfil aleatório e exibe o wizard
    # de boas-vindas — comportamento inaceitável em kiosk.
    #
    # Estrutura criada:
    #   /home/jett/.mozilla/firefox/
    #   ├── profiles.ini          → registro dos perfis
    #   ├── jett.default/         → perfil padrão (evita wizard de primeiro boot)
    #   └── jett-kiosk/           → perfil kiosk (user.js, usado pelo wrapper)

    local mozilla_firefox_dir="/home/${USUARIO_JETT}/.mozilla/firefox"

    # Cria o perfil kiosk (usado pelo wrapper via --profile)
    log_info "Criando perfil kiosk do Firefox: ${FIREFOX_PERFIL_DIR}"
    mkdir -p "$FIREFOX_PERFIL_DIR"

    # Escreve user.js com as preferências técnicas de integração
    # JETT_FIREFOX_USERJS é definido em config/browsers/firefox.conf
    printf '%s\n' "${JETT_FIREFOX_USERJS}" > "${FIREFOX_PERFIL_DIR}/user.js"
    log_ok "user.js criado em ${FIREFOX_PERFIL_DIR}/user.js (WebRender + e10s + prefs kiosk)"

    # Cria o perfil padrão (jett.default)
    # Necessário para que o Firefox não crie um perfil com nome aleatório
    # nem exiba o wizard de primeiro uso antes do primeiro boot
    log_info "Criando perfil padrão: ${mozilla_firefox_dir}/jett.default"
    mkdir -p "${mozilla_firefox_dir}/jett.default"

    # Cria o profiles.ini registrando ambos os perfis
    # Formato: https://support.mozilla.org/pt-BR/kb/perfis-onde-firefox-armazena
    # Profile0 (jett.default) é o Default=1 — fallback sem --profile
    # Profile1 (jett-kiosk) é o perfil usado pelo wrapper em modo kiosk
    cat > "${mozilla_firefox_dir}/profiles.ini" << PROFILES_INI
[Profile0]
Name=jett.default
IsRelative=1
Path=jett.default
Default=1

[Profile1]
Name=jett-kiosk
IsRelative=1
Path=jett-kiosk

[General]
StartWithLastProfile=1
Version=2
PROFILES_INI
    log_ok "profiles.ini criado: ${mozilla_firefox_dir}/profiles.ini"

    # Fix 1: chown -R em todo /home/jett/.mozilla (não só no perfil kiosk)
    # Garante que jett.default/, jett-kiosk/ e profiles.ini pertencem ao usuário
    chown -R "${USUARIO_JETT}:${USUARIO_JETT}" "/home/${USUARIO_JETT}/.mozilla"
    log_ok "Propriedade definida: jett:jett → /home/${USUARIO_JETT}/.mozilla (recursivo)"

    # ── Cria o wrapper jett-firefox-kiosk ─────────────────────────────────────
    log_info "Criando ${FIREFOX_WRAPPER}..."

    # BUG B fix: wrapper usa --profile para garantir que o user.js seja carregado.
    # Sem --profile, o Firefox usaria o perfil padrão onde user.js não existe.
    cat > "$FIREFOX_WRAPPER" << WRAPPER
#!/usr/bin/env bash
# =============================================================================
# jett-firefox-kiosk — Wrapper do Firefox com Wayland para o Jett OS
# =============================================================================
# Criado por: build/browsers/install-firefox.sh
# Não edite manualmente — será sobrescrito ao re-executar o script.
#
# Propósito:
#   1. Exporta MOZ_ENABLE_WAYLAND=1 para forçar backend Wayland nativo
#   2. Aponta para o perfil kiosk do Jett OS (${FIREFOX_PERFIL_DIR})
#      onde o user.js com gfx.webrender.all=true está configurado
#   3. Inicia o Firefox em modo --kiosk
#
# Uso (chamado automaticamente pelo Jett OS):
#   jett-firefox-kiosk [URL]
#   systemctl start firefox-kiosk
#   swaymsg exec jett-firefox-kiosk
# =============================================================================

# Força o Firefox a usar o backend Wayland (sem XWayland)
export MOZ_ENABLE_WAYLAND=1

# Protocolo XInput2 para Wayland (touchscreen, gestos)
export MOZ_USE_XINPUT2=1

# Desativa crash reporter (sem diálogos em kiosk headless)
export MOZ_CRASHREPORTER_DISABLE=1

# Inicia o Firefox com o perfil kiosk do Jett OS.
# O perfil contém user.js com:
#   gfx.webrender.all=true          (renderização GPU via WebRender)
#   gfx.webrender.compositor=true   (compositor Wayland nativo)
#   browser.startup.homepage_override.mstone=ignore  (sem página de update)
#   toolkit.cosmeticAnimations.enabled=false         (sem animações de UI)
exec /usr/bin/firefox --kiosk --profile "${FIREFOX_PERFIL_DIR}" "\$@"
WRAPPER

    chmod +x "$FIREFOX_WRAPPER"
    log_ok "Wrapper criado e executável: ${FIREFOX_WRAPPER}"
    log_info "  Perfil  : ${FIREFOX_PERFIL_DIR}"
    log_info "  user.js : ${FIREFOX_PERFIL_DIR}/user.js"
}

# -----------------------------------------------------------------------------
# ETAPA 3: Gera os arquivos de serviço kiosk
# -----------------------------------------------------------------------------

configurar_firefox_kiosk() {
    log_separador
    log_etapa "ETAPA 3/4 — Configurando Firefox em modo kiosk"

    local home_jett="/home/${USUARIO_JETT}"
    local systemd_user_dir="${home_jett}/.config/systemd/user"
    local uid_jett
    uid_jett="$(id -u "${USUARIO_JETT}" 2>/dev/null || echo "1000")"

    mkdir -p "$systemd_user_dir"
    mkdir -p "$CONFIG_DIR"

    # ── Serviço de usuário ─────────────────────────────────────────────────────
    local servico_user="${systemd_user_dir}/firefox-kiosk.service"
    log_info "Criando serviço de usuário: ${servico_user}"

    cat > "$servico_user" << EOF
# =============================================================================
# firefox-kiosk.service — Serviço de usuário para Firefox Kiosk
# =============================================================================
# Localização: ~/.config/systemd/user/firefox-kiosk.service
#
# Chama jett-firefox-kiosk (wrapper) que exporta MOZ_ENABLE_WAYLAND=1
# antes de executar firefox --kiosk.
#
# Uso:
#   systemctl --user start  firefox-kiosk
#   systemctl --user stop   firefox-kiosk
#   systemctl --user status firefox-kiosk
# =============================================================================

[Unit]
Description=Jett OS — Firefox Kiosk via Cage
After=default.target
Conflicts=cage-kiosk.service brave-kiosk.service edge-kiosk.service thorium-kiosk.service opera-kiosk.service

[Service]
Type=simple

Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=WAYLAND_DISPLAY=wayland-1
# MOZ_ENABLE_WAYLAND é exportado pelo wrapper jett-firefox-kiosk
# mas também o definimos aqui por segurança (caso o wrapper seja bypassado)
Environment=MOZ_ENABLE_WAYLAND=1
Environment=MOZ_USE_XINPUT2=1
Environment=MOZ_CRASHREPORTER_DISABLE=1

# Cage executa o wrapper (que por sua vez chama firefox --kiosk)
ExecStart=/usr/bin/cage -- ${FIREFOX_WRAPPER} "${FIREFOX_URL_INICIAL}"

Restart=always
RestartSec=3
TimeoutStartSec=20

StandardOutput=journal
StandardError=journal
SyslogIdentifier=jett-firefox-kiosk

[Install]
WantedBy=default.target
EOF

    # ── Serviço de sistema ─────────────────────────────────────────────────────
    local servico_projeto="${CONFIG_DIR}/firefox-kiosk.service"
    local servico_sistema="${SERVICO_DESTINO}/firefox-kiosk.service"

    log_info "Criando serviço de sistema: ${servico_projeto}"

    cat > "$servico_projeto" << EOF
# =============================================================================
# firefox-kiosk.service — Serviço de sistema para Firefox Kiosk
# =============================================================================
# Localização: /etc/systemd/system/firefox-kiosk.service
# Instalado por: build/browsers/install-firefox.sh
# Canal: ${FIREFOX_CANAL}
#
# Diferença dos serviços Chromium-based:
#   Firefox requer MOZ_ENABLE_WAYLAND=1 para usar Wayland nativo.
#   Este serviço usa o wrapper ${FIREFOX_WRAPPER} que
#   exporta as variáveis corretas antes de executar firefox --kiosk.
#
# Uso:
#   sudo systemctl start  firefox-kiosk
#   sudo systemctl stop   firefox-kiosk
#   sudo systemctl status firefox-kiosk
#   journalctl -u firefox-kiosk -f
# =============================================================================

[Unit]
Description=Jett OS — Firefox Kiosk (serviço de sistema)
After=network.target multi-user.target systemd-user-sessions.service
RequiresMountsFor=/home
Conflicts=cage-kiosk.service brave-kiosk.service edge-kiosk.service thorium-kiosk.service opera-kiosk.service

[Service]
Type=simple

User=${USUARIO_JETT}
Group=${USUARIO_JETT}

Environment=XDG_RUNTIME_DIR=/run/user/${uid_jett}
Environment=WAYLAND_DISPLAY=wayland-1
Environment=HOME=/home/${USUARIO_JETT}
Environment=USER=${USUARIO_JETT}
# Variáveis específicas do Firefox para Wayland
Environment=MOZ_ENABLE_WAYLAND=1
Environment=MOZ_USE_XINPUT2=1
Environment=MOZ_CRASHREPORTER_DISABLE=1

EnvironmentFile=-/etc/jett-os/firefox.conf

ExecStartPre=/bin/bash -c 'until ls /dev/dri/card* &>/dev/null; do sleep 0.3; done'
ExecStartPre=/bin/bash -c 'mkdir -p /run/user/${uid_jett} && chown ${USUARIO_JETT}:${USUARIO_JETT} /run/user/${uid_jett} && chmod 700 /run/user/${uid_jett}'

# Usa o wrapper que garante MOZ_ENABLE_WAYLAND=1 e executa firefox --kiosk
ExecStart=/usr/bin/cage -- ${FIREFOX_WRAPPER} \${JETT_FIREFOX_URL:-${FIREFOX_URL_INICIAL}}

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
SyslogIdentifier=jett-firefox-kiosk

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

ativar_e_registrar_firefox() {
    log_separador
    log_etapa "ETAPA 4/4 — Registrando Firefox no Jett OS"

    log_info "Recarregando daemon do systemd..."
    systemctl daemon-reload >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "daemon-reload falhou."

    log_info "Habilitando firefox-kiosk.service..."
    systemctl enable firefox-kiosk.service >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "Não foi possível habilitar firefox-kiosk.service."

    log_info "Habilitando serviço do usuário '${USUARIO_JETT}'..."
    su -l "$USUARIO_JETT" -c \
        "XDG_RUNTIME_DIR=/run/user/$(id -u "$USUARIO_JETT") systemctl --user enable firefox-kiosk.service" \
        >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "Não foi possível habilitar firefox-kiosk.service --user."

    # Cria arquivo de configuração específico do Firefox
    mkdir -p "$CONFIG_JETT"
    if [[ ! -f "${CONFIG_JETT}/firefox.conf" ]]; then
        printf "# /etc/jett-os/firefox.conf — Configuração do Firefox no Jett OS\n# Lido como EnvironmentFile pelo firefox-kiosk.service\n\n# URL que o Firefox abre ao iniciar\nJETT_FIREFOX_URL=\"%s\"\n\n# Canal de instalação: stable ou esr\nJETT_FIREFOX_CANAL=\"%s\"\n\n# Wrapper Wayland do Jett OS\nJETT_FIREFOX_WRAPPER=\"%s\"\n" \
            "${FIREFOX_URL_INICIAL}" "${FIREFOX_CANAL}" "${FIREFOX_WRAPPER}" \
            > "${CONFIG_JETT}/firefox.conf"
        log_ok "Arquivo de configuração criado: ${CONFIG_JETT}/firefox.conf"
    else
        log_info "Arquivo ${CONFIG_JETT}/firefox.conf já existe — mantendo."
    fi

    # Registra em navegadores-instalados.conf
    local versao_inst
    versao_inst="$(versao_firefox)"
    registrar_navegador "FIREFOX" "$versao_inst" "$(command -v firefox)"

    # Define como navegador padrão se --set-default foi passado
    # Usa jett-firefox-kiosk (wrapper) como comando — não firefox --kiosk diretamente
    if [[ "$DEFINIR_PADRAO" == "true" ]]; then
        log_info "Definindo Firefox como navegador ativo..."
        printf "# /etc/jett-os/navegador.conf\n# Gerado por install-firefox.sh v%s\nJETT_NAVEGADOR=\"firefox\"\nJETT_NAVEGADOR_CMD=\"%s %s\"\n" \
            "$VERSAO_SCRIPT" "${FIREFOX_WRAPPER}" "${FIREFOX_URL_INICIAL}" \
            > "${CONFIG_JETT}/navegador.conf"
        log_ok "Firefox definido como navegador ativo (via wrapper: ${FIREFOX_WRAPPER})."
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
    echo -e "${COR_VERDE}║       Firefox instalado e configurado!           ║${COR_RESET}"
    echo -e "${COR_VERDE}╚══════════════════════════════════════════════════╝${COR_RESET}"
    echo ""
    echo -e "  Versão instalada  : ${COR_CIANO}$(versao_firefox)${COR_RESET}"
    echo -e "  Canal             : ${COR_CIANO}${FIREFOX_CANAL}${COR_RESET}"
    echo -e "  URL inicial       : ${COR_CIANO}${FIREFOX_URL_INICIAL}${COR_RESET}"
    echo -e "  Wrapper Wayland   : ${COR_CIANO}${FIREFOX_WRAPPER}${COR_RESET}"
    echo -e "  Serviço kiosk     : ${COR_CIANO}firefox-kiosk.service${COR_RESET}"
    echo -e "  Config Firefox    : ${COR_CIANO}${CONFIG_JETT}/firefox.conf${COR_RESET}"
    echo -e "  Registro          : ${COR_CIANO}${CONFIG_JETT}/navegadores-instalados.conf${COR_RESET}"
    echo -e "  Log completo      : ${COR_CIANO}${LOG_ARQUIVO}${COR_RESET}"
    echo ""
    echo -e "  ${COR_AMARELO}Variáveis Wayland (exportadas pelo wrapper):${COR_RESET}"
    echo -e "    ${COR_BRANCO}MOZ_ENABLE_WAYLAND=1     ${COR_RESET}— backend Wayland nativo"
    echo -e "    ${COR_BRANCO}MOZ_USE_XINPUT2=1        ${COR_RESET}— compositor Wayland para input"
    echo -e "    ${COR_BRANCO}MOZ_CRASHREPORTER_DISABLE=1 ${COR_RESET}— sem diálogos de crash"
    echo ""
    echo -e "  ${COR_AMARELO}Para ativar o Firefox como navegador padrão:${COR_RESET}"
    echo -e "    ${COR_CIANO}sudo ./install-firefox.sh --set-default${COR_RESET}"
    echo ""
    echo -e "  ${COR_AMARELO}Nota sobre ESR vs Stable:${COR_RESET}"
    echo -e "    ${COR_BRANCO}stable${COR_RESET} — versão mais recente, atualizações frequentes"
    echo -e "    ${COR_BRANCO}esr   ${COR_RESET}— Long Term Support, mais estável para kiosk"
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
                FIREFOX_URL_INICIAL="$1"
                ;;
            --esr)
                FIREFOX_CANAL="esr"
                ;;
            --set-default)
                DEFINIR_PADRAO=true
                ;;
            --help|-h)
                echo "Uso: sudo ./install-firefox.sh [opções]"
                echo ""
                echo "Opções:"
                echo "  --url URL      URL inicial (padrão: about:blank)"
                echo "  --esr          Instala Firefox ESR (Long Term Support)"
                echo "  --set-default  Define o Firefox como navegador ativo"
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
    echo "  ███████╗██╗██████╗ ███████╗███████╗ ██████╗ ██╗  ██╗"
    echo "  ██╔════╝██║██╔══██╗██╔════╝██╔════╝██╔═══██╗╚██╗██╔╝"
    echo "  █████╗  ██║██████╔╝█████╗  █████╗  ██║   ██║ ╚███╔╝ "
    echo "  ██╔══╝  ██║██╔══██╗██╔══╝  ██╔══╝  ██║   ██║ ██╔██╗ "
    echo "  ██║     ██║██║  ██║███████╗██║      ╚██████╔╝██╔╝ ██╗"
    echo "  ╚═╝     ╚═╝╚═╝  ╚═╝╚══════╝╚═╝       ╚═════╝ ╚═╝  ╚═╝"
    echo -e "${COR_RESET}"
    echo -e "  ${COR_BRANCO}Instalação do Firefox — Jett OS v${VERSAO_SCRIPT}${COR_RESET}"
    echo ""

    processar_argumentos "$@"
    verificar_root
    inicializar_log
    verificar_base_instalada
    verificar_conexao

    log_info "Canal: ${FIREFOX_CANAL} (pacote: $(nome_pacote_firefox))"
    log_info "URL inicial: ${FIREFOX_URL_INICIAL}"
    log_info "Definir como padrão: ${DEFINIR_PADRAO}"
    echo ""

    adicionar_repositorio_mozilla
    instalar_firefox
    criar_wrapper_firefox
    configurar_firefox_kiosk
    ativar_e_registrar_firefox
    exibir_resumo
}

main "$@"
