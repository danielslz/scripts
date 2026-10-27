#!/usr/bin/env bash
#
# wkhtmltopdf-distrobox-installer.sh
# ---------------------------------------------------------------------------
# Instalador / atualizador do wkhtmltopdf (com Qt patcheado) via Distrobox.
#
# Feito para distros imutaveis como Aurora / Fedora Kinoite (rpm-ostree),
# onde nao se deve escrever em /usr. O binario real vive dentro de um
# container Fedora dedicado e e exportado para ~/.local/bin, ficando
# disponivel no host como se fosse nativo.
#
# Por que container? O wkhtmltopdf foi descontinuado (repo arquivado em
# jan/2023) e removido do Homebrew e dos repos oficiais. A unica fonte
# confiavel do binario "with patched qt" -- exigido por sistemas como o
# SUAP para renderizar HTML/CSS corretamente -- e o RPM oficial arquivado
# do projeto wkhtmltopdf/packaging. Isola-lo num Distrobox evita sujar o
# sistema imutavel e mantem as dependencias (Qt, fontes) contidas.
#
# Layout replicado:
#   - Container Distrobox : wkhtmltopdf-box  (Fedora)
#   - RPM oficial         : wkhtmltox-<ver>.fedora<N>.<arch>.rpm (dnf resolve deps)
#   - Binarios exportados : ~/.local/bin/wkhtmltopdf, ~/.local/bin/wkhtmltoimage
#
# Fonte oficial:
#   Releases: https://github.com/wkhtmltopdf/packaging/releases
#
# Uso:
#   ./wkhtmltopdf-distrobox-installer.sh install     # cria container + instala + exporta
#   ./wkhtmltopdf-distrobox-installer.sh update       # atualiza se houver versao mais nova
#   ./wkhtmltopdf-distrobox-installer.sh check         # verifica atualizacao (exit 10 se houver)
#   ./wkhtmltopdf-distrobox-installer.sh version       # mostra a versao instalada
#   ./wkhtmltopdf-distrobox-installer.sh test          # gera um PDF de teste a partir do host
#   ./wkhtmltopdf-distrobox-installer.sh uninstall     # remove binarios exportados e o container
#
# Variaveis de ambiente opcionais:
#   WK_BOX_NAME     nome do container distrobox (default: wkhtmltopdf-box)
#   WK_BOX_IMAGE    imagem base do container     (default: registry.fedoraproject.org/fedora:41)
#   WK_FEDORA_TAG   forca a tag do asset .rpm    (ex.: fedora37; default: maior disponivel)
#   WK_PIN_VERSION  fixa uma versao especifica    (ex: 0.12.6.1-3)
# ---------------------------------------------------------------------------

set -euo pipefail

# --------------------------- Configuracao ----------------------------------

BOX_NAME="${WK_BOX_NAME:-wkhtmltopdf-box}"
BOX_IMAGE="${WK_BOX_IMAGE:-registry.fedoraproject.org/fedora:41}"
PIN_VERSION="${WK_PIN_VERSION:-}"

BIN_DIR="$HOME/.local/bin"
STATE_DIR="$HOME/.local/share/wkhtmltopdf-distrobox"
STATE_TAG="$STATE_DIR/installed-tag"
RELEASES_API="https://api.github.com/repos/wkhtmltopdf/packaging/releases/latest"

BIN_PDF="$BIN_DIR/wkhtmltopdf"
BIN_IMG="$BIN_DIR/wkhtmltoimage"

# --------------------------- Utilidades -------------------------------------

c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_blu=$'\033[34m'
log()  { printf "${c_blu}==>${c_reset} %s\n" "$*"; }
ok()   { printf "${c_grn}✓${c_reset} %s\n" "$*"; }
warn() { printf "${c_yel}!${c_reset} %s\n" "$*"; }
err()  { printf "${c_red}✗ %s${c_reset}\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Comando necessario ausente: $1"; }

# Compara versoes. Retorna 0 se $1 > $2. Normaliza '-' para '.' (0.12.6.1-3).
ver_gt() {
    local a="${1//-/.}" b="${2//-/.}"
    [ "$a" = "$b" ] && return 1
    local greater
    greater="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)"
    [ "$greater" = "$a" ]
}

# --------------------------- Deteccao de plataforma -------------------------

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "x86_64" ;;
        arm64|aarch64) echo "aarch64" ;;
        *) die "Arquitetura nao suportada: $(uname -m)" ;;
    esac
}

box_exists() { distrobox list 2>/dev/null | awk -F'|' 'NR>1 {gsub(/ /,"",$2); print $2}' | grep -qx "$BOX_NAME"; }

# Roda um comando dentro do container.
in_box() { distrobox enter "$BOX_NAME" -- bash -lc "$1"; }

# --------------------------- Versao / release -------------------------------

# Versao base reportada pelo proprio binario (sem o sufixo de packaging).
# Ex.: "wkhtmltopdf 0.12.6.1 (with patched qt)" -> 0.12.6.1
installed_version() {
    command -v wkhtmltopdf >/dev/null 2>&1 || { echo ""; return 0; }
    wkhtmltopdf --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1
}

# Tag de packaging efetivamente instalada (ex.: 0.12.6.1-3), gravada no install.
# O --version do binario nao expoe o sufixo "-N", entao guardamos num arquivo
# de estado para que check/update comparem maca com maca. Sem estado, cai para
# a versao base do binario.
installed_tag() {
    if [ -r "$STATE_TAG" ]; then
        tr -d ' \t\n\r' < "$STATE_TAG"
    else
        installed_version
    fi
}

record_tag() {
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$1" > "$STATE_TAG"
}

fetch_release_json() {
    curl -fsSL --max-time 30 "$RELEASES_API" 2>/dev/null \
        || die "Nao foi possivel consultar as releases ($RELEASES_API)."
}

# Tag da release mais recente (ex.: 0.12.6.1-3).
release_tag() {
    local json="$1"
    if command -v jq >/dev/null 2>&1; then
        echo "$json" | jq -r '.tag_name // empty'
    else
        echo "$json" | tr -d '\n\r' | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
            | head -n1 | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
    fi
}

# Escolhe a URL do .rpm Fedora para a arquitetura atual.
# - Se WK_FEDORA_TAG estiver definido, usa exatamente essa tag (ex.: fedora37).
# - Caso contrario, escolhe a maior tag fedoraNN disponivel nos assets.
pick_rpm_url() {
    local json="$1" arch="$2" urls best
    urls="$(echo "$json" | grep -oE 'https://[^"]+\.rpm' | grep -E "(fedora|fc)[0-9]+" | grep -E "\.${arch}\.rpm$" || true)"
    [ -n "$urls" ] || die "Nenhum asset .rpm Fedora para arquitetura $arch na release."
    # Override explicito via WK_FEDORA_TAG tem prioridade.
    if [ -n "${WK_FEDORA_TAG:-}" ]; then
        best="$(echo "$urls" | grep -E "${WK_FEDORA_TAG}\." | head -n1)"
        [ -n "$best" ] || die "Nenhum asset .rpm para WK_FEDORA_TAG=${WK_FEDORA_TAG} (arch $arch)."
        echo "$best"; return
    fi
    # Maior tag fedoraNN disponivel.
    best="$(echo "$urls" \
        | sed -E 's/.*fedora([0-9]+)\..*/\1\t&/' \
        | sort -nr | head -n1 | cut -f2-)"
    [ -n "$best" ] || die "Nao consegui selecionar um .rpm adequado."
    echo "$best"
}

# --------------------------- Instalacao -------------------------------------

ensure_box() {
    need distrobox
    if box_exists; then
        log "Container ${c_bold}$BOX_NAME${c_reset} ja existe."
    else
        log "Criando container ${c_bold}$BOX_NAME${c_reset} (imagem: $BOX_IMAGE)..."
        distrobox create --name "$BOX_NAME" --image "$BOX_IMAGE" --yes >/dev/null 2>&1 \
            || die "Falha ao criar o container $BOX_NAME."
        # Inicializa (primeira entrada faz o setup do distrobox).
        in_box "true" >/dev/null 2>&1 || true
        ok "Container criado."
    fi
}

export_bins() {
    log "Exportando binarios para $BIN_DIR..."
    in_box "distrobox-export --bin /usr/local/bin/wkhtmltopdf --export-path \"\$HOME/.local/bin\"" >/dev/null 2>&1 \
        || die "Falha ao exportar wkhtmltopdf."
    # wkhtmltoimage e opcional; nao aborta se faltar.
    in_box "distrobox-export --bin /usr/local/bin/wkhtmltoimage --export-path \"\$HOME/.local/bin\"" >/dev/null 2>&1 \
        || warn "wkhtmltoimage nao exportado (opcional)."
    ok "Binarios exportados."
}

do_install() {
    need curl; need distrobox; need grep; need sort

    local arch json tag url arch_rpm
    arch="$(detect_arch)"

    json="$(fetch_release_json)"
    tag="${PIN_VERSION:-$(release_tag "$json")}"
    [ -n "$tag" ] || die "Nao consegui determinar a versao da release."

    url="$(pick_rpm_url "$json" "$arch")"

    # Se foi fixada uma versao, ajusta a URL para a tag pedida.
    if [ -n "$PIN_VERSION" ]; then
        url="$(echo "$url" | sed -E "s#/download/[^/]+/#/download/${PIN_VERSION}/#; s#wkhtmltox-[0-9][^/]*\.fedora#wkhtmltox-${PIN_VERSION}.fedora#")"
    fi

    log "Versao alvo:  ${c_bold}$tag${c_reset}"
    log "RPM:          $(basename "$url")"
    log "URL:          $url"

    ensure_box

    log "Instalando o RPM oficial no container (dnf resolve dependencias)..."
    in_box "sudo dnf install -y '$url'" \
        || die "Falha ao instalar o RPM no container."

    export_bins

    # Registra a tag de packaging instalada para comparacoes futuras.
    record_tag "$tag"

    # Revalida a chamada a partir do host.
    hash -r 2>/dev/null || true
    local v; v="$(installed_version)"
    [ -n "$v" ] || die "Binario exportado mas nao executavel a partir do host."

    ok "wkhtmltopdf ${c_bold}$v${c_reset} (pacote $tag) instalado e exportado em $BIN_DIR"
    wkhtmltopdf --version 2>/dev/null | grep -qi "patched qt" \
        && ok "Build 'with patched qt' confirmado (compativel com SUAP)." \
        || warn "Atencao: build NAO parece ter o Qt patcheado; o SUAP pode renderizar incorretamente."

    case ":$PATH:" in
        *":$BIN_DIR:"*) : ;;
        *) warn "$BIN_DIR nao esta no PATH. Adicione: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
    esac
}

# --------------------------- Comandos ---------------------------------------

cmd_check() {
    local cur json latest
    cur="$(installed_tag)"
    json="$(fetch_release_json)"
    latest="$(release_tag "$json")"
    printf 'Instalada:      %s\n' "${cur:-nenhuma}"
    printf 'Mais recente:   %s\n' "$latest"
    if [ -z "$cur" ]; then
        warn "wkhtmltopdf nao esta instalado. Rode: $0 install"
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
    cur="$(installed_tag)"
    if [ -z "$cur" ]; then
        warn "Nada instalado; executando instalacao completa."
        do_install
        return
    fi
    json="$(fetch_release_json)"
    latest="$(release_tag "$json")"
    if ! ver_gt "$latest" "$cur"; then
        ok "Ja na versao mais recente ($cur). Nada a fazer."
        return
    fi
    log "Atualizando $cur -> $latest"
    do_install
}

cmd_test() {
    command -v wkhtmltopdf >/dev/null 2>&1 || die "wkhtmltopdf nao esta instalado. Rode: $0 install"
    local tmp html pdf
    tmp="$(mktemp -d -t wkhtml-test.XXXXXX)"
    html="$tmp/teste.html"; pdf="$tmp/teste.pdf"
    printf '<html><body><h1>Teste wkhtmltopdf</h1><p>Gerado em %s</p></body></html>' "$(date)" > "$html"
    log "Gerando PDF de teste a partir do host..."
    if wkhtmltopdf "$html" "$pdf" >/dev/null 2>&1 && [ -s "$pdf" ]; then
        ok "PDF gerado com sucesso: $pdf ($(wc -c < "$pdf") bytes)"
        warn "Arquivo temporario; remova com: rm -rf \"$tmp\""
    else
        rm -rf "$tmp"
        die "Falha ao gerar o PDF de teste."
    fi
}

cmd_uninstall() {
    log "Removendo wkhtmltopdf (binarios exportados + container $BOX_NAME)"
    rm -f "$BIN_PDF" "$BIN_IMG"
    rm -rf "$STATE_DIR"
    if box_exists; then
        distrobox rm --force "$BOX_NAME" >/dev/null 2>&1 \
            && ok "Container $BOX_NAME removido." \
            || warn "Nao foi possivel remover o container $BOX_NAME (remova manualmente: distrobox rm -f $BOX_NAME)."
    else
        warn "Container $BOX_NAME nao existe."
    fi
    ok "wkhtmltopdf removido."
}

usage() {
    cat <<EOF
${c_bold}wkhtmltopdf installer/updater via Distrobox${c_reset}  (Aurora/Fedora Kinoite, binario em \$HOME)

Uso: $0 <comando>

Comandos:
  install    Cria o container, instala o RPM oficial (with patched qt) e exporta os binarios
  update     Atualiza se houver versao mais nova
  check      Verifica atualizacao (exit 10 se houver)
  version    Mostra a versao instalada
  test       Gera um PDF de teste a partir do host
  uninstall  Remove binarios exportados e o container

Variaveis:
  WK_BOX_NAME=wkhtmltopdf-box                        nome do container
  WK_BOX_IMAGE=registry.fedoraproject.org/fedora:41  imagem base
  WK_FEDORA_TAG=fedora37                             forca a tag do .rpm (default: maior disponivel)
  WK_PIN_VERSION=0.12.6.1-3                           fixa uma versao especifica
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
        test)      cmd_test ;;
        uninstall) cmd_uninstall ;;
        ""|-h|--help|help) usage ;;
        *) err "Comando desconhecido: $1"; echo; usage; exit 1 ;;
    esac
}

main "$@"
