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
    ├── kiro-cli-installer.sh   # Instalador/atualizador do Kiro CLI
    ├── kiro-ide-installer.sh   # Instalador/atualizador do Kiro IDE
    └── kitty-installer.sh      # Instalador/atualizador do terminal Kitty
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
descobrindo a última versão na página oficial de downloads.

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
