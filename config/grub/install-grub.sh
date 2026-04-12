#!/usr/bin/env bash
# =============================================================================
# install-grub.sh — Instalação do GRUB customizado do Jett OS
# =============================================================================
# Descrição:
#   Detecta o modo de boot (BIOS/Legacy ou UEFI), instala o GRUB no local
#   correto, aplica as configurações e o tema do Jett OS, gera as fontes
#   necessárias para o tema e registra o serviço de seleção de navegador.
#
# Uso:
#   sudo ./install-grub.sh [--disco DISPOSITIVO] [--sem-tema] [--só-config]
#
# Opções:
#   --disco DISPOSITIVO  Disco alvo da instalação do GRUB (ex: /dev/sda, /dev/nvme0n1)
#                        Padrão: detectado automaticamente
#   --sem-tema           Aplica as configs mas pula a instalação do tema visual
#   --só-config          Apenas aplica configs e regenera grub.cfg — não reinstala GRUB
#
# Idempotência:
#   Seguro de executar múltiplas vezes. Faz backup dos arquivos que modifica.
#
# Pré-requisitos:
#   - build-base.sh executado com sucesso
#   - Pacotes: grub-pc (BIOS) ou grub-efi-amd64 (UEFI), grub-common
#   - Para as fontes do tema: grub-mkfont (pacote grub-common)
#   - Fontes TTF: fonts-dejavu-core (ou qualquer fonte sans-serif)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# VARIÁVEIS GLOBAIS
# -----------------------------------------------------------------------------

VERSAO_SCRIPT="1.0.0"
LOG_ARQUIVO="/var/log/jett-os-build.log"

# Diretório raiz do repositório do projeto (dois níveis acima deste script)
PROJETO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRUB_CONFIG_DIR="${PROJETO_DIR}/config/grub"

# Caminhos de destino no sistema
GRUB_THEMES_DIR="/boot/grub/themes/jett-os"
GRUB_DEFAULT_D="/etc/default/grub.d"
GRUB_D="/etc/grub.d"
GRUB_CFG="/boot/grub/grub.cfg"
GRUB_ENV="/boot/grub/grubenv"
SYSTEMD_SYSTEM="/etc/systemd/system"
JETT_CONF_DIR="/etc/jett-os"

# Flags de controle
INSTALAR_TEMA=true
SÓ_CONFIG=false
DISCO_ALVO=""         # detectado automaticamente se vazio

# Modo de boot: "uefi" ou "bios" (detectado)
MODO_BOOT=""

# Fontes TTF candidatas para geração das fontes do tema (em ordem de preferência)
FONTES_BOLD_CANDIDATAS=(
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"
    "/usr/share/fonts/truetype/freefont/FreeSansBold.ttf"
    "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf"
)
FONTES_REGULAR_CANDIDATAS=(
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"
    "/usr/share/fonts/truetype/freefont/FreeSans.ttf"
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf"
)

# Cores para saída no terminal
COR_RESET="\033[0m"
COR_VERDE="\033[1;32m"
COR_AMARELO="\033[1;33m"
COR_VERMELHO="\033[1;31m"
COR_CIANO="\033[1;36m"
COR_BRANCO="\033[1;37m"
COR_CINZA="\033[0;37m"

# -----------------------------------------------------------------------------
# FUNÇÕES DE LOG
# -----------------------------------------------------------------------------

inicializar_log() {
    mkdir -p "$(dirname "$LOG_ARQUIVO")"
    {
        echo "-------------------------------------------------------"
        echo "  install-grub.sh v${VERSAO_SCRIPT} — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "-------------------------------------------------------"
    } >> "$LOG_ARQUIVO"
}

log_etapa() {
    local msg="$1"; local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_CIANO}[${ts}] >>> ${msg}${COR_RESET}"
    echo "[${ts}] [ETAPA] ${msg}" >> "$LOG_ARQUIVO"
}

log_info() {
    local msg="$1"; local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_BRANCO}[${ts}]     ${msg}${COR_RESET}"
    echo "[${ts}] [INFO]  ${msg}" >> "$LOG_ARQUIVO"
}

log_ok() {
    local msg="$1"; local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_VERDE}[${ts}]  ✓  ${msg}${COR_RESET}"
    echo "[${ts}] [OK]    ${msg}" >> "$LOG_ARQUIVO"
}

log_aviso() {
    local msg="$1"; local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_AMARELO}[${ts}]  !  ${msg}${COR_RESET}"
    echo "[${ts}] [AVISO] ${msg}" >> "$LOG_ARQUIVO"
}

log_erro() {
    local msg="$1"; local ts; ts="$(date '+%H:%M:%S')"
    echo -e "${COR_VERMELHO}[${ts}]  ✗  ERRO: ${msg}${COR_RESET}" >&2
    echo "[${ts}] [ERRO]  ${msg}" >> "$LOG_ARQUIVO"
    exit 1
}

log_separador() {
    echo -e "${COR_CIANO}─────────────────────────────────────────────────${COR_RESET}"
}

# Cria backup de um arquivo com timestamp antes de modificá-lo
fazer_backup() {
    local arquivo="$1"
    if [[ -f "$arquivo" ]]; then
        local backup="${arquivo}.bak.$(date '+%Y%m%d_%H%M%S')"
        cp "$arquivo" "$backup"
        log_info "Backup criado: ${backup}"
    fi
}

# -----------------------------------------------------------------------------
# VERIFICAÇÕES
# -----------------------------------------------------------------------------

verificar_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_erro "Este script precisa ser executado como root. Use: sudo ./install-grub.sh"
    fi
}

verificar_dependencias() {
    local deps=("grub-install" "grub-mkconfig" "grub-mkfont" "grub-editenv")
    local faltando=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            faltando+=("$dep")
        fi
    done
    if [[ ${#faltando[@]} -gt 0 ]]; then
        log_aviso "Ferramentas ausentes: ${faltando[*]}"
        log_aviso "Instalando grub-common..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq grub-common \
            >> "$LOG_ARQUIVO" 2>&1 \
            || log_erro "Falha ao instalar grub-common."
    fi
}

# -----------------------------------------------------------------------------
# ETAPA 1: DETECÇÃO DO MODO DE BOOT (BIOS ou UEFI)
# -----------------------------------------------------------------------------

detectar_modo_boot() {
    log_separador
    log_etapa "ETAPA 1/7 — Detectando modo de boot (BIOS ou UEFI)"

    # Método 1: Verifica a presença do sistema de arquivos EFI montado
    if [[ -d /sys/firmware/efi ]]; then
        MODO_BOOT="uefi"
        log_ok "Sistema EFI detectado via /sys/firmware/efi"

    # Método 2: Verifica se a partição EFI está montada em /boot/efi
    elif mountpoint -q /boot/efi 2>/dev/null; then
        MODO_BOOT="uefi"
        log_ok "Partição EFI montada em /boot/efi detectada"

    # Método 3: Verifica variáveis EFI no kernel
    elif [[ -d /sys/firmware/efi/efivars ]]; then
        MODO_BOOT="uefi"
        log_ok "Variáveis EFI detectadas em /sys/firmware/efi/efivars"

    # Método 4: Verifica se grub-efi está instalado
    elif dpkg-query -W grub-efi-amd64 &>/dev/null 2>&1; then
        MODO_BOOT="uefi"
        log_ok "Pacote grub-efi-amd64 detectado"

    # Fallback: sem evidência de UEFI → assume BIOS/Legacy
    else
        MODO_BOOT="bios"
        log_ok "Nenhum indicador UEFI encontrado — modo BIOS/Legacy assumido"
    fi

    log_info "Modo de boot: ${MODO_BOOT^^}"

    # Verifica se os pacotes GRUB corretos estão instalados
    if [[ "$MODO_BOOT" == "uefi" ]]; then
        if ! dpkg-query -W grub-efi-amd64 &>/dev/null 2>&1; then
            log_info "grub-efi-amd64 não instalado. Instalando..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                grub-efi-amd64 grub-efi-amd64-bin \
                >> "$LOG_ARQUIVO" 2>&1 \
                || log_erro "Falha ao instalar grub-efi-amd64."
            log_ok "grub-efi-amd64 instalado."
        else
            log_info "grub-efi-amd64 já instalado."
        fi
    else
        if ! dpkg-query -W grub-pc &>/dev/null 2>&1; then
            log_info "grub-pc não instalado. Instalando..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq grub-pc \
                >> "$LOG_ARQUIVO" 2>&1 \
                || log_erro "Falha ao instalar grub-pc."
            log_ok "grub-pc instalado."
        else
            log_info "grub-pc já instalado."
        fi
    fi
}

# -----------------------------------------------------------------------------
# ETAPA 2: DETECÇÃO DO DISCO ALVO
# -----------------------------------------------------------------------------

detectar_disco_alvo() {
    log_separador
    log_etapa "ETAPA 2/7 — Detectando disco alvo para instalação do GRUB"

    if [[ -n "$DISCO_ALVO" ]]; then
        log_info "Disco especificado via argumento: ${DISCO_ALVO}"
    else
        # Método 1: Disco que contém a partição de /boot
        local dispositivo_boot
        dispositivo_boot="$(findmnt -n -o SOURCE /boot 2>/dev/null || findmnt -n -o SOURCE / 2>/dev/null)"

        if [[ -n "$dispositivo_boot" ]]; then
            # Remove número de partição para obter o disco (ex: /dev/sda1 → /dev/sda)
            # Suporta: /dev/sda1, /dev/nvme0n1p1, /dev/vda1
            if echo "$dispositivo_boot" | grep -qE 'nvme|mmcblk'; then
                # NVMe e eMMC: /dev/nvme0n1p1 → /dev/nvme0n1
                DISCO_ALVO="$(echo "$dispositivo_boot" | sed 's/p[0-9]*$//')"
            else
                # SATA/IDE/VirtIO: /dev/sda1 → /dev/sda
                DISCO_ALVO="$(echo "$dispositivo_boot" | sed 's/[0-9]*$//')"
            fi
            log_info "Disco detectado a partir de /boot: ${DISCO_ALVO}"
        fi
    fi

    # Validação: verifica se o dispositivo existe e é um disco de bloco
    if [[ -z "$DISCO_ALVO" ]]; then
        log_erro "Não foi possível detectar o disco. Use --disco /dev/sdX para especificar."
    fi

    if [[ ! -b "$DISCO_ALVO" ]]; then
        log_erro "Dispositivo '${DISCO_ALVO}' não é um dispositivo de bloco válido."
    fi

    # Exibe informações do disco para confirmação
    local disco_info
    disco_info="$(lsblk -dno SIZE,MODEL "${DISCO_ALVO}" 2>/dev/null || echo "info indisponível")"
    log_ok "Disco alvo: ${DISCO_ALVO} (${disco_info})"
}

# -----------------------------------------------------------------------------
# ETAPA 3: INSTALAÇÃO DO GRUB NO DISCO
# -----------------------------------------------------------------------------

instalar_grub_no_disco() {
    log_separador
    log_etapa "ETAPA 3/7 — Instalando GRUB no disco (${MODO_BOOT^^})"

    if ${SÓ_CONFIG}; then
        log_aviso "Modo --só-config ativo — pulando instalação do GRUB no disco."
        return
    fi

    if [[ "$MODO_BOOT" == "uefi" ]]; then
        # ── UEFI ────────────────────────────────────────────────────────────
        log_info "Instalando GRUB em modo UEFI..."

        # Garante que a partição EFI está montada
        if ! mountpoint -q /boot/efi 2>/dev/null; then
            log_aviso "/boot/efi não está montado."
            log_aviso "Monte a partição EFI antes de continuar:"
            log_aviso "  mount /dev/sdX1 /boot/efi  (substitua sdX1 pela partição EFI)"
            log_erro "Partição EFI não montada. Abortando."
        fi

        # grub-install em modo UEFI
        # --target=x86_64-efi: especifica a arquitetura EFI
        # --efi-directory: onde a partição EFI está montada
        # --bootloader-id: nome da entrada no firmware UEFI (aparece no boot menu da BIOS)
        # --recheck: força reavaliação mesmo se já instalado
        grub-install \
            --target=x86_64-efi \
            --efi-directory=/boot/efi \
            --bootloader-id="JettOS" \
            --recheck \
            >> "$LOG_ARQUIVO" 2>&1 \
            || log_erro "grub-install UEFI falhou. Verifique o log em ${LOG_ARQUIVO}"

        log_ok "GRUB instalado em modo UEFI."
        log_info "Entrada UEFI criada: 'JettOS' (visível no boot menu do firmware)"

        # Cria entrada de fallback no caminho padrão UEFI (/EFI/BOOT/BOOTX64.EFI)
        # Garante boot mesmo em firmwares que ignoram entradas customizadas
        local efi_boot_dir="/boot/efi/EFI/BOOT"
        local jett_efi_dir="/boot/efi/EFI/JettOS"
        if [[ -d "$jett_efi_dir" && -f "${jett_efi_dir}/grubx64.efi" ]]; then
            mkdir -p "$efi_boot_dir"
            cp "${jett_efi_dir}/grubx64.efi" "${efi_boot_dir}/BOOTX64.EFI" \
                >> "$LOG_ARQUIVO" 2>&1 || true
            log_info "Cópia de fallback criada: ${efi_boot_dir}/BOOTX64.EFI"
        fi

    else
        # ── BIOS/Legacy ─────────────────────────────────────────────────────
        log_info "Instalando GRUB em modo BIOS/Legacy no MBR de ${DISCO_ALVO}..."

        # grub-install em modo BIOS
        # --target=i386-pc: especifica a arquitetura BIOS x86
        # --recheck: força reavaliação do mapa de dispositivos
        grub-install \
            --target=i386-pc \
            --recheck \
            "${DISCO_ALVO}" \
            >> "$LOG_ARQUIVO" 2>&1 \
            || log_erro "grub-install BIOS falhou. Verifique o log em ${LOG_ARQUIVO}"

        log_ok "GRUB instalado no MBR de ${DISCO_ALVO} (modo BIOS/Legacy)."
    fi
}

# -----------------------------------------------------------------------------
# ETAPA 4: GERAÇÃO DAS FONTES DO TEMA
# -----------------------------------------------------------------------------

gerar_fontes_tema() {
    log_separador
    log_etapa "ETAPA 4/7 — Gerando fontes .pf2 para o tema GRUB"

    if ! ${INSTALAR_TEMA}; then
        log_aviso "Modo --sem-tema ativo — pulando geração de fontes."
        return
    fi

    # Verifica se grub-mkfont está disponível
    if ! command -v grub-mkfont &>/dev/null; then
        log_aviso "grub-mkfont não encontrado — tema será instalado sem fontes customizadas."
        log_aviso "O GRUB usará a fonte padrão (unicode). Visual pode ser diferente."
        return
    fi

    # Localiza a melhor fonte TTF bold disponível no sistema
    local fonte_bold=""
    for candidata in "${FONTES_BOLD_CANDIDATAS[@]}"; do
        if [[ -f "$candidata" ]]; then
            fonte_bold="$candidata"
            break
        fi
    done

    # Localiza a melhor fonte TTF regular disponível no sistema
    local fonte_regular=""
    for candidata in "${FONTES_REGULAR_CANDIDATAS[@]}"; do
        if [[ -f "$candidata" ]]; then
            fonte_regular="$candidata"
            break
        fi
    done

    # Se nenhuma fonte foi encontrada, tenta instalar fonts-dejavu-core
    if [[ -z "$fonte_bold" || -z "$fonte_regular" ]]; then
        log_info "Nenhuma fonte TTF encontrada. Instalando fonts-dejavu-core..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fonts-dejavu-core \
            >> "$LOG_ARQUIVO" 2>&1 || true
        # Tenta novamente após instalação
        fonte_bold="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
        fonte_regular="/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    fi

    if [[ ! -f "$fonte_bold" || ! -f "$fonte_regular" ]]; then
        log_aviso "Fontes TTF ainda não encontradas após tentativa de instalação."
        log_aviso "O tema usará a fonte padrão do GRUB."
        return
    fi

    log_info "Fonte bold    : ${fonte_bold}"
    log_info "Fonte regular : ${fonte_regular}"

    local fonts_dir="${GRUB_THEMES_DIR}/fonts"
    mkdir -p "$fonts_dir"

    # Definição das fontes a gerar:
    # Formato: "nome_pf2|arquivo_ttf|tamanho|nome_interno"
    # O nome_interno fica embutido no .pf2 e deve corresponder ao theme.txt
    declare -a FONTES_GERAR=(
        "jett-bold-24.pf2|${fonte_bold}|24|jett-bold-24"
        "jett-bold-16.pf2|${fonte_bold}|16|jett-bold-16"
        "jett-regular-16.pf2|${fonte_regular}|16|jett-regular-16"
        "jett-regular-12.pf2|${fonte_regular}|12|jett-regular-12"
    )

    local fontes_geradas=0
    for entrada in "${FONTES_GERAR[@]}"; do
        IFS='|' read -r arquivo_pf2 ttf_fonte tamanho nome_interno <<< "$entrada"
        local destino="${fonts_dir}/${arquivo_pf2}"

        if [[ -f "$destino" ]]; then
            log_info "Já existe: ${arquivo_pf2} — pulando (use --sem-tema para recriar)."
            continue
        fi

        log_info "Gerando: ${arquivo_pf2} (${tamanho}px, fonte: $(basename "$ttf_fonte"))..."
        grub-mkfont \
            --size="${tamanho}" \
            --name="${nome_interno}" \
            --output="${destino}" \
            "${ttf_fonte}" \
            >> "$LOG_ARQUIVO" 2>&1 \
            || log_aviso "Falha ao gerar ${arquivo_pf2} — o tema pode não exibir este tamanho."

        (( fontes_geradas++ )) || true
    done

    log_ok "${fontes_geradas} fonte(s) gerada(s) em ${fonts_dir}."
}

# -----------------------------------------------------------------------------
# ETAPA 5: GERAÇÃO DAS IMAGENS DO TEMA
# -----------------------------------------------------------------------------

gerar_imagens_tema() {
    log_separador
    log_etapa "ETAPA 5/7 — Gerando imagens PNG do tema (separador e seleção)"

    if ! ${INSTALAR_TEMA}; then
        log_aviso "Modo --sem-tema ativo — pulando geração de imagens."
        return
    fi

    # Usa Python3 para criar PNGs mínimos sem depender do ImageMagick
    # Python3 está sempre disponível no Debian
    if ! command -v python3 &>/dev/null; then
        log_aviso "python3 não encontrado — imagens do tema não serão geradas."
        log_aviso "O tema funcionará mas sem destaque visual no item selecionado."
        return
    fi

    log_info "Gerando imagens com Python3..."

    python3 << 'PYTHON_EOF'
import struct
import zlib
import os

def criar_png_solido(caminho, largura, altura, r, g, b):
    """
    Cria um PNG sólido RGB mínimo sem dependências externas.
    Usado para gerar as imagens minimalistas do tema GRUB do Jett OS.
    """
    def chunk(tipo, dados):
        c = tipo + dados
        return (
            struct.pack('>I', len(dados)) +
            c +
            struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)
        )

    # Assinatura PNG
    sig = b'\x89PNG\r\n\x1a\n'

    # IHDR: largura, altura, profundidade de cor, tipo RGB, compressão, filtro, interlace
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', largura, altura, 8, 2, 0, 0, 0))

    # IDAT: dados de pixel brutos (filtro none = 0x00 por linha)
    linhas = b''
    linha_pixel = bytes([r, g, b]) * largura
    for _ in range(altura):
        linhas += b'\x00' + linha_pixel  # byte de filtro + pixels

    idat = chunk(b'IDAT', zlib.compress(linhas, 9))

    # IEND
    iend = chunk(b'IEND', b'')

    os.makedirs(os.path.dirname(caminho) if os.path.dirname(caminho) else '.', exist_ok=True)
    with open(caminho, 'wb') as f:
        f.write(sig + ihdr + idat + iend)
    print(f"  Criado: {os.path.basename(caminho)} ({largura}x{altura}px)")

tema_dir = "/boot/grub/themes/jett-os"

# separator.png — linha horizontal fina branca
# Usada como divisor entre o título e o menu
# A largura é 1px — o GRUB a estira horizontalmente para cobrir o width= do component
criar_png_solido(
    os.path.join(tema_dir, "separator.png"),
    largura=1, altura=1,
    r=80, g=80, b=80   # cinza médio — visível mas discreto
)

# select_c.png — fundo do item selecionado no menu
# "c" = center, o sufixo que o GRUB usa para imagem única esticada
# Branco sólido: cria inversão máxima de contraste com o texto preto
criar_png_solido(
    os.path.join(tema_dir, "select_c.png"),
    largura=1, altura=36,   # altura = item_height do theme.txt
    r=255, g=255, b=255     # branco
)

print("Imagens geradas com sucesso.")
PYTHON_EOF

    log_ok "Imagens do tema geradas."
}

# -----------------------------------------------------------------------------
# ETAPA 6: APLICAÇÃO DAS CONFIGURAÇÕES DO GRUB
# -----------------------------------------------------------------------------

aplicar_configuracoes_grub() {
    log_separador
    log_etapa "ETAPA 6/7 — Aplicando configurações e tema do Jett OS"

    # ── 6a. Instala o tema ───────────────────────────────────────────────────
    if ${INSTALAR_TEMA}; then
        log_info "Copiando tema para ${GRUB_THEMES_DIR}..."
        mkdir -p "${GRUB_THEMES_DIR}"

        # Copia o theme.txt do repositório
        cp "${GRUB_CONFIG_DIR}/theme/theme.txt" "${GRUB_THEMES_DIR}/theme.txt" \
            || log_erro "Falha ao copiar theme.txt para ${GRUB_THEMES_DIR}."

        # Copia as fontes geradas (se existirem no diretório do tema do repositório)
        if ls "${GRUB_CONFIG_DIR}/theme/fonts/"*.pf2 &>/dev/null 2>&1; then
            mkdir -p "${GRUB_THEMES_DIR}/fonts"
            cp "${GRUB_CONFIG_DIR}/theme/fonts/"*.pf2 "${GRUB_THEMES_DIR}/fonts/" \
                >> "$LOG_ARQUIVO" 2>&1 || true
        fi

        log_ok "Tema instalado em ${GRUB_THEMES_DIR}."
    fi

    # ── 6b. Aplica as configurações do /etc/default/grub ────────────────────
    log_info "Aplicando configurações de boot do Jett OS..."

    if [[ -d "$GRUB_DEFAULT_D" ]]; then
        # Debian/Ubuntu moderno: usa /etc/default/grub.d/ para overrides modulares
        local grub_conf_dest="${GRUB_DEFAULT_D}/10-jett-os.cfg"
        fazer_backup "$grub_conf_dest"
        cp "${GRUB_CONFIG_DIR}/jett-os.grub" "$grub_conf_dest" \
            || log_erro "Falha ao copiar jett-os.grub para ${grub_conf_dest}."
        log_ok "Configurações aplicadas em ${grub_conf_dest}."
    else
        # Fallback: patch direto no /etc/default/grub
        log_aviso "/etc/default/grub.d/ não existe. Patching direto em /etc/default/grub."
        fazer_backup "/etc/default/grub"

        # Remove linhas que o jett-os.grub vai sobrescrever (para evitar duplicatas)
        local variaveis_patch=(
            "GRUB_DEFAULT" "GRUB_SAVEDEFAULT" "GRUB_TIMEOUT" "GRUB_TIMEOUT_STYLE"
            "GRUB_DISTRIBUTOR" "GRUB_CMDLINE_LINUX_DEFAULT" "GRUB_CMDLINE_LINUX"
            "GRUB_THEME" "GRUB_BACKGROUND" "GRUB_GFXMODE" "GRUB_GFXPAYLOAD_LINUX"
            "GRUB_TERMINAL_OUTPUT" "GRUB_DISABLE_OS_PROBER" "GRUB_DISABLE_RECOVERY"
        )
        for var in "${variaveis_patch[@]}"; do
            sed -i "/^${var}=/d" /etc/default/grub
        done

        # Adiciona as configurações do Jett OS ao final do arquivo
        echo "" >> /etc/default/grub
        echo "# === Jett OS — adicionado por install-grub.sh ===" >> /etc/default/grub
        grep -v "^#" "${GRUB_CONFIG_DIR}/jett-os.grub" | grep -v "^$" \
            >> /etc/default/grub || true

        log_ok "Configurações aplicadas em /etc/default/grub."
    fi

    # ── 6c. Instala o script de entradas do menu (grub.d) ───────────────────
    log_info "Instalando script de entradas de navegadores..."
    local grub_d_dest="${GRUB_D}/40_jett-os-browsers"
    fazer_backup "$grub_d_dest"
    cp "${GRUB_CONFIG_DIR}/40_jett-os-browsers" "$grub_d_dest" \
        || log_erro "Falha ao copiar 40_jett-os-browsers para ${GRUB_D}."
    chmod +x "$grub_d_dest"
    log_ok "Script de entradas instalado: ${grub_d_dest} (executável)."

    # ── 6d. Instala o serviço de seleção de navegador ───────────────────────
    log_info "Instalando jett-select-browser.service..."
    local svc_dest="${SYSTEMD_SYSTEM}/jett-select-browser.service"
    fazer_backup "$svc_dest"
    cp "${GRUB_CONFIG_DIR}/jett-select-browser.service" "$svc_dest" \
        || log_erro "Falha ao copiar jett-select-browser.service."
    systemctl daemon-reload >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "daemon-reload falhou — pode ser necessário reiniciar."
    systemctl enable jett-select-browser.service >> "$LOG_ARQUIVO" 2>&1 \
        || log_aviso "Não foi possível habilitar jett-select-browser.service."
    log_ok "jett-select-browser.service habilitado."

    # ── 6e. Inicializa o grubenv para GRUB_SAVEDEFAULT ──────────────────────
    log_info "Inicializando grubenv (memória de seleção)..."
    mkdir -p /boot/grub
    if [[ ! -f "$GRUB_ENV" ]]; then
        grub-editenv "$GRUB_ENV" create \
            >> "$LOG_ARQUIVO" 2>&1 \
            || log_aviso "Falha ao criar ${GRUB_ENV}."
        log_ok "grubenv criado em ${GRUB_ENV}."
    else
        log_info "grubenv já existe em ${GRUB_ENV} — preservando seleção atual."
    fi
}

# -----------------------------------------------------------------------------
# ETAPA 7: REGENERAÇÃO DO grub.cfg
# -----------------------------------------------------------------------------

regenerar_grub_cfg() {
    log_separador
    log_etapa "ETAPA 7/7 — Regenerando grub.cfg com as novas configurações"

    log_info "Executando grub-mkconfig..."
    log_info "(Isso pode levar alguns segundos...)"

    # Executa grub-mkconfig e captura a saída para o log
    # A flag -o especifica o arquivo de saída
    if grub-mkconfig -o "$GRUB_CFG" >> "$LOG_ARQUIVO" 2>&1; then
        log_ok "grub.cfg gerado com sucesso em ${GRUB_CFG}."
    else
        log_erro "grub-mkconfig falhou. Verifique o log em ${LOG_ARQUIVO}"
    fi

    # Verifica se as entradas do Jett OS foram incluídas no grub.cfg gerado
    local entradas_jett
    entradas_jett=$(grep -c "jett.browser=" "$GRUB_CFG" 2>/dev/null || echo "0")

    if (( entradas_jett == 0 )); then
        log_aviso "Nenhuma entrada 'jett.browser=' encontrada no grub.cfg gerado."
        log_aviso "Verifique se ${GRUB_D}/40_jett-os-browsers está executável e sem erros."
    else
        log_ok "${entradas_jett} entrada(s) de navegador encontrada(s) no grub.cfg."
    fi

    # Verifica se o tema foi referenciado corretamente
    if grep -q "jett-os" "$GRUB_CFG" 2>/dev/null; then
        log_ok "Tema Jett OS referenciado no grub.cfg."
    else
        log_aviso "Tema não encontrado no grub.cfg — o menu pode aparecer sem estilo."
        log_aviso "Verifique se GRUB_THEME está correto em ${GRUB_DEFAULT_D}/10-jett-os.cfg."
    fi
}

# -----------------------------------------------------------------------------
# RESUMO FINAL
# -----------------------------------------------------------------------------

exibir_resumo() {
    log_separador
    echo ""
    echo -e "${COR_VERDE}╔══════════════════════════════════════════════════╗${COR_RESET}"
    echo -e "${COR_VERDE}║     GRUB do Jett OS instalado com sucesso!       ║${COR_RESET}"
    echo -e "${COR_VERDE}╚══════════════════════════════════════════════════╝${COR_RESET}"
    echo ""
    echo -e "  Modo de boot     : ${COR_CIANO}${MODO_BOOT^^}${COR_RESET}"
    echo -e "  Disco alvo       : ${COR_CIANO}${DISCO_ALVO:-N/A (--só-config)}${COR_RESET}"
    echo -e "  Tema instalado   : ${COR_CIANO}${GRUB_THEMES_DIR}${COR_RESET}"
    echo -e "  grub.cfg gerado  : ${COR_CIANO}${GRUB_CFG}${COR_RESET}"
    echo -e "  Timeout          : ${COR_CIANO}5 segundos${COR_RESET}"
    echo -e "  Memoriza seleção : ${COR_CIANO}sim (GRUB_SAVEDEFAULT=true)${COR_RESET}"
    echo ""
    echo -e "  ${COR_AMARELO}Navegadores no menu:${COR_RESET}"
    echo -e "    ${COR_BRANCO}1. Brave Browser${COR_RESET}"
    echo -e "    ${COR_BRANCO}2. Microsoft Edge${COR_RESET}"
    echo -e "    ${COR_BRANCO}3. Thorium Browser${COR_RESET}"
    echo -e "    ${COR_BRANCO}4. Opera GX${COR_RESET}"
    echo -e "    ${COR_BRANCO}5. Firefox${COR_RESET}"
    echo ""
    echo -e "  ${COR_AMARELO}Próximos passos:${COR_RESET}"
    echo -e "    1. Reinicie para ver o menu GRUB customizado:"
    echo -e "       ${COR_CIANO}sudo reboot${COR_RESET}"
    echo -e "    2. Selecione um navegador — a escolha será memorizada"
    echo -e "    3. Para ajustar o timeout: edite GRUB_TIMEOUT em:"
    echo -e "       ${COR_CIANO}${GRUB_DEFAULT_D}/10-jett-os.cfg${COR_RESET}"
    echo -e "    4. Após editar qualquer conf, regenere o grub.cfg:"
    echo -e "       ${COR_CIANO}sudo grub-mkconfig -o /boot/grub/grub.cfg${COR_RESET}"
    echo ""
    log_separador
}

# -----------------------------------------------------------------------------
# PROCESSAMENTO DE ARGUMENTOS
# -----------------------------------------------------------------------------

processar_argumentos() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --disco)
                shift
                DISCO_ALVO="$1"
                ;;
            --sem-tema)
                INSTALAR_TEMA=false
                ;;
            --só-config|--so-config)
                SÓ_CONFIG=true
                ;;
            --help|-h)
                echo "Uso: sudo ./install-grub.sh [OPÇÕES]"
                echo ""
                echo "Opções:"
                echo "  --disco DISPOSITIVO  Disco alvo (ex: /dev/sda, /dev/nvme0n1)"
                echo "  --sem-tema           Pula instalação do tema visual"
                echo "  --só-config          Apenas configs e grub.cfg — sem grub-install"
                exit 0
                ;;
            *)
                log_erro "Argumento desconhecido: '$1'. Use --help."
                ;;
        esac
        shift
    done
}

# -----------------------------------------------------------------------------
# PONTO DE ENTRADA PRINCIPAL
# -----------------------------------------------------------------------------

main() {
    clear
    echo -e "${COR_CIANO}"
    echo "  ██████╗ ██████╗ ██╗   ██╗██████╗ "
    echo "  ██╔════╝██╔══██╗██║   ██║██╔══██╗"
    echo "  ██║ ███╗██████╔╝██║   ██║██████╔╝"
    echo "  ██║  ██║██╔══██╗██║   ██║██╔══██╗"
    echo "  ╚██████╔╝██║  ██║╚██████╔╝██████╔╝"
    echo "   ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ "
    echo -e "${COR_RESET}"
    echo -e "  ${COR_BRANCO}Instalação do GRUB — Jett OS v${VERSAO_SCRIPT}${COR_RESET}"
    echo ""

    processar_argumentos "$@"
    inicializar_log
    verificar_root
    verificar_dependencias

    # Exibe configuração que será aplicada
    log_info "Modo: $(${SÓ_CONFIG} && echo 'só-config' || echo 'instalação completa')"
    log_info "Tema: $(${INSTALAR_TEMA} && echo 'ativo' || echo 'desativado')"
    echo ""

    detectar_modo_boot
    detectar_disco_alvo
    instalar_grub_no_disco
    gerar_fontes_tema
    gerar_imagens_tema
    aplicar_configuracoes_grub
    regenerar_grub_cfg
    exibir_resumo
}

main "$@"
