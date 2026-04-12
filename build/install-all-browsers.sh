#!/usr/bin/env bash
# =============================================================================
# install-all-browsers.sh — Instalação consolidada de todos os navegadores
# =============================================================================
# Descrição:
#   Instala todos os navegadores suportados pelo Jett OS em sequência:
#     1. Brave Browser    (build/install-brave.sh)
#     2. Microsoft Edge   (build/browsers/install-edge.sh)
#     3. Thorium Browser  (build/browsers/install-thorium.sh)
#     4. Opera GX         (build/browsers/install-opera-gx.sh)
#     5. Firefox          (build/browsers/install-firefox.sh)
#
#   Produz um log consolidado e um relatório final de status.
#   Uma falha em um navegador não interrompe a instalação dos demais.
#
# Uso:
#   sudo ./install-all-browsers.sh [opções]
#
# Opções:
#   --url URL             URL padrão para todos os navegadores (padrão: about:blank)
#   --only NOME[,NOME]    Instala apenas os navegadores listados
#                         (brave, edge, thorium, opera-gx, firefox)
#   --skip NOME[,NOME]    Pula os navegadores listados
#   --thorium-avx2        Usa build AVX2 do Thorium (padrão: AVX)
#   --thorium-sse4        Usa build SSE4 do Thorium (máxima compatibilidade)
#   --firefox-esr         Instala Firefox ESR em vez do Stable
#   --set-default NOME    Define o navegador especificado como ativo após instalar
#                         (brave, edge, thorium, opera-gx, firefox)
#   --help                Exibe esta ajuda
#
# Saída:
#   Log consolidado: /var/log/jett-os-build.log (acumulado)
#   Relatório:       /var/log/jett-os-browsers.log (este script)
#   Registro:        /etc/jett-os/navegadores-instalados.conf
#
# Idempotência:
#   Seguro de executar múltiplas vezes. Cada sub-script verifica o estado
#   atual e pula etapas já concluídas.
#
# Tempo estimado:
#   Depende da velocidade da conexão. Brave, Edge e Firefox são instalados
#   via APT (rápido). Thorium requer download de ~200 MB do GitHub.
#   Estimativa típica: 5-15 minutos com boa conexão.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# VARIÁVEIS GLOBAIS
# -----------------------------------------------------------------------------

VERSAO_SCRIPT="1.0.0"

# Diretório deste script (deve ser build/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROWSERS_DIR="${SCRIPT_DIR}/browsers"

# Log específico deste script (separado do log geral)
LOG_CONSOLIDADO="/var/log/jett-os-browsers.log"
# Log geral compartilhado com os sub-scripts
LOG_ARQUIVO="/var/log/jett-os-build.log"

# URL padrão para todos os navegadores
URL_PADRAO="${URL_PADRAO:-about:blank}"

# Variante do Thorium (avx, avx2, sse4)
THORIUM_VARIANTE="avx"

# Canal do Firefox (stable, esr)
FIREFOX_CANAL="stable"

# Navegador a definir como padrão após instalação (vazio = não muda)
NAVEGADOR_PADRAO=""

# Listas de navegadores para instalar/pular
# Formato: "brave edge thorium opera-gx firefox"
INSTALAR_APENAS=""
PULAR_NAVEGADORES=""

# Navegadores na ordem de instalação
TODOS_NAVEGADORES=("brave" "edge" "thorium" "opera-gx" "firefox")

# Cores para saída no terminal
COR_RESET="\033[0m"
COR_VERDE="\033[1;32m"
COR_AMARELO="\033[1;33m"
COR_VERMELHO="\033[1;31m"
COR_CIANO="\033[1;36m"
COR_BRANCO="\033[1;37m"
COR_CINZA="\033[0;37m"

# Contadores de resultado
TOTAL_SUCESSO=0
TOTAL_PULADO=0
TOTAL_FALHA=0
declare -A RESULTADO_POR_NAVEGADOR

# Timestamp de início para cálculo de duração
TS_INICIO=""

# -----------------------------------------------------------------------------
# FUNÇÕES DE LOG
# -----------------------------------------------------------------------------

inicializar_log() {
    mkdir -p "$(dirname "$LOG_CONSOLIDADO")"
    mkdir -p "$(dirname "$LOG_ARQUIVO")"
    TS_INICIO="$(date +%s)"
    {
        echo "======================================================="
        echo "  install-all-browsers.sh v${VERSAO_SCRIPT}"
        echo "  Início: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "======================================================="
        echo "  URL padrão    : ${URL_PADRAO}"
        echo "  Thorium       : ${THORIUM_VARIANTE}"
        echo "  Firefox canal : ${FIREFOX_CANAL}"
        [[ -n "$INSTALAR_APENAS" ]] && echo "  Apenas        : ${INSTALAR_APENAS}"
        [[ -n "$PULAR_NAVEGADORES" ]] && echo "  Pular         : ${PULAR_NAVEGADORES}"
        [[ -n "$NAVEGADOR_PADRAO" ]] && echo "  Padrão        : ${NAVEGADOR_PADRAO}"
        echo "======================================================="
    } | tee -a "$LOG_CONSOLIDADO" >> "$LOG_ARQUIVO"
}

log_fase() {
    local msg="$1"
    local ts; ts="$(date '+%H:%M:%S')"
    echo ""
    echo -e "${COR_CIANO}╔══════════════════════════════════════════════════╗${COR_RESET}"
    echo -e "${COR_CIANO}║  [${ts}] ${msg}${COR_RESET}"
    echo -e "${COR_CIANO}╚══════════════════════════════════════════════════╝${COR_RESET}"
    echo "[${ts}] [FASE] ${msg}" >> "$LOG_CONSOLIDADO"
}

log_info() {
    local msg="$1"
    local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_BRANCO}[${ts}]  ${msg}${COR_RESET}"
    echo "[${ts}] [INFO] ${msg}" >> "$LOG_CONSOLIDADO"
}

log_ok() {
    local msg="$1"
    local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_VERDE}[${ts}]  ✓  ${msg}${COR_RESET}"
    echo "[${ts}] [OK]   ${msg}" >> "$LOG_CONSOLIDADO"
}

log_aviso() {
    local msg="$1"
    local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_AMARELO}[${ts}]  !  ${msg}${COR_RESET}"
    echo "[${ts}] [AVISO] ${msg}" >> "$LOG_CONSOLIDADO"
}

log_erro_nao_fatal() {
    local msg="$1"
    local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_VERMELHO}[${ts}]  ✗  FALHA: ${msg}${COR_RESET}" >&2
    echo "[${ts}] [ERRO]  ${msg}" >> "$LOG_CONSOLIDADO"
}

log_separador() {
    echo -e "${COR_CINZA}──────────────────────────────────────────────────${COR_RESET}"
}

# -----------------------------------------------------------------------------
# FUNÇÕES DE VERIFICAÇÃO
# -----------------------------------------------------------------------------

verificar_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${COR_VERMELHO}ERRO: Execute como root: sudo ./install-all-browsers.sh${COR_RESET}" >&2
        exit 1
    fi
}

verificar_scripts() {
    local scripts_faltando=false

    # Verifica install-brave.sh (fica em build/, não em build/browsers/)
    if [[ ! -x "${SCRIPT_DIR}/install-brave.sh" ]]; then
        log_aviso "Script não encontrado ou sem permissão: ${SCRIPT_DIR}/install-brave.sh"
        scripts_faltando=true
    fi

    # Verifica scripts em build/browsers/
    for nav in edge thorium opera-gx firefox; do
        local script="${BROWSERS_DIR}/install-${nav}.sh"
        if [[ ! -f "$script" ]]; then
            log_aviso "Script não encontrado: ${script}"
            scripts_faltando=true
        elif [[ ! -x "$script" ]]; then
            log_info "Adicionando permissão de execução: ${script}"
            chmod +x "$script"
        fi
    done

    if [[ "$scripts_faltando" == "true" ]]; then
        log_aviso "Um ou mais scripts de instalação não encontrados. Eles serão pulados."
    fi

    # Garante permissão de execução em install-brave.sh
    [[ -f "${SCRIPT_DIR}/install-brave.sh" ]] && chmod +x "${SCRIPT_DIR}/install-brave.sh"
}

verificar_base_instalada() {
    if ! id "jett" &>/dev/null; then
        echo -e "${COR_VERMELHO}ERRO: Usuário 'jett' não encontrado. Execute build-base.sh primeiro.${COR_RESET}" >&2
        exit 1
    fi
    log_ok "Usuário 'jett' presente."
}

verificar_conexao() {
    log_info "Verificando conexão com a internet..."
    if ! curl -sf --max-time 10 "https://example.com" -o /dev/null; then
        echo -e "${COR_VERMELHO}ERRO: Sem conexão com a internet. Todos os navegadores precisam de download.${COR_RESET}" >&2
        exit 1
    fi
    log_ok "Conexão com a internet confirmada."
}

# -----------------------------------------------------------------------------
# FUNÇÕES DE CONTROLE DE SELEÇÃO
# -----------------------------------------------------------------------------

# Retorna 0 se o navegador deve ser instalado, 1 caso contrário
deve_instalar() {
    local nav="$1"

    # Verifica se está na lista de pular
    if [[ -n "$PULAR_NAVEGADORES" ]]; then
        # Converte vírgulas em espaços para iterar
        for pular in ${PULAR_NAVEGADORES//,/ }; do
            if [[ "$nav" == "$pular" ]]; then
                return 1
            fi
        done
    fi

    # Se --only foi especificado, instala apenas os da lista
    if [[ -n "$INSTALAR_APENAS" ]]; then
        for instalar in ${INSTALAR_APENAS//,/ }; do
            if [[ "$nav" == "$instalar" ]]; then
                return 0
            fi
        done
        return 1  # Não está na lista --only
    fi

    return 0  # Instala por padrão
}

# Retorna o script correspondente ao navegador
script_para_navegador() {
    local nav="$1"
    case "$nav" in
        brave)    echo "${SCRIPT_DIR}/install-brave.sh" ;;
        edge)     echo "${BROWSERS_DIR}/install-edge.sh" ;;
        thorium)  echo "${BROWSERS_DIR}/install-thorium.sh" ;;
        opera-gx) echo "${BROWSERS_DIR}/install-opera-gx.sh" ;;
        firefox)  echo "${BROWSERS_DIR}/install-firefox.sh" ;;
        *)        echo "" ;;
    esac
}

# Monta os argumentos para cada script
args_para_navegador() {
    local nav="$1"
    local args=("--url" "${URL_PADRAO}")

    # Argumentos específicos por navegador
    case "$nav" in
        thorium)
            args+=("--${THORIUM_VARIANTE}")
            ;;
        firefox)
            if [[ "$FIREFOX_CANAL" == "esr" ]]; then
                args+=("--esr")
            fi
            ;;
    esac

    # Adiciona --set-default se este é o navegador padrão escolhido
    if [[ -n "$NAVEGADOR_PADRAO" && "$nav" == "$NAVEGADOR_PADRAO" ]]; then
        args+=("--set-default")
    fi

    echo "${args[@]}"
}

# -----------------------------------------------------------------------------
# FUNÇÃO PRINCIPAL DE INSTALAÇÃO DE UM NAVEGADOR
# -----------------------------------------------------------------------------

instalar_navegador() {
    local nav="$1"
    local nome_exibicao="${2:-$nav}"
    local script
    script="$(script_para_navegador "$nav")"

    log_separador
    log_fase "Instalando: ${nome_exibicao}"

    # Verifica se deve ser instalado
    if ! deve_instalar "$nav"; then
        log_info "Pulando ${nome_exibicao} (excluído via --skip ou não incluso em --only)."
        RESULTADO_POR_NAVEGADOR["$nav"]="PULADO"
        ((TOTAL_PULADO++))
        return 0
    fi

    # Verifica se o script existe
    if [[ -z "$script" || ! -f "$script" ]]; then
        log_erro_nao_fatal "Script de instalação não encontrado para '${nav}': ${script}"
        RESULTADO_POR_NAVEGADOR["$nav"]="FALHA (script não encontrado)"
        ((TOTAL_FALHA++))
        return 0
    fi

    # Monta argumentos
    local args_str
    args_str="$(args_para_navegador "$nav")"

    log_info "Script  : ${script}"
    log_info "Argumentos: ${args_str}"

    local ts_nav_inicio
    ts_nav_inicio="$(date +%s)"

    # Executa o script de instalação
    # Redireciona stdout e stderr: exibe no terminal E registra no log
    if bash "$script" ${args_str} 2>&1 | tee -a "$LOG_ARQUIVO"; then
        local ts_nav_fim duracao_nav
        ts_nav_fim="$(date +%s)"
        duracao_nav="$(( ts_nav_fim - ts_nav_inicio ))"
        log_ok "${nome_exibicao} instalado com sucesso em ${duracao_nav}s."
        RESULTADO_POR_NAVEGADOR["$nav"]="OK (${duracao_nav}s)"
        ((TOTAL_SUCESSO++))
    else
        local codigo_saida=$?
        log_erro_nao_fatal "${nome_exibicao} falhou (código de saída: ${codigo_saida})."
        log_aviso "Continuando com o próximo navegador..."
        RESULTADO_POR_NAVEGADOR["$nav"]="FALHA (código: ${codigo_saida})"
        ((TOTAL_FALHA++))
    fi
}

# -----------------------------------------------------------------------------
# EXIBE RELATÓRIO FINAL
# -----------------------------------------------------------------------------

exibir_relatorio() {
    local ts_fim duracao_total
    ts_fim="$(date +%s)"
    duracao_total="$(( ts_fim - TS_INICIO ))"
    local duracao_min=$(( duracao_total / 60 ))
    local duracao_seg=$(( duracao_total % 60 ))

    echo ""
    echo ""
    echo -e "${COR_BRANCO}╔═══════════════════════════════════════════════════════╗${COR_RESET}"
    echo -e "${COR_BRANCO}║          RELATÓRIO DE INSTALAÇÃO — JETT OS             ║${COR_RESET}"
    echo -e "${COR_BRANCO}╠═══════════════════════════════════════════════════════╣${COR_RESET}"
    echo -e "${COR_BRANCO}║  Concluído em: $(date '+%Y-%m-%d %H:%M:%S')              ║${COR_RESET}"
    printf "${COR_BRANCO}║  Duração total: %dm %ds%$(( 36 - ${#duracao_min} - ${#duracao_seg} ))s║${COR_RESET}\n" \
        "$duracao_min" "$duracao_seg" " "
    echo -e "${COR_BRANCO}╠═══════════════════════════════════════════════════════╣${COR_RESET}"
    echo -e "${COR_BRANCO}║  Resultados por navegador:                            ║${COR_RESET}"
    echo -e "${COR_BRANCO}╠═══════════════════════════════════════════════════════╣${COR_RESET}"

    # Nomes amigáveis para exibição
    declare -A NOMES_EXIBICAO
    NOMES_EXIBICAO["brave"]="Brave Browser  "
    NOMES_EXIBICAO["edge"]="Microsoft Edge "
    NOMES_EXIBICAO["thorium"]="Thorium Browser"
    NOMES_EXIBICAO["opera-gx"]="Opera GX       "
    NOMES_EXIBICAO["firefox"]="Firefox        "

    for nav in "${TODOS_NAVEGADORES[@]}"; do
        local resultado="${RESULTADO_POR_NAVEGADOR[$nav]:-NÃO PROCESSADO}"
        local cor="$COR_CINZA"
        local icone="─"
        case "${resultado%% *}" in
            OK)     cor="$COR_VERDE";   icone="✓" ;;
            FALHA)  cor="$COR_VERMELHO"; icone="✗" ;;
            PULADO) cor="$COR_AMARELO"; icone="○" ;;
        esac
        printf "${COR_BRANCO}║  ${cor}${icone} %-15s : %-34s${COR_BRANCO}║${COR_RESET}\n" \
            "${NOMES_EXIBICAO[$nav]:-$nav}" "$resultado"
    done

    echo -e "${COR_BRANCO}╠═══════════════════════════════════════════════════════╣${COR_RESET}"
    printf "${COR_BRANCO}║  ${COR_VERDE}✓ Sucesso: %-3s${COR_BRANCO}  ${COR_AMARELO}○ Pulados: %-3s${COR_BRANCO}  ${COR_VERMELHO}✗ Falhas: %-3s${COR_BRANCO}  ║${COR_RESET}\n" \
        "$TOTAL_SUCESSO" "$TOTAL_PULADO" "$TOTAL_FALHA"
    echo -e "${COR_BRANCO}╠═══════════════════════════════════════════════════════╣${COR_RESET}"

    # Exibe navegador ativo atual
    local nav_ativo="(não definido)"
    if [[ -f "/etc/jett-os/navegador.conf" ]]; then
        nav_ativo="$(grep '^JETT_NAVEGADOR=' /etc/jett-os/navegador.conf 2>/dev/null | cut -d'"' -f2 || echo "desconhecido")"
    fi
    printf "${COR_BRANCO}║  Navegador ativo: %-37s║${COR_RESET}\n" "${nav_ativo}"
    printf "${COR_BRANCO}║  Registro em: %-41s║${COR_RESET}\n" "/etc/jett-os/navegadores-instalados.conf"
    printf "${COR_BRANCO}║  Log completo: %-40s║${COR_RESET}\n" "${LOG_CONSOLIDADO}"
    echo -e "${COR_BRANCO}╚═══════════════════════════════════════════════════════╝${COR_RESET}"
    echo ""

    if [[ "$TOTAL_FALHA" -gt 0 ]]; then
        echo -e "${COR_AMARELO}  Atenção: ${TOTAL_FALHA} navegador(es) falharam.${COR_RESET}"
        echo -e "${COR_AMARELO}  Verifique: journalctl -xe ou ${LOG_CONSOLIDADO}${COR_RESET}"
        echo ""
    fi

    if [[ "$TOTAL_SUCESSO" -gt 0 ]]; then
        echo -e "  ${COR_VERDE}Próximos passos:${COR_RESET}"
        echo -e "    1. Reinicie para testar o boot automático:"
        echo -e "       ${COR_CIANO}sudo reboot${COR_RESET}"
        echo -e "    2. Para trocar o navegador ativo via GRUB:"
        echo -e "       ${COR_CIANO}sudo update-grub && sudo reboot${COR_RESET}"
        echo -e "    3. Para trocar sem reiniciar (via launcher):"
        echo -e "       ${COR_CIANO}Super+B${COR_RESET} (na sessão Sway do Jett OS)"
        echo ""
    fi

    # Registra relatório no log
    {
        echo ""
        echo "======================================================="
        echo "  RELATÓRIO FINAL"
        echo "  Fim: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  Duração: ${duracao_min}m ${duracao_seg}s"
        echo "  Sucesso: ${TOTAL_SUCESSO} | Pulados: ${TOTAL_PULADO} | Falhas: ${TOTAL_FALHA}"
        for nav in "${TODOS_NAVEGADORES[@]}"; do
            echo "  ${nav}: ${RESULTADO_POR_NAVEGADOR[$nav]:-NÃO PROCESSADO}"
        done
        echo "======================================================="
    } >> "$LOG_CONSOLIDADO"
}

# -----------------------------------------------------------------------------
# PROCESSAMENTO DE ARGUMENTOS
# -----------------------------------------------------------------------------

processar_argumentos() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)
                shift
                URL_PADRAO="$1"
                ;;
            --only)
                shift
                INSTALAR_APENAS="$1"
                ;;
            --skip)
                shift
                PULAR_NAVEGADORES="$1"
                ;;
            --thorium-avx2)
                THORIUM_VARIANTE="avx2"
                ;;
            --thorium-sse4)
                THORIUM_VARIANTE="sse4"
                ;;
            --firefox-esr)
                FIREFOX_CANAL="esr"
                ;;
            --set-default)
                shift
                NAVEGADOR_PADRAO="$1"
                # Valida o nome do navegador
                local validos="brave edge thorium opera-gx firefox"
                if ! echo "$validos" | grep -qw "$NAVEGADOR_PADRAO"; then
                    echo "ERRO: Navegador inválido para --set-default: '${NAVEGADOR_PADRAO}'" >&2
                    echo "      Válidos: ${validos}" >&2
                    exit 1
                fi
                ;;
            --help|-h)
                echo "Uso: sudo ./install-all-browsers.sh [opções]"
                echo ""
                echo "Opções:"
                echo "  --url URL                URL padrão para todos (padrão: about:blank)"
                echo "  --only brave,firefox     Instala apenas os navegadores listados"
                echo "  --skip edge,opera-gx     Pula os navegadores listados"
                echo "  --thorium-avx2           Build AVX2 do Thorium"
                echo "  --thorium-sse4           Build SSE4 do Thorium (máxima compatibilidade)"
                echo "  --firefox-esr            Firefox ESR em vez do Stable"
                echo "  --set-default NOME       Define navegador padrão"
                echo "                           (brave, edge, thorium, opera-gx, firefox)"
                echo ""
                echo "Exemplos:"
                echo "  sudo ./install-all-browsers.sh"
                echo "  sudo ./install-all-browsers.sh --skip opera-gx --set-default brave"
                echo "  sudo ./install-all-browsers.sh --only brave,firefox --firefox-esr"
                echo "  sudo ./install-all-browsers.sh --thorium-avx2 --url https://meusite.com"
                exit 0
                ;;
            *)
                echo "ERRO: Argumento desconhecido: '$1'. Use --help." >&2
                exit 1
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
    echo "     ██╗███████╗████████╗████████╗      ██████╗ ███████╗"
    echo "     ██║██╔════╝╚══██╔══╝╚══██╔══╝     ██╔═══██╗██╔════╝"
    echo "     ██║█████╗     ██║      ██║         ██║   ██║███████╗"
    echo "██   ██║██╔══╝     ██║      ██║         ██║   ██║╚════██║"
    echo "╚█████╔╝███████╗   ██║      ██║         ╚██████╔╝███████║"
    echo " ╚════╝ ╚══════╝   ╚═╝      ╚═╝          ╚═════╝ ╚══════╝"
    echo -e "${COR_RESET}"
    echo -e "  ${COR_BRANCO}Instalação Consolidada de Navegadores — Jett OS v${VERSAO_SCRIPT}${COR_RESET}"
    echo -e "  ${COR_CINZA}brave · edge · thorium · opera-gx · firefox${COR_RESET}"
    echo ""

    processar_argumentos "$@"
    inicializar_log

    verificar_root
    verificar_base_instalada
    verificar_conexao
    verificar_scripts

    echo ""
    log_info "Iniciando instalação de ${#TODOS_NAVEGADORES[@]} navegadores..."
    log_info "URL padrão    : ${URL_PADRAO}"
    log_info "Thorium build : ${THORIUM_VARIANTE}"
    log_info "Firefox canal : ${FIREFOX_CANAL}"
    [[ -n "$NAVEGADOR_PADRAO" ]] && log_info "Padrão ao final: ${NAVEGADOR_PADRAO}"
    [[ -n "$INSTALAR_APENAS" ]]  && log_info "Apenas: ${INSTALAR_APENAS}"
    [[ -n "$PULAR_NAVEGADORES" ]] && log_info "Pular: ${PULAR_NAVEGADORES}"
    echo ""

    # Nomes amigáveis para exibição no log de fase
    declare -A NOMES_EXIBICAO
    NOMES_EXIBICAO["brave"]="Brave Browser"
    NOMES_EXIBICAO["edge"]="Microsoft Edge"
    NOMES_EXIBICAO["thorium"]="Thorium Browser"
    NOMES_EXIBICAO["opera-gx"]="Opera GX"
    NOMES_EXIBICAO["firefox"]="Firefox"

    # ── Instala cada navegador em sequência ────────────────────────────────────
    for nav in "${TODOS_NAVEGADORES[@]}"; do
        instalar_navegador "$nav" "${NOMES_EXIBICAO[$nav]}"
    done

    # ── Relatório final ────────────────────────────────────────────────────────
    exibir_relatorio

    # Código de saída: 0 se todos com sucesso/pulado, 1 se houve alguma falha
    if [[ "$TOTAL_FALHA" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
