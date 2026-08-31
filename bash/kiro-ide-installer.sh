#!/usr/bin/env bash
#
# kiro-ide-installer.sh
# ---------------------------------------------------------------------------
# Instalador / atualizador do Kiro IDE (tarball "Universal" Linux x64).
#
# Feito para instalacoes no $HOME, ideal para distros imutaveis como
# Aurora / Fedora Kinoite (rpm-ostree), onde nao se deve escrever em /usr.
#
# Replica o layout da instalacao atual:
#   - IDE extraido em        : ~/.kiro-ide
#   - Symlink do executavel  : ~/.local/bin/kiro -> ~/.kiro-ide/bin/kiro
#   - Lancador (menu)        : ~/.local/share/applications/kiro-ide.desktop
#   - Handler de URL kiro:// : ~/.local/share/applications/kiro-url-handler.desktop
#
# Uso:
#   ./kiro-ide-installer.sh install        # instala (ou reinstala) a ultima versao
#   ./kiro-ide-installer.sh update         # atualiza somente se houver versao mais nova
#   ./kiro-ide-installer.sh check          # apenas verifica se ha atualizacao (nao instala)
#   ./kiro-ide-installer.sh version        # mostra a versao instalada
#   ./kiro-ide-installer.sh install 1.0.337   # instala uma versao especifica (pin)
#   ./kiro-ide-installer.sh uninstall      # remove a instalacao (preserva ~/.kiro de dados)
#
# Variaveis de ambiente opcionais:
#   KIRO_INSTALL_DIR   diretorio de instalacao (default: ~/.kiro-ide)
#   KIRO_CHANNEL       canal de release        (default: stable)
# ---------------------------------------------------------------------------

set -euo pipefail

# --------------------------- Configuracao ----------------------------------

CHANNEL="${KIRO_CHANNEL:-stable}"
ARCH_KEY="linux-x64"

INSTALL_DIR="${KIRO_INSTALL_DIR:-$HOME/.kiro-ide}"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$HOME/.local/share/applications"
MIME_DIR="$HOME/.local/share/mime/packages"

BIN_SYMLINK="$BIN_DIR/kiro"
DESKTOP_FILE="$APPS_DIR/kiro-ide.desktop"
URLHANDLER_FILE="$APPS_DIR/kiro-url-handler.desktop"
MIME_FILE="$MIME_DIR/kiro-url-handler.desktop"

DOWNLOADS_PAGE="https://kiro.dev/downloads/"
# Padrao de URL de fallback caso o scraping da pagina mude:
#   https://prod.download.desktop.kiro.dev/releases/stable/linux-x64/signed/<VER>/tar/kiro-ide-<VER>-stable-linux-x64.tar.gz
DL_BASE="https://prod.download.desktop.kiro.dev/releases"

# Diretorio temporario (global p/ o trap EXIT funcionar com `set -u`).
tmp=""

# --------------------------- Utilidades -------------------------------------

c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_blu=$'\033[34m'
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

# --------------------------- Descoberta de versao ---------------------------

# Le a versao instalada a partir do product.json.
installed_version() {
    local pj="$INSTALL_DIR/resources/app/product.json"
    [ -f "$pj" ] || { echo ""; return 0; }
    # Ultima ocorrencia de "version" no product.json e a versao do Kiro.
    grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$pj" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -n1
}

# Descobre a URL do tarball "Latest" na pagina oficial de downloads.
latest_tarball_url() {
    curl -fsSL --max-time 30 "$DOWNLOADS_PAGE" 2>/dev/null \
        | grep -oE "https://prod\.download\.desktop\.kiro\.dev/releases/${CHANNEL}/${ARCH_KEY}/signed/[0-9.]+/tar/kiro-ide-[0-9.]+-stable-${ARCH_KEY}\.tar\.gz" \
        | head -n1
}

# Extrai a versao "X.Y.Z" de uma URL de tarball.
url_version() {
    printf '%s' "$1" | grep -oE 'kiro-ide-[0-9]+\.[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

# Monta URL a partir de uma versao especifica (fallback / pin).
url_for_version() {
    local v="$1"
    printf '%s/%s/%s/signed/%s/tar/kiro-ide-%s-stable-%s.tar.gz' \
        "$DL_BASE" "$CHANNEL" "$ARCH_KEY" "$v" "$v" "$ARCH_KEY"
}

# Resolve (URL, versao) da ultima release ou de uma versao fixada.
# Ecoa: "<url> <versao>"
resolve_target() {
    local pin="${1:-}"
    local url ver
    if [ -n "$pin" ]; then
        url="$(url_for_version "$pin")"
        ver="$pin"
    else
        url="$(latest_tarball_url)"
        [ -n "$url" ] || die "Nao foi possivel descobrir a versao mais recente (pagina de downloads mudou?)."
        ver="$(url_version "$url")"
    fi
    printf '%s %s' "$url" "$ver"
}

# --------------------------- Lancadores -------------------------------------

write_launchers() {
    mkdir -p "$BIN_DIR" "$APPS_DIR" "$MIME_DIR"

    # Symlink do executavel (mesmo alvo da instalacao atual: bin/kiro).
    ln -sfn "$INSTALL_DIR/bin/kiro" "$BIN_SYMLINK"

    # Icone: usa o code-icon.svg embutido; cai para "code-oss" se nao existir.
    local icon="$INSTALL_DIR/resources/app/out/media/code-icon.svg"
    [ -f "$icon" ] || icon="code-oss"

    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Kiro
Comment=Kiro IDE
Exec=$INSTALL_DIR/kiro %F
Icon=$icon
Type=Application
Categories=Development;IDE;
StartupWMClass=kiro
Terminal=false
EOF

    cat > "$URLHANDLER_FILE" <<EOF
[Desktop Entry]
Name=Kiro - URL Handler
Comment=Alongside you from concept to production.
GenericName=Kiro
Exec="$INSTALL_DIR/kiro" --open-url %U
Type=Application
NoDisplay=true
StartupNotify=true
Categories=Utility;TextEditor;Development;IDE;
MimeType=x-scheme-handler/kiro;
Keywords=kiro;
EOF

    # Registro MIME para o esquema kiro://
    cp -f "$URLHANDLER_FILE" "$MIME_FILE"

    # Atualiza caches (silencioso se as ferramentas nao existirem).
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
    command -v update-mime-database   >/dev/null 2>&1 && update-mime-database "$HOME/.local/share/mime" >/dev/null 2>&1 || true
    command -v xdg-mime               >/dev/null 2>&1 && xdg-mime default kiro-url-handler.desktop x-scheme-handler/kiro >/dev/null 2>&1 || true

    ok "Lancadores criados:"
    printf '    %s\n' "$BIN_SYMLINK -> $INSTALL_DIR/bin/kiro" "$DESKTOP_FILE" "$URLHANDLER_FILE"

    case ":$PATH:" in
        *":$BIN_DIR:"*) : ;;
        *) warn "$BIN_DIR nao esta no PATH. Adicione ao seu shell rc: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
    esac
}

# --------------------------- Download + extracao ----------------------------

do_install() {
    local url ver target tgz staging
    read -r url ver <<<"$(resolve_target "${1:-}")"

    log "Versao alvo: ${c_bold}$ver${c_reset}"
    log "URL: $url"

    # Verifica se o arquivo existe antes de baixar (evita extrair 404/html).
    if ! curl -fsSLI --max-time 30 "$url" >/dev/null 2>&1; then
        die "Tarball nao encontrado ($url). Versao invalida ou URL mudou."
    fi

    tmp="$(mktemp -d -t kiro-ide.XXXXXX)"
    trap 'rm -rf "${tmp:-}"' EXIT
    tgz="$tmp/kiro.tar.gz"

    log "Baixando..."
    curl -fL --progress-bar --max-time 900 -o "$tgz" "$url"

    log "Extraindo..."
    mkdir -p "$tmp/extract"
    tar -xzf "$tgz" -C "$tmp/extract"

    # O tarball extrai para uma pasta de topo (ex.: "Kiro/"). Detecta a raiz real.
    staging="$tmp/extract"
    if [ ! -x "$staging/bin/kiro" ]; then
        local inner
        inner="$(find "$tmp/extract" -maxdepth 4 -path '*/bin/kiro' -print -quit 2>/dev/null || true)"
        [ -n "$inner" ] || die "Estrutura do tarball inesperada: nao encontrei bin/kiro."
        staging="$(dirname "$(dirname "$inner")")"
    fi

    # Substitui a instalacao de forma atomica.
    if [ -d "$INSTALL_DIR" ]; then
        log "Removendo instalacao anterior em $INSTALL_DIR"
        rm -rf "${INSTALL_DIR:?}"
    fi
    mkdir -p "$(dirname "$INSTALL_DIR")"
    mv "$staging" "$INSTALL_DIR"
    chmod +x "$INSTALL_DIR/kiro" "$INSTALL_DIR/bin/kiro" 2>/dev/null || true

    write_launchers
    ok "Kiro IDE ${c_bold}$ver${c_reset} instalado em $INSTALL_DIR"
}

# --------------------------- Comandos ---------------------------------------

cmd_check() {
    local cur latest url
    cur="$(installed_version)"
    read -r url latest <<<"$(resolve_target)"
    printf 'Instalada:      %s\n' "${cur:-nenhuma}"
    printf 'Mais recente:   %s\n' "$latest"
    if [ -z "$cur" ]; then
        warn "Kiro IDE nao esta instalado. Rode: $0 install"
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
    local cur latest url
    cur="$(installed_version)"
    if [ -z "$cur" ]; then
        warn "Nada instalado; executando instalacao completa."
        do_install
        return
    fi
    read -r url latest <<<"$(resolve_target)"
    if ver_gt "$latest" "$cur"; then
        log "Atualizando $cur -> $latest"
        do_install
    else
        ok "Ja na versao mais recente ($cur). Nada a fazer."
    fi
}

cmd_uninstall() {
    log "Removendo Kiro IDE (dados de usuario em ~/.kiro serao preservados)"
    rm -rf "${INSTALL_DIR:?}"
    rm -f "$BIN_SYMLINK" "$DESKTOP_FILE" "$URLHANDLER_FILE" "$MIME_FILE"
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
    ok "Kiro IDE removido. (Para apagar dados/config: rm -rf ~/.kiro)"
}

usage() {
    cat <<EOF
${c_bold}Kiro IDE installer/updater${c_reset}  (Aurora/Fedora Kinoite, instalacao em \$HOME)

Uso: $0 <comando> [versao]

Comandos:
  install [VER]   Instala/reinstala a ultima versao (ou a VER especificada)
  update          Atualiza somente se houver versao mais nova
  check           Verifica se ha atualizacao (exit 10 se houver)
  version         Mostra a versao instalada
  uninstall       Remove o IDE (preserva dados em ~/.kiro)

Exemplos:
  $0 install
  $0 install 1.0.337
  $0 check
  $0 update
EOF
}

# --------------------------- Main -------------------------------------------

main() {
    need curl; need tar; need grep; need sort; need find; need mktemp

    local cmd="${1:-}"
    case "$cmd" in
        install)   shift || true; do_install "${1:-}" ;;
        update)    cmd_update ;;
        check)     cmd_check ;;
        version)   local v; v="$(installed_version)"; echo "${v:-nenhuma}" ;;
        uninstall) cmd_uninstall ;;
        ""|-h|--help|help) usage ;;
        *) err "Comando desconhecido: $cmd"; echo; usage; exit 1 ;;
    esac
}

main "$@"
