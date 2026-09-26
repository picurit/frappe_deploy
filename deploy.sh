#!/usr/bin/env bash
# Config-driven wizard that renders Docker Compose stacks.
#
# This script knows nothing about Frappe, databases or proxies. Every question, option, compose
# file, environment variable, template and note lives in deploy/*.json (schema:
# deploy/README.md). The script walks the steps, keeps the answers, and runs
#   docker compose --project-directory . --env-file ... -f <file> ... config > <output>
# then optionally builds and starts the stack.
#
# Interactive:      ./deploy.sh
# Non-interactive:  ./deploy.sh --set environment=prod --set database=postgres ... --yes --up
#                   ./deploy.sh --answers devops/stacks/dev-local.json --up
# ./deploy.sh --help lists every option; ./deploy.sh --check validates the JSON config.

# Sourced (`source deploy.sh` / `. deploy.sh`)? Run in a child bash instead: here `exit` (quit,
# esc, errors), `set -e`, `cd` and the traps would all hit the calling shell and close it.
if [[ -z ${BASH_VERSION:-} ]]; then
  echo "deploy.sh needs bash: run it as ./deploy.sh" >&2
  return 1 2>/dev/null || exit 1
fi
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
  bash "${BASH_SOURCE[0]}" "$@"
  return $?
fi

set -euo pipefail

# Compose files may use ${PWD} and relative paths: everything runs from the repo root.
cd "$(dirname "${BASH_SOURCE[0]}")"

CONFIG_DIR=${DEPLOY_CONFIG_DIR:-deploy}
# shellcheck source=lib/json.sh
source lib/json.sh
# shellcheck source=lib/tui.sh
source lib/tui.sh

# ---------------------------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------------------------
UI_ACTIVE=0

info() { printf '%s==>%s %s\n' "$C_ACCENT$C_BOLD" "$C_RESET" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_WARN$C_BOLD" "$C_RESET" "$*" >&2; }
die() {
  if [[ $UI_ACTIVE == 1 ]]; then
    ui_box err "Error" "$@" >&2
  else
    local line
    printf '%serror:%s %s\n' "$C_ERR$C_BOLD" "$C_RESET" "$1" >&2
    shift
    for line in "$@"; do printf '       %s\n' "$line" >&2; done
  fi
  exit 1
}

contains() { local needle=$1 x; shift; for x in "$@"; do [[ $x == "$needle" ]] && return 0; done; return 1; }

RENDER_TMP= RENDER_LOG=
on_exit() {
  [[ -n ${UI_SPIN_PID:-} ]] && kill "$UI_SPIN_PID" 2>/dev/null
  rm -f "$RENDER_TMP" "$RENDER_LOG"
  ui_restore
}

# ---------------------------------------------------------------------------------------------
# Config: deploy/wizard.json + deploy/steps/*.json (each file holds one step or an array of them)
# ---------------------------------------------------------------------------------------------
STEP_IDS=()
declare -A STEP=() STEP_FILE=() PREFIX_FILE=()

add_step() {
  local p=$1 file=$2 id=${J[$1.id]-}
  [[ -n $id ]] || die "$file: a step has no \"id\""
  [[ -z ${STEP[$id]+x} ]] || die "$file: step id '$id' is already used in ${STEP_FILE[$id]}"
  STEP_IDS+=("$id")
  STEP[$id]=$p STEP_FILE[$id]=$file
}

load_config() {
  local f i=0 k
  [[ -f $CONFIG_DIR/wizard.json ]] || die "$CONFIG_DIR/wizard.json not found"
  json_load "$CONFIG_DIR/wizard.json" w || die "invalid JSON in $CONFIG_DIR/wizard.json (see above)"
  PREFIX_FILE[w]=$CONFIG_DIR/wizard.json
  for f in "$CONFIG_DIR"/steps/*.json; do
    [[ -e $f ]] || continue
    json_load "$f" "f$i" || die "invalid JSON in $f (see above)"
    PREFIX_FILE[f$i]=$f
    if [[ ${JT[f$i]} == array ]]; then
      for ((k = 0; k < J[f$i]; k++)); do add_step "f$i.$k" "$f"; done
    else
      add_step "f$i" "$f"
    fi
    i=$((i + 1))
  done
  ((${#STEP_IDS[@]})) || die "no steps found in $CONFIG_DIR/steps/*.json"
}

CFG_ERRS=()

# when: {"<earlier step id>": ["value", "!value", ...], ...}
check_when() {
  local p=$1.when where=$2 seen=$3 key v
  [[ -z ${JT[$p]-} ]] && return 0
  [[ ${JT[$p]} == object ]] || { CFG_ERRS+=("$where: \"when\" must be an object"); return 0; }
  json_keys "$p"
  for key in $REPLY; do
    [[ $seen == *" $key "* ]] || CFG_ERRS+=("$where: \"when\" refers to '$key', which is not an earlier step")
    [[ ${JT[$p.$key]} == array ]] || CFG_ERRS+=("$where: when.$key must be an array of values")
  done
  return 0
}

check_config() {
  local id p f type n i opt oid key v name seen=" " pat re
  local -A layer_ok=() stack_keys=() oids=()
  CFG_ERRS=()

  json_list w.layers
  ((${#JL[@]})) || CFG_ERRS+=("wizard.json: \"layers\" must list at least one compose layer")
  for v in "${JL[@]}"; do layer_ok[$v]=1; done
  for key in project output; do
    [[ -n ${J[w.stack.$key]-} ]] || CFG_ERRS+=("wizard.json: \"stack.$key\" is required")
  done
  json_keys w.stack
  for key in $REPLY; do stack_keys[$key]=1; done

  for id in "${STEP_IDS[@]}"; do
    p=${STEP[$id]} f=${STEP_FILE[$id]}
    [[ $id =~ ^[a-z][a-z0-9_-]*$ ]] || CFG_ERRS+=("$f: step id '$id' must match [a-z][a-z0-9_-]*")
    [[ -z ${stack_keys[$id]+x} ]] || CFG_ERRS+=("$f: step id '$id' clashes with wizard.json stack.$id")
    type=${J[$p.type]-}
    [[ -n ${J[$p.question]-}${J[$p.title]-} ]] || CFG_ERRS+=("$f: step '$id' needs a \"question\" or \"title\"")
    check_when "$p" "$f: step '$id'" "$seen"
    case $type in
      choose | multi)
        json_len "$p.options"
        n=$REPLY
        ((n > 0)) || CFG_ERRS+=("$f: step '$id': \"options\" must be a non-empty array")
        oids=()
        for ((i = 0; i < n; i++)); do
          opt=$p.options.$i oid=${J[$p.options.$i.id]-}
          [[ $oid =~ ^[a-z0-9][a-z0-9_-]*$ ]] || CFG_ERRS+=("$f: step '$id': option id '$oid' must match [a-z0-9][a-z0-9_-]*")
          [[ -z ${oids[$oid]+x} ]] || CFG_ERRS+=("$f: step '$id': duplicate option id '$oid'")
          oids[$oid]=1
          [[ -n ${J[$opt.label]-} ]] || CFG_ERRS+=("$f: option '$id.$oid' needs a \"label\"")
          check_when "$opt" "$f: option '$id.$oid'" "$seen"
          json_keys "$opt.compose"
          for key in $REPLY; do
            [[ -n ${layer_ok[$key]+x} ]] || CFG_ERRS+=("$f: option '$id.$oid': compose layer '$key' is not in wizard.json \"layers\"")
          done
          json_keys "$opt.env"
          for key in $REPLY; do
            [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || CFG_ERRS+=("$f: option '$id.$oid': '$key' is not a valid variable name")
            [[ ${J[$opt.env.$key]} != *\'* ]] || CFG_ERRS+=("$f: option '$id.$oid': env $key may not contain single quotes")
          done
          json_len "$opt.files"
          for ((v = 0; v < REPLY; v++)); do
            [[ -n ${J[$opt.files.$v.from]-} && -n ${J[$opt.files.$v.to]-} ]] || CFG_ERRS+=("$f: option '$id.$oid': files[$v] needs \"from\" and \"to\"")
          done
        done
        json_list "$p.default"
        for v in "${JL[@]}"; do
          [[ -n ${oids[$v]+x} ]] || CFG_ERRS+=("$f: step '$id': default '$v' is not one of its options")
        done
        [[ $type == multi || ${#JL[@]} -le 1 ]] || CFG_ERRS+=("$f: step '$id': a choose step takes a single default")
        ;;
      input | secret)
        name=${J[$p.env]-}
        [[ -z $name || $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || CFG_ERRS+=("$f: step '$id': env '$name' is not a valid variable name")
        pat=${J[$p.pattern]-}
        if [[ -n $pat ]]; then
          [[ "" =~ $pat ]] || [[ $? != 2 ]] || CFG_ERRS+=("$f: step '$id': invalid pattern (bash ERE): $pat")
        fi
        ;;
      *) CFG_ERRS+=("$f: step '$id': \"type\" must be choose, multi, input or secret (got '$type')") ;;
    esac
    seen+="$id "
  done

  # Every {placeholder} must name a step or a wizard.json stack key.
  re='\{([a-z][a-z0-9_-]*)\}'
  for key in "${!J[@]}"; do
    [[ ${JT[$key]} == string ]] || continue
    v=${J[$key]}
    while [[ $v =~ $re ]]; do
      name=${BASH_REMATCH[1]}
      if [[ -z ${STEP[$name]+x} && -z ${stack_keys[$name]+x} ]]; then
        CFG_ERRS+=("${PREFIX_FILE[${key%%.*}]}: unknown placeholder {$name} (at ${key#*.})")
      fi
      v=${v#*"${BASH_REMATCH[0]}"}
    done
  done
  ((${#CFG_ERRS[@]} == 0))
}

# ---------------------------------------------------------------------------------------------
# Answers and conditions
# ---------------------------------------------------------------------------------------------
declare -A ANS=() ACTIVE=() VARS=() PREV_ENV=() BASE_ENV=()

# Does the "when" of step/option prefix $1 hold? Only answers of active steps count.
when_ok() {
  local p=$1.when key v ans positive hit
  [[ ${JT[$p]-} == object ]] || return 0
  json_keys "$p"
  for key in $REPLY; do
    ans=" "
    [[ -n ${ACTIVE[$key]+x} ]] && ans=" ${ANS[$key]-} "
    json_list "$p.$key"
    positive=0 hit=0
    for v in "${JL[@]}"; do
      if [[ $v == !* ]]; then
        [[ $ans == *" ${v#!} "* ]] && return 1
      else
        positive=1
        [[ $ans == *" $v "* ]] && hit=1
      fi
    done
    ((positive == 0 || hit == 1)) || return 1
  done
  return 0
}

# Indexes of the options of step $1 whose "when" holds -> VIS
visible_options() {
  local p=${STEP[$1]} i
  VIS=()
  for ((i = 0; i < ${J[$p.options]:-0}; i++)); do
    when_ok "$p.options.$i" && VIS+=("$i")
  done
  return 0
}

step_applies() {
  local p=${STEP[$1]}
  when_ok "$p" || return 1
  case ${J[$p.type]} in
    choose | multi)
      visible_options "$1"
      ((${#VIS[@]} > 0)) || return 1
      ;;
  esac
  return 0
}

# Recompute ACTIVE for every step, in order ("when" only looks at earlier steps).
resolve_active() {
  local id
  ACTIVE=()
  for id in "${STEP_IDS[@]}"; do
    step_applies "$id" && ACTIVE[$id]=1
  done
  return 0
}

# Replace {name} with a stack value or an answer -> REPLY
subst() {
  local s=$1 out= name re='\{([a-z][a-z0-9_-]*)\}'
  while [[ $s =~ $re ]]; do
    name=${BASH_REMATCH[1]}
    out+=${s%%"${BASH_REMATCH[0]}"*}
    if [[ -n ${VARS[$name]+x} ]]; then
      out+=${VARS[$name]}
    else
      out+=${ANS[$name]-}
    fi
    s=${s#*"${BASH_REMATCH[0]}"}
  done
  REPLY=$out$s
}

# wizard.json "stack" templates, resolved in order -> VARS (so later ones may use earlier ones)
compute_stack() {
  local key
  VARS=()
  json_keys w.stack
  for key in $REPLY; do
    subst "${J[w.stack.$key]}"
    VARS[$key]=$REPLY
  done
}

option_index() { # step option_id -> REPLY index, or return 1
  local p=${STEP[$1]} i
  for ((i = 0; i < ${J[$p.options]:-0}; i++)); do
    [[ ${J[$p.options.$i.id]} == "$2" ]] && { REPLY=$i; return 0; }
  done
  return 1
}

# Variables already set in wizard.json "env_files" (e.g. .env) -> BASE_ENV. They are the defaults
# of steps writing those variables, so the wizard never silently overrides what .env says.
load_base_env() {
  local f line key value
  BASE_ENV=()
  json_list w.env_files
  for f in "${JL[@]}"; do
    [[ -f $f ]] || continue
    while IFS= read -r line || [[ -n $line ]]; do
      [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
      key=${BASH_REMATCH[2]} value=${BASH_REMATCH[3]}
      if [[ $value =~ ^\'(.*)\'$ || $value =~ ^\"(.*)\"$ ]]; then
        value=${BASH_REMATCH[1]}
      else
        value=${value%%[[:space:]]#*} # unquoted: drop a trailing comment
        value=${value%"${value##*[![:space:]]}"}
      fi
      [[ -n $value ]] && BASE_ENV[$key]=$value
    done <"$f"
  done
  return 0
}

# Default answer of step $1 (placeholders resolved) -> REPLY
step_default() {
  local p=${STEP[$1]} v out=
  if [[ -n ${J[$p.env]-} && -n ${BASE_ENV[${J[$p.env]}]+x} ]]; then
    REPLY=${BASE_ENV[${J[$p.env]}]}
    return 0
  fi
  case ${J[$p.type]} in
    multi)
      json_list "$p.default"
      for v in "${JL[@]}"; do out+="${out:+ }$v"; done
      REPLY=$out
      ;;
    *)
      subst "${J[$p.default]-}"
      ;;
  esac
}

# Validate the (possibly defaulted) answer of active step $1; message -> REPLY on failure.
check_answer() {
  local id=$1 p=${STEP[$1]} v n=0 pat
  case ${J[$p.type]} in
    choose)
      visible_options "$id"
      for v in "${VIS[@]}"; do [[ ${J[$p.options.$v.id]} == "${ANS[$id]-}" ]] && return 0; done
      REPLY="'${ANS[$id]-}' is not an available option"
      return 1
      ;;
    multi)
      visible_options "$id"
      for v in ${ANS[$id]-}; do
        option_index "$id" "$v" && contains "$REPLY" "${VIS[@]}" || { REPLY="'$v' is not an available option"; return 1; }
        n=$((n + 1))
      done
      if ((n < ${J[$p.min]:-0})); then REPLY="choose at least ${J[$p.min]}"; return 1; fi
      ;;
    input | secret)
      v=${ANS[$id]-}
      pat=${J[$p.pattern]-}
      if [[ -n $pat && ! $v =~ $pat ]]; then REPLY=${J[$p.error]:-"doesn't match $pat"}; return 1; fi
      if [[ -n ${J[$p.env]-} && $v == *\'* ]]; then REPLY="single quotes are not allowed"; return 1; fi
      ;;
  esac
  return 0
}

# Fill unanswered active steps with defaults and validate them all, in order.
# Returns 1 with FIRST_BAD (step index) and ERRORS set when an answer is missing or invalid.
settle_answers() {
  local i id p
  ERRORS=() FIRST_BAD=-1
  for i in "${!STEP_IDS[@]}"; do
    id=${STEP_IDS[i]} p=${STEP[$id]}
    resolve_active
    [[ -n ${ACTIVE[$id]+x} ]] || continue
    if [[ -z ${ANS[$id]+x} ]]; then
      if [[ ${J[$p.type]} == secret && -n ${J[$p.env]-} && -n ${PREV_ENV[${J[$p.env]}]+x} ]]; then
        ANS[$id]=${PREV_ENV[${J[$p.env]}]}
      else
        step_default "$id"
        ANS[$id]=$REPLY
        # choose without a usable default: the first visible option
        if [[ ${J[$p.type]} == choose ]] && ! check_answer "$id"; then
          visible_options "$id"
          ANS[$id]=${J[$p.options.${VIS[0]}.id]}
        fi
      fi
    fi
    if ! check_answer "$id"; then
      ERRORS+=("$id: $REPLY")
      ((FIRST_BAD >= 0)) || FIRST_BAD=$i
    fi
  done
  resolve_active
  ((${#ERRORS[@]} == 0))
}

# Previous values of the stack env file (so secrets need not be retyped) -> PREV_ENV
load_prev_env() {
  local line file
  PREV_ENV=()
  compute_stack
  file=${VARS[env_file]-}
  [[ -n $file && -f $file ]] || return 0
  while IFS= read -r line; do
    [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=\'(.*)\'$ ]] && PREV_ENV[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
  done <"$file"
  return 0
}

ANSWER_LOADS=0
load_answers() {
  local file=$1 p id
  ANSWER_LOADS=$((ANSWER_LOADS + 1))
  p=a$ANSWER_LOADS
  json_load "$file" "$p" || die "invalid JSON in $file (see above)"
  [[ ${JT[$p]} == object ]] || die "$file: expected an object of step answers"
  for id in "${STEP_IDS[@]}"; do
    case ${JT[$p.$id]-} in
      array) json_list "$p.$id"; ANS[$id]="${JL[*]}" ;;
      string | number | bool) ANS[$id]=${J[$p.$id]} ;;
    esac
  done
}

# Human-readable answer of step $1 -> REPLY
answer_label() {
  local id=$1 p=${STEP[$1]} v out=
  case ${J[$p.type]} in
    choose) option_index "$id" "${ANS[$id]}" && REPLY=${J[$p.options.$REPLY.label]} ;;
    multi)
      for v in ${ANS[$id]-}; do option_index "$id" "$v" && out+="${out:+, }${J[$p.options.$REPLY.label]}"; done
      REPLY=${out:-none}
      ;;
    secret) printf -v REPLY '%*s' "${#ANS[$id]}" ''; REPLY=${REPLY// /$G_MASK} ;;
    *) REPLY=${ANS[$id]-} ;;
  esac
  return 0
}

step_title() { local p=${STEP[$1]}; REPLY=${J[$p.title]:-${J[$p.question]-}}; }

# ---------------------------------------------------------------------------------------------
# Collect what the active answers contribute
# ---------------------------------------------------------------------------------------------
COMPOSE=() COMPOSE_LAYER=() ENV_KEYS=() NOTES=() FILE_FROM=() FILE_TO=()
declare -A ENV_VAL=() ENV_SECRET=()

set_env() {
  [[ -n ${ENV_VAL[$1]+x} ]] || ENV_KEYS+=("$1")
  ENV_VAL[$1]=$2
  ENV_SECRET[$1]=${3:-}
}

add_files() {
  local p=$1 i
  for ((i = 0; i < ${J[$p]:-0}; i++)); do
    subst "${J[$p.$i.from]}"
    FILE_FROM+=("$REPLY")
    subst "${J[$p.$i.to]}"
    FILE_TO+=("$REPLY")
  done
}

# Options selected in active step $1, in option order -> SEL (option prefixes)
selected_options() {
  local id=$1 p=${STEP[$1]} i
  SEL=()
  visible_options "$id"
  for i in "${VIS[@]}"; do
    [[ " ${ANS[$id]-} " == *" ${J[$p.options.$i.id]} "* ]] && SEL+=("$p.options.$i")
  done
  return 0
}

collect() {
  local layer id p opt key i
  COMPOSE=() COMPOSE_LAYER=() ENV_KEYS=() NOTES=() FILE_FROM=() FILE_TO=()
  ENV_VAL=() ENV_SECRET=()
  compute_stack

  json_list w.layers
  local -a layers=("${JL[@]}")
  for layer in "${layers[@]}"; do
    for id in "${STEP_IDS[@]}"; do
      [[ -n ${ACTIVE[$id]+x} ]] || continue
      selected_options "$id"
      for opt in "${SEL[@]}"; do
        json_list "$opt.compose.$layer"
        for key in "${JL[@]}"; do
          subst "$key"
          contains "$REPLY" "${COMPOSE[@]}" && continue
          COMPOSE+=("$REPLY") COMPOSE_LAYER+=("$layer")
        done
      done
    done
  done

  add_files w.files
  json_list w.notes
  for key in "${JL[@]}"; do subst "$key"; NOTES+=("$REPLY"); done
  for id in "${STEP_IDS[@]}"; do
    [[ -n ${ACTIVE[$id]+x} ]] || continue
    p=${STEP[$id]}
    case ${J[$p.type]} in
      choose | multi)
        selected_options "$id"
        for opt in "${SEL[@]}"; do
          json_keys "$opt.env"
          for key in $REPLY; do subst "${J[$opt.env.$key]}"; set_env "$key" "$REPLY"; done
          add_files "$opt.files"
          json_list "$opt.notes"
          for i in "${JL[@]}"; do subst "$i"; NOTES+=("$REPLY"); done
        done
        ;;
      input | secret)
        [[ -n ${J[$p.env]-} ]] && set_env "${J[$p.env]}" "${ANS[$id]}" "$([[ ${J[$p.type]} == secret ]] && echo 1)"
        ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------------------------------------
# Listing (--list)
# ---------------------------------------------------------------------------------------------
when_text() { # prefix -> REPLY "  [when a=x,y b=!z]"
  local p=$1.when key out=
  json_keys "$p"
  for key in $REPLY; do json_list "$p.$key"; local IFS=,; out+=" $key=${JL[*]}"; done
  REPLY=${out:+"  [when$out]"}
}

list_config() {
  local id p i opt layer
  json_list w.layers
  printf 'Compose layers (merge order): %s\n' "${JL[*]}"
  for id in "${STEP_IDS[@]}"; do
    p=${STEP[$id]}
    when_text "$p"
    local cond=$REPLY
    step_title "$id"
    printf '\n%s (%s) %s%s   [%s]\n' "$id" "${J[$p.type]}" "$REPLY" "$cond" "${STEP_FILE[$id]}"
    [[ -n ${J[$p.env]-} ]] && printf '    -> env %s\n' "${J[$p.env]}"
    for ((i = 0; i < ${J[$p.options]:-0}; i++)); do
      opt=$p.options.$i
      when_text "$opt"
      printf '  - %-18s %s%s\n' "${J[$opt.id]}" "${J[$opt.label]}" "$REPLY"
      json_keys "$opt.compose"
      for layer in $REPLY; do
        json_list "$opt.compose.$layer"
        printf '      %-9s %s\n' "$layer" "${JL[*]}"
      done
    done
  done
  return 0
}

# ---------------------------------------------------------------------------------------------
# Interactive screens (lib/tui.sh)
# ---------------------------------------------------------------------------------------------
DOCKER_STATUS=

# Header with the answers given so far (active steps before index $1).
screen() {
  local upto=${1:-${#STEP_IDS[@]}} i id crumbs=
  for ((i = 0; i < upto; i++)); do
    id=${STEP_IDS[i]}
    [[ -n ${ACTIVE[$id]+x} && -n ${ANS[$id]+x} ]] || continue
    case ${J[${STEP[$id]}.type]} in
      choose | multi) REPLY=${ANS[$id]:-none} ;;
      secret) continue ;;
      *) answer_label "$id" ;;
    esac
    crumbs+="${crumbs:+ $G_SEP }$REPLY"
  done
  if [[ -n $crumbs ]]; then
    ui_header "${J[w.title]:-deploy}" "${J[w.subtitle]-}" "$DOCKER_STATUS" "$C_MUTED$crumbs"
  else
    ui_header "${J[w.title]:-deploy}" "${J[w.subtitle]-}" "$DOCKER_STATUS"
  fi
  echo
}

# Ask step $1 (index $2 for the header). Returns 1 when the user goes back.
ask_step() {
  local id=$1 idx=$2 p=${STEP[$1]} question i v err=
  local -a items=()
  question=${J[$p.question]:-${J[$p.title]-}}
  while true; do
    screen "$idx"
    [[ -n $err ]] && { ui_box err "Invalid answer" "$err"; echo; }
    [[ -n ${J[$p.help]-} ]] && printf '%s%s%s\n\n' "$C_MUTED" "${J[$p.help]}" "$C_RESET"
    case ${J[$p.type]} in
      choose)
        visible_options "$id"
        items=() UI_CURSOR=0
        for i in "${!VIS[@]}"; do
          v=$p.options.${VIS[i]}
          items+=("${J[$v.label]}"$'\t'"${J[$v.description]-}")
          [[ ${J[$v.id]} == "${ANS[$id]-}" ]] && UI_CURSOR=$i
        done
        ui_choose "$question" "${items[@]}" || return 1
        ANS[$id]=${J[$p.options.${VIS[UI_INDEX]}.id]}
        ;;
      multi)
        visible_options "$id"
        items=() UI_PRESELECT=
        for i in "${!VIS[@]}"; do
          v=$p.options.${VIS[i]}
          items+=("${J[$v.label]}"$'\t'"${J[$v.description]-}")
          [[ " ${ANS[$id]-} " == *" ${J[$v.id]} "* ]] && UI_PRESELECT+="$i "
        done
        ui_multi "$question" "${items[@]}" || return 1
        v=
        for i in "${UI_CHECKED[@]}"; do v+="${v:+ }${J[$p.options.${VIS[i]}.id]}"; done
        ANS[$id]=$v
        ;;
      input | secret)
        # Validation errors are shown under the field, which is redrawn in place.
        local secret=
        [[ ${J[$p.type]} == secret ]] && secret=1
        UI_INPUT_ERROR=
        while true; do
          ui_input "$question" "${ANS[$id]-}" "$secret" || return 1
          ANS[$id]=$UI_VALUE
          check_answer "$id" && return 0
          UI_INPUT_ERROR=$REPLY
          # Remove the collapsed "question › answer" line before drawing the field again.
          _ui_strip "$question $G_SEP $UI_VALUE"
          printf '\e[%dA\r\e[J' $(((${#UI_PLAIN} + UI_COLS - 1) / UI_COLS))
        done
        ;;
    esac
    check_answer "$id" && return 0
    err=$REPLY
  done
}

# Walk the steps from index $1. Returns 1 if the user backs out of the first one.
HISTORY=()
walk_steps() {
  local idx=$1 id p
  while ((idx < ${#STEP_IDS[@]})); do
    id=${STEP_IDS[idx]} p=${STEP[$id]}
    resolve_active
    if [[ -z ${ACTIVE[$id]+x} ]]; then idx=$((idx + 1)); continue; fi
    # Seed the answer with the default the first time the step is reached.
    if [[ -z ${ANS[$id]+x} ]]; then
      step_default "$id"
      ANS[$id]=$REPLY
    fi
    # A choose step with a single possible option answers itself.
    if [[ ${J[$p.type]} == choose ]]; then
      visible_options "$id"
      if ((${#VIS[@]} == 1)); then
        ANS[$id]=${J[$p.options.${VIS[0]}.id]}
        idx=$((idx + 1))
        continue
      fi
    fi
    if ask_step "$id" "$idx"; then
      HISTORY+=("$idx")
      idx=$((idx + 1))
    else
      ((${#HISTORY[@]})) || return 1
      idx=${HISTORY[-1]}
      unset 'HISTORY[-1]'
    fi
  done
  return 0
}

# HISTORY = the asked (not auto-answered) active steps before index $1, for "back".
rebuild_history() {
  local i id
  HISTORY=()
  for ((i = 0; i < $1; i++)); do
    id=${STEP_IDS[i]}
    [[ -n ${ACTIVE[$id]+x} ]] || continue
    if [[ ${J[${STEP[$id]}.type]} == choose ]]; then
      visible_options "$id"
      ((${#VIS[@]} > 1)) || continue
    fi
    HISTORY+=("$i")
  done
  return 0
}

# Glob of existing answer files, from the wizard.json stack.answers template.
existing_stacks() {
  local tpl=${J[w.stack.answers]-} re='\{[a-z][a-z0-9_-]*\}' f
  STACK_FILES=()
  [[ -n $tpl ]] || return 0
  while [[ $tpl =~ $re ]]; do tpl=${tpl/"${BASH_REMATCH[0]}"/*}; done
  for f in $tpl; do [[ -f $f ]] && STACK_FILES+=("$f"); done
  return 0
}

summary() {
  local id i key lines=() v
  collect
  for id in "${STEP_IDS[@]}"; do
    [[ -n ${ACTIVE[$id]+x} ]] || continue
    step_title "$id"
    printf -v v '%s%-24s%s' "$C_MUTED" "$REPLY" "$C_RESET"
    answer_label "$id"
    lines+=("$v $REPLY")
  done
  ui_box accent "Answers" "${lines[@]}"

  lines=()
  for key in project output env_file; do
    [[ -n ${VARS[$key]-} ]] || continue
    printf -v v '%s%-9s%s %s' "$C_MUTED" "$key" "$C_RESET" "${VARS[$key]}"
    lines+=("$v")
  done
  lines+=("")
  for i in "${!COMPOSE[@]}"; do
    printf -v v '%s+%s %-9s %s' "$C_SEL" "$C_RESET" "${COMPOSE_LAYER[i]}" "${COMPOSE[i]}"
    lines+=("$v")
  done
  if ((${#ENV_KEYS[@]})); then
    lines+=("")
    for key in "${ENV_KEYS[@]}"; do
      v=${ENV_VAL[$key]}
      [[ -n ${ENV_SECRET[$key]} ]] && { printf -v v '%*s' "${#v}" ''; v=${v// /$G_MASK}; }
      lines+=("$C_MUTED$key=$C_RESET$v")
    done
  fi
  for i in "${!FILE_TO[@]}"; do
    [[ -f ${FILE_TO[i]} ]] && continue
    ((i > 0)) || lines+=("")
    lines+=("${C_WARN}new$C_RESET ${FILE_TO[i]} ${C_MUTED}(from ${FILE_FROM[i]})$C_RESET")
  done
  echo
  ui_box accent "Stack" "${lines[@]}"
  echo
}

interactive() {
  local i items=()
  while true; do
    ANS=() HISTORY=() PREV_ENV=()
    existing_stacks
    if ((${#STACK_FILES[@]})); then
      resolve_active
      screen 0
      items=("New stack"$'\t'"Answer every question")
      for i in "${STACK_FILES[@]}"; do items+=("$(basename "${i%.*}")"$'\t'"$i"); done
      items+=("Quit"$'\t'"Exit without changes")
      ui_choose "Create a stack or open an existing one?" "${items[@]}" || exit 0
      ((UI_INDEX == ${#items[@]} - 1)) && exit 0
      if ((UI_INDEX > 0)); then
        load_answers "${STACK_FILES[UI_INDEX-1]}"
        settle_answers || true
        load_prev_env
        # Secrets come from the stack env file; defaults fill anything new in the config.
        for i in "${STEP_IDS[@]}"; do
          [[ ${J[${STEP[$i]}.type]} == secret ]] && unset "ANS[$i]"
        done
        if settle_answers; then
          rebuild_history "${#STEP_IDS[@]}"
          review || continue
          return 0
        fi
        # Something is missing or no longer valid: resume at that step.
        rebuild_history "$FIRST_BAD"
        walk_steps "$FIRST_BAD" || continue
        review || continue
        return 0
      fi
    fi
    walk_steps 0 || { ((${#STACK_FILES[@]})) && continue; exit 0; }
    review || continue
    return 0
  done
}

# Summary + action menu. "Back" re-walks from the last step. Returns 1 to restart.
review() {
  local items
  while true; do
    settle_answers || { walk_steps "$FIRST_BAD" || return 1; continue; }
    screen
    summary
    items=(
      "Render"$'\t'"docker compose config > ${VARS[output]}"
      "Render and build"$'\t'"+ docker compose build"
      "Render, build and start"$'\t'"+ docker compose up -d"
      "Back"$'\t'"Change the answers"
      "Quit"$'\t'"Exit without changes"
    )
    ui_choose "What next?" "${items[@]}" || UI_INDEX=3
    case $UI_INDEX in
      0) return 0 ;;
      1) DO_BUILD=1; return 0 ;;
      2) DO_BUILD=1 DO_UP=1; return 0 ;;
      3)
        if ((${#HISTORY[@]} == 0)); then return 1; fi
        local last=${HISTORY[-1]}
        unset 'HISTORY[-1]'
        walk_steps "$last" || return 1
        ;;
      *) exit 0 ;;
    esac
  done
}

# ---------------------------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------------------------
ask() {
  if [[ $INTERACTIVE == 0 ]]; then [[ $ASSUME_YES == 1 ]]; return; fi
  ui_confirm "$1" "$2"
}

prepare() {
  local i copied=() f
  for i in "${!FILE_TO[@]}"; do
    f=${FILE_TO[i]}
    [[ -f $f ]] && continue
    [[ -f ${FILE_FROM[i]} ]] || die "template ${FILE_FROM[i]} not found (needed for $f)"
    if [[ $DRY_RUN == 1 ]]; then
      show_cmd cp "${FILE_FROM[i]}" "$f"
      continue
    fi
    ask "$f is missing. Copy it from ${FILE_FROM[i]}?" y || die "$f is required. Create it with: cp ${FILE_FROM[i]} $f"
    mkdir -p "$(dirname "$f")"
    cp "${FILE_FROM[i]}" "$f"
    copied+=("$f")
  done
  for f in "${COMPOSE[@]}"; do
    [[ -f $f || $DRY_RUN == 1 ]] || die "compose file $f not found"
  done
  ((${#copied[@]})) || return 0
  if [[ $INTERACTIVE == 0 ]]; then
    warn "created from templates — review/edit before starting the stack:"
    printf '         %s\n' "${copied[@]}" >&2
    return 0
  fi
  echo
  ui_box warn "Created from templates" "Review and edit these before starting the stack:" "${copied[@]/#/  }"
  echo
  if ! ui_confirm "Continue now? (No = stop here so you can edit them first)" n; then
    echo
    ui_box accent "Next step" "Edit the files above, then run ./deploy.sh again (your answers are kept)."
    save_answers
    exit 0
  fi
}

write_env_file() {
  local file=${VARS[env_file]-} key secret=0
  [[ -n $file ]] || return 0
  if [[ $DRY_RUN == 1 ]]; then
    printf '%s# would write %s (%d variables)%s\n' "$C_MUTED" "$file" "${#ENV_KEYS[@]}" "$C_RESET"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  for key in "${ENV_KEYS[@]}"; do [[ -n ${ENV_SECRET[$key]} ]] && secret=1; done
  {
    echo "# Generated by deploy.sh from $CONFIG_DIR/ — re-run the wizard instead of editing."
    for key in "${ENV_KEYS[@]}"; do printf "%s='%s'\n" "$key" "${ENV_VAL[$key]}"; done
  } >"$file"
  ((secret == 0)) || chmod 600 "$file"
}

save_answers() {
  local file=${VARS[answers]-} id p out= v first=1 item
  [[ -n $file && $DRY_RUN == 0 ]] || return 0
  out='{'
  for id in "${STEP_IDS[@]}"; do
    p=${STEP[$id]}
    [[ -n ${ACTIVE[$id]+x} && ${J[$p.type]} != secret ]] || continue
    ((first)) || out+=','
    first=0
    if [[ ${J[$p.type]} == multi ]]; then
      v=
      for item in ${ANS[$id]-}; do json_quote "$item"; v+="${v:+, }$REPLY"; done
      out+=$'\n'"  \"$id\": [$v]"
    else
      json_quote "${ANS[$id]}"
      out+=$'\n'"  \"$id\": $REPLY"
    fi
  done
  out+=$'\n}'
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$out" >"$file"
}

show_cmd() {
  local cmd
  printf -v cmd ' %q' "$@"
  printf '%s$%s%s\n' "$C_MUTED" "$cmd" "$C_RESET"
}

run() {
  show_cmd "$@"
  [[ $DRY_RUN == 1 ]] || "$@"
}

COMPOSE_ARGS=()
compose_config() { docker compose "${COMPOSE_ARGS[@]}" config >"$RENDER_TMP"; }

render() {
  local f out=${VARS[output]}
  COMPOSE_ARGS=(--project-directory . --project-name "${VARS[project]}")
  json_list w.env_files
  for f in "${JL[@]}"; do
    subst "$f"
    [[ -f $REPLY || $DRY_RUN == 1 ]] && COMPOSE_ARGS+=(--env-file "$REPLY")
  done
  [[ -n ${VARS[env_file]-} ]] && COMPOSE_ARGS+=(--env-file "${VARS[env_file]}")
  for f in "${COMPOSE[@]}"; do COMPOSE_ARGS+=(-f "$f"); done
  show_cmd docker compose "${COMPOSE_ARGS[@]}" config
  printf '%s  > %s%s\n' "$C_MUTED" "$out" "$C_RESET"
  [[ $DRY_RUN == 1 ]] && return 0
  mkdir -p "$(dirname "$out")"
  # Render to a temp file first so a failed merge never truncates a working rendered file.
  RENDER_TMP=$(mktemp "$(dirname "$out")/.render.XXXXXX")
  if [[ $INTERACTIVE == 1 ]]; then
    RENDER_LOG=$(mktemp)
    if ! ui_spin "Rendering $out" "$RENDER_LOG" compose_config; then
      local -a log=()
      mapfile -t log < <(tail -n 15 "$RENDER_LOG")
      die "docker compose config failed; $out left untouched." "" "${log[@]}"
    fi
  elif ! compose_config; then
    die "docker compose config failed; $out left untouched"
  fi
  # cat instead of mv: mktemp files are 0600; this keeps $out's mode (or the umask for a new file).
  cat "$RENDER_TMP" >"$out"
  rm -f "$RENDER_TMP"
}

section() {
  if [[ $INTERACTIVE == 1 ]]; then
    printf '\n%s%s %s%s\n' "$C_ACCENT$C_BOLD" "$G_PTR" "$1" "$C_RESET"
  else
    info "$1"
  fi
}

usage() {
  cat <<EOF
Usage: ./deploy.sh [options]

With no answers given, runs interactively: arrow keys to move, enter to select, space to
toggle, esc to go back. Set NO_COLOR=1 for a monochrome UI.

The questions come from $CONFIG_DIR/ (override with DEPLOY_CONFIG_DIR=dir). See $CONFIG_DIR/README.md.

Answers (non-interactive; anything not given takes its default):
  --set STEP=VALUE      Answer a step. Multi-choice steps take comma-separated option ids.
  --answers FILE        Start from a saved answers file (written next to each rendered stack)

Actions (default: render only):
  --build               Render, then docker compose build
  --up                  Render, build, then docker compose up -d
  --dry-run             Print what would happen without writing or running anything
  --yes                 Copy missing files from their templates without asking

Config:
  --list                Show the steps, options and compose files, then exit
  --check               Validate the JSON config, then exit
  -h, --help            Show this help
EOF
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------
DO_BUILD=0 DO_UP=0 DRY_RUN=0 ASSUME_YES=0 INTERACTIVE=1 MODE=run
ANSWERS_FILE=
SETS=()
ui_init
trap on_exit EXIT
trap 'exit 130' INT TERM

while (($#)); do
  case $1 in
    --set) SETS+=("${2:?--set needs STEP=VALUE}"); INTERACTIVE=0; shift ;;
    --answers) ANSWERS_FILE=${2:?--answers needs a file}; INTERACTIVE=0; shift ;;
    --build) DO_BUILD=1 ;;
    --up) DO_BUILD=1 DO_UP=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    --list) MODE=list ;;
    --check) MODE=check ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

load_config
load_base_env
if ! check_config; then
  die "invalid config in $CONFIG_DIR/:" "${CFG_ERRS[@]}"
fi
case $MODE in
  check) info "$CONFIG_DIR/ is valid: ${#STEP_IDS[@]} steps"; exit 0 ;;
  list) list_config; exit 0 ;;
esac

[[ $INTERACTIVE == 1 && ! -t 0 ]] && die "no terminal for the menus; pass --set/--answers (see --help)"
command -v docker >/dev/null || die "docker not found"

if [[ $INTERACTIVE == 0 ]]; then
  [[ -n $ANSWERS_FILE ]] && load_answers "$ANSWERS_FILE"
  for s in "${SETS[@]}"; do
    [[ $s == *=* ]] || die "--set $s: expected STEP=VALUE"
    [[ -n ${STEP[${s%%=*}]+x} ]] || die "--set $s: unknown step '${s%%=*}' (see --list)"
    v=${s#*=}
    # Only multi-choice answers are comma lists; text answers keep their commas.
    [[ ${J[${STEP[${s%%=*}]}.type]} == multi ]] && v=${v//,/ }
    ANS[${s%%=*}]=$v
  done
  # Secrets not given on the command line come from the stack's previous env file.
  settle_answers || true
  load_prev_env
  for id in "${STEP_IDS[@]}"; do
    if [[ ${J[${STEP[$id]}.type]} == secret ]] && ! contains "$id" "${SETS[@]%%=*}"; then unset "ANS[$id]"; fi
  done
  settle_answers || die "invalid or missing answers:" "${ERRORS[@]}"
else
  UI_ACTIVE=1
  if docker info >/dev/null 2>&1; then
    DOCKER_STATUS="${C_OK}$G_YES$C_RESET docker daemon running"
  else
    DOCKER_STATUS="${C_ERR}$G_NO$C_RESET docker daemon not reachable ${C_MUTED}(render works, build/start won't)$C_RESET"
  fi
  interactive
fi

collect
if [[ $INTERACTIVE == 1 ]]; then
  screen
else
  info "Stack ${VARS[project]} -> ${VARS[output]}"
  for i in "${!COMPOSE[@]}"; do printf '    + %-9s %s\n' "${COMPOSE_LAYER[i]}" "${COMPOSE[i]}"; done
fi

prepare
write_env_file
section "Render"
render
save_answers

OUT=${VARS[output]}
if [[ $DO_BUILD == 1 ]]; then
  section "Build"
  run docker compose -f "$OUT" build
fi
if [[ $DO_UP == 1 ]]; then
  section "Start"
  run docker compose -f "$OUT" up -d
fi

echo
if [[ $INTERACTIVE == 1 ]]; then
  lines=("${C_OK}$G_YES$C_RESET $OUT")
  [[ -n ${VARS[answers]-} ]] && lines+=("${C_MUTED}answers saved to ${VARS[answers]} (./deploy.sh --answers ... to repeat)$C_RESET")
  if ((${#NOTES[@]})); then lines+=("" "${NOTES[@]}"); fi
  ui_box ok "Done" "${lines[@]}"
else
  info "Done: $OUT"
  for n in "${NOTES[@]}"; do printf '    %s\n' "$n"; done
fi
