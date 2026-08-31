#!/usr/bin/env bash
#
# kitty-installer.sh
# ---------------------------------------------------------------------------
# Instalador / atualizador do Kitty (terminal), com integracao desktop.
#
# Feito para instalacao no $HOME, ideal para distros imutaveis como
# Aurora / Fedora Kinoite (rpm-ostree), onde nao se deve escrever em /usr.
#
# Segue o metodo OFICIAL do kitty (installer.sh do proprio projeto), que:
#   - Instala em            : ~/.local/kitty.app
#   - Nao toca em nada fora desse diretorio
#   - Re-executar = atualiza
#
# Alem disso, este script faz a "Desktop integration on Linux" documentada:
#   - Symlinks              : ~/.local/bin/kitty  e  ~/.local/bin/kitten
#   - Lancadores            : ~/.local/share/applications/kitty.desktop
#                             ~/.local/share/applications/kitty-open.desktop
#   - Ajusta Icon= e Exec= com caminho absoluto
#   - Registra xdg-terminals.list (kitty como terminal padrao p/ quem suporta)
#
# Config (dotfiles): seus arquivos ja estao em ~/dotfiles/kitty (GNU Stow).
#   Use --link-config para criar o symlink ~/.config/kitty via stow.
#
# Uso:
#   ./kitty-installer.sh install [--link-config]   # instala a ultima versao + integracao
#   ./kitty-installer.sh update                    # atualiza se houver versao mais nova
#   ./kitty-installer.sh check                      # verifica atualizacao (exit 10 se houver)
#   ./kitty-installer.sh version                    # versao instalada
#   ./kitty-installer.sh install 0.48.2             # instala versao especifica
#   ./kitty-installer.sh link-config                # so cria o symlink de config (stow)
#   ./kitty-installer.sh uninstall                  # remove kitty.app, symlinks e lancadores
#
# Variaveis de ambiente opcionais:
#   KITTY_DEST        diretorio de instalacao (default: ~/.local/kitty.app)
#   KITTY_LAUNCH      =1 abre o kitty apos instalar (default: nao)
# ---------------------------------------------------------------------------

set -euo pipefail

# --------------------------- Configuracao ----------------------------------

DEST="${KITTY_DEST:-$HOME/.local/kitty.app}"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$HOME/.local/share/applications"
CONFIG_DIR="$HOME/.config/kitty"
XDG_TERMINALS_LIST="$HOME/.config/xdg-terminals.list"

DOTFILES_DIR="$HOME/dotfiles"          # raiz dos dotfiles (GNU Stow)
STOW_PKG="kitty"                       # pacote stow -> ~/dotfiles/kitty/.config/kitty

INSTALLER_URL="https://sw.kovidgoyal.net/kitty/installer.sh"
CURRENT_VERSION_URL="https://sw.kovidgoyal.net/kitty/current-version.txt"

# --------------------------- Utilidades -------------------------------------

c_reset='\033[0m'; c_bold='\033[1m'; c_grn='\033[32m'; c_yel='\033[33m'; c_red='\033[31m'; c_blu='\033[34m'
log()  { printf "${c_blu}==>${c_reset} %s\n" "$*"; }
ok()   { printf "${c_grn}✓${c_reset} %s\n" "$*"; }
warn() { printf "${c_yel}!${c_reset} %s\n" "$*"; }
err()  { printf "${c_red}✗ %s${c_reset}\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Comando necessario ausente: $1"; }

# Compara versoes semver. Retorna 0 se $1 > $2.
ver_gt() {
    [ "$1" = "$2" ] && return 1
    local greater
    greater="$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)"
    [ "$greater" = "$1" ]
}

# --------------------------- Versao -----------------------------------------

installed_version() {
    local bin="$DEST/bin/kitty"
    [ -x "$bin" ] || { echo ""; return 0; }
    "$bin" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

latest_version() {
    curl -fsSL --max-time 30 "$CURRENT_VERSION_URL" 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

# --------------------------- Integracao desktop -----------------------------

setup_desktop_integration() {
    mkdir -p "$BIN_DIR" "$APPS_DIR" "$(dirname "$XDG_TERMINALS_LIST")"

    # Symlinks para PATH (kitty e kitten) apontando para dentro de kitty.app.
    ln -sf "$DEST/bin/kitty" "$DEST/bin/kitten" "$BIN_DIR/"

    # Copia os .desktop e ajusta Icon=/Exec= com caminho absoluto.
    local abs_home icon
    abs_home="$(readlink -f "$HOME")"
    icon="$abs_home/.local/kitty.app/share/icons/hicolor/256x256/apps/kitty.png"

    for df in kitty.desktop kitty-open.desktop; do
        local src="$DEST/share/applications/$df"
        [ -f "$src" ] || continue
        cp -f "$src" "$APPS_DIR/$df"
        sed -i "s|Icon=kitty|Icon=$icon|g" "$APPS_DIR/$df"
        sed -i "s|Exec=kitty|Exec=$DEST/bin/kitty|g" "$APPS_DIR/$df"
    done

    # kitty como terminal padrao para ambientes que suportam xdg-terminal-exec.
    echo 'kitty.desktop' > "$XDG_TERMINALS_LIST"

    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true

    ok "Integracao desktop concluida:"
    printf '    %s\n' "$BIN_DIR/kitty -> $DEST/bin/kitty" "$BIN_DIR/kitten -> $DEST/bin/kitten" \
        "$APPS_DIR/kitty.desktop" "$APPS_DIR/kitty-open.desktop"

    case ":$PATH:" in
        *":$BIN_DIR:"*) : ;;
        *) warn "$BIN_DIR nao esta no PATH. Adicione ao shell rc: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
    esac
}

# Cria o symlink ~/.config/kitty a partir dos dotfiles (GNU Stow).
link_config() {
    local pkg_path="$DOTFILES_DIR/$STOW_PKG/.config/kitty"
    if [ ! -d "$pkg_path" ]; then
        warn "Dotfiles nao encontrados em $pkg_path — pulando link de config."
        return 0
    fi
    if [ -e "$CONFIG_DIR" ] && [ ! -L "$CONFIG_DIR" ]; then
        warn "$CONFIG_DIR ja existe e nao e um symlink. Nao vou sobrescrever."
        return 0
    fi
    if command -v stow >/dev/null 2>&1; then
        log "Linkando config via GNU Stow ($STOW_PKG)"
        ( cd "$DOTFILES_DIR" && stow -v -R "$STOW_PKG" )
    else
        warn "GNU Stow nao instalado; criando symlink direto."
        mkdir -p "$(dirname "$CONFIG_DIR")"
        ln -sfn "$pkg_path" "$CONFIG_DIR"
    fi
    ok "Config linkada: $CONFIG_DIR -> $pkg_path"
}

# --------------------------- Instalacao -------------------------------------

# Executa o installer.sh oficial. Aceita versao opcional como $1.
run_official_installer() {
    need curl
    local ver="${1:-}"
    local args="dest=$DEST"
    [ "${KITTY_LAUNCH:-0}" = "1" ] || args="$args launch=n"
    [ -n "$ver" ] && args="$args installer=version-$ver"

    log "Executando installer oficial do kitty ($args)"
    # shellcheck disable=SC2086
    curl -L --fail --silent --show-error "$INSTALLER_URL" | sh /dev/stdin $args
}

do_install() {
    local ver="${1:-}" link_cfg="${2:-0}"
    run_official_installer "$ver"
    [ -x "$DEST/bin/kitty" ] || die "Instalacao falhou: $DEST/bin/kitty nao existe."
    setup_desktop_integration
    [ "$link_cfg" = "1" ] && link_config
    ok "Kitty ${c_bold}$(installed_version)${c_reset} instalado em $DEST"
}

# --------------------------- Comandos ---------------------------------------

cmd_check() {
    local cur latest
    cur="$(installed_version)"
    latest="$(latest_version)"
    [ -n "$latest" ] || die "Nao foi possivel descobrir a versao mais recente."
    printf 'Instalada:      %s\n' "${cur:-nenhuma}"
    printf 'Mais recente:   %s\n' "$latest"
    if [ -z "$cur" ]; then
        warn "Kitty nao esta instalado. Rode: $0 install"
        return 0
    fi
    if ver_gt "$latest" "$cur"; then
        warn "Atualizacao disponivel: $cur -> $latest  (rode: $0 update)"
        return 10
    fi
    ok "Voce ja esta na versao mais recente."
    return 0
}

cmd_update() {
    local cur latest
    cur="$(installed_version)"
    if [ -z "$cur" ]; then
        warn "Nada instalado; executando instalacao completa."
        do_install "" 0
        return
    fi
    latest="$(latest_version)"
    if ver_gt "$latest" "$cur"; then
        log "Atualizando $cur -> $latest"
        # Re-executar o installer no mesmo dest atualiza (metodo oficial).
        run_official_installer ""
        setup_desktop_integration
        ok "Atualizado para $(installed_version)."
    else
        ok "Ja na versao mais recente ($cur). Nada a fazer."
    fi
}

cmd_uninstall() {
    log "Removendo Kitty (config em ~/.config/kitty e dotfiles preservados)"
    rm -rf "$DEST"
    rm -f "$BIN_DIR/kitty" "$BIN_DIR/kitten"
    rm -f "$APPS_DIR/kitty.desktop" "$APPS_DIR/kitty-open.desktop"
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
    ok "Kitty removido."
}

usage() {
    cat <<EOF
${c_bold}Kitty installer/updater${c_reset}  (Aurora/Fedora Kinoite, instalacao em \$HOME)

Uso: $0 <comando> [opcoes]

Comandos:
  install [VER] [--link-config]  Instala a ultima versao (ou VER) + integracao desktop
  update                         Atualiza se houver versao mais nova
  check                          Verifica atualizacao (exit 10 se houver)
  version                        Mostra a versao instalada
  link-config                    Cria symlink ~/.config/kitty a partir dos dotfiles (stow)
  uninstall                      Remove kitty.app, symlinks e lancadores

Exemplos:
  $0 install --link-config
  $0 install 0.48.2
  $0 check
  $0 update

Variaveis:
  KITTY_DEST=~/.local/kitty.app   diretorio de instalacao
  KITTY_LAUNCH=1                  abre o kitty ao final da instalacao
EOF
}

# --------------------------- Main -------------------------------------------

main() {
    need curl; need sort; need sed; need grep

    local cmd="${1:-}"; shift || true

    # Parse simples de opcoes/args restantes.
    local ver="" link_cfg=0 a
    for a in "$@"; do
        case "$a" in
            --link-config) link_cfg=1 ;;
            [0-9]*.[0-9]*) ver="$a" ;;
            *) ;;
        esac
    done

    case "$cmd" in
        install)     do_install "$ver" "$link_cfg" ;;
        update)      cmd_update ;;
        check)       cmd_check ;;
        version)     local v; v="$(installed_version)"; echo "${v:-nenhuma}" ;;
        link-config) link_config ;;
        uninstall)   cmd_uninstall ;;
        ""|-h|--help|help) usage ;;
        *) err "Comando desconhecido: $cmd"; echo; usage; exit 1 ;;
    esac
}

main "$@"
