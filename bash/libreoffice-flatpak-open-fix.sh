#!/usr/bin/env bash
#
# libreoffice-flatpak-open-fix.sh
# ---------------------------------------------------------------------------
# Corrige o erro "/run/user/<uid>/doc/.../arquivo.xlsx nao existe" ao abrir
# documentos baixados pelo navegador (Firefox/LibreWolf Flatpak) quando o
# LibreOffice tambem e Flatpak.
#
# Feito para distros imutaveis como Aurora / Fedora Kinoite (rpm-ostree):
# nada e escrito fora do $HOME (usa apenas handlers MIME do usuario e
# `flatpak override --user`).
#
# CAUSA
#   O document portal recusa montar o arquivo no sandbox do LibreOffice
#   porque o handler padrao usa o app-id do subaplicativo
#   (org.libreoffice.LibreOffice.calc/.writer/.impress), que NAO corresponde
#   ao app-id real do Flatpak instalado: org.libreoffice.LibreOffice.
#   Log tipico: xdg-document-portal: erro: org.libreoffice.LibreOffice.calc
#   ... nao instalado.
#
# CORRECAO
#   1) Define o handler dos documentos para org.libreoffice.LibreOffice.desktop
#      (app-id que corresponde ao Flatpak instalado).
#   2) Troca --filesystem=host por home (+ /run/media) no LibreOffice,
#      restaurando a integracao com o document portal.
#
# Uso:
#   ./libreoffice-flatpak-open-fix.sh apply            # aplica tudo (handler + perms)
#   ./libreoffice-flatpak-open-fix.sh apply --no-perms # aplica so o handler
#   ./libreoffice-flatpak-open-fix.sh check            # ha algo a corrigir? (exit 10 se sim)
#   ./libreoffice-flatpak-open-fix.sh verify           # mostra o estado atual
#   ./libreoffice-flatpak-open-fix.sh uninstall        # reverte (handlers p/ subapps + reset perms)
#
# Variaveis de ambiente opcionais:
#   LO_FIX_NO_PERMS   =1 nao altera permissoes do Flatpak (equivale a --no-perms)
# ---------------------------------------------------------------------------

set -euo pipefail

APP_ID="org.libreoffice.LibreOffice"
DESKTOP_MAIN="org.libreoffice.LibreOffice.desktop"

# Mapa: mime -> .desktop original do subaplicativo (usado no uninstall p/ restaurar).
# Formato: "mime|desktop_original"
declare -a MIME_MAP=(
  # Calc
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet|org.libreoffice.LibreOffice.calc.desktop"
  "application/vnd.ms-excel|org.libreoffice.LibreOffice.calc.desktop"
  "application/vnd.oasis.opendocument.spreadsheet|org.libreoffice.LibreOffice.calc.desktop"
  "application/vnd.oasis.opendocument.spreadsheet-template|org.libreoffice.LibreOffice.calc.desktop"
  "application/vnd.openxmlformats-officedocument.spreadsheetml.template|org.libreoffice.LibreOffice.calc.desktop"
  "text/csv|org.libreoffice.LibreOffice.calc.desktop"
  # Writer
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document|org.libreoffice.LibreOffice.writer.desktop"
  "application/msword|org.libreoffice.LibreOffice.writer.desktop"
  "application/vnd.oasis.opendocument.text|org.libreoffice.LibreOffice.writer.desktop"
  "application/rtf|org.libreoffice.LibreOffice.writer.desktop"
  # Impress
  "application/vnd.openxmlformats-officedocument.presentationml.presentation|org.libreoffice.LibreOffice.impress.desktop"
  "application/vnd.ms-powerpoint|org.libreoffice.LibreOffice.impress.desktop"
  "application/vnd.oasis.opendocument.presentation|org.libreoffice.LibreOffice.impress.desktop"
)

NO_PERMS="${LO_FIX_NO_PERMS:-}"

color() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info()  { color "1;34" "[INFO]  $*"; }
ok()    { color "1;32" "[OK]    $*"; }
warn()  { color "1;33" "[AVISO] $*"; }
err()   { color "1;31" "[ERRO]  $*"; }

mimes() { printf '%s\n' "${MIME_MAP[@]}" | cut -d'|' -f1; }

check_prereqs() {
  if ! command -v flatpak >/dev/null 2>&1; then
    err "flatpak nao encontrado. Esta correcao e para LibreOffice via Flatpak."
    exit 1
  fi
  if ! flatpak list --app --columns=application 2>/dev/null | grep -qx "$APP_ID"; then
    err "LibreOffice Flatpak ($APP_ID) nao esta instalado."
    err "Instale com: flatpak install flathub $APP_ID"
    exit 1
  fi
  if ! command -v xdg-mime >/dev/null 2>&1; then
    err "xdg-mime nao encontrado (pacote xdg-utils)."
    exit 1
  fi
}

apply_handler() {
  info "Definindo $DESKTOP_MAIN como handler dos documentos..."
  local m
  while read -r m; do
    xdg-mime default "$DESKTOP_MAIN" "$m" 2>/dev/null || true
  done < <(mimes)
  command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
  ok "Handlers definidos."
}

apply_perms() {
  if [ -n "$NO_PERMS" ]; then
    warn "Permissoes NAO alteradas (--no-perms / LO_FIX_NO_PERMS=1)."
    return
  fi
  info "Ajustando permissoes do LibreOffice (host -> home + /run/media)..."
  flatpak override --user --nofilesystem=host "$APP_ID"
  flatpak override --user --filesystem=home "$APP_ID"
  flatpak override --user --filesystem=/run/media "$APP_ID" 2>/dev/null || true
  ok "Permissoes ajustadas."
}

# Retorna 0 se tudo ja esta correto; 1 se ha algo a corrigir.
is_fixed() {
  local m fixed=0
  while read -r m; do
    [ "$(xdg-mime query default "$m" 2>/dev/null)" = "$DESKTOP_MAIN" ] || fixed=1
  done < <(mimes)
  return "$fixed"
}

verify() {
  info "Verificando estado atual..."
  local m cur
  while read -r m; do
    cur="$(xdg-mime query default "$m" 2>/dev/null || echo '(nenhum)')"
    if [ "$cur" = "$DESKTOP_MAIN" ]; then ok "$m -> $cur"
    else warn "$m -> $cur (esperado: $DESKTOP_MAIN)"; fi
  done < <(mimes)
  echo
  info "Overrides do LibreOffice:"
  flatpak override --user --show "$APP_ID" 2>/dev/null | sed 's/^/        /' || echo "        (nenhum)"
}

cmd_apply() {
  check_prereqs
  apply_handler
  apply_perms
  echo; verify
  echo; ok "Pronto. Feche e reabra o navegador, depois teste abrir um documento baixado."
}

cmd_check() {
  check_prereqs
  if is_fixed; then
    ok "Tudo ja esta corrigido."
    exit 0
  else
    warn "Ha handlers fora do valor esperado. Rode: $(basename "$0") apply"
    exit 10
  fi
}

cmd_uninstall() {
  check_prereqs
  info "Revertendo handlers para os .desktop originais dos subaplicativos..."
  local line m orig
  for line in "${MIME_MAP[@]}"; do
    m="${line%%|*}"; orig="${line##*|}"
    xdg-mime default "$orig" "$m" 2>/dev/null || true
  done
  command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
  ok "Handlers revertidos."
  info "Resetando overrides de permissao do LibreOffice..."
  flatpak override --user --reset "$APP_ID" 2>/dev/null || true
  ok "Overrides resetados ao padrao do manifest."
  warn "Nota: o reset remove TODOS os overrides --user do LibreOffice."
}

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  # suporta flag --no-perms em qualquer posicao
  local args=()
  for a in "$@"; do
    case "$a" in
      --no-perms) NO_PERMS=1 ;;
      *) args+=("$a") ;;
    esac
  done
  set -- "${args[@]:-}"

  case "${1:-}" in
    apply)      cmd_apply ;;
    check)      cmd_check ;;
    verify)     check_prereqs; verify ;;
    uninstall)  cmd_uninstall ;;
    -h|--help|help|"") usage ;;
    *) err "Subcomando desconhecido: $1"; echo; usage; exit 1 ;;
  esac
}

main "$@"
