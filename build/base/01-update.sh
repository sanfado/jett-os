#!/usr/bin/env bash
# =============================================================================
# 01-update.sh — ETAPA 1/7: Atualiza repositórios e sistema base
# =============================================================================
# Uso direto (standalone):
#   sudo ./build/base/01-update.sh
# Uso via orquestrador:
#   chamado automaticamente por build/build-base.sh
# =============================================================================

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

atualizar_sistema() {
    log_separador
    log_etapa "ETAPA 1/7 — Atualizando repositórios e sistema base"

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

# Executa a etapa (standalone ou via source)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    verificar_root
    verificar_sistema
    atualizar_sistema
fi
