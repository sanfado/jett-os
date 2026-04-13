#!/usr/bin/env bash
# =============================================================================
# 05-sway.sh — ETAPA 5/7: Configura Sway como sessão automática (Cage: fallback)
# =============================================================================
# Uso direto (standalone):
#   sudo ./build/base/05-sway.sh [--navegador firefox]
# Uso via orquestrador:
#   chamado automaticamente por build/build-base.sh
#
# Estrutura de origem esperada no projeto:
#   config/sway/config             → ~/.config/sway/config do usuário jett
#   launcher/scripts/              → /usr/local/bin/ (scripts bash e python)
#   launcher/server/               → /usr/local/bin/jett-ui-server
#   launcher/ui/                   → /usr/local/share/jett-os/ui/
# =============================================================================

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

configurar_sway_autostart() {
    log_separador
    log_etapa "ETAPA 5/7 — Configurando Sway como sessão automática via systemd"

    local home_jett="/home/${USUARIO_JETT}"
    local systemd_user_dir="${home_jett}/.config/systemd/user"
    local sway_config_dir="${home_jett}/.config/sway"
    local profile_jett="${home_jett}/.bash_profile"
    local ui_dest_dir="/usr/local/share/jett-os/ui"
    local bin_dest="/usr/local/bin"

    # ── Instala a configuração do Sway ────────────────────────────────────────
    log_info "Instalando configuração do Sway..."
    mkdir -p "$sway_config_dir"
    if [[ -f "${PROJETO_DIR}/config/sway/config" ]]; then
        cp "${PROJETO_DIR}/config/sway/config" "${sway_config_dir}/config"
        log_ok "config/sway/config → ${sway_config_dir}/config"
    else
        log_aviso "config/sway/config não encontrado em ${PROJETO_DIR} — usando config mínimo."
        cat > "${sway_config_dir}/config" << 'SWAYMIN'
# Sway mínimo — gerado por build/base/05-sway.sh (config completo não encontrado)
output * bg #000000 solid_color
default_border none
exec bash -c 'source /etc/jett-os/navegador.conf 2>/dev/null; exec ${JETT_NAVEGADOR_CMD:-firefox --kiosk}'
SWAYMIN
    fi

    # ── Instala scripts em /usr/local/bin/ ────────────────────────────────────
    # Mapeia: caminho de origem (relativo a PROJETO_DIR) → nome no destino
    # scripts/ contém os executáveis shell e python do launcher
    # server/  contém o servidor de interfaces HTTP
    log_info "Instalando scripts do launcher em ${bin_dest}/..."

    declare -A instalar_scripts=(
        ["launcher/scripts/jett-launcher.py"]="jett-launcher"
        ["launcher/scripts/jett-switch.sh"]="jett-switch.sh"
        ["launcher/scripts/jett-exit-confirm"]="jett-exit-confirm"
        ["launcher/scripts/jett-bridge.sh"]="jett-bridge"
        ["launcher/scripts/jett-nav-toggle.sh"]="jett-nav-toggle"
        ["launcher/scripts/jett-menu-toggle.sh"]="jett-menu-toggle"
        ["launcher/scripts/jett-files-toggle.sh"]="jett-files-toggle"
        ["launcher/scripts/jett-updater.sh"]="jett-updater"
        ["launcher/scripts/jett-firstboot.sh"]="jett-firstboot"
        ["launcher/server/jett-ui-server.py"]="jett-ui-server"
    )

    for src_rel in "${!instalar_scripts[@]}"; do
        local src="${PROJETO_DIR}/${src_rel}"
        local dest="${bin_dest}/${instalar_scripts[$src_rel]}"
        if [[ -f "$src" ]]; then
            cp "$src" "$dest"
            chmod +x "$dest"
            log_info "  $(basename "$src") → ${dest}"
        else
            log_aviso "  Não encontrado: ${src}"
        fi
    done

    # ── Instala interfaces HTML ───────────────────────────────────────────────
    log_info "Instalando interfaces HTML em ${ui_dest_dir}/..."
    mkdir -p "$ui_dest_dir"
    if [[ -d "${PROJETO_DIR}/launcher/ui" ]]; then
        cp -r "${PROJETO_DIR}/launcher/ui/." "$ui_dest_dir/"
        log_ok "launcher/ui/ → ${ui_dest_dir}/"
    else
        log_aviso "launcher/ui/ não encontrado — interfaces HTML não instaladas."
    fi

    # ── Cria /etc/jett-os/ e arquivo de versão ────────────────────────────────
    log_info "Inicializando /etc/jett-os/..."
    mkdir -p /etc/jett-os
    if [[ ! -f /etc/jett-os/versao.conf ]]; then
        cat > /etc/jett-os/versao.conf << 'VERSAOEOF'
# Versão instalada do Jett OS
# Usado por: jett-bridge (system version) e jett-updater (comparação com GitHub)
# Formato: JETT_VERSAO="vX.Y.Z-sufixo"  — consulte docs/VERSIONING.md
JETT_VERSAO="v0.1.0-alpha"
VERSAOEOF
        log_ok "/etc/jett-os/versao.conf criado (v0.1.0-alpha)."
    else
        log_info "/etc/jett-os/versao.conf já existe — mantido."
    fi

    # ── Cria serviços systemd do usuário ──────────────────────────────────────
    mkdir -p "$systemd_user_dir"

    # Serviço: jett-ui-server (HTTP 127.0.0.1:1312 — inicia antes do Sway)
    cat > "${systemd_user_dir}/jett-ui-server.service" << EOF
# =============================================================================
# jett-ui-server.service — Servidor HTTP de interfaces do Jett OS
# =============================================================================
# Gerado por: build/base/05-sway.sh v${VERSAO_SCRIPT}

[Unit]
Description=Jett OS — Servidor de Interfaces (127.0.0.1:1312)
After=default.target

[Service]
Type=simple
ExecStart=/usr/local/bin/jett-ui-server
Restart=on-failure
RestartSec=2
StandardOutput=journal
StandardError=journal
SyslogIdentifier=jett-ui-server

[Install]
WantedBy=default.target
EOF
    log_info "Serviço jett-ui-server.service criado."

    # Serviço: sway-kiosk (compositor principal — After=jett-ui-server)
    cat > "${systemd_user_dir}/sway-kiosk.service" << EOF
# =============================================================================
# sway-kiosk.service — Sessão Sway do Jett OS (compositor principal)
# =============================================================================
# Gerado por: build/base/05-sway.sh v${VERSAO_SCRIPT}

[Unit]
Description=Jett OS — Sway Kiosk Session
After=default.target jett-ui-server.service
Wants=jett-ui-server.service

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=XDG_SESSION_TYPE=wayland
Environment=MOZ_ENABLE_WAYLAND=1
Environment=GDK_BACKEND=wayland
Environment=QT_QPA_PLATFORM=wayland
Environment=CLUTTER_BACKEND=wayland
Environment=SDL_VIDEODRIVER=wayland
ExecStart=/usr/bin/sway
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sway-kiosk

[Install]
WantedBy=default.target
EOF
    log_info "Serviço sway-kiosk.service criado."

    # Serviço: cage-kiosk (fallback — desabilitado, Conflicts com sway-kiosk)
    local cmd_navegador
    case "$NAVEGADOR_PADRAO" in
        brave)      cmd_navegador="brave-browser --kiosk" ;;
        edge)       cmd_navegador="microsoft-edge-stable --kiosk --no-first-run" ;;
        thorium)    cmd_navegador="thorium-browser --kiosk" ;;
        opera-gx)   cmd_navegador="opera --kiosk" ;;
        firefox|*)  cmd_navegador="firefox --kiosk" ;;
    esac

    cat > "${systemd_user_dir}/cage-kiosk.service" << EOF
# =============================================================================
# cage-kiosk.service — Sessão Cage do Jett OS (fallback, desabilitado)
# =============================================================================
# Para ativar: systemctl --user disable sway-kiosk && systemctl --user enable cage-kiosk
# Gerado por: build/base/05-sway.sh v${VERSAO_SCRIPT}

[Unit]
Description=Jett OS — Cage Kiosk Session (fallback)
After=default.target
Conflicts=sway-kiosk.service

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=WAYLAND_DISPLAY=wayland-1
Environment=MOZ_ENABLE_WAYLAND=1
Environment=GDK_BACKEND=wayland
Environment=QT_QPA_PLATFORM=wayland
EnvironmentFile=-/etc/jett-os/navegador.conf
ExecStart=/usr/bin/cage -- \${JETT_NAVEGADOR_CMD:-${cmd_navegador}}
Restart=always
RestartSec=3
StandardInput=null

[Install]
WantedBy=default.target
EOF
    log_info "Serviço cage-kiosk.service criado (fallback, desabilitado)."

    # ── Instala serviço do daemon de atualizações ─────────────────────────────
    local updater_svc="${PROJETO_DIR}/config/systemd/jett-updater.service"
    if [[ -f "$updater_svc" ]]; then
        cp "$updater_svc" "${systemd_user_dir}/jett-updater.service"
        log_info "config/systemd/jett-updater.service → ${systemd_user_dir}/jett-updater.service"
    else
        log_aviso "config/systemd/jett-updater.service não encontrado — daemon de atualizações não instalado."
    fi

    # ── Habilita linger e serviços ────────────────────────────────────────────
    log_info "Habilitando linger para o usuário '${USUARIO_JETT}'..."
    loginctl enable-linger "$USUARIO_JETT" >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "loginctl enable-linger falhou — serviços podem não iniciar automaticamente."

    local uid_jett
    uid_jett=$(id -u "$USUARIO_JETT" 2>/dev/null || echo "")
    local systemctl_user="XDG_RUNTIME_DIR=/run/user/${uid_jett} systemctl --user"

    log_info "Habilitando jett-ui-server.service, sway-kiosk.service e jett-updater.service..."
    su -l "$USUARIO_JETT" -c \
        "${systemctl_user} enable jett-ui-server.service sway-kiosk.service jett-updater.service" \
        >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "Não foi possível habilitar serviços — serão ativados no próximo boot."

    log_info "cage-kiosk.service instalado mas mantido desabilitado (fallback manual)."

    # ── .bash_profile: fallback de inicialização ──────────────────────────────
    log_info "Configurando .bash_profile como fallback de inicialização..."
    cat > "$profile_jett" << 'PROFILE'
# =============================================================================
# .bash_profile — Jett OS Kiosk Auto-Start
# =============================================================================
# Fallback: inicia o Sway caso o systemd --user não tenha disparado o serviço.
# Executa apenas no tty1.

if [[ -z "${WAYLAND_DISPLAY}" && -z "${DISPLAY}" && "$(tty)" == "/dev/tty1" ]]; then
    echo "[$(date '+%H:%M:%S')] Iniciando sessão Jett OS via .bash_profile" >> /tmp/jett-session.log

    if systemctl --user is-enabled sway-kiosk.service &>/dev/null; then
        exec systemctl --user start jett-ui-server.service sway-kiosk.service
    elif systemctl --user is-enabled cage-kiosk.service &>/dev/null; then
        exec systemctl --user start cage-kiosk.service
    else
        exec /usr/bin/sway 2>/tmp/jett-sway-crash.log \
            || (source /etc/jett-os/navegador.conf 2>/dev/null; \
                exec /usr/bin/cage -- ${JETT_NAVEGADOR_CMD:-firefox --kiosk})
    fi
fi
PROFILE

    # ── Ajusta propriedade dos arquivos criados ───────────────────────────────
    chown -R "${USUARIO_JETT}:${USUARIO_JETT}" \
        "$home_jett/.config" \
        "$profile_jett"

    log_ok "Sway configurado como sessão automática (Cage mantido como fallback)."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    verificar_root
    verificar_sistema
    configurar_sway_autostart
fi
