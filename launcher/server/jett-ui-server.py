#!/usr/bin/env python3
# =============================================================================
# jett-ui-server.py — Servidor HTTP de interfaces do Jett OS
# =============================================================================
# Uso:
#   jett-ui-server           (iniciado pelo systemd como serviço do usuário jett)
#
# Funções:
#   • Serve as interfaces HTML em /usr/local/share/jett-os/ui/
#     (fallback para ./launcher/ui/ no modo de desenvolvimento)
#   • Expõe uma API REST simples em 127.0.0.1:1312
#   • Delega ações do sistema ao script jett-bridge
#
# Endpoints:
#   GET  /                         → nav.html
#   GET  /nav                      → nav.html (barra de navegação)
#   GET  /menu                     → menu.html (menu de sistema)
#   GET  /wizard                   → wizard.html (assistente de primeiro boot)
#   GET  /files                    → files.html (gerenciador de arquivos)
#   GET  /api/status               → JSON com volume, rede, navegador, hora
#   GET  /api/bluetooth/list       → dispositivos bluetooth pareados
#   POST /api/bluetooth/scan       → busca novos dispositivos (5 s)
#   POST /api/bluetooth/pair       → pareia dispositivo (body: {"address":"AA:BB:..."})
#   POST /api/bluetooth/remove     → remove pareamento (body: {"address":"..."})
#   GET  /api/bluetooth/power      → estado de energia bluetooth
#   POST /api/bluetooth/power_toggle → liga/desliga bluetooth
#   GET  /api/wifi/status          → estado WiFi e SSID atual
#   GET  /api/wifi/list            → redes disponíveis
#   POST /api/wifi/toggle          → liga/desliga WiFi
#   POST /api/wifi/connect         → conecta rede (body: {"ssid":"...","senha":"..."})
#   POST /api/wifi/disconnect      → desconecta WiFi atual
#   GET  /api/files/list?path=     → lista diretório (padrão: /home/jett)
#   POST /api/files/move           → move arquivo (body: {"src":"...","dst":"..."})
#   POST /api/files/copy           → copia arquivo (body: {"src":"...","dst":"..."})
#   POST /api/files/rename         → renomeia (body: {"src":"...","name":"..."})
#   POST /api/files/delete         → remove (body: {"path":"..."})
#   POST /api/files/mkdir          → cria dir (body: {"path":"..."})
#   GET  /api/system/version       → versão Jett OS, base, kernel
#   GET  /api/system/updates/check → contagem de atualizações disponíveis
#   POST /api/system/updates/install → instala atualizações disponíveis
#   GET  /api/pwas/list            → PWAs instalados
#   GET  /api/devices/gamepads     → gamepads detectados
#   POST /api/window/open          → abre janela browser --app=URL (body: {"url":"..."})
#   GET  /api/wizard/install-browsers → progresso da instalação em andamento
#   POST /api/wizard/install-browsers → inicia instalação de navegador (body: {"nav":"brave"})
#   POST /api/wizard/complete      → salva escolhas e cria firstboot.done
#   POST /api/wizard/set-admin-password → define senha admin (body: {"senha":"..."})
#   POST /api/volume/up            → aumenta volume 5%
#   POST /api/volume/down          → diminui volume 5%
#   POST /api/volume/mute          → alterna mudo
#   POST /api/volume/set           → define volume (corpo: {"level":50})
#   GET  /api/network              → informações de rede
#   POST /api/power/shutdown       → desliga
#   POST /api/power/reboot         → reinicia
#   POST /api/power/suspend        → suspende
#   GET  /api/browser/list         → navegadores instalados
#   POST /api/browser/switch       → troca navegador (corpo: {"browser":"firefox"})
#   GET  /api/usb/list             → dispositivos USB
#   POST /api/usb/mount            → monta USB (corpo: {"device":"/dev/sdb1"})
#   POST /api/usb/unmount          → desmonta USB (corpo: {"point":"/media/..."})
#
# Instalação:
#   sudo cp launcher/jett-ui-server.py /usr/local/bin/jett-ui-server
#   sudo chmod +x /usr/local/bin/jett-ui-server
# =============================================================================

import http.server
import json
import os
import subprocess
import sys
import threading
from pathlib import Path
from urllib.parse import urlparse, parse_qs

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURAÇÃO
# ─────────────────────────────────────────────────────────────────────────────

HOST  = '127.0.0.1'
PORTA = 1312

# Diretório de arquivos HTML — produção vs. desenvolvimento
# Em produção: /usr/local/share/jett-os/ui/
# Em dev:      launcher/ui/ (dois níveis acima de launcher/server/)
UI_DIR_PROD = Path('/usr/local/share/jett-os/ui')
UI_DIR_DEV  = Path(__file__).parent.parent / 'ui'
UI_DIR      = UI_DIR_PROD if UI_DIR_PROD.exists() else UI_DIR_DEV

# Caminho do bridge — produção vs. desenvolvimento
# Em produção: /usr/local/bin/jett-bridge
# Em dev:      launcher/scripts/jett-bridge.sh
BRIDGE_PROD = Path('/usr/local/bin/jett-bridge')
BRIDGE_DEV  = Path(__file__).parent.parent / 'scripts' / 'jett-bridge.sh'
BRIDGE      = str(BRIDGE_PROD) if BRIDGE_PROD.exists() else str(BRIDGE_DEV)

# ─────────────────────────────────────────────────────────────────────────────
# BRIDGE — chama jett-bridge.sh e retorna o JSON resultante
# ─────────────────────────────────────────────────────────────────────────────

def bridge(*args: str) -> dict:
    """
    Executa jett-bridge com os argumentos dados.
    Retorna o JSON parseado ou um dicionário de erro.
    """
    try:
        resultado = subprocess.run(
            [BRIDGE, *args],
            capture_output=True,
            text=True,
            timeout=10,
        )
        saida = resultado.stdout.strip()
        if saida:
            return json.loads(saida)
        if resultado.returncode != 0:
            return {'erro': resultado.stderr.strip() or 'bridge retornou erro'}
        return {'ok': True}
    except subprocess.TimeoutExpired:
        return {'erro': 'timeout ao executar bridge'}
    except json.JSONDecodeError as e:
        return {'erro': f'JSON invalido do bridge: {e}'}
    except Exception as e:
        return {'erro': str(e)}

# ─────────────────────────────────────────────────────────────────────────────
# HANDLER HTTP
# ─────────────────────────────────────────────────────────────────────────────

# Rotas de página HTML: caminho_url → nome_do_arquivo
ROTAS_HTML = {
    '/':       'nav.html',
    '/nav':    'nav.html',
    '/menu':   'menu.html',
    '/wizard': 'wizard.html',
    '/files':  'files.html',
}

# Tipos MIME básicos
MIME = {
    '.html': 'text/html; charset=utf-8',
    '.css':  'text/css; charset=utf-8',
    '.js':   'application/javascript; charset=utf-8',
    '.json': 'application/json',
    '.svg':  'image/svg+xml',
    '.png':  'image/png',
    '.ico':  'image/x-icon',
}


class Handler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        # Silencia log padrão — evita poluir o journal do systemd
        pass

    # ── Respostas auxiliares ──────────────────────────────────────────────────

    def responder_json(self, dados: dict, status: int = 200):
        corpo = json.dumps(dados, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(corpo)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(corpo)

    def responder_html(self, caminho_arquivo: Path):
        try:
            conteudo = caminho_arquivo.read_bytes()
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'404 - Arquivo nao encontrado')
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(conteudo)))
        self.end_headers()
        self.wfile.write(conteudo)

    def ler_corpo_json(self) -> dict:
        tamanho = int(self.headers.get('Content-Length', 0))
        if tamanho == 0:
            return {}
        corpo = self.rfile.read(tamanho)
        try:
            return json.loads(corpo)
        except json.JSONDecodeError:
            return {}

    # ── GET ───────────────────────────────────────────────────────────────────

    def do_GET(self):
        parsed = urlparse(self.path)
        caminho = parsed.path.rstrip('/')  or '/'

        # Páginas HTML
        if caminho in ROTAS_HTML or caminho == '/':
            nome = ROTAS_HTML.get(caminho, 'nav.html')
            self.responder_html(UI_DIR / nome)
            return

        # Arquivo estático em /ui/
        if caminho.startswith('/ui/'):
            nome_arquivo = caminho[4:]  # remove /ui/
            arquivo = UI_DIR / nome_arquivo
            ext = os.path.splitext(nome_arquivo)[1].lower()
            if arquivo.exists() and arquivo.is_file():
                conteudo = arquivo.read_bytes()
                self.send_response(200)
                self.send_header('Content-Type', MIME.get(ext, 'application/octet-stream'))
                self.send_header('Content-Length', str(len(conteudo)))
                self.end_headers()
                self.wfile.write(conteudo)
            else:
                self.send_response(404)
                self.end_headers()
            return

        # API
        if caminho == '/api/status':
            vol    = bridge('volume', 'get')
            rede   = bridge('network', 'info')
            navs   = bridge('browser', 'list')
            sistema = bridge('system', 'info')
            self.responder_json({
                'volume':    vol,
                'rede':      rede,
                'navegadores': navs if isinstance(navs, list) else [],
                'sistema':   sistema,
            })
            return

        if caminho == '/api/network':
            self.responder_json(bridge('network', 'info'))
            return

        if caminho == '/api/browser/list':
            dados = bridge('browser', 'list')
            if isinstance(dados, list):
                self.responder_json({'navegadores': dados})
            else:
                self.responder_json(dados)
            return

        if caminho == '/api/usb/list':
            dados = bridge('usb', 'list')
            if isinstance(dados, list):
                self.responder_json({'dispositivos': dados})
            else:
                self.responder_json(dados)
            return

        if caminho == '/api/bluetooth/list':
            dados = bridge('bluetooth', 'list')
            if isinstance(dados, list):
                self.responder_json({'dispositivos': dados})
            else:
                self.responder_json(dados)
            return

        if caminho == '/api/bluetooth/power':
            self.responder_json(bridge('bluetooth', 'power_status'))
            return

        if caminho == '/api/wifi/status':
            self.responder_json(bridge('wifi', 'status'))
            return

        if caminho == '/api/wifi/list':
            dados = bridge('wifi', 'list')
            if isinstance(dados, list):
                self.responder_json({'redes': dados})
            else:
                self.responder_json(dados)
            return

        if caminho == '/api/nav/status':
            self.responder_json(bridge('nav', 'status'))
            return

        if caminho == '/api/system/version':
            self.responder_json(bridge('system', 'version'))
            return

        if caminho == '/api/system/updates/check':
            self.responder_json(bridge('system', 'updates_check'))
            return

        if caminho == '/api/pwas/list':
            dados = bridge('pwas', 'list')
            if isinstance(dados, list):
                self.responder_json({'pwas': dados})
            else:
                self.responder_json(dados)
            return

        if caminho == '/api/devices/gamepads':
            dados = bridge('devices', 'gamepads')
            if isinstance(dados, list):
                self.responder_json({'gamepads': dados})
            else:
                self.responder_json(dados)
            return

        if caminho == '/api/wizard/install-browsers':
            self.responder_json(bridge('wizard', 'install_status'))
            return

        if caminho == '/api/files/list':
            params = parse_qs(parsed.query)
            path = params.get('path', ['/home/jett'])[0]
            self.responder_json(bridge('files', 'list', path))
            return

        self.send_response(404)
        self.end_headers()

    # ── POST ──────────────────────────────────────────────────────────────────

    def do_POST(self):
        parsed = urlparse(self.path)
        caminho = parsed.path.rstrip('/')

        # Volume
        if caminho == '/api/volume/up':
            self.responder_json(bridge('volume', 'up'))
        elif caminho == '/api/volume/down':
            self.responder_json(bridge('volume', 'down'))
        elif caminho == '/api/volume/mute':
            self.responder_json(bridge('volume', 'mute'))
        elif caminho == '/api/volume/set':
            corpo = self.ler_corpo_json()
            nivel = str(corpo.get('level', 50))
            self.responder_json(bridge('volume', 'set', nivel))

        # Energia
        elif caminho in ('/api/power/shutdown', '/api/power/reboot', '/api/power/suspend'):
            subcmd = caminho.split('/')[-1]  # shutdown | reboot | suspend
            # Responde antes de desligar para não deixar o browser em erro
            self.responder_json({'ok': True, 'acao': subcmd})
            threading.Timer(0.5, lambda: bridge('power', subcmd)).start()

        # Navegador
        elif caminho == '/api/browser/switch':
            corpo = self.ler_corpo_json()
            nav = corpo.get('browser', '')
            if nav:
                self.responder_json(bridge('browser', 'switch', nav))
            else:
                self.responder_json({'erro': 'campo "browser" ausente'}, 400)

        # USB
        elif caminho == '/api/usb/mount':
            corpo = self.ler_corpo_json()
            dev = corpo.get('device', '')
            if dev:
                self.responder_json(bridge('usb', 'mount', dev))
            else:
                self.responder_json({'erro': 'campo "device" ausente'}, 400)

        elif caminho == '/api/usb/unmount':
            corpo = self.ler_corpo_json()
            ponto = corpo.get('point', '')
            if ponto:
                self.responder_json(bridge('usb', 'unmount', ponto))
            else:
                self.responder_json({'erro': 'campo "point" ausente'}, 400)

        # Bluetooth
        elif caminho == '/api/bluetooth/scan':
            self.responder_json(bridge('bluetooth', 'scan'))

        elif caminho == '/api/bluetooth/pair':
            corpo = self.ler_corpo_json()
            addr = corpo.get('address', '')
            if addr:
                self.responder_json(bridge('bluetooth', 'pair', addr))
            else:
                self.responder_json({'erro': 'campo "address" ausente'}, 400)

        elif caminho == '/api/bluetooth/remove':
            corpo = self.ler_corpo_json()
            addr = corpo.get('address', '')
            if addr:
                self.responder_json(bridge('bluetooth', 'remove', addr))
            else:
                self.responder_json({'erro': 'campo "address" ausente'}, 400)

        elif caminho == '/api/bluetooth/power_toggle':
            self.responder_json(bridge('bluetooth', 'power_toggle'))

        # WiFi
        elif caminho == '/api/wifi/toggle':
            self.responder_json(bridge('wifi', 'toggle'))

        elif caminho == '/api/wifi/connect':
            corpo = self.ler_corpo_json()
            ssid = corpo.get('ssid', '')
            senha = corpo.get('senha', '')
            if ssid:
                self.responder_json(bridge('wifi', 'connect', ssid, senha))
            else:
                self.responder_json({'erro': 'campo "ssid" ausente'}, 400)

        elif caminho == '/api/wifi/disconnect':
            self.responder_json(bridge('wifi', 'disconnect'))

        # Arquivos
        elif caminho == '/api/files/move':
            corpo = self.ler_corpo_json()
            src, dst = corpo.get('src', ''), corpo.get('dst', '')
            if src and dst:
                self.responder_json(bridge('files', 'move', src, dst))
            else:
                self.responder_json({'erro': 'campos "src" e "dst" são obrigatórios'}, 400)

        elif caminho == '/api/files/copy':
            corpo = self.ler_corpo_json()
            src, dst = corpo.get('src', ''), corpo.get('dst', '')
            if src and dst:
                self.responder_json(bridge('files', 'copy', src, dst))
            else:
                self.responder_json({'erro': 'campos "src" e "dst" são obrigatórios'}, 400)

        elif caminho == '/api/files/rename':
            corpo = self.ler_corpo_json()
            src, nome = corpo.get('src', ''), corpo.get('name', '')
            if src and nome:
                self.responder_json(bridge('files', 'rename', src, nome))
            else:
                self.responder_json({'erro': 'campos "src" e "name" são obrigatórios'}, 400)

        elif caminho == '/api/files/delete':
            corpo = self.ler_corpo_json()
            path = corpo.get('path', '')
            if path:
                self.responder_json(bridge('files', 'delete', path))
            else:
                self.responder_json({'erro': 'campo "path" ausente'}, 400)

        elif caminho == '/api/files/mkdir':
            corpo = self.ler_corpo_json()
            path = corpo.get('path', '')
            if path:
                self.responder_json(bridge('files', 'mkdir', path))
            else:
                self.responder_json({'erro': 'campo "path" ausente'}, 400)

        # Sistema
        elif caminho == '/api/system/updates/install':
            self.responder_json(bridge('system', 'updates_install'))

        # Window
        elif caminho == '/api/window/open':
            corpo = self.ler_corpo_json()
            url = corpo.get('url', '')
            if url:
                self.responder_json(bridge('window', 'open', url))
            else:
                self.responder_json({'erro': 'campo "url" ausente'}, 400)

        # Wizard
        elif caminho == '/api/wizard/install-browsers':
            corpo = self.ler_corpo_json()
            nav = corpo.get('nav', 'firefox')
            self.responder_json(bridge('wizard', 'install_browsers', nav))

        elif caminho == '/api/wizard/complete':
            corpo = self.ler_corpo_json()
            nav   = corpo.get('nav', '')
            senha = corpo.get('senha', '')
            self.responder_json(bridge('wizard', 'complete', nav, senha))

        elif caminho == '/api/wizard/set-admin-password':
            corpo = self.ler_corpo_json()
            senha = corpo.get('senha', '')
            if senha:
                self.responder_json(bridge('wizard', 'set_admin_password', senha))
            else:
                self.responder_json({'erro': 'campo "senha" ausente'}, 400)

        # Nav — controle da barra de navegação via xdotool
        elif caminho == '/api/nav/navigate':
            corpo = self.ler_corpo_json()
            url = corpo.get('url', '')
            if url:
                self.responder_json(bridge('nav', 'navigate', url))
            else:
                self.responder_json({'erro': 'campo "url" ausente'}, 400)

        elif caminho in ('/api/nav/newtab', '/api/nav/closetab',
                         '/api/nav/nexttab', '/api/nav/prevtab'):
            subcmd = caminho.split('/')[-1]   # newtab | closetab | nexttab | prevtab
            self.responder_json(bridge('nav', subcmd))

        else:
            self.send_response(404)
            self.end_headers()

    # ── OPTIONS (CORS preflight) ──────────────────────────────────────────────

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()


# ─────────────────────────────────────────────────────────────────────────────
# SERVIDOR
# ─────────────────────────────────────────────────────────────────────────────

class _ServidorThreaded(http.server.ThreadingHTTPServer):
    """Permite múltiplas requisições simultâneas sem bloquear."""
    daemon_threads = True
    allow_reuse_address = True


def main():
    if not UI_DIR.exists():
        print(
            f'[jett-ui-server] AVISO: diretório de UI não encontrado em {UI_DIR}',
            file=sys.stderr,
        )

    if not os.path.exists(BRIDGE):
        print(
            f'[jett-ui-server] AVISO: bridge não encontrado em {BRIDGE}',
            file=sys.stderr,
        )

    servidor = _ServidorThreaded((HOST, PORTA), Handler)
    print(f'[jett-ui-server] Ouvindo em http://{HOST}:{PORTA}/', flush=True)

    try:
        servidor.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        servidor.server_close()
        print('[jett-ui-server] Encerrado.', flush=True)


if __name__ == '__main__':
    main()
