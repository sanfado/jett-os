#!/usr/bin/env bash
# =============================================================================
# 06-network.sh — ETAPA 6/7: Configura rede via systemd-networkd (DHCP + DNS)
# =============================================================================
# Uso direto (standalone):
#   sudo ./build/base/06-network.sh
# Uso via orquestrador:
#   chamado automaticamente por build/build-base.sh
# =============================================================================

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

configurar_rede_networkd() {
    log_separador
    log_etapa "ETAPA 6/7 — Configurando rede via systemd-networkd (DHCP + DNS)"

    # ── Arquivo de rede: DHCP para interfaces cabeadas (en*) ──────────────────
    # O padrão Name=en* cobre enp2s0, eno1, eth0-renomeados, etc.
    local network_file="/etc/systemd/network/10-wired.network"

    if [[ -f "$network_file" ]]; then
        log_info "Arquivo de rede já existe em ${network_file} — sobrescrevendo."
    else
        log_info "Criando configuração de rede: ${network_file}"
    fi

    mkdir -p /etc/systemd/network
    cat > "$network_file" << 'NETCONF'
# =============================================================================
# /etc/systemd/network/10-wired.network — Rede cabeada do Jett OS
# =============================================================================
# Gerenciado por: systemd-networkd
# Aplica DHCP a todas as interfaces cabeadas com nome começando em 'en'
# (padrão de nomenclatura previsível do kernel: enp2s0, eno1, enx*, etc.)
#
# Para IP fixo, substitua DHCP=yes por DHCP=no e adicione:
#   [Address]
#   Address=192.168.1.100/24
#   [Route]
#   Gateway=192.168.1.1

[Match]
Name=en*

[Network]
DHCP=yes
NETCONF

    log_ok "Configuração de rede criada: ${network_file}"

    # ── Hook DNS: escreve /etc/resolv.conf após obter IP via DHCP ─────────────
    # networkd-dispatcher executa scripts em /etc/networkd-dispatcher/<estado>.d/
    # quando uma interface muda de estado. 'routable' = IP e rota configurados.
    local hook_dir="/etc/networkd-dispatcher/routable.d"
    local hook_file="${hook_dir}/50-jett-dns"

    log_info "Criando hook de DNS: ${hook_file}"
    mkdir -p "$hook_dir"

    cat > "$hook_file" << 'HOOK'
#!/bin/bash
# =============================================================================
# 50-jett-dns — Hook DNS do Jett OS para networkd-dispatcher
# =============================================================================
# Localização: /etc/networkd-dispatcher/routable.d/50-jett-dns
#
# Executado quando uma interface torna-se roteável (após DHCP obter IP).
#
# Variáveis injetadas pelo networkd-dispatcher:
#   $IFACE              — nome da interface (ex: enp2s0)
#   $OperationalState   — neste hook: sempre 'routable'
#
# Estratégia DNS:
#   1. Gateway da rede local (DNS primário — geralmente faz forwarding)
#   2. 8.8.8.8 (Google DNS — fallback público)
#   3. 8.8.4.4 (Google DNS secundário)
# =============================================================================

set -euo pipefail

GATEWAY=$(ip route show default dev "${IFACE}" 2>/dev/null \
    | awk '/via/ {print $3; exit}')

{
    printf "# /etc/resolv.conf — Gerado automaticamente pelo Jett OS\n"
    printf "# Atualizado em: %s  |  Interface: %s\n" \
        "$(date '+%Y-%m-%d %H:%M:%S')" "${IFACE}"
    printf "# Hook: /etc/networkd-dispatcher/routable.d/50-jett-dns\n"
    printf "#\n"
    if [[ -n "${GATEWAY}" ]]; then
        printf "nameserver %s\n" "${GATEWAY}"
    fi
    printf "nameserver 8.8.8.8\n"
    printf "nameserver 8.8.4.4\n"
} > /etc/resolv.conf

logger -t jett-dns "resolv.conf atualizado: gateway=${GATEWAY:-ausente}, iface=${IFACE}"
HOOK

    chmod +x "$hook_file"
    log_ok "Hook DNS criado: ${hook_file}"

    # ── Habilita systemd-networkd ──────────────────────────────────────────────
    log_info "Habilitando systemd-networkd para iniciar no boot..."
    systemctl enable systemd-networkd >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "Não foi possível habilitar systemd-networkd."

    systemctl enable networkd-dispatcher >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "Não foi possível habilitar networkd-dispatcher."

    if ! systemctl is-active systemd-networkd &>/dev/null; then
        log_info "Iniciando systemd-networkd..."
        systemctl start systemd-networkd >> "$LOG_ARQUIVO" 2>&1 \
            || log_aviso "systemd-networkd não pôde ser iniciado agora — será ativo no próximo boot."
    else
        log_info "systemd-networkd já está ativo."
    fi

    log_ok "Configuração de rede concluída: DHCP para en*, DNS via gateway + 8.8.8.8."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    verificar_root
    configurar_rede_networkd
fi
