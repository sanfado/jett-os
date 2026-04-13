#!/usr/bin/env bash
# =============================================================================
# jett-nav-toggle.sh — Alterna a barra de navegação do Jett OS
# =============================================================================
# Uso:
#   jett-nav-toggle           (chamado pelo atalho --release Super_L do Sway)
#
# Comportamento:
#   1. Se /tmp/.jett-super-used existir: outro atalho Super+<tecla> foi usado
#      → remove o arquivo de flag e sai sem abrir a barra (previne disparo duplo)
#   2. Se a janela "Jett OS — Nav" já estiver aberta no Sway:
#      → fecha a janela via swaymsg
#   3. Caso contrário:
#      → abre a barra em http://127.0.0.1:1312/nav usando o navegador disponível
#
# Ao abrir:
#   - O Sway posiciona a janela via for_window [title="^Jett OS — Nav"] e
#     concede foco imediato (@focus no config/sway/config).
#   - O nav.html foca automaticamente o campo de endereço via JS no load,
#     permitindo que o usuário comece a digitar imediatamente.
#
# Ao fechar (usuário pressiona Enter ou Escape na barra):
#   - O nav.html chama window.close() → Sway fecha a janela.
#   - O foco retorna ao navegador principal automaticamente pelo Sway.
#
# Controles de aba e navegação:
#   - São executados via POST /api/nav/* → jett-bridge → xdotool
#   - xdotool envia atalhos de teclado diretamente à janela do navegador kiosk
#   - Requer 'xdotool' instalado (adicionado pelo 03-install-packages.sh)
#
# A janela é posicionada pelo Sway via a regra for_window definida no config:
#   for_window [title="^Jett OS — Nav"] { floating enable; resize set 100ppt 56; move position 0 0; focus }
#
# Instalação:
#   sudo cp launcher/scripts/jett-nav-toggle.sh /usr/local/bin/jett-nav-toggle
#   sudo chmod +x /usr/local/bin/jett-nav-toggle
# =============================================================================

set -euo pipefail

FLAG_SUPER="/tmp/.jett-super-used"
URL_NAV="http://127.0.0.1:1312/nav"

# ─────────────────────────────────────────────────────────────────────────────
# Verifica se o Super foi usado como modificador de outro atalho.
# Nesse caso, o Super release não deve abrir a barra.
# ─────────────────────────────────────────────────────────────────────────────
if [[ -f "$FLAG_SUPER" ]]; then
    rm -f "$FLAG_SUPER"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Verifica se a janela de navegação já está aberta inspecionando a árvore Sway
# ─────────────────────────────────────────────────────────────────────────────
janela_aberta() {
    swaymsg -t get_tree 2>/dev/null | grep -q '"Jett OS — Nav"'
}

# ─────────────────────────────────────────────────────────────────────────────
# Abre a barra de navegação no navegador disponível.
#
# Modo --app= (Chromium): abre sem barra de endereços nem abas.
#   O título da janela vem de <title>Jett OS — Nav</title>, permitindo
#   que o Sway identifique e aplique as regras for_window.
#
# Firefox: usa --new-instance --new-window (não suporta --app).
#   O título exibirá "Jett OS — Nav — Mozilla Firefox", que o regex
#   "^Jett OS — Nav" no Sway cobre corretamente.
# ─────────────────────────────────────────────────────────────────────────────
abrir_nav() {
    local candidatos=(
        "brave-browser --new-window --app=${URL_NAV} --no-first-run"
        "microsoft-edge-stable --new-window --app=${URL_NAV} --no-first-run"
        "thorium-browser --new-window --app=${URL_NAV} --no-first-run"
        "opera --new-window ${URL_NAV}"
        "firefox --new-instance --new-window ${URL_NAV}"
    )
    for cmd_str in "${candidatos[@]}"; do
        local bin
        bin=$(echo "$cmd_str" | awk '{print $1}')
        if command -v "$bin" &>/dev/null; then
            # shellcheck disable=SC2086
            $cmd_str &
            disown
            return 0
        fi
    done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Toggle principal
# ─────────────────────────────────────────────────────────────────────────────
if janela_aberta; then
    # Fecha: swaymsg envia kill para a janela identificada pelo título.
    # O foco retorna automaticamente ao navegador kiosk.
    swaymsg '[title="^Jett OS — Nav"] kill'
else
    # Abre: o nav.html foca o campo de endereço via JS no load.
    abrir_nav || true
fi
