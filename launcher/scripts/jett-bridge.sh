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
#   nav status                    — volume e rede atuais (JSON)
#   nav navigate <url>            — faz o navegador acessar a URL via xdotool
#   nav newtab                    — nova aba no navegador (Ctrl+T via xdotool)
#   nav closetab                  — fecha aba atual (Ctrl+W via xdotool)
#   nav nexttab                   — próxima aba (Ctrl+Tab via xdotool)
#   nav prevtab                   — aba anterior (Ctrl+Shift+Tab via xdotool)
#
#   wifi status                   — estado WiFi e SSID atual (JSON)
#   wifi toggle                   — liga/desliga WiFi
#   wifi list                     — redes disponíveis (JSON)
#   wifi connect <ssid> [senha]   — conecta a rede WiFi
#   wifi disconnect               — desconecta WiFi atual
#
#   bluetooth power_status        — estado de energia Bluetooth (JSON)
#   bluetooth power_toggle        — liga/desliga Bluetooth
#   (demais subcomandos já existentes: list, scan, pair, remove)
#
#   system info                   — hostname, uptime, OS, arch (JSON)
#   system version                — versão Jett OS, base Debian, kernel (JSON)
#   system updates_check          — contagem de atualizações disponíveis (JSON)
#   system updates_install        — instala atualizações via sudo -n apt-get upgrade
#
#   pwas list                     — PWAs instalados (~/.local/share/applications, JSON)
#
#   devices gamepads              — gamepads detectados (/dev/input/js*, JSON)
#
#   window open <url>             — abre janela browser --app=URL (detecta navegador ativo)
#
#   wizard install_browsers <nav> — instala/configura navegador em background (JSON imediato)
#   wizard install_status         — progresso da instalação em andamento (JSON)
#   wizard complete <nav> [senha] — cria firstboot.done, define nav padrão e senha admin
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

bluetooth_power_status() {
    cmd_disponivel bluetoothctl || erro_json "bluetoothctl não encontrado"
    local estado
    estado=$(bluetoothctl show 2>/dev/null | grep 'Powered:' | awk '{print $2}')
    if [[ "$estado" == "yes" ]]; then
        printf '{"ligado":true}\n'
    else
        printf '{"ligado":false}\n'
    fi
}

bluetooth_power_toggle() {
    cmd_disponivel bluetoothctl || erro_json "bluetoothctl não encontrado"
    local estado
    estado=$(bluetoothctl show 2>/dev/null | grep 'Powered:' | awk '{print $2}')
    if [[ "$estado" == "yes" ]]; then
        bluetoothctl power off >> /tmp/jett-bridge.log 2>&1 || true
        printf '{"ok":true,"ligado":false}\n'
    else
        bluetoothctl power on  >> /tmp/jett-bridge.log 2>&1 || true
        printf '{"ok":true,"ligado":true}\n'
    fi
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
# NAV — Controle da barra de navegação via xdotool
# ─────────────────────────────────────────────────────────────────────────────
# Todos os comandos nav_* usam xdotool para enviar teclas ao navegador kiosk.
# Requer: xdotool instalado e DISPLAY configurado (XWayland ativo no Sway).

# Encontra o Window ID do navegador kiosk ativo.
# Tenta múltiplos class names para cobrir todos os navegadores suportados.
_nav_encontrar_browser() {
    cmd_disponivel xdotool || erro_json "xdotool não encontrado"
    local classes=(
        "brave-browser" "Brave-browser"
        "microsoft-edge" "Microsoft-edge"
        "thorium-browser" "Thorium-browser"
        "opera" "Opera"
        "Navigator" "firefox" "Firefox"
    )
    local wid
    for cls in "${classes[@]}"; do
        wid=$(xdotool search --classname "$cls" 2>/dev/null | head -1)
        [[ -n "$wid" ]] && { printf '%s' "$wid"; return 0; }
    done
    for cls in "${classes[@]}"; do
        wid=$(xdotool search --class "$cls" 2>/dev/null | head -1)
        [[ -n "$wid" ]] && { printf '%s' "$wid"; return 0; }
    done
    return 1
}

nav_status() {
    # Reutiliza volume_get e network_info para retornar status consolidado
    local vol_json rede_json
    vol_json=$(volume_get 2>/dev/null || printf '{}')
    rede_json=$(network_info 2>/dev/null || printf '{}')
    printf '{"volume":%s,"rede":%s}\n' "$vol_json" "$rede_json"
}

nav_navigate() {
    local url="${1:-}"
    [[ -z "$url" ]] && erro_json "URL não especificada"
    cmd_disponivel xdotool || erro_json "xdotool não encontrado"

    local wid
    wid=$(_nav_encontrar_browser) || erro_json "janela do navegador não encontrada"

    # Foca o navegador, abre a barra de endereços nativa, digita e confirma
    xdotool windowfocus --sync "$wid"
    xdotool key --window "$wid" ctrl+l
    sleep 0.15
    xdotool key --window "$wid" ctrl+a
    xdotool type --window "$wid" --clearmodifiers -- "$url"
    xdotool key --window "$wid" Return
    printf '{"ok":true,"url":"%s"}\n' "${url//\"/\\\"}"
}

nav_newtab() {
    cmd_disponivel xdotool || erro_json "xdotool não encontrado"
    local wid
    wid=$(_nav_encontrar_browser) || erro_json "janela do navegador não encontrada"
    xdotool windowfocus --sync "$wid"
    xdotool key --window "$wid" ctrl+t
    printf '{"ok":true}\n'
}

nav_closetab() {
    cmd_disponivel xdotool || erro_json "xdotool não encontrado"
    local wid
    wid=$(_nav_encontrar_browser) || erro_json "janela do navegador não encontrada"
    xdotool windowfocus --sync "$wid"
    xdotool key --window "$wid" ctrl+w
    printf '{"ok":true}\n'
}

nav_nexttab() {
    cmd_disponivel xdotool || erro_json "xdotool não encontrado"
    local wid
    wid=$(_nav_encontrar_browser) || erro_json "janela do navegador não encontrada"
    xdotool windowfocus --sync "$wid"
    xdotool key --window "$wid" ctrl+Tab
    printf '{"ok":true}\n'
}

nav_prevtab() {
    cmd_disponivel xdotool || erro_json "xdotool não encontrado"
    local wid
    wid=$(_nav_encontrar_browser) || erro_json "janela do navegador não encontrada"
    xdotool windowfocus --sync "$wid"
    xdotool key --window "$wid" ctrl+shift+Tab
    printf '{"ok":true}\n'
}

# ─────────────────────────────────────────────────────────────────────────────
# WIFI
# ─────────────────────────────────────────────────────────────────────────────

wifi_status() {
    cmd_disponivel nmcli || erro_json "nmcli não encontrado"
    local ligado
    ligado=$(nmcli radio wifi 2>/dev/null | tr -d '\n')
    if [[ "$ligado" == "enabled" ]]; then
        local ssid
        ssid=$(nmcli -t -e no -f ACTIVE,SSID dev wifi list 2>/dev/null \
            | awk -F: '/^yes/{for(i=2;i<=NF;i++) printf "%s%s",(i>2?":":""),$i; exit}')
        printf '{"ligado":true,"ssid":"%s"}\n' "${ssid//\"/\\\"}"
    else
        printf '{"ligado":false,"ssid":""}\n'
    fi
}

wifi_toggle() {
    cmd_disponivel nmcli || erro_json "nmcli não encontrado"
    local estado
    estado=$(nmcli radio wifi 2>/dev/null | tr -d '\n')
    if [[ "$estado" == "enabled" ]]; then
        nmcli radio wifi off 2>/dev/null || true
        printf '{"ok":true,"ligado":false}\n'
    else
        nmcli radio wifi on 2>/dev/null || true
        printf '{"ok":true,"ligado":true}\n'
    fi
}

wifi_list() {
    cmd_disponivel nmcli || erro_json "nmcli não encontrado"
    nmcli dev wifi rescan 2>/dev/null || true
    local primeira=true
    printf '['
    while IFS= read -r linha; do
        [[ -z "$linha" ]] && continue
        # Formato -t -e no: IN-USE:SSID:SIGNAL:SECURITY
        # SSID pode conter ':', então pegamos com awk pelo número de campos
        local em_uso ssid sinal seguranca n_campos
        em_uso=$(echo "$linha" | awk -F: '{print $1}')
        seguranca=$(echo "$linha" | awk -F: '{print $NF}')
        sinal=$(echo "$linha" | awk -F: '{print $(NF-1)}')
        n_campos=$(echo "$linha" | awk -F: '{print NF}')
        if [[ "$n_campos" -ge 4 ]]; then
            ssid=$(echo "$linha" | awk -F: -v n="$n_campos" \
                '{for(i=2;i<=n-2;i++) printf "%s%s",(i>2?":":""),$i}')
        else
            ssid=$(echo "$linha" | awk -F: '{print $2}')
        fi
        [[ -z "$ssid" ]] && continue
        local ativo=false seguro=false
        [[ "$em_uso" == "*" ]] && ativo=true
        [[ "$seguranca" != "--" && -n "$seguranca" ]] && seguro=true
        "$primeira" || printf ','
        printf '{"ssid":"%s","sinal":%s,"seguro":%s,"ativo":%s}' \
            "${ssid//\"/\\\"}" "${sinal:-0}" "$seguro" "$ativo"
        primeira=false
    done < <(nmcli -t -e no -f IN-USE,SSID,SIGNAL,SECURITY dev wifi list 2>/dev/null)
    printf ']\n'
}

wifi_connect() {
    local ssid="${1:-}" senha="${2:-}"
    [[ -z "$ssid" ]] && erro_json "SSID não especificado"
    cmd_disponivel nmcli || erro_json "nmcli não encontrado"
    if [[ -n "$senha" ]]; then
        nmcli dev wifi connect "$ssid" password "$senha" \
            >> /tmp/jett-bridge.log 2>&1 \
            || erro_json "falha ao conectar em ${ssid}"
    else
        nmcli dev wifi connect "$ssid" \
            >> /tmp/jett-bridge.log 2>&1 \
            || erro_json "falha ao conectar em ${ssid}"
    fi
    printf '{"ok":true,"ssid":"%s"}\n' "${ssid//\"/\\\"}"
}

wifi_disconnect() {
    cmd_disponivel nmcli || erro_json "nmcli não encontrado"
    local dev_wifi
    dev_wifi=$(nmcli -t -f DEVICE,TYPE dev 2>/dev/null \
        | awk -F: '$2=="wifi"{print $1; exit}')
    [[ -z "$dev_wifi" ]] && erro_json "interface WiFi não encontrada"
    nmcli dev disconnect "$dev_wifi" >> /tmp/jett-bridge.log 2>&1 \
        || erro_json "falha ao desconectar WiFi"
    printf '{"ok":true}\n'
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

system_version() {
    local versao_debian build_id kernel
    versao_debian=$(cat /etc/debian_version 2>/dev/null | tr -d '\n' || echo "desconhecido")
    build_id=$(grep 'JETT_VERSAO' "${CONF_JETT}/versao.conf" 2>/dev/null \
        | cut -d= -f2 | tr -d '"' | tr -d '\n' || echo "dev")
    kernel=$(uname -r 2>/dev/null || echo "desconhecido")
    printf '{"versao_jett":"%s","base":"Debian %s","kernel":"%s"}\n' \
        "${build_id}" "${versao_debian}" "${kernel}"
}

system_updates_check() {
    # Usa cache do apt — não requer root nem executa apt-get update
    local contagem
    contagem=$(apt list --upgradable 2>/dev/null | grep -c '/' || true)
    printf '{"atualizacoes":%s}\n' "${contagem:-0}"
}

system_updates_install() {
    # Requer: jett ALL=(root) NOPASSWD: /usr/bin/apt-get upgrade -y
    sudo -n apt-get upgrade -y >> /tmp/jett-bridge.log 2>&1 \
        || erro_json "falha ao instalar atualizações (verifique sudoers)"
    printf '{"ok":true}\n'
}

# ─────────────────────────────────────────────────────────────────────────────
# PWAS
# ─────────────────────────────────────────────────────────────────────────────

pwas_list() {
    local dir_apps="${HOME}/.local/share/applications"
    [[ -d "$dir_apps" ]] || { printf '[]\n'; return; }
    local primeira=true
    printf '['
    # .desktop de PWAs criados pelos navegadores Chromium/Edge/Brave
    while IFS= read -r desktop; do
        local nome url
        nome=$(grep -m1 '^Name=' "$desktop" 2>/dev/null | cut -d= -f2-)
        # X-WebApp-Url (padrão Edge/Chrome PWA)
        url=$(grep -m1 '^X-WebApp-Url=' "$desktop" 2>/dev/null | cut -d= -f2-)
        # Fallback: extrai --app=URL da linha Exec=
        if [[ -z "$url" ]]; then
            url=$(grep -m1 '^Exec=' "$desktop" 2>/dev/null \
                | grep -oP '(?<=--app=)\S+' | head -1)
        fi
        [[ -z "$nome" || -z "$url" ]] && continue
        "$primeira" || printf ','
        printf '{"nome":"%s","url":"%s"}' \
            "${nome//\"/\\\"}" "${url//\"/\\\"}"
        primeira=false
    done < <(find "$dir_apps" -maxdepth 1 \
        \( -name 'chrome-*.desktop' -o -name 'msedge-*.desktop' \
           -o -name 'brave-*.desktop' \) 2>/dev/null | sort)
    printf ']\n'
}

# ─────────────────────────────────────────────────────────────────────────────
# DEVICES
# ─────────────────────────────────────────────────────────────────────────────

devices_gamepads() {
    local primeira=true
    printf '['
    for js in /dev/input/js*; do
        [[ -e "$js" ]] || continue
        local num nome
        num=${js##*/js}
        nome=""
        local name_file="/sys/class/input/js${num}/device/name"
        [[ -f "$name_file" ]] && nome=$(cat "$name_file" 2>/dev/null | tr -d '\n')
        "$primeira" || printf ','
        printf '{"dispositivo":"%s","nome":"%s"}' \
            "${js//\"/\\\"}" "${nome//\"/\\\"}"
        primeira=false
    done
    printf ']\n'
}

# ─────────────────────────────────────────────────────────────────────────────
# WINDOW
# ─────────────────────────────────────────────────────────────────────────────

window_open() {
    local url="${1:-}"
    [[ -z "$url" ]] && erro_json "URL não especificada"

    local conf_instalados="${CONF_JETT}/navegadores-instalados.conf"
    local conf_ativo="${CONF_JETT}/navegador.conf"
    local binario=""

    # Tenta usar o navegador ativo configurado
    if [[ -f "$conf_ativo" && -f "$conf_instalados" ]]; then
        local nav_ativo
        nav_ativo=$(bash -c "source '${conf_ativo}' 2>/dev/null; echo \"\${JETT_NAVEGADOR:-}\"" 2>/dev/null || true)
        if [[ -n "$nav_ativo" ]]; then
            declare -A _id2chave=([brave]="BRAVE" [edge]="EDGE" [thorium]="THORIUM" [opera-gx]="OPERA" [firefox]="FIREFOX")
            local chave="${_id2chave[$nav_ativo]:-}"
            if [[ -n "$chave" ]]; then
                binario=$(bash -c "source '${conf_instalados}' 2>/dev/null; echo \"\${JETT_${chave}_BINARIO:-}\"" 2>/dev/null || true)
            fi
        fi
    fi

    # Fallback: candidatos em ordem de preferência
    if [[ -z "$binario" ]] || ! command -v "$binario" &>/dev/null; then
        local candidatos=(brave-browser microsoft-edge-stable thorium-browser opera firefox)
        for c in "${candidatos[@]}"; do
            if command -v "$c" &>/dev/null; then
                binario="$c"
                break
            fi
        done
    fi

    [[ -z "$binario" ]] && erro_json "nenhum navegador disponível"

    if [[ "$binario" == "firefox" ]]; then
        "$binario" --new-instance --new-window "$url" &
    else
        "$binario" --new-window "--app=${url}" --no-first-run &
    fi
    disown
    printf '{"ok":true,"url":"%s"}\n' "${url//\"/\\\"}"
}

# ─────────────────────────────────────────────────────────────────────────────
# WIZARD — Assistente de primeiro boot
# ─────────────────────────────────────────────────────────────────────────────

_WIZARD_PROG_FILE="/tmp/jett-install-progress.json"
_FIRSTBOOT_DONE_SYSTEM="/etc/jett-os/firstboot.done"
_FIRSTBOOT_DONE_USER="${HOME}/.config/jett-os/firstboot.done"

wizard_install_browsers() {
    local nav_id="${1:-firefox}"
    local prog="$_WIZARD_PROG_FILE"

    # Lança instalação em background e acompanha com progresso simulado
    (
        printf '{"status":"em_andamento","progresso":5,"mensagem":"Preparando instalação..."}\n' > "$prog"

        local ok=true
        if cmd_disponivel jett-switch.sh; then
            # jett-switch.sh configura e instala o navegador escolhido
            jett-switch.sh "$nav_id" >> /tmp/jett-bridge.log 2>&1 &
        else
            # Fallback: tenta sudo apt-get diretamente
            sudo -n apt-get install -y "$nav_id" >> /tmp/jett-bridge.log 2>&1 &
        fi
        local install_pid=$!

        # Avança progresso enquanto o instalador roda
        local p=10
        while kill -0 "$install_pid" 2>/dev/null; do
            sleep 2
            p=$(( p < 88 ? p + 9 : p ))
            printf '{"status":"em_andamento","progresso":%d,"mensagem":"Instalando %s..."}\n' \
                "$p" "${nav_id}" > "$prog"
        done

        wait "$install_pid" && ok=true || ok=false
        if [[ "$ok" == "true" ]]; then
            printf '{"status":"concluido","progresso":100,"mensagem":"Instalação concluída!"}\n' > "$prog"
        else
            printf '{"status":"erro","progresso":0,"mensagem":"Falha na instalação. Verifique /tmp/jett-bridge.log."}\n' > "$prog"
        fi
    ) &
    disown

    printf '{"ok":true,"nav":"%s"}\n' "${nav_id//\"/\\\"}"
}

wizard_install_status() {
    if [[ -f "$_WIZARD_PROG_FILE" ]]; then
        cat "$_WIZARD_PROG_FILE"
    else
        printf '{"status":"aguardando","progresso":0,"mensagem":"Aguardando início..."}\n'
    fi
}

wizard_complete() {
    local nav_id="${1:-}" senha="${2:-}"

    # 1. Define o navegador padrão
    if [[ -n "$nav_id" ]] && cmd_disponivel jett-switch.sh; then
        jett-switch.sh "$nav_id" >> /tmp/jett-bridge.log 2>&1 || true
    fi

    # 2. Define a senha de administrador (jett user)
    if [[ -n "$senha" ]] && [[ ${#senha} -ge 4 ]]; then
        printf 'jett:%s\n' "$senha" | sudo -n chpasswd >> /tmp/jett-bridge.log 2>&1 \
            || printf 'aviso: senha nao configurada\n' >&2
    fi

    # 3. Cria o arquivo firstboot.done
    #    Tenta via sudo primeiro; caso falhe, usa o path do usuário
    local ok_done=false
    if sudo -n tee "$_FIRSTBOOT_DONE_SYSTEM" >/dev/null 2>&1 <<< "$(date)"; then
        ok_done=true
    else
        mkdir -p "$(dirname "$_FIRSTBOOT_DONE_USER")"
        date > "$_FIRSTBOOT_DONE_USER" && ok_done=true || true
    fi

    if [[ "$ok_done" == "true" ]]; then
        printf '{"ok":true,"nav":"%s"}\n' "${nav_id//\"/\\\"}"
    else
        erro_json "falha ao criar firstboot.done"
    fi
}

# Apenas define a senha — não cria firstboot.done
wizard_set_admin_password() {
    local senha="${1:-}"
    [[ -z "$senha" ]] && erro_json "senha não especificada"
    [[ ${#senha} -lt 4 ]] && erro_json "senha deve ter pelo menos 4 caracteres"
    printf 'jett:%s\n' "$senha" | sudo -n chpasswd >> /tmp/jett-bridge.log 2>&1 \
        || erro_json "falha ao definir senha (verifique sudoers: jett ALL=(root) NOPASSWD: /usr/sbin/chpasswd)"
    printf '{"ok":true}\n'
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
            list)          bluetooth_list ;;
            scan)          bluetooth_scan ;;
            pair)          bluetooth_pair "$ARG1" ;;
            remove)        bluetooth_remove "$ARG1" ;;
            power_status)  bluetooth_power_status ;;
            power_toggle)  bluetooth_power_toggle ;;
            *)             erro_json "subcomando de bluetooth inválido: ${SUBCOMANDO}" ;;
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
    nav)
        case "$SUBCOMANDO" in
            status)   nav_status ;;
            navigate) nav_navigate "$ARG1" ;;
            newtab)   nav_newtab ;;
            closetab) nav_closetab ;;
            nexttab)  nav_nexttab ;;
            prevtab)  nav_prevtab ;;
            *)        erro_json "subcomando de nav inválido: ${SUBCOMANDO}" ;;
        esac ;;
    wifi)
        case "$SUBCOMANDO" in
            status)     wifi_status ;;
            toggle)     wifi_toggle ;;
            list)       wifi_list ;;
            connect)    wifi_connect "$ARG1" "$ARG2" ;;
            disconnect) wifi_disconnect ;;
            *)          erro_json "subcomando de wifi inválido: ${SUBCOMANDO}" ;;
        esac ;;
    system)
        case "$SUBCOMANDO" in
            info)             system_info ;;
            version)          system_version ;;
            updates_check)    system_updates_check ;;
            updates_install)  system_updates_install ;;
            *)                erro_json "subcomando de system inválido: ${SUBCOMANDO}" ;;
        esac ;;
    pwas)
        case "$SUBCOMANDO" in
            list) pwas_list ;;
            *)    erro_json "subcomando de pwas inválido: ${SUBCOMANDO}" ;;
        esac ;;
    devices)
        case "$SUBCOMANDO" in
            gamepads) devices_gamepads ;;
            *)        erro_json "subcomando de devices inválido: ${SUBCOMANDO}" ;;
        esac ;;
    window)
        case "$SUBCOMANDO" in
            open) window_open "$ARG1" ;;
            *)    erro_json "subcomando de window inválido: ${SUBCOMANDO}" ;;
        esac ;;
    wizard)
        case "$SUBCOMANDO" in
            install_browsers)    wizard_install_browsers "$ARG1" ;;
            install_status)      wizard_install_status ;;
            complete)            wizard_complete "$ARG1" "$ARG2" ;;
            set_admin_password)  wizard_set_admin_password "$ARG1" ;;
            *)                   erro_json "subcomando de wizard inválido: ${SUBCOMANDO}" ;;
        esac ;;
    *)
        erro_json "comando desconhecido: ${COMANDO:-vazio}" ;;
esac
