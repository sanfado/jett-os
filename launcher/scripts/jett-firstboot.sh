#!/usr/bin/env bash
# =============================================================================
# jett-firstboot.sh — Wizard de primeiro boot do Jett OS
# =============================================================================
# Uso:
#   Chamado pelo jett-firstboot.service (Before=sway-kiosk.service).
#   Não deve ser invocado diretamente durante uma sessão Sway ativa.
#
# Fluxo:
#   1. Se firstboot.done existir: sai imediatamente (código 0).
#      O systemd então inicia o sway-kiosk.service normalmente.
#
#   2. Se firstboot.done não existir:
#      a. Aguarda o jett-ui-server estar pronto (127.0.0.1:1312)
#      b. Inicia o Cage com o wizard em tela cheia:
#            cage -- [browser] --kiosk http://127.0.0.1:1312/wizard
#      c. Monitora firstboot.done; quando criado (via POST /api/wizard/complete),
#         encerra o Cage e sai (código 0).
#      d. Failsafe: se o Cage encerrar sem criar firstboot.done, cria-o mesmo assim.
#
#   Após o script sair, o systemd inicia automaticamente o sway-kiosk.service
#   (ordenado por After=jett-firstboot.service no sway-kiosk.service).
#
# Arquivo de conclusão aceito em:
#   /etc/jett-os/firstboot.done          (criado via sudo pelo jett-bridge)
#   ~/.config/jett-os/firstboot.done     (fallback, gravável sem root)
#
# Log: /tmp/jett-firstboot.log
#
# Instalação:
#   sudo cp launcher/scripts/jett-firstboot.sh /usr/local/bin/jett-firstboot
#   sudo chmod +x /usr/local/bin/jett-firstboot
# =============================================================================

set -uo pipefail

FIRSTBOOT_DONE_SYSTEM="/etc/jett-os/firstboot.done"
FIRSTBOOT_DONE_USER="${HOME}/.config/jett-os/firstboot.done"
URL_WIZARD="http://127.0.0.1:1312/wizard"
JETT_UI_SERVER_URL="http://127.0.0.1:1312/api/status"

log() { printf '[%s] jett-firstboot: %s\n' "$(date '+%H:%M:%S')" "$*" >> /tmp/jett-firstboot.log 2>&1; }

# ─────────────────────────────────────────────────────────────────────────────
# Verifica se o firstboot já foi concluído (em qualquer dos dois locais)
# ─────────────────────────────────────────────────────────────────────────────
firstboot_concluido() {
    [[ -f "$FIRSTBOOT_DONE_SYSTEM" ]] || [[ -f "$FIRSTBOOT_DONE_USER" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Aguarda o jett-ui-server responder (até 10 s, intervalo de 0.5 s)
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
    log "AVISO: jett-ui-server não respondeu em 10 s — continuando mesmo assim."
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Retorna o primeiro navegador disponível no sistema
# ─────────────────────────────────────────────────────────────────────────────
encontrar_browser() {
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
            echo "$bin"
            return 0
        fi
    done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Cria firstboot.done no local de fallback (sem root)
# ─────────────────────────────────────────────────────────────────────────────
criar_firstboot_done() {
    mkdir -p "$(dirname "$FIRSTBOOT_DONE_USER")"
    date > "$FIRSTBOOT_DONE_USER"
    log "firstboot.done criado em ${FIRSTBOOT_DONE_USER}."
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    log "Iniciando (PID $$)..."

    # Caminho rápido: firstboot já concluído em boot anterior
    if firstboot_concluido; then
        log "Firstboot já concluído — saindo para iniciar o Sway."
        exit 0
    fi

    log "Primeiro boot detectado — iniciando fluxo do wizard."
    aguardar_servidor

    # Determina o browser disponível
    local browser
    if ! browser=$(encontrar_browser); then
        log "ERRO FATAL: nenhum navegador encontrado — criando firstboot.done e passando para o Sway."
        criar_firstboot_done
        exit 0
    fi
    log "Browser selecionado para o wizard: ${browser}"

    # Constrói o comando Cage segundo o browser:
    #   Chromium-based: --app=URL --kiosk  (remove tabs, barra, abas; tela cheia)
    #   Firefox:        --kiosk URL         (modo kiosk nativo; tela cheia)
    local -a cmd_cage
    if [[ "$browser" == "firefox" ]]; then
        cmd_cage=(cage -- "$browser" --kiosk "$URL_WIZARD")
    else
        cmd_cage=(cage -- "$browser" --kiosk --no-first-run "--app=${URL_WIZARD}")
    fi

    log "Iniciando Cage: ${cmd_cage[*]}"
    "${cmd_cage[@]}" &
    local cage_pid=$!
    log "Cage iniciado (PID ${cage_pid}). Monitorando firstboot.done..."

    # Loop de monitoramento: aguarda firstboot.done OU o Cage encerrar
    while kill -0 "$cage_pid" 2>/dev/null; do
        sleep 1
        if firstboot_concluido; then
            log "Wizard concluído (firstboot.done detectado). Encerrando Cage..."
            kill "$cage_pid" 2>/dev/null || true
            sleep 0.5
            kill -9 "$cage_pid" 2>/dev/null || true
            break
        fi
    done

    # Aguarda o processo Cage encerrar de fato antes de prosseguir
    wait "$cage_pid" 2>/dev/null || true

    # Failsafe: Cage encerrou sem o wizard criar firstboot.done
    if ! firstboot_concluido; then
        log "Cage encerrou sem wizard completar — criando firstboot.done por segurança."
        criar_firstboot_done
    fi

    log "Wizard finalizado. Sway será iniciado pelo systemd (sway-kiosk.service)."
    exit 0
}

main "$@"
