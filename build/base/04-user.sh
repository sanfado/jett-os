#!/usr/bin/env bash
# =============================================================================
# 04-user.sh — ETAPA 4/7: Cria e configura o usuário kiosk 'jett'
# =============================================================================
# Uso direto (standalone):
#   sudo ./build/base/04-user.sh
# Uso via orquestrador:
#   chamado automaticamente por build/build-base.sh
# =============================================================================

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

configurar_usuario_jett() {
    log_separador
    log_etapa "ETAPA 4/7 — Configurando usuário kiosk '${USUARIO_JETT}'"

    # Cria o usuário se não existir
    if usuario_existe "$USUARIO_JETT"; then
        log_info "Usuário '${USUARIO_JETT}' já existe — verificando configurações."
    else
        log_info "Criando usuário '${USUARIO_JETT}' sem senha e sem shell interativo..."
        # --create-home: cria /home/jett
        # --shell:       bash mínimo (autologin via getty, não interativo)
        # --groups:      acesso a áudio, vídeo e dispositivos de entrada
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

    # Configura login automático via getty no tty1
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
# Gerado por: build/base/04-user.sh v${VERSAO_SCRIPT}
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${USUARIO_JETT} --noclear %I \$TERM
EOF

    log_ok "Login automático configurado em ${getty_override_file}."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    verificar_root
    verificar_sistema
    configurar_usuario_jett
fi
