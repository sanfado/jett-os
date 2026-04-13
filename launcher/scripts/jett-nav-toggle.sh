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
# A janela é posicionada pelo Sway via a regra for_window definida no config:
#   for_window [title="^Jett OS — Nav"] { ... }
#
# Instalação:
#   sudo cp launcher/jett-nav-toggle.sh /usr/local/bin/jett-nav-toggle
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
# Verifica se a janela já está aberta inspecionando a árvore do Sway
# ─────────────────────────────────────────────────────────────────────────────
janela_aberta() {
    swaymsg -t get_tree 2>/dev/null | grep -q '"Jett OS — Nav"'
}

# ─────────────────────────────────────────────────────────────────────────────
# Abre a barra de navegação no navegador disponível.
# Usa --app= para abrir sem barra de endereços nem abas (janela limpa).
# ─────────────────────────────────────────────────────────────────────────────
abrir_nav() {
    local candidatos=(
        "firefox --new-instance --new-window ${URL_NAV}"
        "brave-browser --new-window --app=${URL_NAV} --no-first-run"
        "microsoft-edge-stable --new-window --app=${URL_NAV} --no-first-run"
        "thorium-browser --new-window --app=${URL_NAV} --no-first-run"
        "opera --new-window ${URL_NAV}"
    )
    for cmd_str in "${candidatos[@]}"; do
        # Extrai o nome do binário (primeiro token)
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
    swaymsg '[title="^Jett OS — Nav"] kill'
else
    abrir_nav || true
fi
