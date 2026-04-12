#!/usr/bin/env bash
# =============================================================================
# latency-test.sh — Diagnóstico de performance do Jett OS
# =============================================================================
# Descrição:
#   Mede e registra três dimensões de performance do sistema:
#
#   [1] BOOT    — tempo do kernel até o navegador estar visível
#                 (via systemd-analyze blame e critical-chain)
#
#   [2] REDE    — latência para servidores de cloud gaming:
#                 Xbox Cloud Gaming (xcloud.microsoft.com)
#                 GeForce NOW (stadia.google.com, nvidia GFN endpoints)
#                 Medido com ping (RTT) e mtr (traceroute + perda de pacotes)
#
#   [3] SISTEMA — uso de RAM e CPU em estado idle
#                 (antes de qualquer aba ser aberta no navegador)
#
# Uso:
#   ./latency-test.sh [--só-boot | --só-rede | --só-sistema] [--mtr-ciclos N]
#
# Opções:
#   --só-boot       Executa apenas o teste de boot
#   --só-rede       Executa apenas o teste de rede
#   --só-sistema    Executa apenas o teste de sistema (RAM/CPU)
#   --mtr-ciclos N  Número de ciclos do mtr por host (padrão: 20)
#   --sem-mtr       Pula o mtr (mais rápido, apenas ping)
#
# Saída:
#   Terminal  — resumo colorido com avaliação pass/warn/fail
#   Arquivo   — relatório completo em /tests/results/YYYY-MM-DD_HH-MM-SS.txt
#               e snapshot JSON em /tests/results/YYYY-MM-DD_HH-MM-SS.json
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# VARIÁVEIS GLOBAIS
# -----------------------------------------------------------------------------

VERSAO_SCRIPT="1.0.0"

# Diretório de resultados (relativo ao script, resolvido para caminho absoluto)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"

# Timestamp único para nomear os arquivos desta execução
TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
RESULTADO_TXT="${RESULTS_DIR}/${TIMESTAMP}.txt"
RESULTADO_JSON="${RESULTS_DIR}/${TIMESTAMP}.json"

# Controle de quais testes executar (1 = sim, 0 = não)
TESTAR_BOOT=1
TESTAR_REDE=1
TESTAR_SISTEMA=1
USAR_MTR=1
MTR_CICLOS=20        # ciclos do mtr por host (mais ciclos = resultado mais preciso)
PING_CONTAGEM=20     # pacotes de ping por host

# --- Servidores alvo para teste de rede ------------------------------------
# Cada entrada: "NOME_EXIBICAO|HOST_OU_IP|DESCRICAO"
declare -a SERVIDORES_CLOUD_GAMING=(
    # Xbox Cloud Gaming (xCloud) — Microsoft Azure CDN
    "Xbox xCloud (Global CDN)|xcloud.microsoft.com|Xbox Cloud Gaming — endpoint global"
    "Xbox xCloud (East US)|eastus.cloudapp.azure.com|Microsoft Azure East US"
    "Xbox xCloud (West Europe)|westeurope.cloudapp.azure.com|Microsoft Azure West Europe"
    "Xbox xCloud (Brazil South)|brazilsouth.cloudapp.azure.com|Microsoft Azure Brazil South"

    # GeForce NOW — NVIDIA
    "GeForce NOW (Global)|geforcenow.com|NVIDIA GeForce NOW — endpoint global"
    "GeForce NOW (EU)|eu-prod1.gfnpc.com|NVIDIA GeForce NOW — Europa"
    "GeForce NOW (NA)|us-prod1.gfnpc.com|NVIDIA GeForce NOW — América do Norte"

    # Referências gerais para comparação
    "Cloudflare DNS (referência)|1.1.1.1|Cloudflare — referência de latência baixa"
    "Google DNS (referência)|8.8.8.8|Google — referência de latência moderada"
)

# --- Limites de avaliação para latência (ms) --------------------------------
# Cloud gaming exige < 40ms para experiência confortável
LIMITE_LATENCIA_OK=40      # verde  — excelente para cloud gaming
LIMITE_LATENCIA_AVISO=80   # amarelo — aceitável mas perceptível
# acima de 80ms → vermelho — inadequado para cloud gaming em tempo real

# --- Limites para RAM idle --------------------------------------------------
LIMITE_RAM_OK_MB=400       # verde  — sistema extremamente leve
LIMITE_RAM_AVISO_MB=700    # amarelo — ainda aceitável

# --- Limites para CPU idle --------------------------------------------------
LIMITE_CPU_OK=5            # verde  — CPU quase livre
LIMITE_CPU_AVISO=15        # amarelo — algum processo em background

# Cores para saída no terminal
COR_RESET="\033[0m"
COR_VERDE="\033[1;32m"
COR_AMARELO="\033[1;33m"
COR_VERMELHO="\033[1;31m"
COR_CIANO="\033[1;36m"
COR_BRANCO="\033[1;37m"
COR_CINZA="\033[0;37m"
COR_AZUL="\033[1;34m"

# Dados coletados — preenchidos pelas funções de medição
BOOT_FIRMWARE_S=""
BOOT_LOADER_S=""
BOOT_KERNEL_S=""
BOOT_INITRD_S=""
BOOT_USERSPACE_S=""
BOOT_TOTAL_S=""
BOOT_NAVEGADOR_S=""
RAM_TOTAL_MB=""
RAM_USADA_MB=""
RAM_LIVRE_MB=""
RAM_BUFFERS_MB=""
RAM_DISPONIVEL_MB=""
CPU_IDLE_PCT=""
CPU_USO_PCT=""
CPU_MODELO=""
CPU_NUCLEOS=""
NAVEGADOR_DETECTADO=""

# -----------------------------------------------------------------------------
# FUNÇÕES DE LOG E FORMATAÇÃO
# -----------------------------------------------------------------------------

# Escreve tanto no terminal quanto no arquivo de resultado
log_tee() {
    echo -e "$1" | tee -a "$RESULTADO_TXT"
}

# Versão sem cor para o arquivo (remove sequências ANSI)
log_arquivo() {
    echo "$1" >> "$RESULTADO_TXT"
}

# Cabeçalho de seção
log_secao() {
    local titulo="$1"
    local linha="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "${COR_CIANO}${linha}${COR_RESET}"
    echo -e "${COR_CIANO}  ${titulo}${COR_RESET}"
    echo -e "${COR_CIANO}${linha}${COR_RESET}"
    {
        echo ""
        echo "${linha}"
        echo "  ${titulo}"
        echo "${linha}"
    } >> "$RESULTADO_TXT"
}

# Resultado com avaliação colorida (pass / warn / fail)
log_metrica() {
    local nome="$1"
    local valor="$2"
    local status="$3"   # "ok" | "aviso" | "falha" | "info"
    local detalhe="${4:-}"

    local cor_status icone_status
    case "$status" in
        ok)    cor_status="$COR_VERDE";   icone_status="✓" ;;
        aviso) cor_status="$COR_AMARELO"; icone_status="!" ;;
        falha) cor_status="$COR_VERMELHO";icone_status="✗" ;;
        info)  cor_status="$COR_BRANCO";  icone_status="·" ;;
        *)     cor_status="$COR_BRANCO";  icone_status=" " ;;
    esac

    # Terminal — formatado com colunas e cor
    printf "${COR_BRANCO}  %-32s${COR_RESET} ${cor_status}%s %-20s${COR_RESET}" \
        "$nome" "$icone_status" "$valor"
    if [[ -n "$detalhe" ]]; then
        printf " ${COR_CINZA}%s${COR_RESET}" "$detalhe"
    fi
    echo ""

    # Arquivo — sem cores
    printf "  %-32s %s %-20s" "$nome" "$icone_status" "$valor" >> "$RESULTADO_TXT"
    [[ -n "$detalhe" ]] && printf " %s" "$detalhe" >> "$RESULTADO_TXT"
    echo "" >> "$RESULTADO_TXT"
}

# Avalia latência e retorna status (ok/aviso/falha)
avaliar_latencia() {
    local ms="$1"
    # ms pode ser decimal (ex: 12.345) — compara com bc
    if [[ "$ms" == "TIMEOUT" || "$ms" == "ERRO" ]]; then
        echo "falha"
    elif (( $(echo "$ms < $LIMITE_LATENCIA_OK" | bc -l) )); then
        echo "ok"
    elif (( $(echo "$ms < $LIMITE_LATENCIA_AVISO" | bc -l) )); then
        echo "aviso"
    else
        echo "falha"
    fi
}

# Avalia uso de RAM em MB e retorna status
avaliar_ram() {
    local mb="$1"
    if (( mb < LIMITE_RAM_OK_MB )); then
        echo "ok"
    elif (( mb < LIMITE_RAM_AVISO_MB )); then
        echo "aviso"
    else
        echo "falha"
    fi
}

# Avalia % de CPU e retorna status
avaliar_cpu() {
    local pct="$1"
    # Remove decimal para comparação inteira
    local pct_int="${pct%.*}"
    if (( pct_int < LIMITE_CPU_OK )); then
        echo "ok"
    elif (( pct_int < LIMITE_CPU_AVISO )); then
        echo "aviso"
    else
        echo "falha"
    fi
}

# Formata segundos em string legível (ex: 3.421s ou 1m 23.4s)
formatar_segundos() {
    local valor="$1"
    # Detecta se é número decimal
    if [[ "$valor" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        local inteiro="${valor%.*}"
        if (( inteiro >= 60 )); then
            local minutos=$(( inteiro / 60 ))
            local resto
            resto=$(echo "$valor - $minutos * 60" | bc -l)
            printf "%dm %.1fs" "$minutos" "$resto"
        else
            printf "%.3fs" "$valor"
        fi
    else
        echo "$valor"
    fi
}

# -----------------------------------------------------------------------------
# VERIFICAÇÃO DE DEPENDÊNCIAS
# -----------------------------------------------------------------------------

verificar_dependencias() {
    local deps_obrigatorias=("ping" "awk" "grep" "free" "top" "bc" "date" "tee")
    local deps_opcionais=("mtr" "systemd-analyze" "journalctl" "lscpu" "vmstat")
    local faltando=()
    local opcionais_ausentes=()

    for dep in "${deps_obrigatorias[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            faltando+=("$dep")
        fi
    done

    for dep in "${deps_opcionais[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            opcionais_ausentes+=("$dep")
        fi
    done

    if [[ ${#faltando[@]} -gt 0 ]]; then
        echo -e "${COR_VERMELHO}ERRO: Dependências obrigatórias não encontradas:${COR_RESET}"
        echo -e "${COR_VERMELHO}  ${faltando[*]}${COR_RESET}"
        echo ""
        echo "Instale com: sudo apt install ${faltando[*]}"
        exit 1
    fi

    if [[ ${#opcionais_ausentes[@]} -gt 0 ]]; then
        echo -e "${COR_AMARELO}Aviso: Ferramentas opcionais ausentes: ${opcionais_ausentes[*]}${COR_RESET}"
        echo -e "${COR_AMARELO}       Alguns testes serão pulados ou simplificados.${COR_RESET}"
        echo ""

        # Desativa mtr se não disponível
        if ! command -v mtr &>/dev/null; then
            USAR_MTR=0
            echo -e "${COR_AMARELO}  → mtr não encontrado: instale com 'sudo apt install mtr'${COR_RESET}"
            echo -e "${COR_AMARELO}    Continuando apenas com ping.${COR_RESET}"
        fi
    fi
}

# -----------------------------------------------------------------------------
# TESTE 1: TEMPO DE BOOT
# -----------------------------------------------------------------------------

testar_boot() {
    log_secao "TESTE 1/3 — TEMPO DE BOOT (kernel → navegador visível)"

    # Verifica se systemd está disponível
    if ! command -v systemd-analyze &>/dev/null; then
        log_tee "${COR_AMARELO}  systemd-analyze não disponível — pulando teste de boot.${COR_RESET}"
        log_tee "${COR_AMARELO}  (Este teste requer systemd como init do sistema)${COR_RESET}"
        return
    fi

    echo -e "${COR_BRANCO}  Coletando dados do systemd-analyze...${COR_RESET}"

    # --- Tempo total de boot (firmware + bootloader + kernel + userspace) ----
    local blame_output
    blame_output=$(systemd-analyze 2>/dev/null || echo "")

    if [[ -z "$blame_output" ]]; then
        log_tee "${COR_AMARELO}  Não foi possível obter dados do systemd-analyze.${COR_RESET}"
        log_tee "${COR_AMARELO}  Isso é normal se o sistema foi iniciado há muito tempo ou em VM.${COR_RESET}"
    else
        # Extrai os tempos do firmware, bootloader, kernel e userspace
        # Formato de saída: "Startup finished in Xs (firmware) + Xs (loader) + Xs (kernel) + Xs (userspace) = Xs"
        BOOT_FIRMWARE_S=$(echo "$blame_output" | grep -oP '\K[0-9.]+(?=s \(firmware\))' || echo "N/A")
        BOOT_LOADER_S=$(echo "$blame_output" | grep -oP '\K[0-9.]+(?=s \(loader\))' || echo "N/A")
        BOOT_KERNEL_S=$(echo "$blame_output" | grep -oP '\K[0-9.]+(?=s \(kernel\))' || echo "N/A")
        BOOT_USERSPACE_S=$(echo "$blame_output" | grep -oP '\K[0-9.]+(?=s \(userspace\))' || echo "N/A")
        BOOT_TOTAL_S=$(echo "$blame_output" | grep -oP 'finished in \K[^.]+\.[0-9]+' | head -1 || echo "N/A")

        # Exibe tempos por fase
        log_metrica "Firmware (UEFI/BIOS)" \
            "$(formatar_segundos "$BOOT_FIRMWARE_S")" "info" \
            "tempo antes do bootloader"

        log_metrica "Bootloader (GRUB)" \
            "$(formatar_segundos "$BOOT_LOADER_S")" "info" \
            "tempo do GRUB"

        log_metrica "Kernel + initrd" \
            "$(formatar_segundos "$BOOT_KERNEL_S")" "info" \
            "descompressão + drivers"

        log_metrica "Userspace (systemd)" \
            "$(formatar_segundos "$BOOT_USERSPACE_S")" "info" \
            "serviços até multi-user.target"

        # Avalia o tempo total
        local status_boot="info"
        if [[ "$BOOT_TOTAL_S" != "N/A" ]]; then
            local total_int="${BOOT_TOTAL_S%.*}"
            if (( total_int < 10 )); then
                status_boot="ok"
            elif (( total_int < 20 )); then
                status_boot="aviso"
            else
                status_boot="falha"
            fi
        fi

        log_metrica "TOTAL (POST → userspace)" \
            "$(formatar_segundos "$BOOT_TOTAL_S")" "$status_boot" \
            "meta Jett OS: < 10s"
    fi

    # --- Tempo do navegador (via systemd-analyze blame) ----------------------
    echo ""
    echo -e "${COR_BRANCO}  Buscando tempo de inicialização do serviço do navegador...${COR_RESET}"

    # BUG D fix: detecção com escopo correto por serviço.
    #
    # Arquitetura dos serviços no Jett OS:
    #   brave-kiosk.service → existe como serviço de SISTEMA (/etc/systemd/system/)
    #                         E como serviço de USUÁRIO (~/.config/systemd/user/)
    #   cage-kiosk.service  → existe APENAS como serviço de USUÁRIO
    #                         (gerado pelo build-base.sh em ~/.config/systemd/user/)
    #
    # Usar 'systemctl' (escopo sistema) para cage-kiosk nunca encontra nada.
    # Usar 'systemd-analyze blame' sem '--user' não mostra serviços de usuário.

    local servico_navegador=""
    local servico_escopo=""           # "system" ou "user"
    local uid_jett
    uid_jett=$(id -u "$USUARIO_JETT" 2>/dev/null || echo "1000")
    local xdg_runtime="/run/user/${uid_jett}"

    # 1ª tentativa: serviço de sistema (brave-kiosk instalado pelo install-brave.sh)
    for svc in brave-kiosk.service; do
        if systemctl is-active "$svc" &>/dev/null || \
           systemctl list-units --all 2>/dev/null | grep -q "$svc"; then
            servico_navegador="$svc"
            servico_escopo="system"
            break
        fi
    done

    # 2ª tentativa: serviço de usuário (tanto brave-kiosk quanto cage-kiosk)
    if [[ -z "$servico_navegador" ]]; then
        for svc in brave-kiosk.service cage-kiosk.service; do
            if su -l "$USUARIO_JETT" -c \
               "XDG_RUNTIME_DIR=${xdg_runtime} systemctl --user is-active ${svc}" \
               &>/dev/null 2>&1; then
                servico_navegador="$svc"
                servico_escopo="user"
                break
            fi
            # Verifica também se está habilitado (pode não estar ativo se o boot ainda não ocorreu)
            if su -l "$USUARIO_JETT" -c \
               "XDG_RUNTIME_DIR=${xdg_runtime} systemctl --user is-enabled ${svc}" \
               &>/dev/null 2>&1; then
                servico_navegador="$svc"
                servico_escopo="user"
                break
            fi
        done
    fi

    if [[ -n "$servico_navegador" ]]; then
        local tempo_servico
        # Usa o escopo correto para o blame: --user para serviços de usuário
        if [[ "$servico_escopo" == "user" ]]; then
            tempo_servico=$(su -l "$USUARIO_JETT" -c \
                "XDG_RUNTIME_DIR=${xdg_runtime} systemd-analyze --user blame 2>/dev/null | \
                 grep '${servico_navegador}' | awk '{print \$1}' | head -1" \
                2>/dev/null || echo "N/A")
        else
            tempo_servico=$(systemd-analyze blame 2>/dev/null | \
                grep "$servico_navegador" | \
                awk '{print $1}' | head -1 || echo "N/A")
        fi
        BOOT_NAVEGADOR_S="${tempo_servico:-N/A}"
        log_metrica "Serviço do navegador ($servico_navegador)" \
            "${BOOT_NAVEGADOR_S}" "info" "escopo: ${servico_escopo}"
    else
        log_metrica "Serviço do navegador" \
            "não encontrado" "aviso" "nenhum serviço kiosk ativo ou habilitado"
        BOOT_NAVEGADOR_S="N/A"
    fi

    # --- Top 5 serviços mais lentos no boot ----------------------------------
    echo ""
    echo -e "${COR_BRANCO}  Top 5 serviços mais lentos no boot:${COR_RESET}"
    log_arquivo ""
    log_arquivo "  Top 5 serviços mais lentos no boot:"

    local blame_lista
    blame_lista=$(systemd-analyze blame 2>/dev/null | head -5 || echo "  (não disponível)")

    while IFS= read -r linha; do
        echo -e "  ${COR_CINZA}${linha}${COR_RESET}"
        echo "  ${linha}" >> "$RESULTADO_TXT"
    done <<< "$blame_lista"

    # --- Critical chain ------------------------------------------------------
    echo ""
    echo -e "${COR_BRANCO}  Cadeia crítica de boot (critical-chain):${COR_RESET}"
    log_arquivo ""
    log_arquivo "  Cadeia crítica de boot:"

    local chain_output
    chain_output=$(systemd-analyze critical-chain 2>/dev/null || echo "  (não disponível)")

    while IFS= read -r linha; do
        echo -e "  ${COR_CINZA}${linha}${COR_RESET}"
        echo "  ${linha}" >> "$RESULTADO_TXT"
    done <<< "$chain_output"
}

# -----------------------------------------------------------------------------
# TESTE 2: LATÊNCIA DE REDE
# -----------------------------------------------------------------------------

# Executa ping para um host e retorna RTT médio em ms
# Retorna "TIMEOUT" se não houver resposta
executar_ping() {
    local host="$1"
    local contagem="${2:-$PING_CONTAGEM}"

    local saida_ping
    saida_ping=$(ping -c "$contagem" -W 3 -q "$host" 2>/dev/null || echo "TIMEOUT")

    if [[ "$saida_ping" == "TIMEOUT" ]] || echo "$saida_ping" | grep -q "100% packet loss"; then
        echo "TIMEOUT"
        return
    fi

    # Extrai RTT médio da linha: "rtt min/avg/max/mdev = X.X/X.X/X.X/X.X ms"
    local rtt_avg
    rtt_avg=$(echo "$saida_ping" | grep -oP 'rtt.*= \K[0-9.]+/\K[0-9.]+' || echo "")

    if [[ -z "$rtt_avg" ]]; then
        echo "ERRO"
    else
        echo "$rtt_avg"
    fi
}

# Executa mtr para um host e retorna perda de pacotes e RTT médio
executar_mtr() {
    local host="$1"
    local ciclos="${2:-$MTR_CICLOS}"

    if [[ "$USAR_MTR" -eq 0 ]]; then
        echo "N/A|N/A"
        return
    fi

    # mtr --report: saída tabular. Último hop = destino
    # Requer: mtr instalado (sudo apt install mtr)
    local saida_mtr
    saida_mtr=$(mtr --report --report-cycles "$ciclos" --no-dns "$host" 2>/dev/null || echo "ERRO")

    if [[ "$saida_mtr" == "ERRO" ]]; then
        echo "ERRO|ERRO"
        return
    fi

    # Último hop da tabela mtr: coluna Loss% e Avg
    local ultimo_hop
    ultimo_hop=$(echo "$saida_mtr" | tail -1)

    local perda_pct
    perda_pct=$(echo "$ultimo_hop" | awk '{print $3}' | tr -d '%' || echo "?")

    local rtt_avg_mtr
    rtt_avg_mtr=$(echo "$ultimo_hop" | awk '{print $5}' || echo "?")

    echo "${perda_pct}|${rtt_avg_mtr}"
}

testar_rede() {
    log_secao "TESTE 2/3 — LATÊNCIA DE REDE (cloud gaming)"

    echo -e "${COR_BRANCO}  Hosts alvos: ${#SERVIDORES_CLOUD_GAMING[@]}${COR_RESET}"
    echo -e "${COR_BRANCO}  Ping: ${PING_CONTAGEM} pacotes por host${COR_RESET}"
    [[ "$USAR_MTR" -eq 1 ]] && \
        echo -e "${COR_BRANCO}  mtr:  ${MTR_CICLOS} ciclos por host${COR_RESET}" || \
        echo -e "${COR_AMARELO}  mtr:  desabilitado (use --mtr-ciclos ou instale mtr)${COR_RESET}"
    echo ""

    log_arquivo ""
    log_arquivo "  Hosts testados: ${#SERVIDORES_CLOUD_GAMING[@]}"
    log_arquivo "  Pacotes ping por host: ${PING_CONTAGEM}"
    log_arquivo "  Ciclos mtr por host: ${MTR_CICLOS}"
    log_arquivo ""

    # Cabeçalho da tabela de resultados
    printf "${COR_CIANO}  %-30s %-12s %-12s %-10s %-10s${COR_RESET}\n" \
        "HOST" "PING AVG" "MTR AVG" "PERDA%" "STATUS"
    printf "${COR_CIANO}  %-30s %-12s %-12s %-10s %-10s${COR_RESET}\n" \
        "──────────────────────────────" "────────────" "────────────" "──────────" "──────────"
    printf "  %-30s %-12s %-12s %-10s %-10s\n" \
        "HOST" "PING AVG" "MTR AVG" "PERDA%" "STATUS" >> "$RESULTADO_TXT"

    # Contadores para o resumo
    local total_hosts=0
    local hosts_ok=0
    local hosts_aviso=0
    local hosts_falha=0

    # Armazena resultados para o JSON
    local json_rede="["

    for entrada in "${SERVIDORES_CLOUD_GAMING[@]}"; do
        IFS='|' read -r nome host descricao <<< "$entrada"
        (( total_hosts++ )) || true

        echo -ne "${COR_BRANCO}  Testando: ${nome}...${COR_RESET}\r"

        # Executa ping
        local ping_ms
        ping_ms=$(executar_ping "$host" "$PING_CONTAGEM")

        # Executa mtr (em background para não bloquear muito)
        local mtr_resultado="N/A|N/A"
        if [[ "$USAR_MTR" -eq 1 ]]; then
            mtr_resultado=$(executar_mtr "$host" "$MTR_CICLOS")
        fi

        local mtr_perda
        mtr_perda=$(echo "$mtr_resultado" | cut -d'|' -f1)
        local mtr_avg
        mtr_avg=$(echo "$mtr_resultado" | cut -d'|' -f2)

        # Avalia qualidade da conexão
        local status
        status=$(avaliar_latencia "$ping_ms")

        # Formata para exibição
        local ping_display mtr_display perda_display cor_status icone
        if [[ "$ping_ms" == "TIMEOUT" || "$ping_ms" == "ERRO" ]]; then
            ping_display="timeout"
            mtr_display="N/A"
            perda_display="100%"
        else
            ping_display="${ping_ms}ms"
            mtr_display="${mtr_avg}ms"
            perda_display="${mtr_perda}%"
        fi

        case "$status" in
            ok)    cor_status="$COR_VERDE";    icone="✓ EXCELENTE" ; (( hosts_ok++ ))    || true ;;
            aviso) cor_status="$COR_AMARELO";  icone="! ACEITÁVEL" ; (( hosts_aviso++ )) || true ;;
            falha) cor_status="$COR_VERMELHO"; icone="✗ ALTO/FALHA"; (( hosts_falha++ )) || true ;;
        esac

        # Limpa a linha de progresso e exibe resultado
        printf "  %-30s ${cor_status}%-12s %-12s %-10s %-10s${COR_RESET}\n" \
            "${nome:0:30}" "$ping_display" "$mtr_display" "$perda_display" "$icone"

        # Arquivo sem cores
        printf "  %-30s %-12s %-12s %-10s %-10s\n" \
            "${nome:0:30}" "$ping_display" "$mtr_display" "$perda_display" "$icone" \
            >> "$RESULTADO_TXT"

        # Acumula JSON
        json_rede+="{\"host\":\"${host}\",\"nome\":\"${nome}\",\"ping_ms\":\"${ping_ms}\",\"mtr_avg\":\"${mtr_avg}\",\"perda_pct\":\"${mtr_perda}\",\"status\":\"${status}\"},"
    done

    # Fecha array JSON (remove última vírgula)
    json_rede="${json_rede%,}]"

    # Salva para uso no relatório JSON
    REDE_JSON_RESULTADOS="$json_rede"

    echo ""
    echo ""
    log_arquivo ""

    # Resumo dos resultados de rede
    log_metrica "Hosts testados" "$total_hosts" "info"
    log_metrica "Excelentes (< ${LIMITE_LATENCIA_OK}ms)" "$hosts_ok" \
        "$([ "$hosts_ok" -gt 0 ] && echo ok || echo info)"
    log_metrica "Aceitáveis (${LIMITE_LATENCIA_OK}–${LIMITE_LATENCIA_AVISO}ms)" "$hosts_aviso" \
        "$([ "$hosts_aviso" -gt 0 ] && echo aviso || echo info)"
    log_metrica "Altos/timeout (> ${LIMITE_LATENCIA_AVISO}ms)" "$hosts_falha" \
        "$([ "$hosts_falha" -gt 0 ] && echo falha || echo info)"
}

# -----------------------------------------------------------------------------
# TESTE 3: USO DE RAM E CPU EM IDLE
# -----------------------------------------------------------------------------

testar_sistema() {
    log_secao "TESTE 3/3 — USO DE SISTEMA EM IDLE (RAM e CPU)"

    # --- Coleta de informações do hardware -----------------------------------
    echo -e "${COR_BRANCO}  Coletando informações de hardware...${COR_RESET}"

    # CPU — modelo e núcleos
    if command -v lscpu &>/dev/null; then
        CPU_MODELO=$(lscpu | grep -E "^Model name" | sed 's/Model name:\s*//' | xargs)
        CPU_NUCLEOS=$(lscpu | grep -E "^CPU\(s\):" | awk '{print $2}')
        local cpu_freq
        cpu_freq=$(lscpu | grep -E "^CPU MHz:" | awk '{printf "%.0f", $3}' || echo "?")
        local cpu_arch
        cpu_arch=$(lscpu | grep -E "^Architecture:" | awk '{print $2}')
    else
        CPU_MODELO="$(cat /proc/cpuinfo | grep 'model name' | head -1 | cut -d':' -f2 | xargs)"
        CPU_NUCLEOS="$(nproc)"
        cpu_freq="?"
        cpu_arch="?"
    fi

    log_metrica "CPU modelo" "${CPU_MODELO:0:40}" "info"
    log_metrica "CPU núcleos" "$CPU_NUCLEOS" "info"
    log_metrica "CPU freq atual (MHz)" "${cpu_freq:-?}" "info"
    log_metrica "CPU arquitetura" "${cpu_arch:-?}" "info"

    echo ""

    # --- RAM -----------------------------------------------------------------
    echo -e "${COR_BRANCO}  Medindo uso de memória RAM...${COR_RESET}"

    # 'free -m' exibe em megabytes
    # Linha "Mem:": total  usado  livre  compartilhado  buff/cache  disponível
    local free_saida
    free_saida=$(free -m)

    RAM_TOTAL_MB=$(echo "$free_saida" | awk '/^Mem:/ {print $2}')
    RAM_USADA_MB=$(echo "$free_saida" | awk '/^Mem:/ {print $3}')
    RAM_LIVRE_MB=$(echo "$free_saida" | awk '/^Mem:/ {print $4}')
    RAM_BUFFERS_MB=$(echo "$free_saida" | awk '/^Mem:/ {print $6}')    # buff/cache
    RAM_DISPONIVEL_MB=$(echo "$free_saida" | awk '/^Mem:/ {print $7}')  # disponível real

    # % de uso
    local ram_pct_uso
    ram_pct_uso=$(echo "scale=1; $RAM_USADA_MB * 100 / $RAM_TOTAL_MB" | bc -l)

    local status_ram
    status_ram=$(avaliar_ram "$RAM_USADA_MB")

    log_metrica "RAM total" "${RAM_TOTAL_MB} MB" "info"
    log_metrica "RAM usada (idle)" "${RAM_USADA_MB} MB (${ram_pct_uso}%)" "$status_ram" \
        "meta Jett OS: < ${LIMITE_RAM_OK_MB}MB"
    log_metrica "RAM disponível" "${RAM_DISPONIVEL_MB} MB" "info"
    log_metrica "RAM buff/cache" "${RAM_BUFFERS_MB} MB" "info" \
        "(recuperável pelo SO quando necessário)"

    echo ""

    # --- CPU idle ------------------------------------------------------------
    echo -e "${COR_BRANCO}  Medindo uso de CPU (média de 3 amostras com intervalo de 1s)...${COR_RESET}"

    # Coleta 3 amostras de CPU e calcula média
    # Usa /proc/stat para leitura direta sem dependência de ferramentas extras
    local amostras_cpu=()
    for i in 1 2 3; do
        # Lê /proc/stat duas vezes com intervalo de 1s para calcular delta
        local stat1 stat2
        stat1=$(awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8}' /proc/stat)
        sleep 1
        stat2=$(awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8}' /proc/stat)

        # Calcula tempo idle e total a partir do delta
        local idle_delta total_delta
        idle_delta=$(awk -v s1="$stat1" -v s2="$stat2" 'BEGIN {
            split(s1, a, " "); split(s2, b, " ");
            idle = b[4] - a[4];
            total = 0;
            for(i=1; i<=7; i++) total += b[i] - a[i];
            printf "%.2f", idle
        }')
        total_delta=$(awk -v s1="$stat1" -v s2="$stat2" 'BEGIN {
            split(s1, a, " "); split(s2, b, " ");
            total = 0;
            for(i=1; i<=7; i++) total += b[i] - a[i];
            printf "%.2f", total
        }')

        local uso_amostra
        uso_amostra=$(echo "scale=2; (1 - $idle_delta / $total_delta) * 100" | bc -l 2>/dev/null || echo "0")
        amostras_cpu+=("$uso_amostra")
    done

    # Média das 3 amostras
    CPU_USO_PCT=$(echo "${amostras_cpu[*]}" | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; printf "%.1f", s/NF}')
    CPU_IDLE_PCT=$(echo "scale=1; 100 - $CPU_USO_PCT" | bc -l)

    local status_cpu
    status_cpu=$(avaliar_cpu "$CPU_USO_PCT")

    log_metrica "CPU uso (idle)" "${CPU_USO_PCT}%" "$status_cpu" \
        "meta Jett OS: < ${LIMITE_CPU_OK}%"
    log_metrica "CPU idle" "${CPU_IDLE_PCT}%" "info"

    # Amostras individuais para transparência
    log_metrica "Amostras (3x 1s)" \
        "$(printf "%.1f%% / %.1f%% / %.1f%%" "${amostras_cpu[@]}")" "info"

    echo ""

    # --- Processos em execução -----------------------------------------------
    echo -e "${COR_BRANCO}  Top 10 processos por uso de memória:${COR_RESET}"
    log_arquivo ""
    log_arquivo "  Top 10 processos por uso de memória:"

    # ps com RSS (Resident Set Size) em KB, convertido para MB
    local proc_lista
    proc_lista=$(ps aux --sort=-%mem | awk 'NR>1 && NR<=11 {
        printf "  %-8s %-20s %5s%% %5.0fMB\n", $1, substr($11,1,20), $4, $6/1024
    }')

    while IFS= read -r linha; do
        echo -e "  ${COR_CINZA}${linha}${COR_RESET}"
        echo "  ${linha}" >> "$RESULTADO_TXT"
    done <<< "$proc_lista"

    echo ""

    # --- Navegador detectado -------------------------------------------------
    echo -e "${COR_BRANCO}  Detectando navegador ativo...${COR_RESET}"

    for nav in brave-browser microsoft-edge thorium-browser opera firefox; do
        if pgrep -x "$nav" &>/dev/null 2>&1; then
            NAVEGADOR_DETECTADO="$nav"
            break
        fi
    done

    if [[ -z "$NAVEGADOR_DETECTADO" ]]; then
        NAVEGADOR_DETECTADO="nenhum detectado"
        log_metrica "Navegador em execução" "$NAVEGADOR_DETECTADO" "aviso" \
            "(execute o teste com o navegador já aberto)"
    else
        log_metrica "Navegador em execução" "$NAVEGADOR_DETECTADO" "info"
        # Uso de RAM específico do navegador
        local ram_nav_mb
        ram_nav_mb=$(ps aux | grep "$NAVEGADOR_DETECTADO" | \
            awk '{sum += $6} END {printf "%.0f", sum/1024}')
        log_metrica "RAM do navegador" "${ram_nav_mb} MB" "info" \
            "(soma de todos os processos)"
    fi
}

# -----------------------------------------------------------------------------
# RELATÓRIO FINAL E JSON
# -----------------------------------------------------------------------------

gerar_relatorio_json() {
    local json_rede="${REDE_JSON_RESULTADOS:-[]}"

    cat > "$RESULTADO_JSON" << EOF
{
  "jett_os_latency_report": {
    "versao_script": "${VERSAO_SCRIPT}",
    "timestamp": "${TIMESTAMP}",
    "data_hora": "$(date '+%Y-%m-%d %H:%M:%S')",
    "hostname": "$(hostname)",
    "kernel": "$(uname -r)",

    "boot": {
      "firmware_s": "${BOOT_FIRMWARE_S}",
      "bootloader_s": "${BOOT_LOADER_S}",
      "kernel_s": "${BOOT_KERNEL_S}",
      "userspace_s": "${BOOT_USERSPACE_S}",
      "total_s": "${BOOT_TOTAL_S}",
      "navegador_s": "${BOOT_NAVEGADOR_S}"
    },

    "sistema": {
      "cpu_modelo": "${CPU_MODELO}",
      "cpu_nucleos": "${CPU_NUCLEOS}",
      "cpu_uso_pct": "${CPU_USO_PCT}",
      "cpu_idle_pct": "${CPU_IDLE_PCT}",
      "ram_total_mb": "${RAM_TOTAL_MB}",
      "ram_usada_mb": "${RAM_USADA_MB}",
      "ram_disponivel_mb": "${RAM_DISPONIVEL_MB}",
      "ram_buffers_mb": "${RAM_BUFFERS_MB}",
      "navegador_detectado": "${NAVEGADOR_DETECTADO}"
    },

    "rede": ${json_rede},

    "limites_avaliacao": {
      "latencia_ok_ms": ${LIMITE_LATENCIA_OK},
      "latencia_aviso_ms": ${LIMITE_LATENCIA_AVISO},
      "ram_ok_mb": ${LIMITE_RAM_OK_MB},
      "ram_aviso_mb": ${LIMITE_RAM_AVISO_MB},
      "cpu_ok_pct": ${LIMITE_CPU_OK},
      "cpu_aviso_pct": ${LIMITE_CPU_AVISO}
    }
  }
}
EOF
}

exibir_resumo_final() {
    echo ""
    echo -e "${COR_CIANO}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COR_RESET}"
    echo -e "${COR_CIANO}  RESUMO GERAL — Jett OS Performance Report${COR_RESET}"
    echo -e "${COR_CIANO}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COR_RESET}"
    {
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  RESUMO GERAL — Jett OS Performance Report"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    } >> "$RESULTADO_TXT"

    echo ""
    echo -e "  ${COR_BRANCO}Data/Hora  :${COR_RESET} $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  ${COR_BRANCO}Hostname   :${COR_RESET} $(hostname)"
    echo -e "  ${COR_BRANCO}Kernel     :${COR_RESET} $(uname -r)"
    echo -e "  ${COR_BRANCO}Navegador  :${COR_RESET} ${NAVEGADOR_DETECTADO:-N/A}"
    echo ""

    # Boot
    if [[ "$TESTAR_BOOT" -eq 1 && -n "$BOOT_TOTAL_S" ]]; then
        local status_boot_icon="?"
        if [[ "$BOOT_TOTAL_S" != "N/A" ]]; then
            local total_int="${BOOT_TOTAL_S%.*}"
            if (( total_int < 10 )); then
                status_boot_icon="${COR_VERDE}✓ ${BOOT_TOTAL_S}s — excelente${COR_RESET}"
            elif (( total_int < 20 )); then
                status_boot_icon="${COR_AMARELO}! ${BOOT_TOTAL_S}s — aceitável${COR_RESET}"
            else
                status_boot_icon="${COR_VERMELHO}✗ ${BOOT_TOTAL_S}s — lento${COR_RESET}"
            fi
        fi
        echo -e "  ${COR_BRANCO}Boot total :${COR_RESET} ${status_boot_icon}"
    fi

    # RAM
    if [[ "$TESTAR_SISTEMA" -eq 1 && -n "$RAM_USADA_MB" ]]; then
        local status_ram_icon
        case "$(avaliar_ram "$RAM_USADA_MB")" in
            ok)    status_ram_icon="${COR_VERDE}✓ ${RAM_USADA_MB}MB — dentro da meta${COR_RESET}" ;;
            aviso) status_ram_icon="${COR_AMARELO}! ${RAM_USADA_MB}MB — aceitável${COR_RESET}" ;;
            falha) status_ram_icon="${COR_VERMELHO}✗ ${RAM_USADA_MB}MB — acima do ideal${COR_RESET}" ;;
        esac
        echo -e "  ${COR_BRANCO}RAM idle   :${COR_RESET} ${status_ram_icon}"
    fi

    # CPU
    if [[ "$TESTAR_SISTEMA" -eq 1 && -n "$CPU_USO_PCT" ]]; then
        local status_cpu_icon
        case "$(avaliar_cpu "$CPU_USO_PCT")" in
            ok)    status_cpu_icon="${COR_VERDE}✓ ${CPU_USO_PCT}% — sistema limpo${COR_RESET}" ;;
            aviso) status_cpu_icon="${COR_AMARELO}! ${CPU_USO_PCT}% — verificar processos${COR_RESET}" ;;
            falha) status_cpu_icon="${COR_VERMELHO}✗ ${CPU_USO_PCT}% — alto em idle${COR_RESET}" ;;
        esac
        echo -e "  ${COR_BRANCO}CPU idle   :${COR_RESET} ${status_cpu_icon}"
    fi

    echo ""
    echo -e "${COR_CIANO}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COR_RESET}"
    echo ""
    echo -e "  ${COR_BRANCO}Relatório TXT :${COR_RESET} ${RESULTADO_TXT}"
    echo -e "  ${COR_BRANCO}Snapshot JSON :${COR_RESET} ${RESULTADO_JSON}"
    echo ""
    echo -e "  ${COR_CINZA}Compare resultados entre builds:${COR_RESET}"
    echo -e "  ${COR_CINZA}  ls -lt ${RESULTS_DIR}/${COR_RESET}"
    echo -e "  ${COR_CINZA}  diff ${RESULTS_DIR}/*.txt${COR_RESET}"
    echo ""
}

# -----------------------------------------------------------------------------
# PROCESSAMENTO DE ARGUMENTOS
# -----------------------------------------------------------------------------

processar_argumentos() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --só-boot|--so-boot)
                TESTAR_BOOT=1; TESTAR_REDE=0; TESTAR_SISTEMA=0 ;;
            --só-rede|--so-rede)
                TESTAR_BOOT=0; TESTAR_REDE=1; TESTAR_SISTEMA=0 ;;
            --só-sistema|--so-sistema)
                TESTAR_BOOT=0; TESTAR_REDE=0; TESTAR_SISTEMA=1 ;;
            --sem-mtr)
                USAR_MTR=0 ;;
            --mtr-ciclos)
                shift
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    MTR_CICLOS="$1"
                else
                    echo "ERRO: --mtr-ciclos requer um número inteiro." >&2; exit 1
                fi
                ;;
            --ping-contagem)
                shift
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    PING_CONTAGEM="$1"
                else
                    echo "ERRO: --ping-contagem requer um número inteiro." >&2; exit 1
                fi
                ;;
            --help|-h)
                echo "Uso: ./latency-test.sh [OPÇÕES]"
                echo ""
                echo "Opções:"
                echo "  --só-boot          Apenas teste de boot"
                echo "  --só-rede          Apenas teste de rede"
                echo "  --só-sistema       Apenas teste de RAM/CPU"
                echo "  --sem-mtr          Pula o mtr (mais rápido)"
                echo "  --mtr-ciclos N     Ciclos do mtr por host (padrão: 20)"
                echo "  --ping-contagem N  Pacotes de ping por host (padrão: 20)"
                echo ""
                echo "Saída: tests/results/TIMESTAMP.txt e .json"
                exit 0
                ;;
            *)
                echo "Argumento desconhecido: '$1'. Use --help." >&2; exit 1 ;;
        esac
        shift
    done
}

# -----------------------------------------------------------------------------
# PONTO DE ENTRADA PRINCIPAL
# -----------------------------------------------------------------------------

main() {
    processar_argumentos "$@"

    # Cria diretório de resultados
    mkdir -p "$RESULTS_DIR"

    # Cabeçalho do arquivo de resultado
    {
        echo "============================================================"
        echo "  JETT OS — Latency & Performance Report"
        echo "  Versão do script: ${VERSAO_SCRIPT}"
        echo "  Gerado em: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  Hostname: $(hostname)"
        echo "  Kernel: $(uname -r)"
        echo "============================================================"
    } > "$RESULTADO_TXT"

    # Cabeçalho no terminal
    clear
    echo -e "${COR_CIANO}"
    echo "  ██╗     █████╗ ████████╗███████╗███╗   ██╗ ██████╗██╗   ██╗"
    echo "  ██║    ██╔══██╗╚══██╔══╝██╔════╝████╗  ██║██╔════╝╚██╗ ██╔╝"
    echo "  ██║    ███████║   ██║   █████╗  ██╔██╗ ██║██║      ╚████╔╝ "
    echo "  ██║    ██╔══██║   ██║   ██╔══╝  ██║╚██╗██║██║       ╚██╔╝  "
    echo "  ███████╗██║  ██║  ██║   ███████╗██║ ╚████║╚██████╗   ██║   "
    echo "  ╚══════╝╚═╝  ╚═╝  ╚═╝   ╚══════╝╚═╝  ╚═══╝ ╚═════╝   ╚═╝  "
    echo -e "${COR_RESET}"
    echo -e "  ${COR_BRANCO}Performance Report v${VERSAO_SCRIPT}${COR_RESET}  |  $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  ${COR_CINZA}Resultados: ${RESULTS_DIR}/${COR_RESET}"
    echo ""

    verificar_dependencias

    # Executa os testes selecionados
    [[ "$TESTAR_BOOT"    -eq 1 ]] && testar_boot
    [[ "$TESTAR_REDE"    -eq 1 ]] && testar_rede
    [[ "$TESTAR_SISTEMA" -eq 1 ]] && testar_sistema

    # Gera o snapshot JSON e exibe o resumo final
    gerar_relatorio_json
    exibir_resumo_final
}

main "$@"
