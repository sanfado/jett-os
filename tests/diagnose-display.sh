#!/usr/bin/env bash
# =============================================================================
# diagnose-display.sh — Diagnóstico de display/GPU para o Jett OS
# =============================================================================
# Coleta informações de saída de vídeo, driver, Mesa e logs do Sway.
# Identifica causas comuns do erro "page-flip failed on output DP-X" e sugere
# correções.
#
# Uso:
#   bash tests/diagnose-display.sh
#   bash tests/diagnose-display.sh 2>&1 | tee /tmp/jett-display-diag.txt
#
# Não requer root. Tenta coletar o máximo possível sem privilégios.
# =============================================================================

set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Cores
# ─────────────────────────────────────────────────────────────────────────────
R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; B='\033[1;34m'; N='\033[0m'; W='\033[1;37m'

titulo()  { echo -e "\n${B}══════════════════════════════════════════════════${N}"; \
            echo -e "${W}  $*${N}"; \
            echo -e "${B}══════════════════════════════════════════════════${N}"; }
secao()   { echo -e "\n${C}── $* ${N}"; }
ok()      { echo -e "  ${G}✔${N}  $*"; }
aviso()   { echo -e "  ${Y}⚠${N}  $*"; }
erro()    { echo -e "  ${R}✖${N}  $*"; }
info()    { echo -e "  ${N}·${N}  $*"; }
sugestao(){ echo -e "\n  ${Y}→ SUGESTÃO:${N} $*"; }

# ─────────────────────────────────────────────────────────────────────────────
titulo "Jett OS — Diagnóstico de Display / GPU"
echo "  $(date '+%Y-%m-%d %H:%M:%S')  |  $(uname -r)  |  $(hostname)"
# ─────────────────────────────────────────────────────────────────────────────

# Acumula sugestões para exibir no resumo final
SUGESTOES=()

# ─────────────────────────────────────────────────────────────────────────────
secao "1. Dispositivos DRM (/dev/dri/)"
# ─────────────────────────────────────────────────────────────────────────────
if ls /dev/dri/ &>/dev/null; then
    ls -la /dev/dri/ 2>/dev/null | grep -v '^total' | while read -r linha; do
        info "$linha"
    done
else
    erro "Nenhum dispositivo DRM encontrado em /dev/dri/"
    SUGESTOES+=("Verifique se o kernel i915/amdgpu/nouveau está carregado: lsmod | grep -E 'i915|amdgpu|nouveau'")
fi

# ─────────────────────────────────────────────────────────────────────────────
secao "2. Saídas DRM disponíveis e status"
# ─────────────────────────────────────────────────────────────────────────────
page_flip_output=""
if ls /sys/class/drm/ &>/dev/null; then
    for conector in /sys/class/drm/card*-*; do
        [[ -d "$conector" ]] || continue
        nome=$(basename "$conector")
        status=$(cat "${conector}/status" 2>/dev/null || echo "desconhecido")
        enabled=$(cat "${conector}/enabled" 2>/dev/null || echo "?")
        if [[ "$status" == "connected" ]]; then
            ok "${nome}: ${status} (enabled=${enabled})"
            # Guarda para checar correlação com page-flip
            page_flip_output="${nome}"
        else
            info "${nome}: ${status}"
        fi
    done
else
    aviso "Diretório /sys/class/drm/ não acessível."
fi

# ─────────────────────────────────────────────────────────────────────────────
secao "3. Driver de GPU em uso"
# ─────────────────────────────────────────────────────────────────────────────
gpu_driver=""
if command -v lspci &>/dev/null; then
    while IFS= read -r linha; do
        info "$linha"
        if echo "$linha" | grep -qi "intel"; then gpu_driver="i915"; fi
        if echo "$linha" | grep -qi "amd\|radeon"; then gpu_driver="amdgpu"; fi
        if echo "$linha" | grep -qi "nvidia"; then gpu_driver="nvidia"; fi
    done < <(lspci | grep -i "vga\|3d\|display" 2>/dev/null)
else
    aviso "lspci não disponível — instale pciutils para identificar a GPU."
fi

if [[ -n "$gpu_driver" ]]; then
    ok "Driver esperado: ${gpu_driver}"
    if lsmod | grep -q "^${gpu_driver}"; then
        ok "Módulo ${gpu_driver} carregado."
    else
        erro "Módulo ${gpu_driver} NÃO está carregado!"
        SUGESTOES+=("Carregue o módulo: sudo modprobe ${gpu_driver}")
    fi
fi

# Verifica presença de firmware Intel
if [[ "$gpu_driver" == "i915" ]]; then
    if dpkg -l intel-microcode &>/dev/null 2>&1 || \
       ls /lib/firmware/i915/ &>/dev/null 2>&1; then
        ok "Firmware i915 disponível."
    else
        aviso "Firmware i915 pode estar ausente."
        SUGESTOES+=("Instale: sudo apt install firmware-misc-nonfree intel-microcode")
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
secao "4. Mesa / OpenGL"
# ─────────────────────────────────────────────────────────────────────────────
if command -v glxinfo &>/dev/null; then
    renderer=$(glxinfo 2>/dev/null | grep "OpenGL renderer" || echo "")
    version=$(glxinfo  2>/dev/null | grep "OpenGL version"  || echo "")
    if [[ -n "$renderer" ]]; then
        ok "$renderer"
        ok "$version"
        if echo "$renderer" | grep -qi "software\|llvm\|swrast\|softpipe\|llvmpipe"; then
            aviso "Renderização por SOFTWARE detectada — GPU não está sendo usada."
            SUGESTOES+=("Verifique se libgl1-mesa-dri está instalado: dpkg -l libgl1-mesa-dri")
        fi
    else
        aviso "glxinfo não retornou dados úteis (display pode não estar disponível)."
    fi
else
    aviso "glxinfo não encontrado. Instale mesa-utils para diagnóstico de OpenGL."
    SUGESTOES+=("Instale mesa-utils: sudo apt install mesa-utils")
fi

# Versão Mesa pelo dpkg
mesa_ver=$(dpkg -l libgl1-mesa-dri 2>/dev/null | grep '^ii' | awk '{print $3}' || echo "")
if [[ -n "$mesa_ver" ]]; then
    ok "libgl1-mesa-dri: ${mesa_ver}"
else
    erro "libgl1-mesa-dri não instalado."
    SUGESTOES+=("Instale: sudo apt install libgl1-mesa-dri")
fi

# ─────────────────────────────────────────────────────────────────────────────
secao "5. Variáveis de ambiente Wayland/wlroots"
# ─────────────────────────────────────────────────────────────────────────────
vars_checar=(
    WLR_DRM_NO_ATOMIC
    WLR_RENDERER
    WAYLAND_DISPLAY
    XDG_SESSION_TYPE
    XDG_RUNTIME_DIR
    MOZ_ENABLE_WAYLAND
    GDK_BACKEND
)
page_flip_fix=false
for var in "${vars_checar[@]}"; do
    val="${!var:-}"
    if [[ -n "$val" ]]; then
        ok "${var}=${val}"
        if [[ "$var" == "WLR_DRM_NO_ATOMIC" && "$val" == "1" ]]; then
            page_flip_fix=true
        fi
    else
        info "${var}=(não definida)"
    fi
done

if ! $page_flip_fix; then
    aviso "WLR_DRM_NO_ATOMIC=1 não está definida no ambiente atual."
    SUGESTOES+=("Adicione 'Environment=WLR_DRM_NO_ATOMIC=1' ao sway-kiosk.service (já aplicado pela build).")
    SUGESTOES+=("Se iniciar pelo .bash_profile: 'export WLR_DRM_NO_ATOMIC=1' já está incluído.")
fi

# ─────────────────────────────────────────────────────────────────────────────
secao "6. Logs do kernel — erros DRM/i915"
# ─────────────────────────────────────────────────────────────────────────────
drm_erros=$(dmesg 2>/dev/null | grep -iE "page.flip.failed|drm.*error|i915.*error|atomic.*fail|flip.*timeout" | tail -20 || echo "")
if [[ -n "$drm_erros" ]]; then
    erro "Erros DRM encontrados no dmesg:"
    while IFS= read -r linha; do
        info "  $linha"
    done <<< "$drm_erros"
    SUGESTOES+=("Erro 'page-flip failed': defina WLR_DRM_NO_ATOMIC=1 no sway-kiosk.service.")
    SUGESTOES+=("Se persistir, tente WLR_RENDERER=pixman como último recurso (renderização por software).")
else
    ok "Nenhum erro de page-flip encontrado no dmesg recente."
fi

i915_info=$(dmesg 2>/dev/null | grep -i "i915" | tail -5 || echo "")
if [[ -n "$i915_info" ]]; then
    secao "  i915 (últimas 5 mensagens)"
    while IFS= read -r linha; do
        info "  $linha"
    done <<< "$i915_info"
fi

# ─────────────────────────────────────────────────────────────────────────────
secao "7. Logs do Sway — erros relevantes"
# ─────────────────────────────────────────────────────────────────────────────
sway_log_files=(
    "/tmp/jett-sway-crash.log"
    "/tmp/sway.log"
    "${HOME}/.local/share/sway/sway.log"
)
sway_log_encontrado=false
for f in "${sway_log_files[@]}"; do
    if [[ -f "$f" ]]; then
        sway_log_encontrado=true
        info "Arquivo: $f"
        erros_sway=$(grep -iE "page.flip|error|failed|atomic|drm" "$f" 2>/dev/null | tail -20 || echo "")
        if [[ -n "$erros_sway" ]]; then
            while IFS= read -r linha; do
                info "  $linha"
            done <<< "$erros_sway"
        else
            ok "Nenhum erro relevante em $f"
        fi
    fi
done

# Log do systemd journal (se disponível)
if command -v journalctl &>/dev/null; then
    sway_journal=$(journalctl --user -u sway-kiosk.service -n 30 --no-pager 2>/dev/null \
                   | grep -iE "page.flip|error|failed|atomic|WLR|DRM" | tail -15 || echo "")
    if [[ -n "$sway_journal" ]]; then
        info "journalctl sway-kiosk (erros relevantes):"
        while IFS= read -r linha; do
            info "  $linha"
        done <<< "$sway_journal"
        sway_log_encontrado=true
    fi
fi

if ! $sway_log_encontrado; then
    aviso "Nenhum log do Sway encontrado. Execute o diagnóstico após uma sessão com falha."
    info  "Para capturar: sway 2>/tmp/jett-sway-crash.log"
fi

# ─────────────────────────────────────────────────────────────────────────────
secao "8. Serviços systemd do Jett OS"
# ─────────────────────────────────────────────────────────────────────────────
if command -v systemctl &>/dev/null; then
    for svc in sway-kiosk.service jett-ui-server.service jett-updater.service; do
        status=$(systemctl --user is-active "$svc" 2>/dev/null || echo "inativo/desconhecido")
        enabled=$(systemctl --user is-enabled "$svc" 2>/dev/null || echo "?")
        if [[ "$status" == "active" ]]; then
            ok "${svc}: ${status} (enabled=${enabled})"
        elif [[ "$status" == "inactive" && "$enabled" == "enabled" ]]; then
            aviso "${svc}: ${status} (enabled=${enabled})"
        else
            info "${svc}: ${status} (enabled=${enabled})"
        fi
    done

    # Verifica se WLR_DRM_NO_ATOMIC está no sway-kiosk.service ativo
    svc_env=$(systemctl --user cat sway-kiosk.service 2>/dev/null | grep "WLR_DRM_NO_ATOMIC" || echo "")
    if [[ -n "$svc_env" ]]; then
        ok "sway-kiosk.service contém: ${svc_env}"
    else
        aviso "WLR_DRM_NO_ATOMIC não encontrado em sway-kiosk.service."
        SUGESTOES+=("Regenere o serviço rodando: sudo bash build/base/05-sway.sh")
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
secao "9. Pacotes de vídeo instalados"
# ─────────────────────────────────────────────────────────────────────────────
pacotes_video=(
    "sway"
    "libgl1-mesa-dri"
    "mesa-utils"
    "xserver-xorg-video-intel"
    "firmware-misc-nonfree"
    "intel-microcode"
)
for pkg in "${pacotes_video[@]}"; do
    if dpkg -l "$pkg" &>/dev/null 2>&1 && dpkg -l "$pkg" | grep -q '^ii'; then
        ver=$(dpkg -l "$pkg" 2>/dev/null | grep '^ii' | awk '{print $3}')
        ok "${pkg} ${ver}"
    else
        aviso "${pkg} não instalado"
        if [[ "$pkg" == "libgl1-mesa-dri" || "$pkg" == "xserver-xorg-video-intel" ]]; then
            SUGESTOES+=("Instale pacote de vídeo ausente: sudo apt install ${pkg}")
        fi
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
secao "10. Versão do kernel e módulos de vídeo"
# ─────────────────────────────────────────────────────────────────────────────
info "Kernel: $(uname -r)"
for mod in i915 amdgpu nouveau drm drm_kms_helper; do
    if lsmod | grep -q "^${mod}"; then
        ok "Módulo: ${mod} (carregado)"
    else
        info "Módulo: ${mod} (não carregado)"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# RESUMO DE SUGESTÕES
# ─────────────────────────────────────────────────────────────────────────────
titulo "Resumo de Sugestões"
if [[ ${#SUGESTOES[@]} -eq 0 ]]; then
    ok "Nenhum problema crítico identificado."
    info "Se ainda houver page-flip failures, colete logs completos com:"
    info "  journalctl --user -u sway-kiosk.service -n 100 --no-pager"
else
    i=1
    for sug in "${SUGESTOES[@]}"; do
        echo -e "  ${Y}${i}.${N} ${sug}"
        (( i++ ))
    done
fi

echo ""
info "Log completo do diagnóstico pode ser salvo com:"
info "  bash tests/diagnose-display.sh 2>&1 | tee /tmp/jett-display-diag.txt"
echo ""
