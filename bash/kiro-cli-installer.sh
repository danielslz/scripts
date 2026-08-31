#!/usr/bin/env bash
#
# kiro-cli-installer.sh
# ---------------------------------------------------------------------------
# Instalador / atualizador do Kiro CLI.
#
# Feito para instalacoes no $HOME, ideal para distros imutaveis como
# Aurora / Fedora Kinoite (rpm-ostree), onde nao se deve escrever em /usr.
#
# Replica o layout da instalacao atual (identico ao instalador oficial):
#   - Binarios em ~/.local/bin : kiro-cli, kiro-cli-chat, kiro-cli-term
#   - Runtime/dados            : ~/.local/share/kiro-cli (bun, tui.js, sqlite...)
#
# Fonte oficial (mesma usada por `curl https://cli.kiro.dev/install | bash`):
#   Manifest : https://prod.download.cli.kiro.dev/<channel>/latest/manifest.json
#   Pacote   : https://prod.download.cli.kiro.dev/<channel>/latest/kirocli-<arch>-linux[-musl].zip
#
# Uso:
#   ./kiro-cli-installer.sh install     # instala/reinstala a ultima versao
#   ./kiro-cli-installer.sh update      # atualiza se houver versao mais nova
#   ./kiro-cli-installer.sh check       # verifica se ha atualizacao (exit 10 se houver)
#   ./kiro-cli-installer.sh version     # mostra a versao instalada
#   ./kiro-cli-installer.sh uninstall   # remove binarios/runtime (preserva config)
#
# Variaveis de ambiente opcionais:
#   KIRO_CLI_CHANNEL     canal de release (default: stable)
#   KIRO_CLI_FORCE_MUSL  =1 forca uso do build musl
#   KIRO_CLI_NO_SELF     =1 nao usa o `kiro-cli update` embutido; sempre reinstala
# ---------------------------------------------------------------------------

set -euo pipefail

# --------------------------- Configuracao ----------------------------------

CHANNEL="${KIRO_CLI_CHANNEL:-stable}"
BASE_URL="https://prod.download.cli.kiro.dev"

BIN_DIR="$HOME/.local/bin"
SHARE_DIR="$HOME/.local/share/kiro-cli"
PKG_NAME="kirocli"                 # prefixo dos arquivos .zip
LINUX_PACKAGE_DIR="kirocli"        # pasta interna do zip que contem install.sh

BIN_MAIN="$BIN_DIR/kiro-cli"

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

# --------------------------- Deteccao de plataforma -------------------------

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "x86_64" ;;
        arm64|aarch64) echo "aarch64" ;;
        *) die "Arquitetura nao suportada: $(uname -m)" ;;
    esac
}

# Decide se usa build musl. glibc minimo: x86_64>=2.34, aarch64>=2.39.
detect_musl() {
    [ "${KIRO_CLI_FORCE_MUSL:-0}" = "1" ] && { echo "true"; return; }
    local arch="$1" min_minor=34 v major minor
    [ "$arch" = "aarch64" ] && min_minor=39
    if command -v ldd >/dev/null 2>&1; then
        if ldd --version 2>&1 | head -n1 | grep -qi musl; then echo "true"; return; fi
        v="$(ldd --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)"
        if [ -n "$v" ]; then
            major="${v%%.*}"; minor="${v##*.}"
            if [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge "$min_minor" ]; }; then
                echo "false"; return
            fi
        fi
    fi
    # Deteccao direta de musl
    if [ -f /lib/libc.musl-x86_64.so.1 ] || [ -f /lib/libc.musl-aarch64.so.1 ]; then
        echo "true"; return
    fi
    # Sem certeza de glibc suficiente -> musl (mais portavel)
    echo "true"
}

pkg_filename() {
    local arch="$1" musl="$2"
    if [ "$musl" = "true" ]; then
        echo "${PKG_NAME}-${arch}-linux-musl.zip"
    else
        echo "${PKG_NAME}-${arch}-linux.zip"
    fi
}

# --------------------------- Versao / manifest ------------------------------

installed_version() {
    command -v kiro-cli >/dev/null 2>&1 || { echo ""; return 0; }
    kiro-cli --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

manifest_url() { echo "${BASE_URL}/${CHANNEL}/latest/manifest.json"; }

fetch_manifest() {
    curl -fsSL --max-time 30 "$(manifest_url)" 2>/dev/null \
        || die "Nao foi possivel baixar o manifest ($(manifest_url))."
}

# Versao mais recente a partir do manifest.
manifest_version() {
    local json="$1"
    if command -v jq >/dev/null 2>&1; then
        echo "$json" | jq -r '.version // empty'
    else
        echo "$json" | tr -d '\n\r' | grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' \
            | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
    fi
}

# sha256 esperado de um arquivo (pelo sufixo do campo "download") no manifest.
manifest_sha256() {
    local json="$1" filename="$2"
    if command -v jq >/dev/null 2>&1; then
        echo "$json" | jq -r --arg f "$filename" \
            '.packages[] | select(.download | endswith($f)) | .sha256' 2>/dev/null | head -n1
    else
        local obj
        obj="$(echo "$json" | tr -d '\n\r' | grep -oE '\{[^{}]*'"$filename"'[^{}]*\}' | head -n1)"
        echo "$obj" | grep -oE '"sha256"[[:space:]]*:[[:space:]]*"[a-f0-9]{64}"' | grep -oE '[a-f0-9]{64}' | head -n1
    fi
}

# --------------------------- Instalacao -------------------------------------

do_install() {
    need curl; need unzip; need sha256sum

    local arch musl fname url json ver expected zip actual
    arch="$(detect_arch)"
    musl="$(detect_musl "$arch")"
    fname="$(pkg_filename "$arch" "$musl")"
    url="${BASE_URL}/${CHANNEL}/latest/${fname}"

    json="$(fetch_manifest)"
    ver="$(manifest_version "$json")"
    [ -n "$ver" ] || die "Nao consegui ler a versao do manifest."

    log "Versao alvo:  ${c_bold}$ver${c_reset}  (canal: $CHANNEL)"
    log "Pacote:       $fname $([ "$musl" = true ] && echo '(musl)' || echo '(glibc)')"
    log "URL:          $url"

    expected="$(manifest_sha256 "$json" "$fname")"
    [ -n "$expected" ] && [[ "$expected" =~ ^[a-f0-9]{64}$ ]] \
        || die "Checksum ausente/invalido para $fname no manifest."

    tmp="$(mktemp -d -t kiro-cli.XXXXXX)"
    trap 'rm -rf "${tmp:-}"' EXIT
    zip="$tmp/$fname"

    log "Baixando..."
    curl -fL --progress-bar --max-time 1800 -o "$zip" "$url" || die "Falha no download."

    log "Verificando checksum (sha256)..."
    actual="$(sha256sum "$zip" | cut -d' ' -f1)"
    [ "$actual" = "$expected" ] || die "Checksum divergente. Esperado $expected, obtido $actual."
    ok "Checksum conferido."

    log "Extraindo..."
    mkdir -p "$tmp/extract"
    unzip -q "$zip" -d "$tmp/extract"

    # Localiza o install.sh interno (mesmo mecanismo do instalador oficial).
    local install_script="$tmp/extract/${LINUX_PACKAGE_DIR}/install.sh"
    if [ ! -f "$install_script" ]; then
        install_script="$(find "$tmp/extract" -maxdepth 3 -name install.sh -type f -print -quit 2>/dev/null || true)"
        [ -n "$install_script" ] || die "install.sh nao encontrado no pacote."
    fi
    chmod +x "$install_script"

    log "Instalando (install.sh oficial, KIRO_CLI_SKIP_SETUP=1)..."
    KIRO_CLI_SKIP_SETUP=1 "$install_script"

    ok "Kiro CLI ${c_bold}$ver${c_reset} instalado em $BIN_DIR"
    case ":$PATH:" in
        *":$BIN_DIR:"*) : ;;
        *) warn "$BIN_DIR nao esta no PATH. Adicione: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
    esac
}

# --------------------------- Comandos ---------------------------------------

cmd_check() {
    local cur json latest
    cur="$(installed_version)"
    json="$(fetch_manifest)"
    latest="$(manifest_version "$json")"
    printf 'Instalada:      %s\n' "${cur:-nenhuma}"
    printf 'Mais recente:   %s\n' "$latest"
    if [ -z "$cur" ]; then
        warn "Kiro CLI nao esta instalado. Rode: $0 install"
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
    local cur json latest
    cur="$(installed_version)"
    if [ -z "$cur" ]; then
        warn "Nada instalado; executando instalacao completa."
        do_install
        return
    fi
    json="$(fetch_manifest)"
    latest="$(manifest_version "$json")"
    if ! ver_gt "$latest" "$cur"; then
        ok "Ja na versao mais recente ($cur). Nada a fazer."
        return
    fi
    log "Atualizando $cur -> $latest"
    # Preferir o updater embutido do proprio CLI (canonico), com fallback.
    if [ "${KIRO_CLI_NO_SELF:-0}" != "1" ] && kiro-cli update --help >/dev/null 2>&1; then
        log "Usando updater embutido: kiro-cli update -y"
        if kiro-cli update -y; then
            ok "Atualizado via kiro-cli update (agora: $(installed_version))."
            return
        fi
        warn "Updater embutido falhou; caindo para reinstalacao pelo manifest."
    fi
    do_install
}

cmd_uninstall() {
    log "Removendo Kiro CLI (config em ~/.config/kiro-cli e ~/.kiro sao preservados)"
    rm -f "$BIN_DIR/kiro-cli" "$BIN_DIR/kiro-cli-chat" "$BIN_DIR/kiro-cli-term"
    rm -rf "$SHARE_DIR"
    ok "Kiro CLI removido."
    warn "Para apagar tambem config/dados: rm -rf ~/.config/kiro-cli ~/.local/share/kiro-cli"
}

usage() {
    cat <<EOF
${c_bold}Kiro CLI installer/updater${c_reset}  (Aurora/Fedora Kinoite, instalacao em \$HOME)

Uso: $0 <comando>

Comandos:
  install    Instala/reinstala a ultima versao (download + checksum + install.sh oficial)
  update     Atualiza se houver versao mais nova (usa 'kiro-cli update' quando possivel)
  check      Verifica atualizacao (exit 10 se houver)
  version    Mostra a versao instalada
  uninstall  Remove binarios e runtime (preserva config)

Variaveis:
  KIRO_CLI_CHANNEL=stable   canal de release
  KIRO_CLI_FORCE_MUSL=1     forca build musl
  KIRO_CLI_NO_SELF=1        nao usa o updater embutido; sempre reinstala
EOF
}

# --------------------------- Main -------------------------------------------

main() {
    need curl; need grep; need sort; need mktemp

    case "${1:-}" in
        install)   do_install ;;
        update)    cmd_update ;;
        check)     cmd_check ;;
        version)   local v; v="$(installed_version)"; echo "${v:-nenhuma}" ;;
        uninstall) cmd_uninstall ;;
        ""|-h|--help|help) usage ;;
        *) err "Comando desconhecido: $1"; echo; usage; exit 1 ;;
    esac
}

main "$@"
