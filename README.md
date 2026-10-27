# scripts

Coleção de scripts de instalação e manutenção de ferramentas, feitos para
instalar tudo dentro do `$HOME` do usuário. São ideais para distribuições
imutáveis como **Aurora / Fedora Kinoite** (rpm-ostree), onde não se deve
escrever em `/usr`.

Todos os instaladores seguem o mesmo padrão de subcomandos (`install`,
`update`, `check`, `version`, `uninstall`), usam a fonte oficial de cada
projeto e replicam o layout de uma instalação nativa (binários em
`~/.local/bin`, lançadores em `~/.local/share/applications`, etc.).

## Estrutura

```
scripts/
└── bash/
    ├── kiro-cli-installer.sh         # Instalador/atualizador do Kiro CLI
    ├── kiro-ide-installer.sh         # Instalador/atualizador do Kiro IDE
    ├── kitty-installer.sh            # Instalador/atualizador do terminal Kitty
    ├── libreoffice-flatpak-open-fix.sh  # Corrige abertura de docs do LibreOffice via navegador Flatpak
    └── wkhtmltopdf-distrobox-installer.sh  # Instala wkhtmltopdf (Qt patcheado) via Distrobox
```

## Requisitos gerais

Utilitários comuns esperados no sistema (variam por script): `curl`, `grep`,
`sort`, `mktemp`, `unzip`, `sha256sum`, `tar`, `find`, `sed`. Cada script
verifica suas dependências e aborta com mensagem clara se algo estiver
ausente. Certifique-se de que `~/.local/bin` esteja no seu `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Scripts

### `bash/kiro-cli-installer.sh`

Instala e atualiza o **Kiro CLI** usando a mesma fonte oficial de
`curl https://cli.kiro.dev/install | bash` (manifest + pacote `.zip`),
com verificação de checksum sha256.

- Binários: `~/.local/bin` (`kiro-cli`, `kiro-cli-chat`, `kiro-cli-term`)
- Runtime/dados: `~/.local/share/kiro-cli`
- Detecta arquitetura (`x86_64`/`aarch64`) e decide entre build glibc e musl.
- No `update`, prefere o updater embutido (`kiro-cli update`) quando disponível.

```bash
./bash/kiro-cli-installer.sh install     # instala/reinstala a última versão
./bash/kiro-cli-installer.sh update      # atualiza se houver versão mais nova
./bash/kiro-cli-installer.sh check       # verifica atualização (exit 10 se houver)
./bash/kiro-cli-installer.sh version     # mostra a versão instalada
./bash/kiro-cli-installer.sh uninstall   # remove binários/runtime (preserva config)
```

Variáveis de ambiente opcionais:

| Variável | Descrição | Default |
| --- | --- | --- |
| `KIRO_CLI_CHANNEL` | Canal de release | `stable` |
| `KIRO_CLI_FORCE_MUSL` | `=1` força o uso do build musl | — |
| `KIRO_CLI_NO_SELF` | `=1` não usa o updater embutido; sempre reinstala | — |

### `bash/kiro-ide-installer.sh`

Instala e atualiza o **Kiro IDE** a partir do tarball "Universal" Linux x64,
descobrindo a última versão pelo endpoint oficial de metadados em JSON (o mesmo
usado pelo auto-update do Kiro). Usa `jq` quando disponível, com fallback para
`grep` caso não esteja instalado.

- IDE extraído em: `~/.kiro-ide`
- Symlink do executável: `~/.local/bin/kiro`
- Lançador (menu): `~/.local/share/applications/kiro-ide.desktop`
- Handler de URL `kiro://`: `~/.local/share/applications/kiro-url-handler.desktop`
- Suporta fixar (pin) uma versão específica no `install`.

```bash
./bash/kiro-ide-installer.sh install          # instala/reinstala a última versão
./bash/kiro-ide-installer.sh install 1.0.337  # instala uma versão específica (pin)
./bash/kiro-ide-installer.sh update           # atualiza se houver versão mais nova
./bash/kiro-ide-installer.sh check            # verifica atualização (exit 10 se houver)
./bash/kiro-ide-installer.sh version          # mostra a versão instalada
./bash/kiro-ide-installer.sh uninstall        # remove a instalação (preserva ~/.kiro)
```

Variáveis de ambiente opcionais:

| Variável | Descrição | Default |
| --- | --- | --- |
| `KIRO_INSTALL_DIR` | Diretório de instalação | `~/.kiro-ide` |
| `KIRO_CHANNEL` | Canal de release | `stable` |

### `bash/kitty-installer.sh`

Instala e atualiza o terminal **Kitty** usando o método oficial do projeto
(`installer.sh` do kitty), mais a integração desktop documentada.

- Instalação em: `~/.local/kitty.app` (re-executar atualiza)
- Symlinks: `~/.local/bin/kitty` e `~/.local/bin/kitten`
- Lançadores: `kitty.desktop` e `kitty-open.desktop` em `~/.local/share/applications`
- Registra kitty como terminal padrão via `~/.config/xdg-terminals.list`
- `--link-config` cria o symlink `~/.config/kitty` a partir dos dotfiles (GNU Stow)

```bash
./bash/kitty-installer.sh install --link-config  # instala + integração + config
./bash/kitty-installer.sh install 0.48.2         # instala versão específica
./bash/kitty-installer.sh update                 # atualiza se houver versão mais nova
./bash/kitty-installer.sh check                  # verifica atualização (exit 10 se houver)
./bash/kitty-installer.sh version                # mostra a versão instalada
./bash/kitty-installer.sh link-config            # só cria o symlink de config (stow)
./bash/kitty-installer.sh uninstall              # remove kitty.app, symlinks e lançadores
```

Variáveis de ambiente opcionais:

| Variável | Descrição | Default |
| --- | --- | --- |
| `KITTY_DEST` | Diretório de instalação | `~/.local/kitty.app` |
| `KITTY_LAUNCH` | `=1` abre o kitty após instalar | — |

### `bash/libreoffice-flatpak-open-fix.sh`

Corrige o erro **"/run/user/&lt;uid&gt;/doc/.../arquivo.xlsx não existe"** ao abrir
documentos baixados pelo navegador (**Firefox/LibreWolf Flatpak**) quando o
**LibreOffice também é Flatpak**.

A causa é um desencontro de app-id: o handler padrão aponta para o `.desktop`
do subaplicativo (`org.libreoffice.LibreOffice.calc`/`.writer`/`.impress`), que
não corresponde ao app-id real do Flatpak (`org.libreoffice.LibreOffice`), e o
document portal se recusa a montar o arquivo no sandbox.

A correção tem duas partes:

1. Define o handler dos documentos (Calc, Writer e Impress) para
   `org.libreoffice.LibreOffice.desktop`.
2. Troca `--filesystem=host` por `home` (+ `/run/media`) no LibreOffice,
   restaurando a integração com o document portal.

- Usa apenas handlers MIME do usuário e `flatpak override --user` (nada fora do `$HOME`).
- É idempotente; `uninstall` reverte handlers e reseta os overrides.

```bash
./bash/libreoffice-flatpak-open-fix.sh apply             # aplica tudo (handler + permissões)
./bash/libreoffice-flatpak-open-fix.sh apply --no-perms  # aplica só o handler
./bash/libreoffice-flatpak-open-fix.sh check             # há algo a corrigir? (exit 10 se sim)
./bash/libreoffice-flatpak-open-fix.sh verify            # mostra o estado atual
./bash/libreoffice-flatpak-open-fix.sh uninstall         # reverte handlers e reseta permissões
```

Variáveis de ambiente opcionais:

| Variável | Descrição | Default |
| --- | --- | --- |
| `LO_FIX_NO_PERMS` | `=1` não altera as permissões do Flatpak | — |

### `bash/wkhtmltopdf-distrobox-installer.sh`

Instala e atualiza o **wkhtmltopdf** (variante **"with patched qt"**) num
sistema imutável usando **Distrobox**. O `wkhtmltopdf` foi descontinuado (repo
arquivado em jan/2023) e removido do Homebrew e dos repositórios oficiais; a
única fonte confiável do binário com Qt patcheado — exigido por sistemas como
o **SUAP** para renderizar HTML/CSS corretamente — é o RPM oficial arquivado do
projeto `wkhtmltopdf/packaging`.

O script cria um container Fedora dedicado, instala o RPM oficial lá dentro
(o `dnf` resolve Qt e fontes) e **exporta** os binários para o host, deixando-os
disponíveis como se fossem nativos, sem escrever em `/usr`.

- Container Distrobox: `wkhtmltopdf-box` (Fedora)
- Binários exportados: `~/.local/bin/wkhtmltopdf`, `~/.local/bin/wkhtmltoimage`
- Estado (tag instalada): `~/.local/share/wkhtmltopdf-distrobox/installed-tag`
- Detecta arquitetura (`x86_64`/`aarch64`) e escolhe o `.rpm` Fedora mais recente.

```bash
./bash/wkhtmltopdf-distrobox-installer.sh install     # cria container + instala + exporta
./bash/wkhtmltopdf-distrobox-installer.sh update      # atualiza se houver versão mais nova
./bash/wkhtmltopdf-distrobox-installer.sh check       # verifica atualização (exit 10 se houver)
./bash/wkhtmltopdf-distrobox-installer.sh version     # mostra a versão instalada
./bash/wkhtmltopdf-distrobox-installer.sh test        # gera um PDF de teste a partir do host
./bash/wkhtmltopdf-distrobox-installer.sh uninstall   # remove binários exportados e o container
```

> O container `wkhtmltopdf-box` precisa existir para o binário funcionar (é onde
> o executável real reside). A primeira chamada pode ter um pequeno atraso
> enquanto o container inicia.

Variáveis de ambiente opcionais:

| Variável | Descrição | Default |
| --- | --- | --- |
| `WK_BOX_NAME` | Nome do container Distrobox | `wkhtmltopdf-box` |
| `WK_BOX_IMAGE` | Imagem base do container | `registry.fedoraproject.org/fedora:41` |
| `WK_FEDORA_TAG` | Tag do asset `.rpm` (fallback) | `fedora37` |
| `WK_PIN_VERSION` | Fixa uma versão específica (ex.: `0.12.6.1-3`) | — |

## Convenções

- **Comando `check`**: retorna exit code `10` quando há atualização disponível,
  útil para automações e verificações periódicas.
- **Uninstall preserva dados/config**: cada script remove apenas binários e
  runtime, mantendo diretórios de configuração e dados do usuário.
- **Nada é escrito fora do `$HOME`**, garantindo compatibilidade com sistemas
  de arquivos imutáveis.

## Uso

Torne o script executável e rode o subcomando desejado:

```bash
chmod +x bash/kiro-cli-installer.sh
./bash/kiro-cli-installer.sh install
```

## Licença

Distribuído sob a licença MIT. Veja o arquivo [LICENSE](LICENSE) para os
termos completos.

Copyright (c) 2026 Daniel Lopes Soares Lima
