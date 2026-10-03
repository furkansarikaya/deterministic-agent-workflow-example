# lib.awk: helpers shared by every oversight awk program. POSIX awk only.
#
# Conventions
#   * Programs run with LC_ALL=C, so string comparison and substr() are bytewise
#     and identical across BSD awk, mawk and gawk.
#   * The model is a stream of records  kind US index US field US value  (US = \037).
#     A repeated (kind, index, field) is a list: its items are joined with SUB (\036).
#   * A scalar with provenance ("Val") is one string: SOURCE ":" TYPE ":" VALUE.
#         r:s:major      recorded, read verbatim from run state
#         d:b:true       derived  (type b = bool, n = number, s = string)
#         u::            unavailable (run state does not hold it)

function lib_init(   i) {
  US = "\037"; SUB = "\036"
  BADCH = "[" US SUB "]"
  CTRL = "[" sprintf("%c", 1) "-" sprintf("%c", 31) "]"
  for (i = 128; i < 192; i++) CONT[sprintf("%c", i)] = 1   # UTF-8 continuation bytes
  for (i = 1; i < 32; i++) CTL[i] = sprintf("%c", i)
  JSHORT[8] = "\\b"; JSHORT[9] = "\\t"; JSHORT[10] = "\\n"; JSHORT[12] = "\\f"; JSHORT[13] = "\\r"
}

# ---- strings --------------------------------------------------------------

function trim(s) { sub(/^[ \t\r\n\v\f]+/, "", s); sub(/[ \t\r\n\v\f]+$/, "", s); return s }
function oneline(s) { gsub(/[ \t\r\n\v\f]+/, " ", s); return trim(s) }
function seq_eq(a, b) { return (a "") == (b "") }        # force string comparison
function strlt(a, b) { return (a "") < (b "") }

# cut(s, n): first n characters of s (UTF-8 aware: never splits a character).
function cut(s, n,   i, len, c, chars) {
  len = length(s)
  if (len <= n) return s
  chars = 0
  for (i = 1; i <= len; i++) {
    c = substr(s, i, 1)
    if (!(c in CONT)) { chars++; if (chars > n) return substr(s, 1, i - 1) }
  }
  return s
}
# nchars(s): length in characters.
function nchars(s,   i, len, c, n) {
  len = length(s); n = 0
  for (i = 1; i <= len; i++) { c = substr(s, i, 1); if (!(c in CONT)) n++ }
  return n
}
# trunc(s, n): one-line form of s, at most n characters, "…" marks a cut.
function trunc(s, n) {
  s = oneline(s)
  if (nchars(s) <= n) return s
  return cut(s, n - 1) "…"
}

# lrep(s, from, to): replace every literal occurrence. Not gsub: the replacement
# of gsub treats "&" and "\" specially and engines disagree on the details.
function lrep(s, from, to,   out, i, n) {
  if (index(s, from) == 0) return s
  out = ""; n = length(from)
  while ((i = index(s, from)) > 0) { out = out substr(s, 1, i - 1) to; s = substr(s, i + n) }
  return out s
}

# esc(s): HTML-escape every dynamic value: & < > " '
function esc(s) {
  s = lrep(s, "&", "&amp;"); s = lrep(s, "<", "&lt;"); s = lrep(s, ">", "&gt;")
  s = lrep(s, "\"", "&quot;"); s = lrep(s, "'", "&#39;")
  return s
}

# jesc(s): JSON string body. Escapes backslash, quote and every control character.
function jesc(s,   i) {
  s = lrep(s, "\\", "\\\\"); s = lrep(s, "\"", "\\\"")
  if (s ~ CTRL)
    for (i = 1; i < 32; i++)
      if (index(s, CTL[i])) s = lrep(s, CTL[i], (i in JSHORT) ? JSHORT[i] : sprintf("\\u%04x", i))
  return s
}

# ---- ordering -------------------------------------------------------------

# ssort(A, n): sort A[1..n] ascending as strings (shell sort, in place).
function ssort(A, n,   gap, i, j, t) {
  for (gap = int(n / 2); gap > 0; gap = int(gap / 2))
    for (i = gap + 1; i <= n; i++) {
      t = A[i]
      for (j = i; j > gap && (A[j - gap] "") > (t ""); j -= gap) A[j] = A[j - gap]
      A[j] = t
    }
}
# order(K, n, OUT): K[1..n] are sort keys; OUT[1..n] gets the original indexes in
# ascending key order, ties in original order (a stable sort).
function order(K, n, OUT,   i, T) {
  for (i = 1; i <= n; i++) T[i] = K[i] "\001" sprintf("%09d", i)
  ssort(T, n)
  for (i = 1; i <= n; i++) OUT[i] = substr(T[i], length(T[i]) - 8) + 0
}
# natkey(s): a key whose string order is natural order ("AC-2" before "AC-10").
function natkey(s,   p, d) {
  if (match(s, /[0-9]+$/)) {
    p = substr(s, 1, RSTART - 1); d = substr(s, RSTART); sub(/^0+/, "", d)
    return p "\034" substr("00000000000000000000", 1, 20 - length(d)) d "\034" s
  }
  return s "\034" "00000000000000000000" "\034" s
}
# sortedkeys(SET, OUT): the keys of SET, sorted as strings, in OUT[1..n]; returns n.
function sortedkeys(SET, OUT,   k, n) {
  n = 0
  for (k in SET) OUT[++n] = k
  ssort(OUT, n)
  return n
}

# ---- Val ------------------------------------------------------------------

function U() { return "u::" }
function R(v) { if (v == "" || v == "PENDING" || v == "pending") return U(); return "r:s:" v }
function RV(v) { return "r:s:" v }                     # recorded verbatim, even when empty-looking
function DS(v) { return "d:s:" v }
function DB(b) { return "d:b:" (b ? "true" : "false") }
function DN(n) { return "d:n:" n }
function vsrc(v) { return substr(v, 1, 1) }            # r | d | u
function vtyp(v) { return substr(v, 3, 1) }            # s | b | n
function vval(v) { return substr(v, 5) }
function vavail(v) { return vsrc(v) == "r" || vsrc(v) == "d" }
function vstr(v) { return (vavail(v) && vtyp(v) == "s") ? vval(v) : "" }
function vtrue(v) { return vavail(v) && vtyp(v) == "b" && vval(v) == "true" }
function vfalse(v) { return vavail(v) && vtyp(v) == "b" && vval(v) == "false" }
function srcname(v,   s) { s = vsrc(v); return s == "r" ? "recorded" : (s == "d" ? "derived" : "unavailable") }

# ---- lists ----------------------------------------------------------------

function lsplit(v, OUT) { if (v == "") return 0; return split(v, OUT, SUB) }
function ljoin(v, sep,   n, a, i, s) {
  n = lsplit(v, a); s = ""
  for (i = 1; i <= n; i++) s = s (i > 1 ? sep : "") a[i]
  return s
}
function lhas(v, item,   n, a, i) {
  n = lsplit(v, a)
  for (i = 1; i <= n; i++) if (seq_eq(a[i], item)) return 1
  return 0
}
