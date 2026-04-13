#!/usr/bin/env bash
# =============================================================================
# 07-bbr.sh — ETAPA 7/7: TCP BBR, otimizações de rede e config do navegador
# =============================================================================
# Uso direto (standalone):
#   sudo ./build/base/07-bbr.sh [--navegador firefox]
# Uso via orquestrador:
#   chamado automaticamente por build/build-base.sh
# =============================================================================

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Salva a configuração do navegador em /etc/jett-os/navegador.conf
# Arquivo lido em runtime pelo Sway, jett-switch.sh e jett-launcher.py
salvar_config_navegador() {
    local config_dir="/etc/jett-os"
    local config_file="${config_dir}/navegador.conf"

    mkdir -p "$config_dir"
    cat > "$config_file" << EOF
# =============================================================================
# /etc/jett-os/navegador.conf — Configuração central do navegador Jett OS
# =============================================================================
# Gerado por: build/base/07-bbr.sh v${VERSAO_SCRIPT}
# Editável manualmente ou pelo jett-launcher.

# Navegador ativo
JETT_NAVEGADOR="${NAVEGADOR_PADRAO}"

# Comando completo para o Sway/Cage (inclui flags de kiosk)
EOF

    case "$NAVEGADOR_PADRAO" in
        brave)      echo 'JETT_NAVEGADOR_CMD="brave-browser --kiosk"' >> "$config_file" ;;
        edge)       echo 'JETT_NAVEGADOR_CMD="microsoft-edge-stable --kiosk --no-first-run"' >> "$config_file" ;;
        thorium)    echo 'JETT_NAVEGADOR_CMD="thorium-browser --kiosk"' >> "$config_file" ;;
        opera-gx)   echo 'JETT_NAVEGADOR_CMD="opera --kiosk"' >> "$config_file" ;;
        firefox|*)  echo 'JETT_NAVEGADOR_CMD="firefox --kiosk"' >> "$config_file" ;;
    esac

    log_info "Configuração do navegador salva em ${config_file}."
}

configurar_rede_bbr() {
    log_separador
    log_etapa "ETAPA 7/7 — Configurando TCP BBR e otimizações de rede"

    local sysctl_jett="/etc/sysctl.d/99-jett-os.conf"

    if [[ -f "$sysctl_jett" ]]; then
        log_info "Arquivo ${sysctl_jett} já existe — sobrescrevendo."
    else
        log_info "Criando ${sysctl_jett}..."
    fi

    cat > "$sysctl_jett" << 'EOF'
# =============================================================================
# 99-jett-os.conf — Otimizações de rede do Jett OS
# =============================================================================
# Aplicadas automaticamente pelo systemd-sysctl no boot.
# Para aplicar imediatamente: sysctl --system

# --- TCP BBR (Bottleneck Bandwidth and Round-trip propagation time) ----------
# Melhora throughput e latência em conexões modernas.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Buffers de socket -------------------------------------------------------
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# --- Otimizações TCP gerais --------------------------------------------------
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# --- DNS e performance geral -------------------------------------------------
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 5000
EOF

    log_info "Configurações escritas em ${sysctl_jett}."

    log_info "Aplicando configurações via sysctl --system..."
    sysctl --system >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "sysctl --system retornou erro — configurações serão aplicadas no próximo boot."

    local bbr_ativo
    bbr_ativo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "desconhecido")
    if [[ "$bbr_ativo" == "bbr" ]]; then
        log_ok "TCP BBR ativado com sucesso."
    else
        log_aviso "TCP BBR não está ativo agora (valor: '${bbr_ativo}'). Será ativado no próximo boot."
    fi

    # Salva a configuração do navegador ao final da etapa
    salvar_config_navegador

    log_ok "Configurações de rede e navegador aplicadas."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    verificar_root
    configurar_rede_bbr
fi
