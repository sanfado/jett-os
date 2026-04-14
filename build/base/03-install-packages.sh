#!/usr/bin/env bash
# =============================================================================
# 03-install-packages.sh — ETAPA 3/7: Instala pacotes essenciais do Jett OS
# =============================================================================
# Uso direto (standalone):
#   sudo ./build/base/03-install-packages.sh
# Uso via orquestrador:
#   chamado automaticamente por build/build-base.sh
# =============================================================================

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Pacotes essenciais para o Jett OS funcionar
# Sway puxa libwayland-*, wayland-protocols e xkb como dependências automáticas.
PACOTES_INSTALAR=(
    # Sway — compositor Wayland tiling (principal)
    "sway"
    "xwayland"             # suporte a apps X11 (tkinter usado pelo jett-launcher)

    # Cage — mantido como fallback; inativo por padrão, mas instalado
    "cage"

    # Fontes essenciais para renderização no navegador
    "fonts-noto"           # cobre unicode amplo, incluindo emoji
    "fonts-noto-color-emoji"

    # Áudio — PulseAudio para suporte de som no navegador
    "pulseaudio"
    "pulseaudio-utils"

    # Utilitários mínimos de sistema
    "dbus-user-session"    # necessário para sessão Wayland do usuário
    "xdg-utils"            # integração desktop mínima para navegadores
    "ca-certificates"      # certificados TLS/SSL
    "curl"                 # transferências HTTP (usado em scripts)
    "wget"                 # downloads (instalação de navegadores)
    "gnupg"                # verificação de chaves GPG dos repositórios
    "apt-transport-https"  # repositórios via HTTPS

    # Rede — gerenciamento e consulta
    "networkd-dispatcher"  # hooks de evento para systemd-networkd
    "network-manager"      # gerenciador de redes (nmcli usado pelo jett-bridge)

    # Bluetooth
    "bluetooth"            # serviço bluetoothd (requerido por bluetoothctl)
    "bluez"                # stack Bluetooth (bluetoothctl, pairing, conexão)

    # Interfaces e controle do sistema
    "udisks2"              # montagem de dispositivos USB sem root (udisksctl)
    "python3"              # runtime para jett-ui-server
    "jq"                   # parsing de JSON em scripts shell
    "brightnessctl"        # controle de brilho do backlight
    "xdotool"              # controle de janelas X11 (nav — atalhos de teclado ao navegador)

    # GPU / drivers de vídeo — Intel HD Graphics e Mesa
    "mesa-utils"               # glxinfo, eglinfo — diagnóstico de GPU/OpenGL
    "libgl1-mesa-dri"          # driver DRI/Mesa para Intel/AMD/VMware via DRM
    "xserver-xorg-video-intel" # driver X11 Intel (legacy 2D; necessário para VGA via i915)
)

instalar_pacotes_essenciais() {
    log_separador
    log_etapa "ETAPA 3/7 — Instalando pacotes essenciais (Sway, Cage, fontes, áudio, utilitários)"

    export DEBIAN_FRONTEND=noninteractive

    local instalados=0
    local ja_presentes=0

    for pacote in "${PACOTES_INSTALAR[@]}"; do
        if pacote_instalado "$pacote"; then
            log_info "Já instalado: ${pacote} — pulando."
            (( ja_presentes++ )) || true
        else
            log_info "Instalando: ${pacote}..."
            apt-get install -y -qq "$pacote" >> "$LOG_ARQUIVO" 2>&1 \
                || log_erro "Falha ao instalar: ${pacote}. Verifique o log em ${LOG_ARQUIVO}"
            (( instalados++ )) || true
        fi
    done

    log_ok "Instalação concluída: ${instalados} novo(s), ${ja_presentes} já presente(s)."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    verificar_root
    instalar_pacotes_essenciais
fi
