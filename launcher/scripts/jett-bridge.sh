#!/usr/bin/env bash
# =============================================================================
# jett-bridge.sh — Ponte entre a interface HTML e o sistema operacional
# =============================================================================
# Uso:
#   jett-bridge.sh <comando> [subcomando] [argumento]
#
# Comandos disponíveis:
#   volume get                 — retorna nível e estado mudo (JSON)
#   volume up                  — aumenta 5%
#   volume down                — diminui 5%
#   volume mute                — alterna mudo
#   volume set <0-100>         — define nível exato
#
#   network info               — informações da conexão ativa (JSON)
#
#   power shutdown             — desliga o sistema
#   power reboot               — reinicia o sistema
#   power suspend              — suspende o sistema
#
#   browser list               — lista navegadores instalados (JSON)
#   browser switch <id>        — troca o navegador ativo
#
#   usb list                   — lista dispositivos USB montáveis (JSON)
#   usb mount <dispositivo>    — monta dispositivo (ex: /dev/sdb1)
#   usb unmount <ponto>        — desmonta pelo ponto de montagem
#
#   system info                — informações gerais do sistema (JSON)
#
# Saída: JSON em stdout. Erros em stderr.
# Código de retorno: 0 = sucesso, 1 = erro.
#
# Instalação:
#   sudo cp launcher/jett-bridge.sh /usr/local/bin/jett-bridge
#   sudo chmod +x /usr/local/bin/jett-bridge
# =============================================================================

set -euo pipefail

CONF_JETT="/etc/jett-os"

# ─────────────────────────────────────────────────────────────────────────────
# UTILITÁRIOS
# ─────────────────────────────────────────────────────────────────────────────

# Emite JSON de erro padronizado
erro_json() {
    printf '{"erro":"%s"}\n' "$1"
    exit 1
}

# Verifica se um comando está disponível
cmd_disponivel() {
    command -v "$1" &>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# VOLUME
# ─────────────────────────────────────────────────────────────────────────────

volume_get() {
    cmd_disponivel pactl || erro_json "pactl nao encontrado"

    local nivel mudo
    nivel=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null \
        | grep -oP '\d+%' | head -1 | tr -d '%')
    mudo=$(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null \
        | grep -oP 'yes|no' | head -1)

    printf '{"volume":%s,"mudo":%s}\n' \
        "${nivel:-0}" \
        "$([ "${mudo:-no}" = "yes" ] && echo true || echo false)"
}

volume_up() {
    pactl set-sink-volume @DEFAULT_SINK@ +5%
    volume_get
}

volume_down() {
    pactl set-sink-volume @DEFAULT_SINK@ -5%
    volume_get
}

volume_mute() {
    pactl set-sink-mute @DEFAULT_SINK@ toggle
    volume_get
}

volume_set() {
    local nivel="${1:-50}"
    # Clamp: 0-100
    nivel=$(( nivel < 0 ? 0 : nivel > 100 ? 100 : nivel ))
    pactl set-sink-volume @DEFAULT_SINK@ "${nivel}%"
    volume_get
}

# ─────────────────────────────────────────────────────────────────────────────
# REDE
# ─────────────────────────────────────────────────────────────────────────────

network_info() {
    local iface ip gateway status

    # Interface ativa com rota padrão
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')

    if [[ -z "$iface" ]]; then
        printf '{"conectado":false,"interface":"","ip":"","gateway":""}\n'
        return
    fi

    ip=$(ip addr show "$iface" 2>/dev/null \
        | awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')
    gateway=$(ip route show default dev "$iface" 2>/dev/null \
        | awk '/via/ {print $3; exit}')

    # Testa conectividade com um ping rápido
    if ping -c1 -W1 -q 8.8.8.8 &>/dev/null 2>&1; then
        status="online"
    else
        status="sem_internet"
    fi

    printf '{"conectado":true,"interface":"%s","ip":"%s","gateway":"%s","status":"%s"}\n' \
        "${iface}" "${ip:-}" "${gateway:-}" "${status}"
}

# ─────────────────────────────────────────────────────────────────────────────
# ENERGIA
# ─────────────────────────────────────────────────────────────────────────────

power_cmd() {
    local subcmd="${1:-}"
    case "$subcmd" in
        shutdown)  systemctl poweroff ;;
        reboot)    systemctl reboot ;;
        suspend)   systemctl suspend ;;
        *)         erro_json "subcomando de power invalido: ${subcmd}" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# NAVEGADORES
# ─────────────────────────────────────────────────────────────────────────────

browser_list() {
    local conf_instalados="${CONF_JETT}/navegadores-instalados.conf"
    local conf_ativo="${CONF_JETT}/navegador.conf"

    # Lê o navegador ativo
    local nav_ativo=""
    if [[ -f "$conf_ativo" ]]; then
        nav_ativo=$(bash -c "source '${conf_ativo}' 2>/dev/null; echo \"\${JETT_NAVEGADOR:-}\"" 2>/dev/null || true)
    fi

    # Mapeia IDs de variável para IDs de navegador
    declare -A id_map=( [BRAVE]="brave" [EDGE]="edge" [THORIUM]="thorium" [OPERA]="opera-gx" [FIREFOX]="firefox" )
    declare -A nome_map=( [BRAVE]="Brave" [EDGE]="Microsoft Edge" [THORIUM]="Thorium" [OPERA]="Opera GX" [FIREFOX]="Firefox" )

    local primeira=true
    printf '['
    for chave_var in BRAVE EDGE THORIUM OPERA FIREFOX; do
        local instalado_var="JETT_${chave_var}_INSTALADO"
        local versao_var="JETT_${chave_var}_VERSAO"
        local binario_var="JETT_${chave_var}_BINARIO"

        local instalado="" versao="" binario=""
        if [[ -f "$conf_instalados" ]]; then
            instalado=$(bash -c "source '${conf_instalados}' 2>/dev/null; echo \"\${${instalado_var}:-false}\"" 2>/dev/null || true)
            versao=$(bash -c "source '${conf_instalados}' 2>/dev/null; echo \"\${${versao_var}:-}\"" 2>/dev/null || true)
            binario=$(bash -c "source '${conf_instalados}' 2>/dev/null; echo \"\${${binario_var}:-}\"" 2>/dev/null || true)
        fi

        [[ "$instalado" != "true" ]] && continue

        local nav_id="${id_map[$chave_var]}"
        local ativo="false"
        [[ "$nav_ativo" == "$nav_id" ]] && ativo="true"

        "$primeira" || printf ','
        printf '{"id":"%s","nome":"%s","versao":"%s","binario":"%s","ativo":%s}' \
            "$nav_id" "${nome_map[$chave_var]}" "${versao//\"/\\\"}" \
            "${binario//\"/\\\"}" "$ativo"
        primeira=false
    done
    printf ']\n'
}

browser_switch() {
    local nav="${1:-}"
    [[ -z "$nav" ]] && erro_json "navegador nao especificado"
    cmd_disponivel jett-switch.sh || erro_json "jett-switch.sh nao encontrado"
    jett-switch.sh "$nav" >> /tmp/jett-bridge.log 2>&1 \
        || erro_json "falha ao trocar para: ${nav}"
    printf '{"ok":true,"navegador":"%s"}\n' "$nav"
}

# ─────────────────────────────────────────────────────────────────────────────
# USB
# ─────────────────────────────────────────────────────────────────────────────

usb_list() {
    # Lista dispositivos de bloco removíveis com udisksctl ou lsblk
    local primeira=true
    printf '['

    while IFS= read -r linha; do
        local dev tamanho tipo montagem
        dev=$(echo "$linha" | awk '{print $1}')
        tamanho=$(echo "$linha" | awk '{print $4}')
        tipo=$(echo "$linha" | awk '{print $6}')
        montagem=$(echo "$linha" | awk '{print $7}')

        [[ "$tipo" != "part" && "$tipo" != "disk" ]] && continue
        [[ "$dev" == *loop* ]] && continue

        "$primeira" || printf ','
        printf '{"dispositivo":"/dev/%s","tamanho":"%s","montagem":"%s"}' \
            "$dev" "$tamanho" "${montagem:-}"
        primeira=false
    done < <(lsblk -rno NAME,MAJ:MIN,RM,SIZE,TYPE,MOUNTPOINT 2>/dev/null \
        | awk '$3 == "1"')  # RM=1 = removível

    printf ']\n'
}

usb_mount() {
    local dispositivo="${1:-}"
    [[ -z "$dispositivo" ]] && erro_json "dispositivo nao especificado"
    cmd_disponivel udisksctl || erro_json "udisksctl nao encontrado"

    local saida
    saida=$(udisksctl mount -b "$dispositivo" 2>&1) \
        || erro_json "falha ao montar ${dispositivo}: ${saida}"

    local ponto
    ponto=$(echo "$saida" | grep -oP 'at \K\S+' | head -1)
    printf '{"ok":true,"dispositivo":"%s","montagem":"%s"}\n' \
        "$dispositivo" "${ponto:-}"
}

usb_unmount() {
    local ponto="${1:-}"
    [[ -z "$ponto" ]] && erro_json "ponto de montagem nao especificado"
    cmd_disponivel udisksctl || erro_json "udisksctl nao encontrado"

    udisksctl unmount -b "$ponto" >> /tmp/jett-bridge.log 2>&1 \
        || erro_json "falha ao desmontar ${ponto}"
    printf '{"ok":true,"ponto":"%s"}\n' "$ponto"
}

# ─────────────────────────────────────────────────────────────────────────────
# SISTEMA
# ─────────────────────────────────────────────────────────────────────────────

system_info() {
    local hostname uptime_seg uptime_fmt versao_os

    hostname=$(hostname 2>/dev/null || echo "jett-os")
    uptime_seg=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    versao_os=$(cat /etc/debian_version 2>/dev/null | tr -d '\n' || echo "desconhecido")

    local h=$(( uptime_seg / 3600 ))
    local m=$(( (uptime_seg % 3600) / 60 ))
    uptime_fmt="${h}h${m}m"

    printf '{"hostname":"%s","uptime":"%s","os":"Debian %s","arch":"%s"}\n' \
        "$hostname" "$uptime_fmt" "$versao_os" "$(uname -m)"
}

# ─────────────────────────────────────────────────────────────────────────────
# DESPACHO
# ─────────────────────────────────────────────────────────────────────────────

COMANDO="${1:-}"
SUBCOMANDO="${2:-}"
ARGUMENTO="${3:-}"

case "$COMANDO" in
    volume)
        case "$SUBCOMANDO" in
            get)    volume_get ;;
            up)     volume_up ;;
            down)   volume_down ;;
            mute)   volume_mute ;;
            set)    volume_set "$ARGUMENTO" ;;
            *)      erro_json "subcomando de volume invalido: ${SUBCOMANDO}" ;;
        esac
        ;;
    network)
        case "$SUBCOMANDO" in
            info)   network_info ;;
            *)      erro_json "subcomando de network invalido: ${SUBCOMANDO}" ;;
        esac
        ;;
    power)
        power_cmd "$SUBCOMANDO"
        ;;
    browser)
        case "$SUBCOMANDO" in
            list)   browser_list ;;
            switch) browser_switch "$ARGUMENTO" ;;
            *)      erro_json "subcomando de browser invalido: ${SUBCOMANDO}" ;;
        esac
        ;;
    usb)
        case "$SUBCOMANDO" in
            list)    usb_list ;;
            mount)   usb_mount "$ARGUMENTO" ;;
            unmount) usb_unmount "$ARGUMENTO" ;;
            *)       erro_json "subcomando de usb invalido: ${SUBCOMANDO}" ;;
        esac
        ;;
    system)
        case "$SUBCOMANDO" in
            info)   system_info ;;
            *)      erro_json "subcomando de system invalido: ${SUBCOMANDO}" ;;
        esac
        ;;
    *)
        erro_json "comando desconhecido: ${COMANDO:-vazio}"
        ;;
esac
