#!/usr/bin/env bash
# =============================================================================
# jett-firstboot.sh — Gerencia o primeiro boot do Jett OS
# =============================================================================
# Uso:
#   jett-firstboot          (chamado no exec do Sway)
#
# Comportamento:
#   1. Aguarda o jett-ui-server estar disponível em 127.0.0.1:1312
#   2. Se /etc/jett-os/firstboot.done existir: inicia diretamente o kiosk
#   3. Caso contrário: abre o wizard em http://127.0.0.1:1312/wizard,
#      aguarda firstboot.done ser criado (via POST /api/wizard/complete),
#      então inicia o kiosk com o navegador escolhido
#
# Arquivo de conclusão aceito em dois locais:
#   /etc/jett-os/firstboot.done          (criado via sudo por bridge)
#   ~/.config/jett-os/firstboot.done     (fallback, gravável sem sudo)
#
# Log:
#   /tmp/jett-firstboot.log
#
# Instalação:
#   sudo cp launcher/scripts/jett-firstboot.sh /usr/local/bin/jett-firstboot
#   sudo chmod +x /usr/local/bin/jett-firstboot
# =============================================================================

set -euo pipefail

FIRSTBOOT_DONE_SYSTEM="/etc/jett-os/firstboot.done"
FIRSTBOOT_DONE_USER="${HOME}/.config/jett-os/firstboot.done"
URL_WIZARD="http://127.0.0.1:1312/wizard"
JETT_UI_SERVER_URL="http://127.0.0.1:1312/api/status"

log() { printf '[%s] jett-firstboot: %s\n' "$(date '+%H:%M:%S')" "$*" >> /tmp/jett-firstboot.log 2>&1; }

# ─────────────────────────────────────────────────────────────────────────────
# Aguarda o jett-ui-server responder (até 10 s)
# ─────────────────────────────────────────────────────────────────────────────
aguardar_servidor() {
    log "Aguardando jett-ui-server em 127.0.0.1:1312..."
    for i in $(seq 1 20); do
        if curl -sf "$JETT_UI_SERVER_URL" >/dev/null 2>&1; then
            log "jett-ui-server pronto."
            return 0
        fi
        sleep 0.5
    done
    log "AVISO: jett-ui-server não respondeu em 10 s — continuando assim mesmo."
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Verifica se o firstboot já foi concluído
# ─────────────────────────────────────────────────────────────────────────────
firstboot_concluido() {
    [[ -f "$FIRSTBOOT_DONE_SYSTEM" ]] || [[ -f "$FIRSTBOOT_DONE_USER" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Inicia o wizard em background; retorna o PID do processo do browser
# ─────────────────────────────────────────────────────────────────────────────
abrir_wizard() {
    local candidatos=(
        brave-browser
        microsoft-edge-stable
        thorium-browser
        chromium
        opera
        firefox
    )
    for bin in "${candidatos[@]}"; do
        if command -v "$bin" &>/dev/null; then
            log "Abrindo wizard com $bin"
            if [[ "$bin" == "firefox" ]]; then
                "$bin" --new-instance --new-window "$URL_WIZARD" &
            else
                "$bin" "--app=${URL_WIZARD}" --no-first-run &
            fi
            echo $!
            return 0
        fi
    done
    log "ERRO: nenhum navegador encontrado para abrir o wizard"
    echo ""
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Inicia o navegador kiosk configurado (nunca retorna em condições normais)
# ─────────────────────────────────────────────────────────────────────────────
iniciar_kiosk() {
    log "Iniciando kiosk..."

    # Carrega configuração do navegador
    local nav_cmd=""
    if [[ -f /etc/jett-os/navegador.conf ]]; then
        # shellcheck disable=SC1091
        source /etc/jett-os/navegador.conf 2>/dev/null || true
        nav_cmd="${JETT_NAVEGADOR_CMD:-}"
    fi

    if [[ -n "$nav_cmd" ]]; then
        log "Usando nav configurado: ${nav_cmd%% *}"
        exec bash -c "$nav_cmd"
    fi

    # Fallback: primeiro candidato disponível em modo kiosk
    local candidatos_kiosk=(
        "brave-browser --kiosk"
        "microsoft-edge-stable --kiosk --no-first-run"
        "thorium-browser --kiosk"
        "opera --kiosk"
        "chromium --kiosk"
        "firefox --kiosk"
    )
    for cmd_kiosk in "${candidatos_kiosk[@]}"; do
        local bin="${cmd_kiosk%% *}"
        if command -v "$bin" &>/dev/null; then
            log "Fallback: usando $bin --kiosk"
            exec $cmd_kiosk
        fi
    done

    log "ERRO FATAL: nenhum navegador encontrado para o kiosk"
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    log "Iniciando..."
    aguardar_servidor

    if firstboot_concluido; then
        log "Firstboot já concluído — boot direto no kiosk."
        iniciar_kiosk
    fi

    log "Primeiro boot — abrindo wizard."
    local wizard_pid
    wizard_pid=$(abrir_wizard) || {
        log "Falha ao abrir wizard — criando firstboot.done e iniciando kiosk."
        mkdir -p "$(dirname "$FIRSTBOOT_DONE_USER")"
        date > "$FIRSTBOOT_DONE_USER"
        iniciar_kiosk
    }

    if [[ -z "$wizard_pid" ]]; then
        log "Nenhum browser disponível — criando firstboot.done e iniciando kiosk."
        mkdir -p "$(dirname "$FIRSTBOOT_DONE_USER")"
        date > "$FIRSTBOOT_DONE_USER"
        iniciar_kiosk
    fi

    # Aguarda o wizard concluir (bridge POST /api/wizard/complete cria firstboot.done)
    log "Wizard aberto (PID ${wizard_pid}). Aguardando conclusão..."
    while ! firstboot_concluido; do
        sleep 1
        # Se o wizard foi fechado sem concluir, cria done como failsafe
        if ! kill -0 "$wizard_pid" 2>/dev/null; then
            log "Wizard fechou sem completar — criando firstboot.done por segurança."
            mkdir -p "$(dirname "$FIRSTBOOT_DONE_USER")"
            date > "$FIRSTBOOT_DONE_USER"
            break
        fi
    done

    log "Wizard concluído — iniciando kiosk."
    iniciar_kiosk
}

main "$@"
