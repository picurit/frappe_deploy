# Minimal gum-style terminal widgets in pure bash, sourced by ./deploy.sh.
#
# Only bash builtins, `stty` and `sleep` (coreutils) and raw ANSI escape sequences: no gum,
# dialog/whiptail, ncurses or tput (tput needs a terminfo entry, which minimal images lack).
#
#   ui_init                        detect colors/unicode; call once before any widget
#   ui_restore                     show the cursor and re-enable echo (call from an EXIT trap)
#   ui_clear / ui_header           full-screen redraw with a rounded title box
#   ui_box STYLE TITLE LINE...     rounded box; STYLE = accent|ok|warn|err
#   ui_choose HEADER ITEM...       single choice   -> UI_INDEX            (return 1 on esc/q)
#   ui_multi HEADER ITEM...        multiple choice -> UI_CHECKED (indexes) (return 1 on esc/q)
#   ui_confirm QUESTION [y|n]      Yes/No buttons  -> return 0 for yes
#   ui_input LABEL DEFAULT [secret] line editor -> UI_VALUE (return 1 on esc)
#   ui_spin TITLE LOG CMD...       run CMD in the background with a spinner, output -> LOG
#
# ITEMs are "label<TAB>description"; the description is optional and shown dimmed.
# UI_CURSOR (initial cursor index) and UI_PRESELECT (space-separated indexes, ui_multi only)
# are read once per call when set.
#
# Redraws move the cursor up over the lines already printed, so every widget line is cut to
# the terminal width: a line the terminal wraps would throw that count off.

ui_init() {
  local locale=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
  if [[ -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb && -t 1 ]]; then
    C_RESET=$'\e[0m' C_BOLD=$'\e[1m'
    C_ACCENT=$'\e[38;5;63m' C_SEL=$'\e[38;5;45m' C_MUTED=$'\e[38;5;244m'
    C_OK=$'\e[38;5;42m' C_WARN=$'\e[38;5;214m' C_ERR=$'\e[38;5;203m'
    C_BTN_ON=$'\e[1;38;5;255;48;5;63m' C_BTN_OFF=$'\e[38;5;250;48;5;236m'
    UI_COLOR=1
  else
    C_RESET= C_BOLD= C_ACCENT= C_SEL= C_MUTED= C_OK= C_WARN= C_ERR= C_BTN_ON= C_BTN_OFF=
    UI_COLOR=0
  fi
  if [[ $locale =~ [Uu][Tt][Ff]-?8 ]]; then
    G_TL='╭' G_TR='╮' G_BL='╰' G_BR='╯' G_H='─' G_V='│'
    G_PTR='❯' G_ON='✓' G_OFF='•' G_YES='✓' G_NO='✗' G_SEP='›' G_DOT='•' G_UD='↑/↓' G_LR='←/→' G_ELL='…' G_MASK='•'
    G_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  else
    G_TL='+' G_TR='+' G_BL='+' G_BR='+' G_H='-' G_V='|'
    G_PTR='>' G_ON='x' G_OFF='-' G_YES='ok' G_NO='x' G_SEP='>' G_DOT='-' G_UD='up/down' G_LR='left/right' G_ELL='.' G_MASK='*'
    G_SPIN=('|' '/' '-' '\')
  fi
  UI_SPIN_PID=
}

ui_restore() {
  [[ -t 1 ]] && printf '\e[?25h'
  [[ -t 0 ]] && stty echo 2>/dev/null
  return 0
}

ui_size() {
  local size
  size=$(stty size 2>/dev/null) || size=
  UI_ROWS=${size% *} UI_COLS=${size#* }
  [[ $UI_ROWS =~ ^[0-9]+$ && $UI_ROWS -gt 0 ]] || UI_ROWS=24
  [[ $UI_COLS =~ ^[0-9]+$ && $UI_COLS -gt 0 ]] || UI_COLS=80
}

ui_clear() { printf '\e[H\e[2J'; }

# ---------------------------------------------------------------------------------------------
# Text helpers
# ---------------------------------------------------------------------------------------------

# Visible text of $1 (ANSI SGR sequences removed) -> UI_PLAIN
_ui_strip() {
  UI_PLAIN=$1
  local re=$'\e\\[[0-9;]*m'
  while [[ $UI_PLAIN =~ $re ]]; do UI_PLAIN=${UI_PLAIN/"${BASH_REMATCH[0]}"/}; done
}

# Word-wrap plain TEXT to WIDTH columns -> UI_WRAPPED array
_ui_wrap() {
  local width=$2 word line=
  local -a words=()
  read -r -a words <<<"$1"
  UI_WRAPPED=()
  for word in "${words[@]}"; do
    while ((${#word} > width)); do
      [[ -n $line ]] && { UI_WRAPPED+=("$line"); line=; }
      UI_WRAPPED+=("${word:0:width}"); word=${word:width}
    done
    if [[ -z $line ]]; then
      line=$word
    elif ((${#line} + 1 + ${#word} <= width)); then
      line+=" $word"
    else
      UI_WRAPPED+=("$line"); line=$word
    fi
  done
  [[ -n $line || ${#UI_WRAPPED[@]} -eq 0 ]] && UI_WRAPPED+=("$line")
  return 0
}

# Print one redrawable widget line and count it in the caller's `lines`.
_ui_line() {
  printf '\r\e[2K%s%s\n' "$1" "$C_RESET"
  lines=$((lines + 1))
}

# Read one key -> UI_KEY. Named keys (always 2+ chars): up down left right home end delete
# backspace clear (ctrl-u) enter space tab esc eof other. A typed character comes back as itself,
# so ${#UI_KEY} == 1 means "text".
ui_key() {
  local k= rest= tail=
  if ! IFS= read -rsn1 k; then UI_KEY=eof; return 0; fi
  case $k in
    $'\e')
      IFS= read -rsn2 -t 0.05 rest || true
      case $rest in
        '[1' | '[3' | '[4' | '[7' | '[8') IFS= read -rsn1 -t 0.05 tail || true ;;
      esac
      case $rest$tail in
        '[A' | OA) UI_KEY=up ;;
        '[B' | OB) UI_KEY=down ;;
        '[C' | OC) UI_KEY=right ;;
        '[D' | OD) UI_KEY=left ;;
        '[H' | OH | '[1~' | '[7~') UI_KEY=home ;;
        '[F' | OF | '[4~' | '[8~') UI_KEY=end ;;
        '[3~') UI_KEY=delete ;;
        '') UI_KEY=esc ;;
        *) UI_KEY=other ;;
      esac
      ;;
    '') UI_KEY=enter ;;
    ' ') UI_KEY=space ;;
    $'\t') UI_KEY=tab ;;
    $'\x7f' | $'\b') UI_KEY=backspace ;;
    $'\x15') UI_KEY=clear ;;
    $'\x01') UI_KEY=home ;;
    $'\x05') UI_KEY=end ;;
    [[:cntrl:]]) UI_KEY=other ;;
    *) UI_KEY=$k ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# Static output
# ---------------------------------------------------------------------------------------------

ui_box() {
  local style=$1 title=$2 color line bar w=0 max vis
  shift 2
  case $style in
    ok) color=$C_OK ;; warn) color=$C_WARN ;; err) color=$C_ERR ;; *) color=$C_ACCENT ;;
  esac
  ui_size
  max=$((UI_COLS - 4))
  ((max < 10)) && max=10

  # Word-wrap plain prose that is too wide. Styled or column-aligned lines (indented, or with a
  # run of spaces) are truncated below instead: wrapping would squeeze out the alignment.
  local -a body=()
  for line in "$@"; do
    _ui_strip "$line"
    if ((${#UI_PLAIN} > max)) && [[ $UI_PLAIN == "$line" && $line != ' '* && $line != *'  '* ]]; then
      _ui_wrap "$line" "$max"
      body+=("${UI_WRAPPED[@]}")
    else
      body+=("$line")
    fi
  done
  for line in "${body[@]}"; do
    _ui_strip "$line"
    ((${#UI_PLAIN} > w)) && w=${#UI_PLAIN}
  done
  ((${#title} + 3 > w)) && w=$((${#title} + 3))
  ((w > max)) && w=$max

  if [[ -n $title ]]; then
    printf -v bar '%*s' $((w - ${#title} - 1)) ''
    printf '%s%s%s %s%s%s %s%s%s\n' "$color" "$G_TL" "$G_H" "$C_BOLD" "$title" "$C_RESET$color" "${bar// /$G_H}" "$G_TR" "$C_RESET"
  else
    printf -v bar '%*s' $((w + 2)) ''
    printf '%s%s%s%s%s\n' "$color" "$G_TL" "${bar// /$G_H}" "$G_TR" "$C_RESET"
  fi
  for line in "${body[@]}"; do
    _ui_strip "$line"
    vis=${#UI_PLAIN}
    ((vis > w)) && { line="${UI_PLAIN:0:w-1}$G_ELL"; vis=$w; }
    printf '%s%s%s %s%s%*s %s%s%s\n' "$color" "$G_V" "$C_RESET" "$line" "$C_RESET" $((w - vis)) '' "$color" "$G_V" "$C_RESET"
  done
  printf -v bar '%*s' $((w + 2)) ''
  printf '%s%s%s%s%s\n' "$color" "$G_BL" "${bar// /$G_H}" "$G_BR" "$C_RESET"
}

# ui_header TITLE SUBTITLE [EXTRA_LINE...]: clear the screen and draw the app banner.
ui_header() {
  local title=$1 subtitle=$2
  shift 2
  ui_clear
  ui_box accent "" "$C_BOLD$C_ACCENT$title$C_RESET  $C_MUTED$subtitle$C_RESET" "$@"
}

# ---------------------------------------------------------------------------------------------
# Interactive widgets
# ---------------------------------------------------------------------------------------------

# Shared list widget for ui_choose (one) and ui_multi (many).
_ui_list() {
  local mode=$1 header=$2
  shift 2
  local -a items=("$@") checked=() labels=() descs=()
  local n=$# cur=${UI_CURSOR:-0} top=0 h lines=0 i label desc width room pointer mark style help pad hl avail marklen=0
  UI_CURSOR= UI_CHECKED=()

  for ((i = 0; i < n; i++)); do
    labels[i]=${items[i]%%$'\t'*}
    descs[i]=
    [[ ${items[i]} == *$'\t'* ]] && descs[i]=${items[i]#*$'\t'}
    checked[i]=0
  done
  for i in ${UI_PRESELECT:-}; do ((i >= 0 && i < n)) && checked[i]=1; done
  UI_PRESELECT=
  width=0
  for label in "${labels[@]}"; do ((${#label} > width)) && width=${#label}; done
  ((cur >= 0 && cur < n)) || cur=0
  [[ $mode == many ]] && marklen=2

  if [[ $mode == one ]]; then
    help="$G_UD move $G_DOT enter select $G_DOT esc back"
  else
    help="$G_UD move $G_DOT space toggle $G_DOT a all $G_DOT enter confirm $G_DOT esc back"
  fi

  printf '\e[?25l'
  while true; do
    ui_size
    room=$((UI_ROWS - 14))
    ((room < 3)) && room=3
    h=$n
    ((h > room)) && h=$room
    ((cur < top)) && top=$cur
    ((cur >= top + h)) && top=$((cur - h + 1))

    ((lines > 0)) && printf '\e[%dA' "$lines"
    lines=0
    _ui_wrap "$header" $((UI_COLS - 1))
    for hl in "${UI_WRAPPED[@]}"; do _ui_line "$C_BOLD$hl"; done
    for ((i = top; i < top + h; i++)); do
      if ((i == cur)); then pointer="$C_ACCENT$G_PTR$C_RESET " style=$C_ACCENT$C_BOLD; else pointer='  ' style=; fi
      mark=
      if [[ $mode == many ]]; then
        if ((checked[i])); then mark="$C_SEL$G_ON$C_RESET "; ((i == cur)) || style=$C_SEL; else mark="$C_MUTED$G_OFF$C_RESET "; fi
      fi
      printf -v pad '%-*s' "$width" "${labels[i]}"
      desc=${descs[i]}
      # pointer (2) + mark + label + 2 spaces, keeping one spare column
      avail=$((UI_COLS - 1 - 2 - marklen - width - 2))
      if ((avail < 4)); then desc=; elif ((${#desc} > avail)); then desc="${desc:0:avail-1}$G_ELL"; fi
      _ui_line "$pointer$mark$style$pad$C_RESET  $C_MUTED$desc"
    done
    label=$help
    ((n > h)) && label="$help $G_DOT $((cur + 1))/$n"
    ((${#label} > UI_COLS - 1)) && label=${label:0:UI_COLS-1}
    _ui_line "$C_MUTED$label"

    ui_key
    case $UI_KEY in
      up | k) cur=$(((cur - 1 + n) % n)) ;;
      down | j | tab) cur=$(((cur + 1) % n)) ;;
      home | g) cur=0 ;;
      end | G) cur=$((n - 1)) ;;
      space | x)
        [[ $mode == many ]] && checked[cur]=$((1 - checked[cur]))
        ;;
      a)
        if [[ $mode == many ]]; then
          local all=1 v
          for v in "${checked[@]}"; do ((v)) || all=0; done
          for ((i = 0; i < n; i++)); do checked[i]=$((1 - all)); done
        fi
        ;;
      enter) break ;;
      esc | q | eof)
        printf '\e[%dA\e[J' "$lines"
        printf '\e[?25h'
        return 1
        ;;
    esac
  done

  # Collapse the widget into a single "header › answer" line, like gum does.
  printf '\e[%dA\e[J' "$lines"
  UI_INDEX=$cur
  if [[ $mode == one ]]; then
    label=${labels[cur]}
  else
    label=
    for ((i = 0; i < n; i++)); do
      ((checked[i])) || continue
      UI_CHECKED+=("$i")
      label+="${label:+, }${labels[i]}"
    done
    [[ -n $label ]] || label='(none)'
  fi
  printf '%s%s %s%s %s%s\n' "$C_MUTED" "$header" "$G_SEP" "$C_RESET$C_ACCENT" "$label" "$C_RESET"
  printf '\e[?25h'
  return 0
}

ui_choose() { _ui_list one "$@"; }
ui_multi() { _ui_list many "$@"; }

ui_confirm() {
  local question=$1 sel=1 lines=0 yes no hl
  [[ ${2:-y} == y ]] && sel=0
  printf '\e[?25l'
  while true; do
    ui_size
    ((lines > 0)) && printf '\e[%dA' "$lines"
    lines=0
    if [[ $UI_COLOR == 1 ]]; then
      if ((sel == 0)); then yes="$C_BTN_ON  Yes  $C_RESET" no="$C_BTN_OFF  No  $C_RESET"
      else yes="$C_BTN_OFF  Yes  $C_RESET" no="$C_BTN_ON  No  $C_RESET"; fi
    else
      if ((sel == 0)); then yes='[ Yes ]' no='  No  '; else yes='  Yes  ' no='[ No ]'; fi
    fi
    _ui_wrap "$question" $((UI_COLS - 1))
    for hl in "${UI_WRAPPED[@]}"; do _ui_line "$C_BOLD$hl"; done
    _ui_line ""
    _ui_line "  $yes   $no"
    _ui_line "$C_MUTED$G_LR toggle $G_DOT enter submit $G_DOT y/n"
    ui_key
    case $UI_KEY in
      left | right | tab | h | l) sel=$((1 - sel)) ;;
      y | Y) sel=0; break ;;
      n | N | esc | eof) sel=1; break ;;
      enter) break ;;
    esac
  done
  printf '\e[%dA\e[J' "$lines"
  if ((sel == 0)); then yes="$C_OK$G_YES Yes"; else yes="$C_ERR$G_NO No"; fi
  printf '%s%s %s%s %s%s\n' "$C_MUTED" "$question" "$G_SEP" "$C_RESET" "$yes" "$C_RESET"
  printf '\e[?25h'
  return $sel
}

# ui_input LABEL DEFAULT [secret]: single-line editor prefilled with DEFAULT -> UI_VALUE.
# Returns 1 on esc. UI_INPUT_ERROR, when set, is shown under the field (for caller validation
# loops) and cleared. A self-made editor instead of `read -e` so esc can mean "back", as in
# every other widget, and secrets can be masked.
ui_input() {
  local label=$1 value=$2 secret=${3:-} cur lines=0 row=0 hl shown start avail col err=${UI_INPUT_ERROR:-}
  UI_INPUT_ERROR=
  cur=${#value}
  while true; do
    ui_size
    # Back to the top of the widget, clear it, draw it again.
    ((row > 0)) && printf '\e[%dA' "$row"
    printf '\r\e[J'
    lines=0
    _ui_wrap "$label" $((UI_COLS - 1))
    for hl in "${UI_WRAPPED[@]}"; do _ui_line "$C_BOLD$hl"; done
    _ui_line "$C_MUTED""enter accept $G_DOT $G_LR move $G_DOT ctrl-u clear $G_DOT esc back"
    row=$lines
    shown=$value
    if [[ -n $secret ]]; then printf -v shown '%*s' "${#value}" ''; shown=${shown// /$G_MASK}; fi
    # Scroll horizontally so the cursor stays visible.
    avail=$((UI_COLS - 3))
    start=0
    ((cur > avail)) && start=$((cur - avail))
    _ui_line "$C_ACCENT$G_PTR$C_RESET ${shown:start:avail}"
    [[ -n $err ]] && _ui_line "$C_ERR$G_NO $err"
    # Park the terminal cursor on the edit position.
    col=$((2 + cur - start))
    printf '\e[%dA\r\e[%dC\e[?25h' $((lines - row)) "$col"

    ui_key
    case $UI_KEY in
      enter) break ;;
      esc | eof)
        ((row > 0)) && printf '\e[%dA' "$row"
        printf '\r\e[J'
        return 1
        ;;
      left) ((cur > 0)) && cur=$((cur - 1)) ;;
      right) ((cur < ${#value})) && cur=$((cur + 1)) ;;
      home) cur=0 ;;
      end) cur=${#value} ;;
      backspace) ((cur > 0)) && { value=${value:0:cur-1}${value:cur}; cur=$((cur - 1)); } ;;
      delete) ((cur < ${#value})) && value=${value:0:cur}${value:cur+1} ;;
      clear) value= cur=0 ;;
      space) value="${value:0:cur} ${value:cur}"; cur=$((cur + 1)) ;;
      *)
        if ((${#UI_KEY} == 1)); then
          value=${value:0:cur}$UI_KEY${value:cur}
          cur=$((cur + 1))
        fi
        ;;
    esac
    err=
  done
  ((row > 0)) && printf '\e[%dA' "$row"
  printf '\r\e[J'
  shown=$value
  if [[ -n $secret ]]; then printf -v shown '%*s' "${#value}" ''; shown=${shown// /$G_MASK}; fi
  printf '%s%s %s%s %s%s\n' "$C_MUTED" "$label" "$G_SEP" "$C_RESET$C_ACCENT" "$shown" "$C_RESET"
  UI_VALUE=$value
  return 0
}

ui_spin() {
  local title=$1 log=$2 i=0 rc=0
  shift 2
  "$@" >"$log" 2>&1 &
  UI_SPIN_PID=$!
  printf '\e[?25l'
  while kill -0 "$UI_SPIN_PID" 2>/dev/null; do
    printf '\r\e[2K%s%s%s %s' "$C_ACCENT" "${G_SPIN[i % ${#G_SPIN[@]}]}" "$C_RESET" "$title"
    i=$((i + 1))
    sleep 0.08
  done
  wait "$UI_SPIN_PID" || rc=$?
  UI_SPIN_PID=
  if ((rc == 0)); then
    printf '\r\e[2K%s%s%s %s\n' "$C_OK" "$G_YES" "$C_RESET" "$title"
  else
    printf '\r\e[2K%s%s%s %s\n' "$C_ERR" "$G_NO" "$C_RESET" "$title"
  fi
  printf '\e[?25h'
  return $rc
}
