#!/usr/bin/env bash
# =============================================================================
# jett-menu-toggle.sh — Alterna o menu de sistema do Jett OS
# =============================================================================
# Uso:
#   jett-menu-toggle           (chamado pelo atalho Super+X do Sway)
#
# Comportamento:
#   1. Marca /tmp/.jett-super-used para que o jett-nav-toggle não abra a barra
#      ao soltar o Super (que dispara --release Super_L)
#   2. Se a janela "Jett OS — Menu" já estiver aberta no Sway: fecha
#   3. Caso contrário: abre o menu em http://127.0.0.1:1312/menu
#
# A janela é posicionada pelo Sway via:
#   for_window [title="^Jett OS — Menu"] { floating enable; resize set 380 480; move position center; }
#
# Instalação:
#   sudo cp launcher/jett-menu-toggle.sh /usr/local/bin/jett-menu-toggle
#   sudo chmod +x /usr/local/bin/jett-menu-toggle
# =============================================================================

set -euo pipefail

FLAG_SUPER="/tmp/.jett-super-used"
URL_MENU="http://127.0.0.1:1312/menu"

# Sinaliza ao jett-nav-toggle que o Super foi usado como modificador
touch "$FLAG_SUPER"

# ─────────────────────────────────────────────────────────────────────────────
# Verifica se a janela do menu já está aberta
# ─────────────────────────────────────────────────────────────────────────────
janela_aberta() {
    swaymsg -t get_tree 2>/dev/null | grep -q '"Jett OS — Menu"'
}

# ─────────────────────────────────────────────────────────────────────────────
# Abre o menu no navegador disponível (sem barra de endereços)
# ─────────────────────────────────────────────────────────────────────────────
abrir_menu() {
    local candidatos=(
        "firefox --new-instance --new-window ${URL_MENU}"
        "brave-browser --new-window --app=${URL_MENU} --no-first-run"
        "microsoft-edge-stable --new-window --app=${URL_MENU} --no-first-run"
        "thorium-browser --new-window --app=${URL_MENU} --no-first-run"
        "opera --new-window ${URL_MENU}"
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
# Toggle
# ─────────────────────────────────────────────────────────────────────────────
if janela_aberta; then
    swaymsg '[title="^Jett OS — Menu"] kill'
else
    abrir_menu || true
fi
