#!/usr/bin/env bash
# =============================================================================
# jett-updater.sh — Daemon de atualizações do Jett OS
# =============================================================================
# Uso:
#   jett-updater           (iniciado pelo systemd como jett-updater.service)
#
# Comportamento:
#   - Aguarda 30s na inicialização para deixar o sistema estabilizar
#   - Loop infinito com intervalo de 6h (21600s)
#   - Verifica atualizações de pacotes Debian via apt list --upgradable
#   - Verifica nova versão do Jett OS via GitHub API (releases/latest)
#   - Escreve resultado em /tmp/jett-updates-available.json (atômico)
#   - Notifica o jett-ui-server via POST /api/updates/notify quando há updates
#
# Formato do JSON gerado:
#   {
#     "debian": <número de pacotes atualizáveis>,
#     "jett_os": <true|false>,
#     "jett_versao_atual": "v0.3.0-alpha",
#     "jett_versao_nova": "v0.4.0-alpha",
#     "timestamp": <unix timestamp>
#   }
#
# Instalação:
#   sudo cp launcher/scripts/jett-updater.sh /usr/local/bin/jett-updater
#   sudo chmod +x /usr/local/bin/jett-updater
#   systemctl --user enable --now jett-updater.service
# =============================================================================

set -euo pipefail

readonly JSON_FILE="/tmp/jett-updates-available.json"
readonly JSON_TMP="/tmp/.jett-updates-available.json.tmp"
readonly LOG_FILE="/tmp/jett-updater.log"
readonly CONF_VERSAO="/etc/jett-os/versao.conf"
readonly URL_SERVER="http://127.0.0.1:1312"
readonly GITHUB_API="https://api.github.com/repos/sanfado/jett-os/releases/latest"
readonly INTERVALO=21600   # 6 horas em segundos
readonly DELAY_INICIAL=30  # Aguarda antes da primeira verificação

# ─────────────────────────────────────────────────────────────────────────────
# Utilitários de log
# ─────────────────────────────────────────────────────────────────────────────
log() {
    local nivel="$1"
    shift
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$nivel" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

log_info()  { log "INFO"  "$@"; }
log_ok()    { log "OK"    "$@"; }
log_aviso() { log "AVISO" "$@"; }
log_erro()  { log "ERRO"  "$@"; }

# ─────────────────────────────────────────────────────────────────────────────
# Verificação de pacotes Debian
# ─────────────────────────────────────────────────────────────────────────────
verificar_debian() {
    local contagem=0

    # Atualiza o cache do apt silenciosamente (pode falhar sem internet)
    apt-get update -qq 2>/dev/null || {
        log_aviso "apt-get update falhou — usando cache existente."
    }

    # Conta pacotes atualizáveis (exclui a linha de cabeçalho "Listing...")
    contagem=$(apt list --upgradable 2>/dev/null \
        | grep -vc '^Listing\.\.\.' || true)

    echo "${contagem:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Verificação de versão do Jett OS
# ─────────────────────────────────────────────────────────────────────────────
verificar_jett_os() {
    local versao_atual versao_nova nova_disponivel

    # Lê a versão instalada
    if [[ -f "$CONF_VERSAO" ]]; then
        # shellcheck disable=SC1090
        versao_atual=$(grep -E '^JETT_VERSAO=' "$CONF_VERSAO" \
            | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs || true)
    fi
    versao_atual="${versao_atual:-desconhecida}"

    # Consulta a API do GitHub
    versao_nova=$(curl -fsSL --max-time 10 \
        -H "User-Agent: jett-updater/1.0" \
        -H "Accept: application/vnd.github+json" \
        "$GITHUB_API" 2>/dev/null \
        | grep -o '"tag_name":"[^"]*"' \
        | cut -d'"' -f4 || true)
    versao_nova="${versao_nova:-}"

    # Determina se há atualização disponível
    if [[ -n "$versao_nova" && "$versao_nova" != "$versao_atual" ]]; then
        nova_disponivel="true"
    else
        nova_disponivel="false"
    fi

    printf '%s %s %s' "$nova_disponivel" "$versao_atual" "${versao_nova:-$versao_atual}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Escreve o JSON de status (atômico: grava no tmp e move)
# ─────────────────────────────────────────────────────────────────────────────
escrever_json() {
    local pacotes_debian="$1"
    local jett_nova="$2"
    local versao_atual="$3"
    local versao_nova="$4"
    local ts
    ts=$(date '+%s')

    cat > "$JSON_TMP" << EOF
{
  "debian": ${pacotes_debian},
  "jett_os": ${jett_nova},
  "jett_versao_atual": "${versao_atual}",
  "jett_versao_nova": "${versao_nova}",
  "timestamp": ${ts}
}
EOF
    mv -f "$JSON_TMP" "$JSON_FILE"
    log_ok "JSON escrito: debian=${pacotes_debian}, jett_os=${jett_nova}, versao_nova=${versao_nova}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Notifica o jett-ui-server quando há atualizações
# ─────────────────────────────────────────────────────────────────────────────
notificar_server() {
    curl -fsSL --max-time 5 \
        -X POST \
        -H "Content-Type: application/json" \
        -d @"$JSON_FILE" \
        "${URL_SERVER}/api/updates/notify" \
        > /dev/null 2>&1 || {
        log_aviso "Notificação ao server falhou (server pode estar offline)."
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Ciclo principal de verificação
# ─────────────────────────────────────────────────────────────────────────────
verificar_atualizacoes() {
    log_info "Iniciando verificação de atualizações..."

    # Verifica pacotes Debian
    local pacotes_debian
    pacotes_debian=$(verificar_debian)
    log_info "Pacotes Debian atualizáveis: ${pacotes_debian}"

    # Verifica versão Jett OS
    local resultado jett_nova versao_atual versao_nova
    resultado=$(verificar_jett_os)
    jett_nova=$(echo "$resultado" | awk '{print $1}')
    versao_atual=$(echo "$resultado" | awk '{print $2}')
    versao_nova=$(echo "$resultado" | awk '{print $3}')
    log_info "Jett OS: atual=${versao_atual}, nova=${versao_nova}, update=${jett_nova}"

    # Escreve o JSON
    escrever_json "$pacotes_debian" "$jett_nova" "$versao_atual" "$versao_nova"

    # Notifica o server se há alguma atualização disponível
    if [[ "$pacotes_debian" -gt 0 ]] || [[ "$jett_nova" == "true" ]]; then
        notificar_server
        log_info "Server notificado."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
main() {
    log_info "jett-updater iniciado (PID $$)."
    log_info "Aguardando ${DELAY_INICIAL}s para sistema estabilizar..."
    sleep "$DELAY_INICIAL"

    while true; do
        verificar_atualizacoes || log_erro "verificar_atualizacoes falhou (continuando)."
        log_info "Próxima verificação em ${INTERVALO}s."
        sleep "$INTERVALO"
    done
}

main "$@"
