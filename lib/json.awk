# Flatten one JSON document into "path<TAB>type<TAB>value" lines, for lib/json.sh.
#
# POSIX awk (gawk, mawk, busybox and BSD awk all work), so reading config needs no jq.
#
#   {"a": {"b": [1, "x"]}}   ->   .        object  a
#                                 a        object  b
#                                 a.b      array   2
#                                 a.b.0    number  1
#                                 a.b.1    string  x
#
# object -> space-separated keys in document order; array -> element count.
# The document root is ".". Array elements are addressed by index.
#
# Deliberate limits, reported as errors with file:line:col: object keys may not contain dots,
# whitespace or tabs (they would break the paths), strings may not contain newlines or tabs
# (they would break the lines), and \u escapes are limited to ASCII.
#
# usage: awk -v file=NAME -f lib/json.awk NAME

BEGIN { RS = "\001" }
{ text = text $0 }
END {
  if (failed) exit 1
  n = length(text)
  pos = 1
  skip_ws()
  if (pos > n) fail("empty document")
  parse_value(".")
  skip_ws()
  if (pos <= n) fail("unexpected data after the document")
}

function fail(msg,    i, line, col) {
  line = 1; col = 1
  for (i = 1; i < pos && i <= n; i++) {
    if (substr(text, i, 1) == "\n") { line++; col = 1 } else col++
  }
  printf "%s:%d:%d: %s\n", file, line, col, msg > "/dev/stderr"
  failed = 1
  exit 1
}

function skip_ws(    c) {
  while (pos <= n) {
    c = substr(text, pos, 1)
    if (c != " " && c != "\t" && c != "\n" && c != "\r") return
    pos++
  }
}

function child(path, key) { return path == "." ? key : path "." key }

function emit(path, type, value) { printf "%s\t%s\t%s\n", path, type, value }

function parse_value(path,    c, rest) {
  c = substr(text, pos, 1)
  if (c == "{") return parse_object(path)
  if (c == "[") return parse_array(path)
  if (c == "\"") { emit(path, "string", parse_string()); return }
  rest = substr(text, pos, 40)
  if (match(rest, /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?/)) {
    emit(path, "number", substr(rest, 1, RLENGTH)); pos += RLENGTH; return
  }
  if (substr(rest, 1, 4) == "true") { emit(path, "bool", "true"); pos += 4; return }
  if (substr(rest, 1, 5) == "false") { emit(path, "bool", "false"); pos += 5; return }
  if (substr(rest, 1, 4) == "null") { emit(path, "null", ""); pos += 4; return }
  fail(c == "" ? "unexpected end of document" : "unexpected character '" c "'")
}

function parse_object(path,    key, keys, seen, c) {
  pos++
  keys = ""
  skip_ws()
  if (substr(text, pos, 1) == "}") { pos++; emit(path, "object", ""); return }
  while (1) {
    skip_ws()
    if (substr(text, pos, 1) != "\"") fail("expected a quoted object key")
    key = parse_string()
    if (key == "" || key ~ /[.[:space:]]/) fail("object key \"" key "\" must be non-empty, without dots or whitespace")
    if (("|" key "|") in seen) fail("duplicate key \"" key "\"")
    seen["|" key "|"] = 1
    skip_ws()
    if (substr(text, pos, 1) != ":") fail("expected ':' after key \"" key "\"")
    pos++
    skip_ws()
    parse_value(child(path, key))
    keys = keys (keys == "" ? "" : " ") key
    skip_ws()
    c = substr(text, pos, 1)
    if (c == ",") { pos++; continue }
    if (c == "}") { pos++; break }
    fail("expected ',' or '}' in object")
  }
  emit(path, "object", keys)
}

function parse_array(path,    count, c) {
  pos++
  count = 0
  skip_ws()
  if (substr(text, pos, 1) == "]") { pos++; emit(path, "array", 0); return }
  while (1) {
    skip_ws()
    parse_value(child(path, count))
    count++
    skip_ws()
    c = substr(text, pos, 1)
    if (c == ",") { pos++; continue }
    if (c == "]") { pos++; break }
    fail("expected ',' or ']' in array")
  }
  emit(path, "array", count)
}

function parse_string(    out, c, e, hex, code, rest) {
  pos++
  out = ""
  while (1) {
    # Copy the run of ordinary characters in one go.
    rest = substr(text, pos)
    if (match(rest, /^[^"\\\t\n\r]+/)) { out = out substr(rest, 1, RLENGTH); pos += RLENGTH }
    c = substr(text, pos, 1)
    if (c == "\"") { pos++; return out }
    if (c == "") fail("unterminated string")
    if (c == "\t" || c == "\n" || c == "\r") fail("raw tab/newline inside a string")
    # backslash escape
    e = substr(text, pos + 1, 1)
    if (e == "\"" || e == "\\" || e == "/") { out = out e; pos += 2; continue }
    if (e == "u") {
      hex = toupper(substr(text, pos + 2, 4))
      if (hex !~ /^00[0-7][0-9A-F]$/) fail("only ASCII \\u escapes (\\u0000-\\u007F) are supported; write other characters literally")
      code = index("0123456789ABCDEF", substr(hex, 3, 1)) * 16 + index("0123456789ABCDEF", substr(hex, 4, 1)) - 17
      if (code < 32) fail("control characters are not supported in strings")
      out = out sprintf("%c", code); pos += 6; continue
    }
    if (e == "n" || e == "t" || e == "r" || e == "b" || e == "f") fail("\\" e " is not supported: strings are single-line (use an array of lines)")
    fail("invalid escape \\" e)
  }
}
