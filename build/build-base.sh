#!/usr/bin/env bash
# =============================================================================
# build-base.sh — Orquestrador do build da base do Jett OS
# =============================================================================
# Descrição:
#   Coordena as etapas de configuração do sistema, chamando cada módulo em
#   build/base/ na sequência correta. Cada módulo também pode ser executado
#   individualmente para depuração ou reexecução parcial.
#
# Uso:
#   sudo ./build/build-base.sh [--navegador NOME]
#
# Opções:
#   --navegador   Navegador padrão a configurar no sistema
#                 Valores: brave | edge | thorium | opera-gx | firefox
#                 Padrão: firefox
#
# Módulos executados em sequência:
#   build/base/01-update.sh          — atualiza repositórios e sistema base
#   build/base/02-remove-bloat.sh    — remove pacotes desnecessários
#   build/base/03-install-packages.sh — instala pacotes essenciais
#   build/base/04-user.sh            — cria e configura o usuário kiosk 'jett'
#   build/base/05-sway.sh            — instala Sway e scripts do launcher
#   build/base/06-network.sh         — configura rede via systemd-networkd
#   build/base/07-bbr.sh             — aplica TCP BBR e salva config do navegador
#
# Idempotência:
#   Cada módulo verifica o estado atual antes de agir. É seguro executar
#   este script múltiplas vezes sem efeitos colaterais indesejados.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# BOOTSTRAP: define variáveis globais e exporta para os módulos
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJETO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Valores exportados — módulos leem via lib.sh (com fallback para esses valores)
export NAVEGADOR_PADRAO="${NAVEGADOR_PADRAO:-firefox}"
export USUARIO_JETT="jett"
export LOG_ARQUIVO="/var/log/jett-os-build.log"
export VERSAO_SCRIPT="1.0.0"
export PROJETO_DIR

# Carrega funções de log e utilitários compartilhados
# shellcheck source=base/lib.sh
source "${SCRIPT_DIR}/base/lib.sh"

# -----------------------------------------------------------------------------
# FUNÇÕES DO ORQUESTRADOR
# (processamento de args, verificações e relatório final ficam aqui)
# -----------------------------------------------------------------------------

processar_argumentos() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --navegador)
                shift
                case "$1" in
                    brave|edge|thorium|opera-gx|firefox)
                        NAVEGADOR_PADRAO="$1"
                        export NAVEGADOR_PADRAO
                        ;;
                    *)
                        log_erro "Navegador inválido: '$1'. Use: brave | edge | thorium | opera-gx | firefox"
                        ;;
                esac
                ;;
            --help|-h)
                echo "Uso: sudo ./build/build-base.sh [--navegador NOME]"
                echo "Navegadores: brave | edge | thorium | opera-gx | firefox"
                echo ""
                echo "Módulos disponíveis para execução individual:"
                echo "  sudo ./build/base/01-update.sh"
                echo "  sudo ./build/base/02-remove-bloat.sh"
                echo "  sudo ./build/base/03-install-packages.sh"
                echo "  sudo ./build/base/04-user.sh"
                echo "  sudo ./build/base/05-sway.sh"
                echo "  sudo ./build/base/06-network.sh"
                echo "  sudo ./build/base/07-bbr.sh"
                exit 0
                ;;
            *)
                log_erro "Argumento desconhecido: '$1'. Use --help para ver as opções."
                ;;
        esac
        shift
    done
}

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
    echo -e "       → Execute: sudo ./build/browsers/install-${NAVEGADOR_PADRAO}.sh"
    echo -e "    2. Reinicie o sistema para ativar todas as configurações"
    echo -e "       → Execute: sudo reboot"
    echo ""
    log_separador
}

# Executa um módulo via bash, herdando todas as variáveis exportadas
executar_modulo() {
    local modulo="$1"
    local caminho="${SCRIPT_DIR}/base/${modulo}"
    if [[ ! -f "$caminho" ]]; then
        log_erro "Módulo não encontrado: ${caminho}"
    fi
    bash "$caminho"
}

# -----------------------------------------------------------------------------
# PONTO DE ENTRADA PRINCIPAL
# -----------------------------------------------------------------------------

main() {
    clear
    echo -e "${COR_CIANO}"
    echo "  ╦╔═╗╔╦╗╔╦╗  ╔═╗╔═╗"
    echo "  ║║╣  ║  ║   ║ ║╚═╗"
    echo " ╚╝╚═╝ ╩  ╩   ╚═╝╚═╝"
    echo -e "${COR_RESET}"
    echo -e "  ${COR_BRANCO}Build Base v${VERSAO_SCRIPT} — Construindo a fundação${COR_RESET}"
    echo ""

    processar_argumentos "$@"
    inicializar_log
    verificar_root
    verificar_sistema

    log_info "Iniciando build com navegador padrão: ${NAVEGADOR_PADRAO}"
    log_info "Módulos em: ${SCRIPT_DIR}/base/"
    log_info "Log sendo salvo em: ${LOG_ARQUIVO}"
    echo ""

    # Executa cada módulo em sequência
    # Cada módulo herda as variáveis exportadas e usa lib.sh para log
    executar_modulo "01-update.sh"
    executar_modulo "02-remove-bloat.sh"
    executar_modulo "03-install-packages.sh"
    executar_modulo "04-user.sh"
    executar_modulo "05-sway.sh"
    executar_modulo "06-network.sh"
    executar_modulo "07-bbr.sh"

    exibir_resumo
}

main "$@"
