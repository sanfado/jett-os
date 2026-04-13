#!/usr/bin/env bash
# =============================================================================
# jett-files-toggle.sh — Alterna o gerenciador de arquivos do Jett OS
# =============================================================================
# Uso:
#   jett-files-toggle           (chamado pelo atalho Super+F do Sway)
#
# Comportamento:
#   1. Marca /tmp/.jett-super-used para que o jett-nav-toggle não abra a barra
#      ao soltar o Super (que dispara --release Super_L)
#   2. Se a janela "Jett OS — Arquivos" já estiver aberta no Sway: fecha
#   3. Caso contrário: abre o gerenciador em http://127.0.0.1:1312/files
#
# A janela é posicionada pelo Sway via:
#   for_window [title="^Jett OS — Arquivos"] { floating enable; resize set 900 580; move position center; }
#
# Instalação:
#   sudo cp launcher/scripts/jett-files-toggle.sh /usr/local/bin/jett-files-toggle
#   sudo chmod +x /usr/local/bin/jett-files-toggle
# =============================================================================

set -euo pipefail

FLAG_SUPER="/tmp/.jett-super-used"
URL_FILES="http://127.0.0.1:1312/files"

# Sinaliza ao jett-nav-toggle que o Super foi usado como modificador
touch "$FLAG_SUPER"

# ─────────────────────────────────────────────────────────────────────────────
# Verifica se a janela do gerenciador já está aberta
# ─────────────────────────────────────────────────────────────────────────────
janela_aberta() {
    swaymsg -t get_tree 2>/dev/null | grep -q '"Jett OS — Arquivos"'
}

# ─────────────────────────────────────────────────────────────────────────────
# Abre o gerenciador no navegador disponível (sem barra de endereços)
# ─────────────────────────────────────────────────────────────────────────────
abrir_files() {
    local candidatos=(
        "brave-browser --new-window --app=${URL_FILES} --no-first-run"
        "microsoft-edge-stable --new-window --app=${URL_FILES} --no-first-run"
        "thorium-browser --new-window --app=${URL_FILES} --no-first-run"
        "opera --new-window ${URL_FILES}"
        "firefox --new-instance --new-window ${URL_FILES}"
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
    swaymsg '[title="^Jett OS — Arquivos"] kill'
else
    abrir_files || true
fi
