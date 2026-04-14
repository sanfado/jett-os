#!/usr/bin/env bash
# =============================================================================
# jett-switch.sh — Lógica de troca de navegador do Jett OS
# =============================================================================
# Descrição:
#   Encerra o navegador em uso graciosamente e inicia o novo navegador
#   escolhido pelo usuário via jett-launcher.py.
#
# Uso:
#   sudo jett-switch.sh --navegador NOME
#
# Argumentos:
#   --navegador   ID do navegador alvo: brave | edge | thorium | opera-gx | firefox
#
# Privilégios:
#   Requer root para escrever em /etc/jett-os/navegador.conf.
#   Configuração sudoers (feita pelo install-launcher.sh):
#     jett ALL=(ALL) NOPASSWD: /usr/local/bin/jett-switch.sh
#
# Contexto de execução:
#   Este script é chamado dentro de uma sessão Sway (Wayland).
#   Usa 'swaymsg exec' para iniciar o novo navegador dentro do Sway,
#   garantindo que o Sway o coloque em tela cheia conforme as regras
#   definidas em config/sway/config.
#
# Fluxo de execução:
#   1. Valida o navegador alvo
#   2. Lê o navegador atual de /etc/jett-os/navegador.conf
#   3. Encerra o processo do navegador atual (SIGTERM → aguarda → SIGKILL)
#   4. Atualiza /etc/jett-os/navegador.conf com o novo navegador
#   5. Inicia o novo navegador via 'swaymsg exec'
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# VARIÁVEIS GLOBAIS
# ─────────────────────────────────────────────────────────────────────────────

VERSAO_SCRIPT="1.0.0"
CONF_DIR="/etc/jett-os"
CONF_NAVEGADOR="${CONF_DIR}/navegador.conf"
LOG_ARQUIVO="/tmp/jett-os-switch.log"

# Tempo máximo de espera por encerramento gracioso (segundos)
TIMEOUT_ENCERRAMENTO=5

# Usuário da sessão Sway (para swaymsg, que requer variáveis do usuário)
USUARIO_JETT="${SUDO_USER:-jett}"

# Cores para saída no terminal (útil para debug manual)
COR_RESET="\033[0m"
COR_VERDE="\033[1;32m"
COR_AMARELO="\033[1;33m"
COR_VERMELHO="\033[1;31m"
COR_CIANO="\033[1;36m"

# ─────────────────────────────────────────────────────────────────────────────
# MAPA DE NAVEGADORES
# Cada entrada: ID → "binario|processo_pkill|comando_kiosk"
#   binario       → executável no PATH
#   processo      → nome do processo para pkill
#   comando       → comando completo para iniciar em modo kiosk
# ─────────────────────────────────────────────────────────────────────────────

declare -A NAV_BINARIO=(
    [brave]="brave-browser"
    [edge]="microsoft-edge-stable"   # pacote instala microsoft-edge-stable, não microsoft-edge
    [thorium]="thorium-browser"
    [opera-gx]="opera"
    [firefox]="firefox"
)

declare -A NAV_PROCESSO=(
    [brave]="brave"
    [edge]="microsoft-edge-stable"
    [thorium]="thorium-browser"
    [opera-gx]="opera"
    [firefox]="firefox"
)

# Mapeamento de ID do navegador para o arquivo de configuração runtime
# e para o nome da variável de flags dentro desse arquivo.
declare -A NAV_CONF_ARQUIVO=(
    [brave]="brave.conf"
    [edge]="edge.conf"
    [thorium]="thorium.conf"
    [opera-gx]="opera.conf"
)
declare -A NAV_CONF_VAR=(
    [brave]="JETT_BRAVE_FLAGS_STR"
    [edge]="JETT_EDGE_FLAGS_STR"
    [thorium]="JETT_THORIUM_FLAGS_STR"
    [opera-gx]="JETT_OPERA_FLAGS_STR"
)

declare -A NAV_NOME_DISPLAY=(
    [brave]="Brave Browser"
    [edge]="Microsoft Edge"
    [thorium]="Thorium Browser"
    [opera-gx]="Opera GX"
    [firefox]="Firefox"
)

# ─────────────────────────────────────────────────────────────────────────────
# FUNÇÕES DE UTILIDADE — FLAGS E COMANDO DO NAVEGADOR
# ─────────────────────────────────────────────────────────────────────────────

# Retorna o comando completo para iniciar o navegador em modo kiosk.
# Fonte: /etc/jett-os/<nav>.conf (escrito pelo install-<nav>.sh).
# O Firefox usa o wrapper dedicado /usr/local/bin/jett-firefox-kiosk que
# exporta MOZ_ENABLE_WAYLAND e passa --profile com user.js correto.
obter_comando_navegador() {
    local id_nav="$1"

    # Firefox: wrapper dedicado cuida de flags, env vars e perfil
    if [[ "$id_nav" == "firefox" ]]; then
        echo "/usr/local/bin/jett-firefox-kiosk"
        return
    fi

    local binario="${NAV_BINARIO[$id_nav]:-$id_nav}"
    local conf_arquivo="${NAV_CONF_ARQUIVO[$id_nav]:-}"
    local conf_var="${NAV_CONF_VAR[$id_nav]:-}"

    if [[ -n "$conf_arquivo" && -n "$conf_var" ]]; then
        local conf_path="${CONF_DIR}/${conf_arquivo}"
        if [[ -f "$conf_path" ]]; then
            # Carrega o arquivo de configuração em subshell para não poluir o ambiente
            local flags_str
            flags_str=$(bash -c "source '${conf_path}' 2>/dev/null; echo \"\${${conf_var}:-}\"" 2>/dev/null || true)
            if [[ -n "$flags_str" ]]; then
                echo "${binario} ${flags_str}"
                return
            fi
        fi
    fi

    # Fallback: binário sem flags customizadas
    # (ocorre quando o script de instalação não foi executado ainda)
    echo "$binario"
}

# ─────────────────────────────────────────────────────────────────────────────
# FUNÇÕES DE LOG
# ─────────────────────────────────────────────────────────────────────────────

inicializar_log() {
    mkdir -p "$(dirname "$LOG_ARQUIVO")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] jett-switch.sh iniciado (v${VERSAO_SCRIPT})" \
        >> "$LOG_ARQUIVO"
}

log_info() {
    local msg="$1"
    local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_CIANO}[${ts}] ${msg}${COR_RESET}"
    echo "[${ts}] [INFO]  ${msg}" >> "$LOG_ARQUIVO"
}

log_ok() {
    local msg="$1"
    local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_VERDE}[${ts}] ✓ ${msg}${COR_RESET}"
    echo "[${ts}] [OK]    ${msg}" >> "$LOG_ARQUIVO"
}

log_aviso() {
    local msg="$1"
    local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_AMARELO}[${ts}] ! ${msg}${COR_RESET}"
    echo "[${ts}] [AVISO] ${msg}" >> "$LOG_ARQUIVO"
}

log_erro() {
    local msg="$1"
    local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_VERMELHO}[${ts}] ✗ ERRO: ${msg}${COR_RESET}" >&2
    echo "[${ts}] [ERRO]  ${msg}" >> "$LOG_ARQUIVO"
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# FUNÇÕES DE UTILIDADE
# ─────────────────────────────────────────────────────────────────────────────

# Lê o navegador atualmente configurado em navegador.conf
ler_navegador_atual() {
    if [[ -f "$CONF_NAVEGADOR" ]]; then
        local valor
        valor=$(grep -E '^JETT_NAVEGADOR=' "$CONF_NAVEGADOR" \
            | head -1 \
            | cut -d'=' -f2- \
            | tr -d '"' \
            | tr -d "'" \
            | xargs 2>/dev/null || echo "")
        echo "$valor"
    else
        echo ""
    fi
}

# Retorna o PID do navegador em execução, ou vazio se não estiver rodando
pid_navegador() {
    local id_nav="$1"
    local processo="${NAV_PROCESSO[$id_nav]:-}"
    if [[ -z "$processo" ]]; then
        echo ""
        return
    fi
    # Busca processos pelo nome do binário
    pgrep -f "${NAV_BINARIO[$id_nav]}" 2>/dev/null | head -1 || echo ""
}

# Encerra o navegador graciosamente: SIGTERM → aguarda → SIGKILL
encerrar_navegador() {
    local id_nav="$1"
    local binario="${NAV_BINARIO[$id_nav]:-}"
    local nome="${NAV_NOME_DISPLAY[$id_nav]:-$id_nav}"

    if [[ -z "$binario" ]]; then
        log_aviso "Navegador '${id_nav}' não reconhecido — nenhum processo encerrado."
        return
    fi

    # Verifica se o processo está em execução
    if ! pgrep -f "$binario" &>/dev/null 2>&1; then
        log_info "${nome} não está em execução — nada a encerrar."
        return
    fi

    log_info "Encerrando ${nome} graciosamente (SIGTERM)..."
    pkill -SIGTERM -f "$binario" 2>/dev/null || true

    # Aguarda o processo encerrar graciosamente
    local contagem=0
    while pgrep -f "$binario" &>/dev/null 2>&1; do
        sleep 0.5
        (( contagem++ )) || true
        if (( contagem >= TIMEOUT_ENCERRAMENTO * 2 )); then
            log_aviso "${nome} não encerrou em ${TIMEOUT_ENCERRAMENTO}s — forçando SIGKILL..."
            pkill -SIGKILL -f "$binario" 2>/dev/null || true
            sleep 0.5
            break
        fi
    done

    if pgrep -f "$binario" &>/dev/null 2>&1; then
        log_aviso "${nome} ainda em execução após SIGKILL. Continuando mesmo assim."
    else
        log_ok "${nome} encerrado."
    fi
}

# Atualiza /etc/jett-os/navegador.conf com o novo navegador
atualizar_conf() {
    local id_nav="$1"
    local cmd
    cmd="$(obter_comando_navegador "$id_nav")"
    local nome="${NAV_NOME_DISPLAY[$id_nav]}"

    mkdir -p "$CONF_DIR"

    cat > "$CONF_NAVEGADOR" << EOF
# /etc/jett-os/navegador.conf
# Gerado automaticamente pelo jett-switch.sh em $(date '+%Y-%m-%d %H:%M:%S').
# Para trocar de navegador: pressione Super+B no Sway.

# Navegador ativo
JETT_NAVEGADOR="${id_nav}"

# Comando completo (lido pelo cage-kiosk.service e pelo .bash_profile fallback)
JETT_NAVEGADOR_CMD="${cmd}"
EOF

    log_ok "navegador.conf atualizado: ${nome} (${id_nav})"
}

# Inicia o novo navegador dentro da sessão Sway do usuário
iniciar_navegador_sway() {
    local id_nav="$1"
    local cmd
    cmd="$(obter_comando_navegador "$id_nav")"
    local nome="${NAV_NOME_DISPLAY[$id_nav]}"

    log_info "Iniciando ${nome} via Sway..."

    # Descoberta do socket do Sway do usuário
    # O socket fica em $XDG_RUNTIME_DIR/sway-ipc.$UID.*.sock
    local uid_jett
    uid_jett=$(id -u "$USUARIO_JETT" 2>/dev/null || echo "1000")
    local xdg_runtime="/run/user/${uid_jett}"
    local sway_socket=""

    # Procura o socket do Sway
    sway_socket=$(ls "${xdg_runtime}/sway-ipc."*.sock 2>/dev/null | head -1 || echo "")

    if [[ -n "$sway_socket" ]]; then
        # Executa o browser dentro do Sway via swaymsg
        # SWAYSOCK precisa apontar para o socket correto
        log_info "Socket Sway encontrado: ${sway_socket}"
        su -l "$USUARIO_JETT" -c \
            "SWAYSOCK='${sway_socket}' \
             XDG_RUNTIME_DIR='${xdg_runtime}' \
             swaymsg exec '${cmd}'" \
            >> "$LOG_ARQUIVO" 2>&1 \
            || log_aviso "swaymsg exec falhou — tentando iniciar diretamente."

        log_ok "${nome} iniciado via swaymsg."
    else
        # Fallback: inicia o processo diretamente como o usuário jett
        # Ocorre quando o Sway não está acessível (ex: teste fora do Sway)
        log_aviso "Socket Sway não encontrado. Iniciando ${nome} diretamente."
        su -l "$USUARIO_JETT" -c \
            "XDG_RUNTIME_DIR='${xdg_runtime}' \
             WAYLAND_DISPLAY='wayland-1' \
             nohup ${cmd} >/dev/null 2>&1 &" \
            >> "$LOG_ARQUIVO" 2>&1 \
            || log_aviso "Falha ao iniciar ${nome} diretamente. Verifique o log."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PROCESSAMENTO DE ARGUMENTOS
# ─────────────────────────────────────────────────────────────────────────────

NAVEGADOR_NOVO=""

processar_argumentos() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --navegador)
                shift
                NAVEGADOR_NOVO="$1"
                ;;
            --help|-h)
                echo "Uso: sudo jett-switch.sh --navegador NOME"
                echo ""
                echo "Navegadores válidos: brave | edge | thorium | opera-gx | firefox"
                exit 0
                ;;
            *)
                log_erro "Argumento desconhecido: '$1'. Use --help."
                ;;
        esac
        shift
    done

    if [[ -z "$NAVEGADOR_NOVO" ]]; then
        log_erro "Argumento --navegador é obrigatório. Use --help."
    fi

    # Valida o nome do navegador
    if [[ -z "${NAV_BINARIO[$NAVEGADOR_NOVO]+x}" ]]; then
        log_erro "Navegador inválido: '${NAVEGADOR_NOVO}'. Use: brave | edge | thorium | opera-gx | firefox"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PONTO DE ENTRADA PRINCIPAL
# ─────────────────────────────────────────────────────────────────────────────

main() {
    processar_argumentos "$@"
    inicializar_log

    local nav_novo="$NAVEGADOR_NOVO"
    local nav_atual
    nav_atual="$(ler_navegador_atual)"
    local nome_novo="${NAV_NOME_DISPLAY[$nav_novo]}"

    log_info "Troca solicitada: '${nav_atual:-desconhecido}' → '${nav_novo}'"

    # Verifica se o navegador alvo está instalado
    if ! command -v "${NAV_BINARIO[$nav_novo]}" &>/dev/null; then
        log_erro "${nome_novo} não está instalado (${NAV_BINARIO[$nav_novo]} não encontrado no PATH)."
    fi

    # Se já é o navegador ativo, não faz nada
    if [[ "$nav_novo" == "$nav_atual" ]]; then
        log_info "Navegador '${nav_novo}' já está ativo. Nenhuma troca necessária."
        exit 0
    fi

    # Encerra o navegador atual
    if [[ -n "$nav_atual" && -n "${NAV_BINARIO[$nav_atual]+x}" ]]; then
        encerrar_navegador "$nav_atual"
    else
        # Encerra qualquer navegador conhecido em execução
        log_info "Navegador atual desconhecido — encerrando todos os navegadores conhecidos..."
        for id_nav in brave edge thorium opera-gx firefox; do
            if pgrep -f "${NAV_BINARIO[$id_nav]}" &>/dev/null 2>&1; then
                encerrar_navegador "$id_nav"
            fi
        done
    fi

    # Aguarda um instante para liberar recursos gráficos (display, DRM)
    sleep 0.3

    # Atualiza a configuração central
    atualizar_conf "$nav_novo"

    # Inicia o novo navegador na sessão Sway
    iniciar_navegador_sway "$nav_novo"

    log_ok "Troca concluída: ${nome_novo} está iniciando."
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Troca concluída: ${nav_novo}" >> "$LOG_ARQUIVO"
}

main "$@"
