#!/usr/bin/env bash
# =============================================================================
# jett-bridge.sh — Ponte entre a interface HTML e o sistema operacional
# =============================================================================
# Uso:
#   jett-bridge <comando> [subcomando] [arg1] [arg2]
#
# Comandos disponíveis:
#   volume get                    — nível e estado mudo (JSON)
#   volume up|down|mute           — controla volume
#   volume set <0-100>            — define nível exato
#
#   network info                  — interface, IP, status
#
#   power shutdown|reboot|suspend — controla energia
#
#   browser list                  — navegadores instalados (JSON)
#   browser switch <id>           — troca navegador ativo
#
#   usb list                      — dispositivos USB montáveis (JSON)
#   usb mount <dispositivo>       — monta (ex: /dev/sdb1)
#   usb unmount <dispositivo>     — desmonta
#
#   bluetooth list                — dispositivos pareados (JSON)
#   bluetooth scan                — busca novos dispositivos (5 s, JSON)
#   bluetooth pair <endereço>     — pareia e conecta
#   bluetooth remove <endereço>   — remove pareamento
#
#   files list [caminho]          — lista diretório (JSON); padrão: /home/jett
#   files move <src> <dst>        — move arquivo/dir
#   files copy <src> <dst>        — copia arquivo/dir
#   files rename <src> <novo>     — renomeia dentro do mesmo dir
#   files delete <caminho>        — remove arquivo ou dir vazio
#   files mkdir <caminho>         — cria diretório
#
#   system info                   — hostname, uptime, OS, arch (JSON)
#
# Segurança de arquivos:
#   Operações em files/* são restritas a /home/jett, /media, /mnt e /run/media.
#   Tentativas de acessar outras áreas retornam erro JSON sem executar nada.
#
# Saída: JSON em stdout. Erros em stderr + JSON {"erro":"..."} em stdout.
# Código de retorno: 0 = sucesso, 1 = erro.
#
# Instalação:
#   sudo cp launcher/scripts/jett-bridge.sh /usr/local/bin/jett-bridge
#   sudo chmod +x /usr/local/bin/jett-bridge
# =============================================================================

set -euo pipefail

CONF_JETT="/etc/jett-os"
RAIZ_INTERNA="/home/jett"
RAIZES_REMOVIVEIS=("/media" "/mnt" "/run/media")

# ─────────────────────────────────────────────────────────────────────────────
# UTILITÁRIOS
# ─────────────────────────────────────────────────────────────────────────────

erro_json() {
    printf '{"erro":"%s"}\n' "${1//\"/\\\"}"
    exit 1
}

cmd_disponivel() {
    command -v "$1" &>/dev/null
}

# Valida que o caminho está dentro das raízes permitidas.
# Retorna o caminho resolvido via stdout. Aborta se fora das raízes.
validar_caminho() {
    local caminho="$1"
    [[ -z "$caminho" ]] && erro_json "caminho vazio"

    # realpath -m resolve sem exigir existência e elimina traversals (..)
    local real
    real=$(realpath -m -- "$caminho" 2>/dev/null) \
        || erro_json "caminho inválido: ${caminho}"

    local permitido=false
    # Raiz interna: /home/jett
    if [[ "$real" == "$RAIZ_INTERNA" || "$real" == "${RAIZ_INTERNA}/"* ]]; then
        permitido=true
    fi
    # Raízes de mídia removível
    for raiz in "${RAIZES_REMOVIVEIS[@]}"; do
        if [[ "$real" == "$raiz" || "$real" == "${raiz}/"* ]]; then
            permitido=true; break
        fi
    done

    [[ "$permitido" == true ]] \
        || erro_json "acesso negado: ${real} está fora das áreas permitidas"
    printf '%s' "$real"
}

# ─────────────────────────────────────────────────────────────────────────────
# VOLUME
# ─────────────────────────────────────────────────────────────────────────────

volume_get() {
    cmd_disponivel pactl || erro_json "pactl não encontrado"
    local nivel mudo
    nivel=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null \
        | grep -oP '\d+%' | head -1 | tr -d '%')
    mudo=$(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null \
        | grep -oP 'yes|no' | head -1)
    printf '{"volume":%s,"mudo":%s}\n' \
        "${nivel:-0}" \
        "$([ "${mudo:-no}" = "yes" ] && echo true || echo false)"
}

volume_up()   { pactl set-sink-volume @DEFAULT_SINK@ +5%;     volume_get; }
volume_down() { pactl set-sink-volume @DEFAULT_SINK@ -5%;     volume_get; }
volume_mute() { pactl set-sink-mute   @DEFAULT_SINK@ toggle;  volume_get; }

volume_set() {
    local nivel="${1:-50}"
    nivel=$(( nivel < 0 ? 0 : nivel > 100 ? 100 : nivel ))
    pactl set-sink-volume @DEFAULT_SINK@ "${nivel}%"
    volume_get
}

# ─────────────────────────────────────────────────────────────────────────────
# REDE
# ─────────────────────────────────────────────────────────────────────────────

network_info() {
    local iface ip gateway status
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [[ -z "$iface" ]]; then
        printf '{"conectado":false,"interface":"","ip":"","gateway":""}\n'; return
    fi
    ip=$(ip addr show "$iface" 2>/dev/null \
        | awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')
    gateway=$(ip route show default dev "$iface" 2>/dev/null \
        | awk '/via/ {print $3; exit}')
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
    case "${1:-}" in
        shutdown) systemctl poweroff ;;
        reboot)   systemctl reboot ;;
        suspend)  systemctl suspend ;;
        *)        erro_json "subcomando de power inválido: ${1:-}" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# NAVEGADORES
# ─────────────────────────────────────────────────────────────────────────────

browser_list() {
    local conf_instalados="${CONF_JETT}/navegadores-instalados.conf"
    local conf_ativo="${CONF_JETT}/navegador.conf"
    local nav_ativo=""
    if [[ -f "$conf_ativo" ]]; then
        nav_ativo=$(bash -c "source '${conf_ativo}' 2>/dev/null; echo \"\${JETT_NAVEGADOR:-}\"" 2>/dev/null || true)
    fi
    declare -A id_map=( [BRAVE]="brave" [EDGE]="edge" [THORIUM]="thorium" [OPERA]="opera-gx" [FIREFOX]="firefox" )
    declare -A nome_map=( [BRAVE]="Brave" [EDGE]="Microsoft Edge" [THORIUM]="Thorium" [OPERA]="Opera GX" [FIREFOX]="Firefox" )
    local primeira=true
    printf '['
    for chave_var in BRAVE EDGE THORIUM OPERA FIREFOX; do
        local instalado versao binario
        instalado=""; versao=""; binario=""
        if [[ -f "$conf_instalados" ]]; then
            instalado=$(bash -c "source '${conf_instalados}' 2>/dev/null; echo \"\${JETT_${chave_var}_INSTALADO:-false}\"" 2>/dev/null || true)
            versao=$(bash -c "source '${conf_instalados}' 2>/dev/null; echo \"\${JETT_${chave_var}_VERSAO:-}\"" 2>/dev/null || true)
            binario=$(bash -c "source '${conf_instalados}' 2>/dev/null; echo \"\${JETT_${chave_var}_BINARIO:-}\"" 2>/dev/null || true)
        fi
        [[ "$instalado" != "true" ]] && continue
        local nav_id="${id_map[$chave_var]}"
        local ativo="false"
        [[ "$nav_ativo" == "$nav_id" ]] && ativo="true"
        "$primeira" || printf ','
        printf '{"id":"%s","nome":"%s","versao":"%s","binario":"%s","ativo":%s}' \
            "$nav_id" "${nome_map[$chave_var]}" \
            "${versao//\"/\\\"}" "${binario//\"/\\\"}" "$ativo"
        primeira=false
    done
    printf ']\n'
}

browser_switch() {
    local nav="${1:-}"
    [[ -z "$nav" ]] && erro_json "navegador não especificado"
    cmd_disponivel jett-switch.sh || erro_json "jett-switch.sh não encontrado"
    jett-switch.sh "$nav" >> /tmp/jett-bridge.log 2>&1 \
        || erro_json "falha ao trocar para: ${nav}"
    printf '{"ok":true,"navegador":"%s"}\n' "$nav"
}

# ─────────────────────────────────────────────────────────────────────────────
# USB
# ─────────────────────────────────────────────────────────────────────────────

usb_list() {
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
    done < <(lsblk -rno NAME,MAJ:MIN,RM,SIZE,TYPE,MOUNTPOINT 2>/dev/null | awk '$3=="1"')
    printf ']\n'
}

usb_mount() {
    local dispositivo="${1:-}"
    [[ -z "$dispositivo" ]] && erro_json "dispositivo não especificado"
    cmd_disponivel udisksctl || erro_json "udisksctl não encontrado"
    local saida
    saida=$(udisksctl mount -b "$dispositivo" 2>&1) \
        || erro_json "falha ao montar ${dispositivo}"
    local ponto
    ponto=$(echo "$saida" | grep -oP 'at \K\S+' | head -1)
    printf '{"ok":true,"dispositivo":"%s","montagem":"%s"}\n' \
        "$dispositivo" "${ponto:-}"
}

usb_unmount() {
    local dispositivo="${1:-}"
    [[ -z "$dispositivo" ]] && erro_json "dispositivo não especificado"
    cmd_disponivel udisksctl || erro_json "udisksctl não encontrado"
    udisksctl unmount -b "$dispositivo" >> /tmp/jett-bridge.log 2>&1 \
        || erro_json "falha ao desmontar ${dispositivo}"
    printf '{"ok":true,"dispositivo":"%s"}\n' "$dispositivo"
}

# ─────────────────────────────────────────────────────────────────────────────
# BLUETOOTH
# ─────────────────────────────────────────────────────────────────────────────

# Emite linha JSON de dispositivo bluetooth a partir da saída do bluetoothctl
_bt_device_json() {
    local linha="$1" pareado="${2:-false}"
    local addr nome
    # Formato: "Device AA:BB:CC:DD:EE:FF Nome do Dispositivo"
    addr=$(echo "$linha" | awk '{print $2}')
    nome=$(echo "$linha" | cut -d' ' -f3-)
    [[ -z "$addr" ]] && return
    # Verifica se está conectado
    local conectado=false
    if bluetoothctl info "$addr" 2>/dev/null | grep -q "Connected: yes"; then
        conectado=true
    fi
    printf '{"endereco":"%s","nome":"%s","pareado":%s,"conectado":%s}' \
        "$addr" "${nome//\"/\\\"}" "$pareado" "$conectado"
}

bluetooth_list() {
    cmd_disponivel bluetoothctl || erro_json "bluetoothctl não encontrado"
    local primeira=true
    printf '['
    while IFS= read -r linha; do
        [[ "$linha" != Device* ]] && continue
        "$primeira" || printf ','
        _bt_device_json "$linha" true
        primeira=false
    done < <(bluetoothctl devices 2>/dev/null)
    printf ']\n'
}

bluetooth_scan() {
    cmd_disponivel bluetoothctl || erro_json "bluetoothctl não encontrado"
    # Liga o scan por 5 segundos, aguarda, desliga
    # Usa timeout para garantir que não ficará pendurado
    bluetoothctl power on >> /tmp/jett-bridge.log 2>&1 || true
    timeout 6 bluetoothctl scan on >> /tmp/jett-bridge.log 2>&1 || true

    # Lista todos os dispositivos descobertos (inclui não pareados)
    local primeira=true
    printf '['
    while IFS= read -r linha; do
        [[ "$linha" != Device* ]] && continue
        local addr
        addr=$(echo "$linha" | awk '{print $2}')
        local pareado=false
        bluetoothctl info "$addr" 2>/dev/null | grep -q "Paired: yes" && pareado=true
        "$primeira" || printf ','
        _bt_device_json "$linha" "$pareado"
        primeira=false
    done < <(bluetoothctl devices 2>/dev/null)
    printf ']\n'
}

bluetooth_pair() {
    local addr="${1:-}"
    [[ -z "$addr" ]] && erro_json "endereço bluetooth não especificado"
    cmd_disponivel bluetoothctl || erro_json "bluetoothctl não encontrado"

    bluetoothctl pair    "$addr" >> /tmp/jett-bridge.log 2>&1 \
        || erro_json "falha ao parear com ${addr}"
    bluetoothctl connect "$addr" >> /tmp/jett-bridge.log 2>&1 || true
    bluetoothctl trust   "$addr" >> /tmp/jett-bridge.log 2>&1 || true

    printf '{"ok":true,"endereco":"%s"}\n' "$addr"
}

bluetooth_remove() {
    local addr="${1:-}"
    [[ -z "$addr" ]] && erro_json "endereço bluetooth não especificado"
    cmd_disponivel bluetoothctl || erro_json "bluetoothctl não encontrado"

    bluetoothctl disconnect "$addr" >> /tmp/jett-bridge.log 2>&1 || true
    bluetoothctl remove     "$addr" >> /tmp/jett-bridge.log 2>&1 \
        || erro_json "falha ao remover ${addr}"
    printf '{"ok":true,"endereco":"%s"}\n' "$addr"
}

# ─────────────────────────────────────────────────────────────────────────────
# ARQUIVOS
# ─────────────────────────────────────────────────────────────────────────────

files_list() {
    local caminho="${1:-${RAIZ_INTERNA}}"
    local real
    real=$(validar_caminho "$caminho")
    [[ -d "$real" ]] || erro_json "diretório não encontrado: ${caminho}"

    local -a dirs=() arqs=()

    # Coleta entradas não-ocultas, separando dirs de arquivos
    while IFS= read -r -d '' entrada; do
        local nome
        nome=$(basename "$entrada")
        [[ "$nome" == .* ]] && continue          # ignora ocultos
        if [[ -d "$entrada" ]]; then
            dirs+=("$entrada")
        elif [[ -f "$entrada" || -L "$entrada" ]]; then
            arqs+=("$entrada")
        fi
    done < <(find "$real" -maxdepth 1 -mindepth 1 -print0 2>/dev/null | sort -z)

    # Monta array de objetos JSON: diretórios primeiro, depois arquivos
    local -a entradas=()
    for entrada in "${dirs[@]}"; do
        local nome
        nome=$(basename "$entrada")
        entradas+=("{\"nome\":\"${nome//\"/\\\"}\",\"tipo\":\"dir\",\"tamanho\":0}")
    done
    for entrada in "${arqs[@]}"; do
        local nome tamanho
        nome=$(basename "$entrada")
        tamanho=$(stat -c%s "$entrada" 2>/dev/null || echo 0)
        entradas+=("{\"nome\":\"${nome//\"/\\\"}\",\"tipo\":\"file\",\"tamanho\":${tamanho}}")
    done

    local json_entradas=""
    [[ ${#entradas[@]} -gt 0 ]] && json_entradas=$(IFS=','; echo "${entradas[*]}")
    printf '{"caminho":"%s","entradas":[%s]}\n' "${real//\"/\\\"}" "$json_entradas"
}

files_move() {
    local src="${1:-}" dst="${2:-}"
    [[ -z "$src" || -z "$dst" ]] && erro_json "src e dst são obrigatórios"
    local real_src real_dst
    real_src=$(validar_caminho "$src")
    real_dst=$(validar_caminho "$dst")
    [[ -e "$real_src" ]] || erro_json "origem não encontrada: ${real_src}"
    # Se dst é diretório existente, move para dentro dele
    if [[ -d "$real_dst" ]]; then
        mv -- "$real_src" "${real_dst}/"
    else
        mv -- "$real_src" "$real_dst"
    fi
    printf '{"ok":true}\n'
}

files_copy() {
    local src="${1:-}" dst="${2:-}"
    [[ -z "$src" || -z "$dst" ]] && erro_json "src e dst são obrigatórios"
    local real_src real_dst
    real_src=$(validar_caminho "$src")
    real_dst=$(validar_caminho "$dst")
    [[ -e "$real_src" ]] || erro_json "origem não encontrada: ${real_src}"
    if [[ -d "$real_src" ]]; then
        cp -r -- "$real_src" "$real_dst"
    else
        cp -- "$real_src" "$real_dst"
    fi
    printf '{"ok":true}\n'
}

files_rename() {
    local src="${1:-}" novo_nome="${2:-}"
    [[ -z "$src" || -z "$novo_nome" ]] && erro_json "src e novo nome são obrigatórios"
    # Novo nome não pode conter separador de caminho
    [[ "$novo_nome" == */* ]] && erro_json "novo nome não pode conter '/'"
    local real_src
    real_src=$(validar_caminho "$src")
    [[ -e "$real_src" ]] || erro_json "arquivo não encontrado: ${real_src}"
    local dir_pai
    dir_pai=$(dirname "$real_src")
    local real_dst
    real_dst=$(validar_caminho "${dir_pai}/${novo_nome}")
    mv -- "$real_src" "$real_dst"
    printf '{"ok":true}\n'
}

files_delete() {
    local caminho="${1:-}"
    [[ -z "$caminho" ]] && erro_json "caminho não especificado"
    local real
    real=$(validar_caminho "$caminho")
    [[ -e "$real" ]] || erro_json "arquivo não encontrado: ${real}"
    if [[ -d "$real" ]]; then
        # Só permite remover diretórios vazios (segurança)
        rmdir -- "$real" 2>/dev/null \
            || erro_json "diretório não está vazio: ${real}"
    else
        rm -- "$real"
    fi
    printf '{"ok":true}\n'
}

files_mkdir() {
    local caminho="${1:-}"
    [[ -z "$caminho" ]] && erro_json "caminho não especificado"
    local real
    real=$(validar_caminho "$caminho")
    mkdir -p -- "$real" \
        || erro_json "falha ao criar diretório: ${real}"
    printf '{"ok":true,"caminho":"%s"}\n' "${real//\"/\\\"}"
}

# ─────────────────────────────────────────────────────────────────────────────
# SISTEMA
# ─────────────────────────────────────────────────────────────────────────────

system_info() {
    local hostname uptime_seg versao_os
    hostname=$(hostname 2>/dev/null || echo "jett-os")
    uptime_seg=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    versao_os=$(cat /etc/debian_version 2>/dev/null | tr -d '\n' || echo "desconhecido")
    local h=$(( uptime_seg / 3600 )) m=$(( (uptime_seg % 3600) / 60 ))
    printf '{"hostname":"%s","uptime":"%dh%dm","os":"Debian %s","arch":"%s"}\n' \
        "$hostname" "$h" "$m" "$versao_os" "$(uname -m)"
}

# ─────────────────────────────────────────────────────────────────────────────
# DESPACHO
# ─────────────────────────────────────────────────────────────────────────────

COMANDO="${1:-}"
SUBCOMANDO="${2:-}"
ARG1="${3:-}"
ARG2="${4:-}"

case "$COMANDO" in
    volume)
        case "$SUBCOMANDO" in
            get)    volume_get ;;
            up)     volume_up ;;
            down)   volume_down ;;
            mute)   volume_mute ;;
            set)    volume_set "$ARG1" ;;
            *)      erro_json "subcomando de volume inválido: ${SUBCOMANDO}" ;;
        esac ;;
    network)
        case "$SUBCOMANDO" in
            info)   network_info ;;
            *)      erro_json "subcomando de network inválido: ${SUBCOMANDO}" ;;
        esac ;;
    power)
        power_cmd "$SUBCOMANDO" ;;
    browser)
        case "$SUBCOMANDO" in
            list)   browser_list ;;
            switch) browser_switch "$ARG1" ;;
            *)      erro_json "subcomando de browser inválido: ${SUBCOMANDO}" ;;
        esac ;;
    usb)
        case "$SUBCOMANDO" in
            list)    usb_list ;;
            mount)   usb_mount "$ARG1" ;;
            unmount) usb_unmount "$ARG1" ;;
            *)       erro_json "subcomando de usb inválido: ${SUBCOMANDO}" ;;
        esac ;;
    bluetooth)
        case "$SUBCOMANDO" in
            list)   bluetooth_list ;;
            scan)   bluetooth_scan ;;
            pair)   bluetooth_pair "$ARG1" ;;
            remove) bluetooth_remove "$ARG1" ;;
            *)      erro_json "subcomando de bluetooth inválido: ${SUBCOMANDO}" ;;
        esac ;;
    files)
        case "$SUBCOMANDO" in
            list)   files_list "$ARG1" ;;
            move)   files_move "$ARG1" "$ARG2" ;;
            copy)   files_copy "$ARG1" "$ARG2" ;;
            rename) files_rename "$ARG1" "$ARG2" ;;
            delete) files_delete "$ARG1" ;;
            mkdir)  files_mkdir "$ARG1" ;;
            *)      erro_json "subcomando de files inválido: ${SUBCOMANDO}" ;;
        esac ;;
    system)
        case "$SUBCOMANDO" in
            info)   system_info ;;
            *)      erro_json "subcomando de system inválido: ${SUBCOMANDO}" ;;
        esac ;;
    *)
        erro_json "comando desconhecido: ${COMANDO:-vazio}" ;;
esac
