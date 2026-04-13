#!/usr/bin/env bash
# =============================================================================
# 02-remove-bloat.sh — ETAPA 2/7: Remove pacotes desnecessários
# =============================================================================
# Uso direto (standalone):
#   sudo ./build/base/02-remove-bloat.sh
# Uso via orquestrador:
#   chamado automaticamente por build/build-base.sh
# =============================================================================

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Pacotes desnecessários que podem vir no Debian Minimal
# Remove apenas se presentes — idempotente
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

remover_pacotes_desnecessarios() {
    log_separador
    log_etapa "ETAPA 2/7 — Removendo pacotes desnecessários"

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

    # Remove dependências órfãs
    log_info "Limpando dependências órfãs..."
    apt-get autoremove -y -qq >> "$LOG_ARQUIVO" 2>&1

    # Limpa cache do APT
    log_info "Limpando cache do APT..."
    apt-get clean -qq >> "$LOG_ARQUIVO" 2>&1

    log_ok "Remoção concluída: ${removidos} pacote(s) removido(s), ${nao_encontrados} já ausente(s)."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    verificar_root
    remover_pacotes_desnecessarios
fi
