#!/usr/bin/env python3
# =============================================================================
# jett-launcher.py — Mini-Launcher do Jett OS
# =============================================================================
# Interface gráfica minimalista de seleção de navegadores.
# Ativado via atalho Super+B configurado no Sway.
#
# Dependências:
#   - Python 3.6+ (padrão no Debian 12)
#   - tkinter (python3-tk: sudo apt install python3-tk)
#   - XWayland (xwayland: sudo apt install xwayland)
#     Necessário porque tkinter usa X11 — o Sway habilita XWayland
#     automaticamente (veja config/sway/config)
#
# Fluxo de uso:
#   1. Usuário pressiona Super+B no Sway
#   2. Este launcher abre centralizado na tela
#   3. Usuário navega com ↑ ↓ ou clica, confirma com Enter ou clique
#   4. launcher chama jett-switch.sh com o navegador escolhido
#   5. jett-switch.sh encerra o navegador atual e inicia o novo
#   6. launcher fecha automaticamente
#
# Privilégios:
#   jett-switch.sh precisa de sudo para escrever em /etc/jett-os/
#   Configure /etc/sudoers.d/jett-launcher com:
#     jett ALL=(ALL) NOPASSWD: /usr/local/bin/jett-switch.sh
#   (feito automaticamente por launcher/install-launcher.sh)
# =============================================================================

import tkinter as tk
from tkinter import font as tkfont
import subprocess
import sys
import os
import shutil
from pathlib import Path

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTES
# ─────────────────────────────────────────────────────────────────────────────

VERSAO = "1.0.0"

# Caminho do arquivo de configuração do navegador ativo
CONF_NAVEGADOR = "/etc/jett-os/navegador.conf"

# Registro de navegadores instalados — escrito pelos scripts de instalação
CONF_INSTALADOS = "/etc/jett-os/navegadores-instalados.conf"

# Caminho do script de troca de navegador.
# Prioridade: binário instalado em /usr/local/bin (sudoers aponta para este path).
# Fallback: caminho relativo ao diretório do launcher (para desenvolvimento).
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_SWITCH_INSTALADO = "/usr/local/bin/jett-switch.sh"
_SWITCH_LOCAL     = os.path.join(SCRIPT_DIR, "jett-switch.sh")
JETT_SWITCH = _SWITCH_INSTALADO if os.path.isfile(_SWITCH_INSTALADO) else _SWITCH_LOCAL

# Dimensões da janela do launcher
LARGURA_JANELA = 480
ALTURA_JANELA  = 378

# ─────────────────────────────────────────────────────────────────────────────
# DEFINIÇÃO DOS NAVEGADORES
# ─────────────────────────────────────────────────────────────────────────────
# Cada entrada define:
#   id        → identificador interno (usado no navegador.conf e no jett-switch.sh)
#   nome      → nome exibido na interface
#   binario   → executável a checar com shutil.which() para saber se está instalado
#   processos → lista de nomes de processo para pkill ao encerrar
# ─────────────────────────────────────────────────────────────────────────────

NAVEGADORES = [
    {
        'id':        'brave',
        'nome':      'Brave Browser',
        'binario':   'brave-browser',
        'processos': ['brave', 'brave-browser'],
    },
    {
        'id':        'edge',
        'nome':      'Microsoft Edge',
        'binario':   'microsoft-edge-stable',   # pacote instala microsoft-edge-stable
        'processos': ['microsoft-edge-stable', 'msedge'],
    },
    {
        'id':        'thorium',
        'nome':      'Thorium Browser',
        'binario':   'thorium-browser',
        'processos': ['thorium-browser', 'thorium'],
    },
    {
        'id':        'opera-gx',
        'nome':      'Opera GX',
        'binario':   'opera',
        'processos': ['opera'],
    },
    {
        'id':        'firefox',
        'nome':      'Firefox',
        'binario':   'firefox',
        'processos': ['firefox', 'firefox-esr'],
    },
]

# ─────────────────────────────────────────────────────────────────────────────
# PALETA DE CORES
# Consistente com o tema GRUB do Jett OS:
#   item normal   → preto / cinza
#   item selecionado → branco / preto (inversão de contraste)
# ─────────────────────────────────────────────────────────────────────────────

CORES = {
    # Fundos
    'janela':               '#000000',
    'item_normal':          '#000000',
    'item_selecionado':     '#FFFFFF',

    # Textos — cabeçalho
    'titulo':               '#FFFFFF',
    'tagline':              '#555555',

    # Textos — itens normais (não selecionados)
    'nome_normal':          '#777777',
    'nome_ativo':           '#AAAAAA',   # navegador em uso mas não selecionado no menu
    'nome_nao_instalado':   '#2E2E2E',
    'numero_normal':        '#333333',

    # Textos — item selecionado (fundo branco)
    'nome_selecionado':     '#000000',
    'numero_selecionado':   '#888888',

    # Textos — status à direita
    'status_em_uso':        '#555555',
    'status_instalado':     '#3A3A3A',
    'status_nao_instalado': '#252525',
    'status_selecionado':   '#777777',  # status quando item está selecionado

    # Elementos de layout
    'separador':            '#1C1C1C',
    'dica':                 '#2D2D2D',
}

# ─────────────────────────────────────────────────────────────────────────────
# CLASSE PRINCIPAL
# ─────────────────────────────────────────────────────────────────────────────

class JettLauncher:
    """
    Mini-launcher do Jett OS.
    Exibe os navegadores disponíveis e permite trocar o navegador ativo.
    """

    def __init__(self):
        # Estado inicial
        self.idx_selecionado  = 0
        self.nav_ativo_id     = self._ler_navegador_ativo()
        # Registro lido antes de _verificar_instalacao para que ela possa usá-lo
        self.versoes          = self._ler_registro_instalados()
        self.status           = self._verificar_instalacao()

        # Pré-seleciona o navegador que está em uso
        for i, nav in enumerate(NAVEGADORES):
            if nav['id'] == self.nav_ativo_id:
                self.idx_selecionado = i
                break

        # Constrói a interface
        self._construir_janela()
        self._construir_ui()
        self._configurar_atalhos()

        # Aplica o estado inicial de seleção e centraliza
        self._atualizar_selecao(self.idx_selecionado, forcar=True)
        self.root.update_idletasks()
        self._centralizar_janela()
        self.root.focus_force()

    # ── Leitura de estado ────────────────────────────────────────────────────

    def _ler_registro_instalados(self) -> dict:
        """
        Lê /etc/jett-os/navegadores-instalados.conf e retorna versões instaladas.
        Formato das entradas:
            JETT_BRAVE_INSTALADO=true
            JETT_BRAVE_VERSAO="1.60.114"
            JETT_BRAVE_BINARIO="/usr/bin/brave-browser"
        Retorna dict {nav_id: versao_str} apenas para navegadores marcados como instalados.
        """
        # Mapeamento do prefixo do arquivo de registro para o ID do navegador
        id_map = {
            'BRAVE':   'brave',
            'EDGE':    'edge',
            'THORIUM': 'thorium',
            'OPERA':   'opera-gx',
            'FIREFOX': 'firefox',
        }
        resultado = {}
        try:
            with open(CONF_INSTALADOS) as f:
                for linha in f:
                    linha = linha.strip()
                    if linha.startswith('#') or '=' not in linha:
                        continue
                    chave, _, valor = linha.partition('=')
                    valor = valor.strip().strip('"').strip("'")
                    # JETT_BRAVE_VERSAO → prefixo = "BRAVE"
                    if chave.startswith('JETT_') and chave.endswith('_VERSAO'):
                        prefixo = chave[5:-7]  # Remove "JETT_" e "_VERSAO"
                        nav_id = id_map.get(prefixo)
                        if nav_id and valor:
                            resultado[nav_id] = valor
        except (IOError, PermissionError, FileNotFoundError):
            pass
        return resultado

    def _ler_navegador_ativo(self) -> str:
        """
        Lê JETT_NAVEGADOR de /etc/jett-os/navegador.conf.
        Retorna 'firefox' como fallback se o arquivo não existir ou não puder ser lido.
        """
        try:
            with open(CONF_NAVEGADOR) as f:
                for linha in f:
                    linha = linha.strip()
                    if linha.startswith('#') or '=' not in linha:
                        continue
                    chave, _, valor = linha.partition('=')
                    if chave.strip() == 'JETT_NAVEGADOR':
                        return valor.strip().strip('"').strip("'")
        except (IOError, PermissionError, FileNotFoundError):
            pass
        return 'firefox'

    def _verificar_instalacao(self) -> dict:
        """
        Verifica quais navegadores estão instalados.
        Prioridade: registro em navegadores-instalados.conf (escrito pelo install script).
        Fallback: shutil.which() para detectar binários não registrados.
        Retorna dict {nav_id: bool}.
        """
        resultado = {}
        for nav in NAVEGADORES:
            nav_id = nav['id']
            if nav_id in self.versoes:
                # Confirmado pelo script de instalação
                resultado[nav_id] = True
            else:
                # Fallback: verifica se o binário está no PATH
                resultado[nav_id] = shutil.which(nav['binario']) is not None
        return resultado

    # ── Construção da janela ─────────────────────────────────────────────────

    def _construir_janela(self):
        """Configura as propriedades da janela tkinter."""
        self.root = tk.Tk()

        # Título: usado pelo Sway para aplicar regras de janela floating
        self.root.title("Jett OS — Launcher")

        self.root.geometry(f"{LARGURA_JANELA}x{ALTURA_JANELA}")
        self.root.resizable(False, False)
        self.root.configure(bg=CORES['janela'])

        # Mantém a janela acima das outras (reforço visual no XWayland)
        self.root.attributes('-topmost', True)

        # Cursor invisível — modo kiosk, o usuário navega pelo teclado
        self.root.config(cursor='none')

        # Intercepta fechar via WM (Alt+F4, etc.) para usar nossa lógica
        self.root.protocol("WM_DELETE_WINDOW", self._fechar)

    # ── Construção da UI ─────────────────────────────────────────────────────

    def _construir_ui(self):
        """Constrói todos os widgets da interface."""

        # ── Fontes ──────────────────────────────────────────────────────────
        # Usa 'DejaVu Sans' se disponível (instalado pelo build-base.sh via
        # fonts-noto), caso contrário usa o sans-serif padrão do sistema.
        familia_sans = self._escolher_fonte(['DejaVu Sans', 'Noto Sans', 'sans-serif'])
        familia_mono = self._escolher_fonte(['DejaVu Sans Mono', 'monospace'])

        self.f_titulo      = tkfont.Font(family=familia_sans, size=17, weight='bold')
        self.f_tagline     = tkfont.Font(family=familia_sans, size=10)
        self.f_item        = tkfont.Font(family=familia_sans, size=12)
        self.f_item_bold   = tkfont.Font(family=familia_sans, size=12, weight='bold')
        self.f_numero      = tkfont.Font(family=familia_mono, size=10)
        self.f_dica        = tkfont.Font(family=familia_sans, size=9)
        self.f_status      = tkfont.Font(family=familia_sans, size=9)

        # ── Container raiz ───────────────────────────────────────────────────
        raiz = tk.Frame(self.root, bg=CORES['janela'])
        raiz.pack(fill='both', expand=True)

        # ── Cabeçalho ────────────────────────────────────────────────────────
        cab = tk.Frame(raiz, bg=CORES['janela'])
        cab.pack(fill='x', padx=44, pady=(26, 0))

        tk.Label(
            cab, text="JETT OS",
            font=self.f_titulo, bg=CORES['janela'], fg=CORES['titulo'],
        ).pack()

        tk.Label(
            cab, text="Selecionar navegador",
            font=self.f_tagline, bg=CORES['janela'], fg=CORES['tagline'],
        ).pack(pady=(3, 0))

        # ── Separador superior ────────────────────────────────────────────────
        self._linha_separador(raiz, topo=14, baixo=10)

        # ── Lista de navegadores ─────────────────────────────────────────────
        self.frame_lista = tk.Frame(raiz, bg=CORES['janela'])
        self.frame_lista.pack(fill='x', padx=28)

        # Registros de cada item para atualização visual
        self.itens: list[dict] = []

        for i, nav in enumerate(NAVEGADORES):
            instalado = self.status.get(nav['id'], False)
            ativo     = (nav['id'] == self.nav_ativo_id)
            item      = self._criar_item(self.frame_lista, i, nav, instalado, ativo)
            self.itens.append(item)

        # ── Separador inferior ────────────────────────────────────────────────
        self._linha_separador(raiz, topo=10, baixo=8)

        # ── Dicas de teclado ─────────────────────────────────────────────────
        tk.Label(
            raiz,
            text="↑ ↓  navegar     Enter  confirmar     Esc  fechar",
            font=self.f_dica, bg=CORES['janela'], fg=CORES['dica'],
        ).pack(pady=(0, 14))

    def _escolher_fonte(self, candidatas: list) -> str:
        """
        Escolhe a primeira fonte disponível no sistema tkinter.
        Evita erros caso uma fonte específica não esteja instalada.
        """
        disponiveis = set(tkfont.families())
        for nome in candidatas:
            if nome in disponiveis:
                return nome
        return candidatas[-1]  # fallback: última da lista (geralmente genérica)

    def _linha_separador(self, parent, topo: int = 8, baixo: int = 8):
        """Desenha uma linha horizontal fina usando Canvas."""
        c = tk.Canvas(
            parent, height=1,
            bg=CORES['janela'], bd=0, highlightthickness=0,
        )
        c.pack(fill='x', padx=44, pady=(topo, baixo))
        # A linha é desenhada com largura fixa; o Canvas se expande depois
        c.create_line(0, 0, LARGURA_JANELA, 0, fill=CORES['separador'])

    def _criar_item(self, parent, idx: int, nav: dict, instalado: bool, ativo: bool) -> dict:
        """
        Cria um item de navegador na lista.
        Layout: [número] [nome do navegador ──────── status]
        Retorna dict com referências a todos os widgets para atualização futura.
        """
        # Frame externo (recebe a cor de fundo da seleção)
        frame = tk.Frame(parent, bg=CORES['item_normal'], pady=0)
        frame.pack(fill='x', pady=1)

        # Frame interno com padding (também recebe cor de fundo)
        inner = tk.Frame(frame, bg=CORES['item_normal'], pady=8)
        inner.pack(fill='x', padx=14)

        # Número de acesso rápido (tecla 1-5)
        lbl_num = tk.Label(
            inner, text=str(idx + 1),
            font=self.f_numero,
            bg=CORES['item_normal'], fg=CORES['numero_normal'],
            width=2, anchor='e',
        )
        lbl_num.pack(side='left', padx=(0, 12))

        # Nome do navegador
        cor_nome_inicial = (
            CORES['nome_ativo'] if ativo
            else CORES['nome_normal'] if instalado
            else CORES['nome_nao_instalado']
        )
        lbl_nome = tk.Label(
            inner, text=nav['nome'],
            font=self.f_item,
            bg=CORES['item_normal'], fg=cor_nome_inicial,
            anchor='w',
        )
        lbl_nome.pack(side='left', fill='x', expand=True)

        # Status à direita — mostra versão quando disponível no registro
        versao = self.versoes.get(nav['id'], '')
        if ativo:
            txt_status = f"● em uso  v{versao}" if versao else "● em uso"
            cor_status = CORES['status_em_uso']
        elif instalado:
            txt_status = f"v{versao}" if versao else "instalado"
            cor_status = CORES['status_instalado']
        else:
            txt_status, cor_status = "não instalado", CORES['status_nao_instalado']

        lbl_status = tk.Label(
            inner, text=txt_status,
            font=self.f_status,
            bg=CORES['item_normal'], fg=cor_status,
            anchor='e',
        )
        lbl_status.pack(side='right')

        # Bind de interação — todos os widgets do item respondem ao clique/hover
        todos_widgets = [frame, inner, lbl_num, lbl_nome, lbl_status]
        for w in todos_widgets:
            w.bind('<Button-1>', lambda e, i=idx: self._ao_clicar(i))
            w.bind('<Enter>',    lambda e, i=idx: self._ao_hover(i))
            # Cursor muda apenas para itens instalados
            if instalado:
                w.config(cursor='hand2')

        return {
            'frame':     frame,
            'inner':     inner,
            'num':       lbl_num,
            'nome':      lbl_nome,
            'status':    lbl_status,
            'instalado': instalado,
            'ativo':     ativo,
            'nav_id':    nav['id'],
        }

    # ── Interação ────────────────────────────────────────────────────────────

    def _ao_clicar(self, idx: int):
        """Clique do mouse: seleciona e confirma com pequeno delay visual."""
        if self.itens[idx]['instalado']:
            self._atualizar_selecao(idx)
            self.root.after(90, self._confirmar_selecao)
        else:
            self._flash_nao_instalado(idx)

    def _ao_hover(self, idx: int):
        """Hover do mouse: pré-seleciona visualmente sem confirmar."""
        if self.itens[idx]['instalado']:
            self._atualizar_selecao(idx)

    def _atualizar_selecao(self, novo_idx: int, forcar: bool = False):
        """
        Atualiza o destaque visual de todos os itens.
        O item em 'novo_idx' recebe fundo branco + texto preto (padrão GRUB).
        Os demais voltam ao estado normal.
        """
        if novo_idx == self.idx_selecionado and not forcar:
            return

        for i, item in enumerate(self.itens):
            sel       = (i == novo_idx)
            instalado = item['instalado']
            ativo     = item['ativo']

            # Define cores de acordo com o estado composto do item
            if sel:
                cor_fundo   = CORES['item_selecionado']
                cor_nome    = CORES['nome_selecionado']
                cor_num     = CORES['numero_selecionado']
                cor_status  = CORES['status_selecionado']
                fonte_nome  = self.f_item_bold
            elif ativo:
                cor_fundo   = CORES['item_normal']
                cor_nome    = CORES['nome_ativo']
                cor_num     = CORES['numero_normal']
                cor_status  = CORES['status_em_uso']
                fonte_nome  = self.f_item
            elif instalado:
                cor_fundo   = CORES['item_normal']
                cor_nome    = CORES['nome_normal']
                cor_num     = CORES['numero_normal']
                cor_status  = CORES['status_instalado']
                fonte_nome  = self.f_item
            else:
                cor_fundo   = CORES['item_normal']
                cor_nome    = CORES['nome_nao_instalado']
                cor_num     = '#222222'
                cor_status  = CORES['status_nao_instalado']
                fonte_nome  = self.f_item

            # Aplica cores a todos os widgets do item
            item['frame'].configure(bg=cor_fundo)
            item['inner'].configure(bg=cor_fundo)
            item['num'].configure(bg=cor_fundo, fg=cor_num)
            item['nome'].configure(bg=cor_fundo, fg=cor_nome, font=fonte_nome)
            item['status'].configure(bg=cor_fundo, fg=cor_status)

        self.idx_selecionado = novo_idx

    def _confirmar_selecao(self):
        """Confirma a troca e fecha. Chama jett-switch.sh com o id do navegador."""
        item   = self.itens[self.idx_selecionado]
        nav_id = item['nav_id']

        if not item['instalado']:
            self._flash_nao_instalado(self.idx_selecionado)
            return

        # Mesmo navegador já ativo — fecha sem fazer nada
        if nav_id == self.nav_ativo_id:
            self._fechar()
            return

        # Chama o script de troca em processo separado para não bloquear a UI.
        # O launcher fecha imediatamente; a troca acontece em background.
        self._chamar_switch(nav_id)
        self._fechar()

    def _chamar_switch(self, nav_id: str):
        """
        Chama jett-switch.sh via sudo.
        Fallback: sem sudo (para testes em ambiente de desenvolvimento).
        """
        cmd_sudo    = ['sudo', JETT_SWITCH, '--navegador', nav_id]
        cmd_direto  = [JETT_SWITCH, '--navegador', nav_id]

        for cmd in [cmd_sudo, cmd_direto]:
            try:
                subprocess.Popen(
                    cmd,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
                return
            except (FileNotFoundError, PermissionError, OSError):
                continue

        # Se nenhum dos comandos funcionou, exibe aviso no terminal
        print(
            f"[jett-launcher] AVISO: não foi possível chamar {JETT_SWITCH}. "
            f"Verifique se o script existe e está executável.",
            file=sys.stderr,
        )

    def _fechar(self):
        """Fecha o launcher sem trocar de navegador."""
        self.root.destroy()

    def _flash_nao_instalado(self, idx: int):
        """
        Feedback visual quando o usuário tenta selecionar um navegador
        que não está instalado: flash vermelho suave por 350ms.
        """
        item = self.itens[idx]

        # Salva estado atual para restaurar depois
        cor_fundo_orig  = item['frame'].cget('bg')
        cor_nome_orig   = item['nome'].cget('fg')
        cor_status_orig = item['status'].cget('fg')
        txt_status_orig = item['status'].cget('text')

        # Aplica flash
        for w in [item['frame'], item['inner']]:
            w.configure(bg='#1A0000')
        item['num'].configure(bg='#1A0000', fg='#3A1A1A')
        item['nome'].configure(bg='#1A0000', fg='#5A2020')
        item['status'].configure(bg='#1A0000', fg='#5A2020', text='⚠ não instalado')

        def restaurar():
            item['frame'].configure(bg=cor_fundo_orig)
            item['inner'].configure(bg=cor_fundo_orig)
            item['num'].configure(bg=cor_fundo_orig)
            item['nome'].configure(bg=cor_fundo_orig, fg=cor_nome_orig)
            item['status'].configure(
                bg=cor_fundo_orig, fg=cor_status_orig, text=txt_status_orig,
            )

        self.root.after(350, restaurar)

    # ── Posicionamento ────────────────────────────────────────────────────────

    def _centralizar_janela(self):
        """Centraliza a janela na tela usando as dimensões reais após renderização."""
        larg_tela  = self.root.winfo_screenwidth()
        alt_tela   = self.root.winfo_screenheight()
        x = (larg_tela  - LARGURA_JANELA) // 2
        y = (alt_tela   - ALTURA_JANELA)  // 2
        self.root.geometry(f"{LARGURA_JANELA}x{ALTURA_JANELA}+{x}+{y}")

    # ── Atalhos de teclado ────────────────────────────────────────────────────

    def _configurar_atalhos(self):
        """Registra todos os atalhos de teclado da janela."""
        kb = self.root.bind

        # Navegação
        kb('<Up>',       self._tecla_cima)
        kb('<Down>',     self._tecla_baixo)
        kb('<k>',        self._tecla_cima)   # vi-like
        kb('<j>',        self._tecla_baixo)  # vi-like

        # Confirmação
        kb('<Return>',   lambda _: self._confirmar_selecao())
        kb('<KP_Enter>', lambda _: self._confirmar_selecao())

        # Fechar
        kb('<Escape>',   lambda _: self._fechar())
        kb('<q>',        lambda _: self._fechar())

        # Seleção direta por número (1–5)
        for i in range(1, 6):
            kb(str(i), lambda _, idx=i - 1: self._selecao_e_confirmacao(idx))

    def _tecla_cima(self, _event=None):
        novo = (self.idx_selecionado - 1) % len(NAVEGADORES)
        self._atualizar_selecao(novo)

    def _tecla_baixo(self, _event=None):
        novo = (self.idx_selecionado + 1) % len(NAVEGADORES)
        self._atualizar_selecao(novo)

    def _selecao_e_confirmacao(self, idx: int):
        """Seleção e confirmação imediata (tecla numérica)."""
        if 0 <= idx < len(NAVEGADORES):
            self._atualizar_selecao(idx)
            self.root.after(90, self._confirmar_selecao)

    # ── Loop principal ────────────────────────────────────────────────────────

    def executar(self):
        """Inicia o loop de eventos tkinter."""
        self.root.mainloop()


# ─────────────────────────────────────────────────────────────────────────────
# PONTO DE ENTRADA
# ─────────────────────────────────────────────────────────────────────────────

def main():
    # Verifica se tkinter está disponível antes de tentar criar a janela
    try:
        import tkinter  # noqa: F401
    except ImportError:
        print(
            "ERRO: tkinter não encontrado.\n"
            "Instale com: sudo apt install python3-tk",
            file=sys.stderr,
        )
        sys.exit(1)

    launcher = JettLauncher()
    launcher.executar()


if __name__ == '__main__':
    main()
