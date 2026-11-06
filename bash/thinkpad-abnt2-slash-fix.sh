#!/usr/bin/env bash
#
# thinkpad-abnt2-slash-fix.sh
# ---------------------------------------------------------------------------
# Corrige a tecla "/ ?" (a tecla extra do ABNT2, a esquerda do Shift direito)
# em notebooks Lenovo ThinkPad com teclado pt-BR rodando Omarchy / Hyprland.
#
# SINTOMA
#   Com layout "br", a tecla ao lado do Shift direito nao gera "/" nem "?"
#   (so AltGr+Q / AltGr+W funcionam).
#
# CAUSA
#   1) O Hyprland ignora o localectl e usa o modelo padrao (pc105), que nao
#      conhece a tecla extra do ABNT2.
#   2) Em alguns ThinkPads (testado no E14 Gen 3) essa tecla e reportada pelo
#      firmware como Control_R (keycode xkb 105) em vez de KEY_RO (keycode 97).
#      Como o teclado ABNT2 do ThinkPad nao tem Ctrl direito, e seguro
#      reaproveitar esse keycode.
#
# CORRECAO
#   1) Cria ~/.config/xkb/symbols/brfix: herda br(abnt2) e troca a tecla RCTL
#      por "/ ? ° ¿".
#   2) Ajusta ~/.config/hypr/input.lua (ou input.conf em versoes antigas do
#      Omarchy) com kb_layout = "brfix" e kb_model = "abnt2", dentro de um bloco
#      marcado (facil de reverter).
#   3) Recarrega o Hyprland (hyprctl reload).
#
# Nada e escrito fora do $HOME.
#
# Uso:
#   ./thinkpad-abnt2-slash-fix.sh apply       # aplica a correcao
#   ./thinkpad-abnt2-slash-fix.sh apply --force   # aplica mesmo fora de um ThinkPad
#   ./thinkpad-abnt2-slash-fix.sh check       # ha algo a corrigir? (exit 10 se sim)
#   ./thinkpad-abnt2-slash-fix.sh verify      # mostra o estado atual
#   ./thinkpad-abnt2-slash-fix.sh uninstall   # remove o bloco e o arquivo xkb
#
# Variaveis de ambiente opcionais:
#   TPFIX_BASE_LAYOUT   layout base herdado           (default: br)
#   TPFIX_BASE_VARIANT  variante do layout base       (default: abnt2)
#   TPFIX_MODEL         modelo de teclado             (default: abnt2)
#   TPFIX_KEY           tecla xkb que vira "/ ?"      (default: RCTL)
#   TPFIX_LAYOUT_NAME   nome do layout criado         (default: brfix)
#   TPFIX_NO_RELOAD     =1 nao executa "hyprctl reload"
#   TPFIX_FORCE         =1 equivale a --force
#
# Para descobrir a tecla que o seu teclado envia, rode `wev` e aperte a tecla:
# "key: 105 / sym: Control_R" corresponde a RCTL. Outros ThinkPads podem enviar
# outro codigo; ajuste TPFIX_KEY com o nome xkb correspondente.
# ---------------------------------------------------------------------------

set -euo pipefail

BASE_LAYOUT="${TPFIX_BASE_LAYOUT:-br}"
BASE_VARIANT="${TPFIX_BASE_VARIANT:-abnt2}"
MODEL="${TPFIX_MODEL:-abnt2}"
KEY="${TPFIX_KEY:-RCTL}"
LAYOUT_NAME="${TPFIX_LAYOUT_NAME:-brfix}"
NO_RELOAD="${TPFIX_NO_RELOAD:-}"
FORCE="${TPFIX_FORCE:-}"

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XKB_FILE="$CONFIG_HOME/xkb/symbols/$LAYOUT_NAME"
HYPR_DIR="$CONFIG_HOME/hypr"

MARK_BEGIN=">>> thinkpad-abnt2-slash-fix (gerenciado por thinkpad-abnt2-slash-fix.sh) >>>"
MARK_END="<<< thinkpad-abnt2-slash-fix <<<"

color() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info()  { color "1;34" "[INFO]  $*"; }
ok()    { color "1;32" "[OK]    $*"; }
warn()  { color "1;33" "[AVISO] $*"; }
err()   { color "1;31" "[ERRO]  $*"; }

# ---------------------------------------------------------------------------
# Deteccao do arquivo de input do Hyprland (define INPUT_FILE, SYNTAX)
#   lua  -> Omarchy recente:  input = { kb_layout = "x", }   comentario: --
#   conf -> Omarchy antigo:   input { kb_layout = x }        comentario: #
# ---------------------------------------------------------------------------
INPUT_FILE=""
SYNTAX=""
detect_input_file() {
  if [ -f "$HYPR_DIR/input.lua" ]; then
    INPUT_FILE="$HYPR_DIR/input.lua"; SYNTAX="lua"
  elif [ -f "$HYPR_DIR/input.conf" ]; then
    INPUT_FILE="$HYPR_DIR/input.conf"; SYNTAX="conf"
  else
    err "Nao encontrei $HYPR_DIR/input.lua nem input.conf."
    err "Este script e para Omarchy/Hyprland."
    exit 1
  fi
}

comment_prefix() { [ "$SYNTAX" = "lua" ] && echo "--" || echo "#"; }

# Linhas de configuracao que serao inseridas no bloco.
block_body() {
  local c; c="$(comment_prefix)"
  if [ "$SYNTAX" = "lua" ]; then
    printf '    %s %s\n' "$c" "$MARK_BEGIN"
    printf '    kb_layout = "%s",\n' "$LAYOUT_NAME"
    printf '    kb_model = "%s",\n' "$MODEL"
    printf '    %s %s\n' "$c" "$MARK_END"
  else
    printf '    %s %s\n' "$c" "$MARK_BEGIN"
    printf '    kb_layout = %s\n' "$LAYOUT_NAME"
    printf '    kb_model = %s\n' "$MODEL"
    printf '    %s %s\n' "$c" "$MARK_END"
  fi
}

has_block() { grep -qF "$MARK_BEGIN" "$INPUT_FILE" 2>/dev/null; }

# Remove o bloco gerenciado (stdout). Nao altera o arquivo.
strip_block() {
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    index($0, b) { skip = 1; next }
    skip && index($0, e) { skip = 0; next }
    !skip { print }
  ' "$INPUT_FILE"
}

# Existe kb_layout/kb_model ativo (nao comentado) fora do nosso bloco?
has_conflict() {
  strip_block | grep -Eq '^[[:space:]]*kb_(layout|model)[[:space:]]*='
}

# ---------------------------------------------------------------------------
# Pre-requisitos
# ---------------------------------------------------------------------------
is_thinkpad() {
  local f
  for f in product_family product_version product_name; do
    if grep -qi 'thinkpad' "/sys/class/dmi/id/$f" 2>/dev/null; then return 0; fi
  done
  return 1
}

check_prereqs() {
  local missing=0 c
  for c in awk grep mktemp; do
    command -v "$c" >/dev/null 2>&1 || { err "Comando ausente: $c"; missing=1; }
  done
  [ "$missing" -eq 0 ] || exit 1
  detect_input_file
}

check_thinkpad() {
  if is_thinkpad; then return; fi
  if [ -n "$FORCE" ]; then
    warn "Nao detectei um ThinkPad; seguindo por causa de --force."
    return
  fi
  err "Este equipamento nao parece ser um ThinkPad."
  err "Se tem certeza, rode novamente com --force."
  exit 1
}

# ---------------------------------------------------------------------------
# Arquivo xkb
# ---------------------------------------------------------------------------
xkb_content() {
  cat <<EOF
// Gerado por thinkpad-abnt2-slash-fix.sh
// Em alguns ThinkPads a tecla "/ ?" do ABNT2 e reportada como Control_R.
default partial alphanumeric_keys
xkb_symbols "$BASE_VARIANT" {
    include "$BASE_LAYOUT($BASE_VARIANT)"
    name[Group1] = "Portuguese (Brazil, ThinkPad slash fix)";
    key <$KEY> { [ slash, question, degree, questiondown ] };
};
EOF
}

xkb_ok() {
  [ -f "$XKB_FILE" ] && [ "$(xkb_content)" = "$(cat "$XKB_FILE")" ]
}

apply_xkb() {
  info "Criando $XKB_FILE ..."
  mkdir -p "$(dirname "$XKB_FILE")"
  xkb_content > "$XKB_FILE"
  ok "Layout xkb '$LAYOUT_NAME' criado (tecla <$KEY> -> / ?)."
}

validate_xkb() {
  command -v xkbcli >/dev/null 2>&1 || return 0
  if XDG_CONFIG_HOME="$CONFIG_HOME" xkbcli compile-keymap \
       --layout "$LAYOUT_NAME" --model "$MODEL" >/dev/null 2>&1; then
    ok "Keymap compila corretamente (xkbcli)."
  else
    err "O keymap '$LAYOUT_NAME' nao compilou. Verifique $XKB_FILE."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Arquivo de input do Hyprland
# ---------------------------------------------------------------------------
block_ok() {
  has_block || return 1
  local want have
  want="$(block_body)"
  have="$(awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    index($0, b) { p = 1 }
    p { print }
    p && index($0, e) { p = 0 }
  ' "$INPUT_FILE")"
  [ "$want" = "$have" ]
}

apply_input() {
  info "Ajustando $INPUT_FILE ..."

  if has_conflict; then
    err "Ja existe kb_layout/kb_model ativo em $INPUT_FILE (fora do bloco gerenciado)."
    err "Ajuste manualmente para:  kb_layout = $LAYOUT_NAME  e  kb_model = $MODEL"
    exit 1
  fi

  local tmp body
  tmp="$(mktemp)"
  body="$(mktemp)"
  block_body > "$body"

  # Remove bloco anterior (se houver) e reinsere logo apos a abertura de "input".
  if [ "$SYNTAX" = "lua" ]; then
    strip_block | awk -v bodyfile="$body" '
      !done && /^[[:space:]]*input[[:space:]]*=[[:space:]]*\{/ {
        print
        while ((getline l < bodyfile) > 0) print l
        done = 1; next
      }
      { print }
      END { if (!done) exit 3 }
    ' > "$tmp" || { rm -f "$tmp" "$body"; err "Nao achei 'input = {' em $INPUT_FILE."; exit 1; }
  else
    strip_block | awk -v bodyfile="$body" '
      !done && /^[[:space:]]*input[[:space:]]*\{/ {
        print
        while ((getline l < bodyfile) > 0) print l
        done = 1; next
      }
      { print }
      END { if (!done) exit 3 }
    ' > "$tmp" || { rm -f "$tmp" "$body"; err "Nao achei o bloco 'input {' em $INPUT_FILE."; exit 1; }
  fi

  # Backup unico do original, antes da primeira alteracao.
  if ! has_block && [ ! -e "$INPUT_FILE.bak-thinkpad-fix" ]; then
    cp -p "$INPUT_FILE" "$INPUT_FILE.bak-thinkpad-fix"
    info "Backup: $INPUT_FILE.bak-thinkpad-fix"
  fi

  cat "$tmp" > "$INPUT_FILE"
  rm -f "$tmp" "$body"
  ok "kb_layout=$LAYOUT_NAME, kb_model=$MODEL gravados."
}

reload_hyprland() {
  if [ -n "$NO_RELOAD" ]; then
    warn "Reload ignorado (TPFIX_NO_RELOAD=1). Rode: hyprctl reload"
    return
  fi
  if ! command -v hyprctl >/dev/null 2>&1 || [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    warn "Hyprland nao esta em execucao nesta sessao; aplique com: hyprctl reload"
    return
  fi
  info "Recarregando o Hyprland ..."
  hyprctl reload >/dev/null
  ok "Hyprland recarregado."
}

# ---------------------------------------------------------------------------
# Comandos
# ---------------------------------------------------------------------------
is_fixed() { xkb_ok && block_ok; }

verify() {
  info "Verificando estado atual..."
  if xkb_ok; then ok "xkb: $XKB_FILE"
  else warn "xkb ausente ou diferente do esperado: $XKB_FILE"; fi

  if block_ok; then ok "input: bloco presente em $INPUT_FILE"
  else warn "input: bloco ausente ou diferente em $INPUT_FILE"; fi

  if command -v hyprctl >/dev/null 2>&1 && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    local line
    line="$(hyprctl devices 2>/dev/null | grep -A5 'at-translated-set-2-keyboard' | grep -E 'rules:|active keymap' || true)"
    if [ -n "$line" ]; then
      echo "$line" | sed 's/^[[:space:]]*/        /'
    fi
  fi
}

cmd_apply() {
  check_prereqs
  check_thinkpad
  apply_xkb
  validate_xkb
  apply_input
  reload_hyprland
  echo; verify
  echo; ok "Pronto. Teste a tecla ao lado do Shift direito (/ e Shift+? )."
  info "Se nao funcionar, rode 'wev' para ver qual tecla ela envia e ajuste TPFIX_KEY."
}

cmd_check() {
  check_prereqs
  if is_fixed; then
    ok "Correcao ja aplicada."
    exit 0
  else
    warn "Correcao nao aplicada. Rode: $(basename "$0") apply"
    exit 10
  fi
}

cmd_uninstall() {
  check_prereqs
  if has_block; then
    local tmp; tmp="$(mktemp)"
    strip_block > "$tmp"
    cat "$tmp" > "$INPUT_FILE"
    rm -f "$tmp"
    ok "Bloco removido de $INPUT_FILE."
  else
    info "Nenhum bloco gerenciado em $INPUT_FILE."
  fi
  if [ -f "$XKB_FILE" ]; then
    rm -f "$XKB_FILE"
    ok "Removido $XKB_FILE."
  fi
  rmdir "$(dirname "$XKB_FILE")" 2>/dev/null || true
  rmdir "$(dirname "$(dirname "$XKB_FILE")")" 2>/dev/null || true
  reload_hyprland
  warn "Sem a correcao, o layout volta ao padrao do Omarchy/Hyprland."
}

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  local args=() a
  for a in "$@"; do
    case "$a" in
      --force) FORCE=1 ;;
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
