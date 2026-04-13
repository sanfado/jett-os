# Jett OS

> Como um jato: ignição imediata, velocidade máxima, sem peso desnecessário.

Jett OS é uma distribuição Linux minimalista construída com um único propósito: inicializar diretamente em um navegador web em modo kiosk. Sem desktop environment, sem menus, sem distrações. O sistema **é** o navegador.

---

## Navegadores Suportados

| Navegador      | Site oficial                   |
|----------------|--------------------------------|
| Brave          | brave.com                      |
| Microsoft Edge | microsoft.com/edge             |
| Thorium        | thorium.rocks                  |
| Opera GX       | opera.com/gx                   |
| Firefox        | mozilla.org/firefox            |

---

## Pré-requisitos de Sistema

### Para construir a ISO (ambiente de build)
- Sistema operacional: Debian 12 (Bookworm) ou Ubuntu 22.04+
- Pacotes necessários:
  ```
  sudo apt install live-build debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin
  ```
- Espaço em disco: mínimo 10 GB livres
- RAM: mínimo 4 GB
- Conexão com a internet (para baixar pacotes durante o build)

### Para rodar o Jett OS (hardware alvo)
- Arquitetura: x86_64 (64-bit)
- RAM: mínimo 512 MB (recomendado 2 GB+)
- Armazenamento: mínimo 4 GB
- GPU: Intel integrado ou AMD (drivers Mesa)
- Modo UEFI ou BIOS Legacy (ambos suportados)

---

## Estrutura do Projeto

```
jett-os/
├── build/
│   ├── build-base.sh          # Orquestrador — chama os módulos em sequência
│   ├── base/                  # Módulos do build da base do sistema
│   │   ├── lib.sh             # Variáveis, cores e funções de log compartilhadas
│   │   ├── 01-update.sh       # Atualiza repositórios e sistema base
│   │   ├── 02-remove-bloat.sh # Remove pacotes desnecessários
│   │   ├── 03-install-packages.sh # Instala Sway, fontes, áudio, bluetooth, utilitários
│   │   ├── 04-user.sh         # Cria e configura o usuário kiosk 'jett' + sudoers
│   │   ├── 05-sway.sh         # Configura Sway, serviços systemd, scripts e /etc/jett-os/
│   │   ├── 06-network.sh      # DHCP via systemd-networkd e hook de DNS
│   │   └── 07-bbr.sh          # TCP BBR e configuração do navegador padrão
│   └── browsers/              # Scripts de instalação de cada navegador
│       ├── install-brave.sh
│       ├── install-edge.sh
│       ├── install-thorium.sh
│       ├── install-opera-gx.sh
│       └── install-firefox.sh
│
├── config/
│   ├── sway/
│   │   ├── config             # Configuração do Sway (atalhos, for_window, exec)
│   │   ├── jett-sudoers       # Regras sudo do launcher (instaladas em /etc/sudoers.d/)
│   │   └── sway-kiosk.service # Serviço systemd do compositor (referência)
│   ├── systemd/
│   │   └── jett-updater.service # Serviço do daemon de atualizações automáticas
│   └── browsers/              # Perfis de flags de cada navegador
│       ├── brave.conf
│       ├── edge.conf
│       ├── thorium.conf
│       ├── opera-gx.conf
│       └── firefox.conf
│
├── launcher/
│   ├── scripts/               # Executáveis do launcher (instalados em /usr/local/bin/)
│   │   ├── jett-launcher.py   # UI tkinter de seleção de navegador (Super+B)
│   │   ├── jett-switch.sh     # Troca o navegador ativo em runtime
│   │   ├── jett-exit-confirm  # Dialog de confirmação de saída do Sway (Super+Shift+E)
│   │   ├── jett-bridge.sh     # Ponte HTML → OS (volume, rede, wifi, bluetooth, USB, arquivos)
│   │   ├── jett-nav-toggle.sh # Alterna a barra de navegação (Super sozinho)
│   │   ├── jett-menu-toggle.sh # Alterna o menu de sistema (Super+X)
│   │   ├── jett-files-toggle.sh # Alterna o gerenciador de arquivos (Super+F)
│   │   ├── jett-firstboot.sh  # Inicia o wizard de primeiro boot
│   │   └── jett-updater.sh    # Daemon de verificação de atualizações (a cada 6h)
│   ├── server/
│   │   └── jett-ui-server.py  # Servidor HTTP 127.0.0.1:1312 (API REST + HTML)
│   └── ui/                    # Interfaces HTML servidas pelo jett-ui-server
│       ├── nav.html           # Barra de navegação flutuante (endereço, abas, relógio, status)
│       ├── menu.html          # Menu de sistema (volume, WiFi, Bluetooth, USB, apps, energia)
│       ├── wizard.html        # Assistente de primeiro boot (navegador + senha + WiFi)
│       └── files.html         # Gerenciador de arquivos dual-panel (DnD, multi-select, USB)
│
├── docs/
│   ├── VERSIONING.md          # Esquema de versões (v0.x-alpha → v1.0-beta → v1.0)
│   └── LICENSE                # Licença MIT
│
├── tests/                     # Scripts de teste de latência e validação
└── README.md
```

---

## Atalhos de Teclado

| Atalho        | Ação                                             |
|---------------|--------------------------------------------------|
| Super         | Abre/fecha a barra de navegação flutuante        |
| Super+X       | Abre/fecha o menu de sistema                     |
| Super+F       | Abre/fecha o gerenciador de arquivos             |
| Super+B       | Abre o seletor de navegador (tkinter)            |
| Super+Shift+E | Dialog de confirmação para sair do Sway          |

---

## Instruções de Build

> As instruções completas estão em desenvolvimento. Cada camada é construída e verificada antes de avançar.

### Build rápido (quando disponível)
```bash
# Clone o repositório
git clone https://github.com/SEU_USUARIO_GITHUB/jett-os.git
cd jett-os

# Execute o script de build principal
chmod +x build/build-iso.sh
sudo ./build/build-iso.sh

# A ISO será gerada em: build/output/jett-os.iso
```

### Testar em máquina virtual
```bash
# Com QEMU
qemu-system-x86_64 -enable-kvm -m 2G -cdrom build/output/jett-os.iso -vga virtio
```

---

## Camadas de Desenvolvimento

| Camada | Descrição                                                         | Status       |
|--------|-------------------------------------------------------------------|--------------|
| 1      | Fundação — base Debian + Sway + kiosk + um navegador             | Concluída    |
| 2      | Launcher — barra de navegação, menu de sistema, primeiro boot    | Concluída    |
| 3      | Todos os navegadores + gerenciador de arquivos + atualizações    | Concluída    |
| 4      | ISO bootável para distribuição                                    | Em andamento |

---

## Como Contribuir

Contribuições são bem-vindas, especialmente em duas áreas:

**Perfis de navegador** (`config/browsers/`): cada arquivo `.conf` define as flags técnicas de integração com o Jett OS para um navegador. Se você identificou uma flag útil ou um ajuste de performance, abra um pull request com justificativa técnica no comentário da flag.

**Scripts de instalação** (`build/browsers/`): melhorias de idempotência, suporte a novas arquiteturas, ou correções de repositório são contribuições diretas.

Para contribuir:
1. Faça um fork do repositório
2. Crie uma branch descritiva (`fix/opera-gx-repo`, `feat/thorium-avx512`)
3. Abra um pull request explicando o problema e a solução

Reporte bugs e sugestões via [Issues](../../issues).

---

## Filosofia

**O sistema é o navegador.**

Cada milissegundo entre o POST da BIOS e o primeiro pixel do navegador é desperdício. Jett OS elimina esse desperdício. Sem gerenciador de janelas, sem barra de tarefas, sem processos em segundo plano competindo por recursos. Apenas hardware, kernel, Wayland, Sway, e o navegador da sua escolha.

---

## Licença

MIT — veja `docs/LICENSE` para detalhes.
