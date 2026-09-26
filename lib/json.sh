# Read JSON files into bash associative arrays (parsing is done by lib/json.awk).
#
#   json_load FILE PREFIX    J[PREFIX.path]=value, JT[PREFIX.path]=type
#                            (the document root itself is J[PREFIX] / JT[PREFIX])
#   json_len KEY             array length (0 when missing)          -> REPLY
#   json_keys KEY            object keys, space-separated ("" when missing) -> REPLY
#   json_list KEY            array of strings -> JL array ("" entries allowed)
#
# Types: object array string number bool null. A missing key has no JT entry.

declare -gA J=() JT=()
JSON_AWK=${JSON_AWK:-$(dirname "${BASH_SOURCE[0]}")/json.awk}

json_load() {
  local file=$1 prefix=$2 out path type value key
  out=$(awk -v file="$file" -f "$JSON_AWK" "$file") || return 1
  while IFS= read -r line; do
    path=${line%%$'\t'*}
    line=${line#*$'\t'}
    type=${line%%$'\t'*}
    value=${line#*$'\t'}
    if [[ $path == . ]]; then key=$prefix; else key=$prefix.$path; fi
    J[$key]=$value
    JT[$key]=$type
  done <<<"$out"
}

json_len() {
  REPLY=0
  [[ ${JT[$1]-} == array ]] && REPLY=${J[$1]}
  return 0
}

json_keys() {
  REPLY=
  [[ ${JT[$1]-} == object ]] && REPLY=${J[$1]}
  return 0
}

json_list() {
  local i
  JL=()
  if [[ ${JT[$1]-} == array ]]; then
    for ((i = 0; i < J[$1]; i++)); do JL+=("${J[$1.$i]-}"); done
  elif [[ -n ${JT[$1]-} && ${JT[$1]} != null ]]; then
    JL=("${J[$1]}") # a lone string is accepted where a list is expected
  fi
  return 0
}

# Escape a string for a JSON document -> REPLY
json_quote() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  REPLY="\"$s\""
}
