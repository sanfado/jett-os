#!/usr/bin/env bash
# =============================================================================
# lib.sh — Biblioteca compartilhada do build do Jett OS
# =============================================================================
# Fonte de verdade para variáveis globais, cores, funções de log e utilitários.
# Sourced por todos os módulos de build (build/base/0N-*.sh) e pelo
# orquestrador (build/build-base.sh).
#
# Uso:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"        # nos módulos
#   source "${SCRIPT_DIR}/base/lib.sh"                    # no orquestrador
#
# Variáveis exportáveis:
#   NAVEGADOR_PADRAO  — navegador a configurar (brave|edge|thorium|opera-gx|firefox)
#   USUARIO_JETT      — nome do usuário kiosk do sistema
#   LOG_ARQUIVO       — caminho para o arquivo de log persistente
#   VERSAO_SCRIPT     — versão do script de build
#   PROJETO_DIR       — raiz absoluta do repositório Jett OS
# =============================================================================

# Evita múltiplos sources (guard de inclusão)
[[ -n "${_JETT_LIB_LOADED:-}" ]] && return 0
readonly _JETT_LIB_LOADED=1

# -----------------------------------------------------------------------------
# VARIÁVEIS GLOBAIS
# Cada variável usa o valor exportado pelo orquestrador se já definido,
# ou cai no valor padrão. Isso permite que os módulos também sejam executados
# diretamente para testes sem precisar do orquestrador.
# -----------------------------------------------------------------------------

NAVEGADOR_PADRAO="${NAVEGADOR_PADRAO:-firefox}"
USUARIO_JETT="${USUARIO_JETT:-jett}"
LOG_ARQUIVO="${LOG_ARQUIVO:-/var/log/jett-os-build.log}"
VERSAO_SCRIPT="${VERSAO_SCRIPT:-1.0.0}"

# Raiz do projeto: dois níveis acima de build/base/ (onde lib.sh está)
# Se PROJETO_DIR já foi exportado pelo orquestrador, usa esse valor.
if [[ -z "${PROJETO_DIR:-}" ]]; then
    PROJETO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# -----------------------------------------------------------------------------
# CORES
# -----------------------------------------------------------------------------

COR_RESET="\033[0m"
COR_VERDE="\033[1;32m"
COR_AMARELO="\033[1;33m"
COR_VERMELHO="\033[1;31m"
COR_CIANO="\033[1;36m"
COR_BRANCO="\033[1;37m"

# -----------------------------------------------------------------------------
# FUNÇÕES DE LOG
# Todas as funções escrevem no terminal e no arquivo de log simultaneamente.
# -----------------------------------------------------------------------------

# Inicializa o arquivo de log com cabeçalho da sessão de build
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

# Exibe erro, registra no log e encerra o processo atual
log_erro() {
    local mensagem="$1"
    local timestamp
    timestamp="$(date '+%H:%M:%S')"
    echo -e "${COR_VERMELHO}[${timestamp}]  ✗  ERRO: ${mensagem}${COR_RESET}" >&2
    echo "[${timestamp}] [ERRO]  ${mensagem}" >> "$LOG_ARQUIVO"
    exit 1
}

# Imprime separador visual para organizar seções no terminal
log_separador() {
    echo -e "${COR_CIANO}─────────────────────────────────────────────────${COR_RESET}"
}

# -----------------------------------------------------------------------------
# FUNÇÕES UTILITÁRIAS
# -----------------------------------------------------------------------------

# Verifica se um pacote está instalado no sistema
pacote_instalado() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# Verifica se um usuário existe no sistema
usuario_existe() {
    id "$1" &>/dev/null
}

# Verifica se o script está sendo executado como root
verificar_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_erro "Este script precisa ser executado como root. Use: sudo $0"
    fi
}

# Verifica se o sistema é Debian ou derivado compatível
verificar_sistema() {
    if [[ ! -f /etc/debian_version ]]; then
        log_erro "Sistema não compatível. Este script requer Debian ou derivado."
    fi
    local versao_debian
    versao_debian=$(cat /etc/debian_version)
    log_info "Sistema detectado: Debian/derivado — versão ${versao_debian}"
}
