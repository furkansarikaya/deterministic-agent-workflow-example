# model.awk: one run directory -> oversight model records. Read-only.
#
# The model is a projection of run state, never truth: it holds no fact the run
# state does not, and every scalar carries a provenance label (see lib.awk).
#   recorded     read verbatim from run state
#   derived      computed deterministically from recorded values
#   unavailable  the run state does not hold it
#
# Input (stdin), written by oversight.sh, one record per line, fields joined by \037:
#   root PATH | task ID | diffstate ok|none | diff PATH ADDED DELETED
#   gate PATH | wevid PATH | decision PATH        (the files to read; awk never lists a directory)
# Every parser accepts exactly the shapes agent.sh writes and ignores the rest.
# This program has no END rule: all work happens in BEGIN.

BEGIN { lib_init(); REF_RE = "[A-Za-z0-9_./-]+\\.[A-Za-z0-9]+:[A-Za-z0-9_.]+"; load_index(); build(); dump(); exit }

# ---- record store -----------------------------------------------------------

# set(kind, idx, field, value): store a record; keys keep first-insertion order.
function set(kind, idx, f, v,   k) {
  k = kind SUBSEP idx SUBSEP f
  if (!(k in SEEN)) { SEEN[k] = 1; KEYS[++NK] = k }
  M[k] = v
}
# ladd(kind, idx, field, item): append an item to a list field.
function ladd(kind, idx, f, item,   k) {
  k = kind SUBSEP idx SUBSEP f
  if (!(k in SEEN)) { SEEN[k] = 1; KEYS[++NK] = k; LISTK[k] = 1; M[k] = item }
  else M[k] = M[k] SUB item
}
function get(kind, idx, f) { return M[kind SUBSEP idx SUBSEP f] }
function note(key) { UNAV[key] = 1 }
function next_idx(kind) { return ++CNT[kind] }

function dump(   i, k, p, n, a, j) {
  for (i = 1; i <= NK; i++) {
    k = KEYS[i]; split(k, p, SUBSEP)
    if (k in LISTK) { n = split(M[k], a, SUB); for (j = 1; j <= n; j++) emit(p[1], p[2], p[3], a[j]) }
    else emit(p[1], p[2], p[3], M[k])
  }
}
function emit(kind, idx, f, v) { printf "%s%s%s%s%s%s%s\n", kind, US, idx, US, f, US, v }

# ---- readers ----------------------------------------------------------------

# One input line, with the two separator bytes removed so records cannot be forged.
function clean(line) { if (line ~ BADCH) gsub(BADCH, "", line); return line }

# readfile(path, L): lines into L[1..n]; returns n, or -1 when the file is unreadable.
function readfile(path, L,   n, line, r) {
  split("", L); n = 0
  r = (getline line < path)
  if (r < 0) return -1
  while (r > 0) { L[++n] = clean(line); r = (getline line < path) }
  close(path)
  return n
}

# split_kv(line, sep): set KV_K / KV_V when line is `key<sep>value` with a bare key.
function split_kv(line, sep,   i, k, v) {
  i = index(line, sep)
  if (i <= 1) return 0
  k = trim(substr(line, 1, i - 1))
  if (k ~ /[ \t]/) return 0
  v = trim(substr(line, i + length(sep)))
  if (length(v) >= 2 && substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"") v = substr(v, 2, length(v) - 2)
  KV_K = k; KV_V = v
  return 1
}

# flat_yaml(path, F): `key: value` lines without nesting; the first key wins.
function flat_yaml(path, F,   L, n, i) {
  split("", F)
  n = readfile(path, L)
  if (n < 0) return 0
  for (i = 1; i <= n; i++) {
    if (substr(L[i], 1, 1) == " " || !split_kv(L[i], ": ")) continue
    if (!(KV_K in F)) F[KV_K] = KV_V
  }
  return 1
}

# split_list(s, OUT): comma separated, trimmed, non-empty items; returns the count.
function split_list(s, OUT,   n, a, i, c, t) {
  n = split(s, a, ","); c = 0
  for (i = 1; i <= n; i++) { t = trim(a[i]); if (t != "") OUT[++c] = t }
  return c
}
function basename(p) { sub(/.*\//, "", p); return p }

# ---- input ------------------------------------------------------------------

function load_index(   line, p) {
  while ((getline line) > 0) {
    split(line, p, US)
    if (p[1] == "root") ROOT = p[2]
    else if (p[1] == "task") TASK = p[2]
    else if (p[1] == "diffstate") DIFFSTATE = p[2]
    else if (p[1] == "diff") { DIFF_ADD[p[2]] = p[3]; DIFF_DEL[p[2]] = p[4] }
    else if (p[1] == "gate") GATEFILE[++NGATEFILE] = p[2]
    else if (p[1] == "wevid") EVFILE[++NEVFILE] = p[2]
    else if (p[1] == "decision") DECFILE[++NDECFILE] = p[2]
  }
  RUNDIR = ROOT "/.agents/runs/" TASK
  if (!flat_run(RUNDIR "/RUN.yaml")) { print "oversight: run not found: " TASK > "/dev/stderr"; exit 1 }
}

# flat_run(path): RUN.yaml's two-level sections as RUN["section.key"]; first key wins.
function flat_run(path,   L, n, i, line, section) {
  n = readfile(path, L)
  if (n < 0) return 0
  for (i = 1; i <= n; i++) {
    line = L[i]
    if (substr(line, 1, 1) == "#" || trim(line) == "") continue
    if (substr(line, 1, 1) != " ") { section = trim(line); sub(/:$/, "", section); continue }
    if (substr(line, 1, 4) == "    ") continue            # nested list items (baseline fingerprints)
    if (split_kv(trim(line), ": ") && !((section "." KV_K) in RUN)) RUN[section "." KV_K] = KV_V
  }
  return 1
}

function build() {
  header(); pipeline(); flow(); gates(); criteria(); files(); commands()
  attempts(); roles(); lifecycle(); fingerprints(); outcome(); finish()
}

# ---- header, pipeline -------------------------------------------------------

function header(   topo, s, h) {
  set("task", 0, "id", TASK)
  set("task", 0, "taskSource", R(RUN["task_source.path"]))
  set("task", 0, "baseSha", R(RUN["repository.base_sha"]))
  set("task", 0, "branch", R(RUN["repository.task_branch"]))
  set("task", 0, "mode", R(RUN["execution.mode"]))
  set("status", 0, "state", R(RUN["execution.state"]))
  set("status", 0, "handoff", R(RUN["handoff.state"]))
  set("status", 0, "knowledge", R(RUN["execution.knowledge_state"]))
  topo = RUN["execution.topology"]
  if (topo == "" || topo == "PENDING") { set("topology", 0, "value", U()); note("topology") }
  else set("topology", 0, "value", R(topo))
  s = vstr(get("status", 0, "state")); h = vstr(get("status", 0, "handoff"))
  if (s == "FAILED" || s == "BLOCKED") set("status", 0, "summary", DS(s))
  else if (h != "") set("status", 0, "summary", DS(h))
  else set("status", 0, "summary", DS(s))
}
function state() { return vstr(get("status", 0, "state")) }
function handoff() { return vstr(get("status", 0, "handoff")) }
function topology() { return vstr(get("topology", 0, "value")) }

# config_pipelines(): the `pipelines:` block of .agents/config.yaml as CFG[class, key].
function config_pipelines(   L, n, i, line, inb, cur) {
  n = readfile(ROOT "/.agents/config.yaml", L)
  for (i = 1; i <= n; i++) {
    line = L[i]
    if (line == "pipelines:") inb = 1
    else if (inb && line != "" && substr(line, 1, 1) != " " && substr(line, 1, 1) != "#") inb = 0
    else if (inb && line ~ /^  [A-Z]+:$/) { cur = trim(line); sub(/:$/, "", cur); CFGHAS[cur] = 1 }
    else if (inb && cur != "" && substr(line, 1, 4) == "    ") {
      if (split_kv(trim(line), ": ")) CFG[cur, KV_K] = KV_V
    }
  }
}

# pipeline(): which gates apply, from the recorded class and the config.
function pipeline(   class, rev, review) {
  class = RUN["pipeline.classification"]
  set("pipeline", 0, "classification", R(class))
  set("pipeline", 0, "review", R(RUN["pipeline.review"]))
  set("pipeline", 0, "evidenceRequired", U()); set("pipeline", 0, "qaPlanRequired", U())
  config_pipelines()
  if (!(class in CFGHAS)) { note("pipeline.requirements"); PIPE_OK = 0; return }
  PIPE_OK = 1
  set("pipeline", 0, "evidenceRequired", DB(CFG[class, "evidence"] == "yes"))
  set("pipeline", 0, "qaPlanRequired", DB(CFG[class, "qa"] == "yes"))
  rev = CFG[class, "review"]
  review = (rev == "yes") || (rev == "optional" && RUN["pipeline.review"] == "yes")
  if (review) ladd("pipeline", 0, "requiredGates", "REVIEW")
  if (CFG[class, "qa"] == "yes") ladd("pipeline", 0, "requiredGates", "QA")
  ladd("pipeline", 0, "requiredGates", "VERIFY")
}
function has_gate(g) { return lhas(get("pipeline", 0, "requiredGates"), g) }

# ---- flow: the hash-chained ledger ------------------------------------------

# ledger_parse(line): seq= prev= event= role= from= to= digest= ts= detail=...
function ledger_parse(line,   n, t) {
  if (!match(line, /^seq=[0-9]+ prev=[^ \t]+ event=[^ \t]+ role=[^ \t]+ from=[^ \t]+ to=[^ \t]+ digest=[^ \t]+ ts=[^ \t]+ detail=/)) return 0
  n = split(substr(line, 1, RLENGTH), t, " ")
  LN++
  LED_seq[LN] = substr(t[1], 5) + 0; LED_event[LN] = substr(t[3], 7); LED_role[LN] = substr(t[4], 6)
  LED_from[LN] = substr(t[5], 6); LED_to[LN] = substr(t[6], 4); LED_ts[LN] = substr(t[8], 4)
  LED_detail[LN] = substr(line, RLENGTH + 1)
  return 1
}

function flow(   path, line, r, i, K, O, sorted, T) {
  path = RUNDIR "/LEDGER.log"
  r = (getline line < path)
  while (r > 0) { ledger_parse(clean(line)); r = (getline line < path) }
  close(path)
  if (LN == 0) { HASLED = 0; note("flow"); return }
  HASLED = 1
  sorted = 1
  for (i = 2; i <= LN; i++) if (LED_seq[i] < LED_seq[i - 1]) sorted = 0
  if (!sorted) {                                   # stable sort by seq
    for (i = 1; i <= LN; i++) K[i] = sprintf("%012d", LED_seq[i])
    order(K, LN, O)
    for (i = 1; i <= LN; i++) {
      T["seq", i] = LED_seq[O[i]]; T["event", i] = LED_event[O[i]]; T["role", i] = LED_role[O[i]]
      T["from", i] = LED_from[O[i]]; T["to", i] = LED_to[O[i]]; T["ts", i] = LED_ts[O[i]]; T["detail", i] = LED_detail[O[i]]
    }
    for (i = 1; i <= LN; i++) {
      LED_seq[i] = T["seq", i]; LED_event[i] = T["event", i]; LED_role[i] = T["role", i]
      LED_from[i] = T["from", i]; LED_to[i] = T["to", i]; LED_ts[i] = T["ts", i]; LED_detail[i] = T["detail", i]
    }
  }
  for (i = 1; i <= LN; i++) {
    set("flow", i, "seq", LED_seq[i]); set("flow", i, "event", LED_event[i]); set("flow", i, "role", LED_role[i])
    set("flow", i, "from", LED_from[i]); set("flow", i, "to", LED_to[i]); set("flow", i, "at", LED_ts[i])
    set("flow", i, "detail", LED_detail[i]); set("flow", i, "source", "recorded")
  }
  CNT["flow"] = LN
}

# ---- gates, findings, remediation -------------------------------------------

# gates(): read every gate record, then derive findings, remediation loops and the
# manifest of changed files. A hash comparison here only labels a record as bound
# to the current frozen contract; integrity itself is `agent.sh verify-gates`.
function gates(   i, j, n, p, pa, pth, b, F, K, O, ord, frz, bound, k, used, lastreopen, terminal, sev, cat, st, res, gi, mpath, ML, mn, line, ix) {
  # 1. the gate files, in file-number order
  n = 0
  for (i = 1; i <= NGATEFILE; i++) {
    b = basename(GATEFILE[i])
    if (b !~ /^[0-9]+-(REVIEW|QA|VERIFY|REOPEN)\.yaml$/) continue
    n++; GP[n] = GATEFILE[i]
    pth = b; sub(/-.*/, "", pth); sub(/^0+/, "", pth)
    K[n] = substr("00000000000000000000", 1, 20 - length(pth)) pth "\034" b
  }
  order(K, n, ord)
  split("task evidence plan qa_plan", frz, " ")
  RN = 0
  for (i = 1; i <= n; i++) {
    pth = GP[ord[i]]
    if (!flat_yaml(pth, F)) continue
    RN++
    bound = 1
    for (k = 1; k <= 4; k++) if (!seq_eq(F[frz[k] "_sha256"], RUN["freeze." frz[k] "_sha256"])) bound = 0
    RG_seq[RN] = F["seq"] + 0; RG_gate[RN] = F["gate"]; RG_result[RN] = F["result"]; RG_role[RN] = F["role"]
    RG_patch[RN] = F["patch_sha256"]; RG_report[RN] = F["report"]; RG_rsha[RN] = F["report_sha256"]
    RG_summary[RN] = F["summary"]; RG_at[RN] = F["timestamp"]; RG_bound[RN] = bound
    RG_fscope[RN] = F["fix_scope"]; RG_finds[RN] = F["findings"]; RG_finstr[RN] = F["fix_instruction"]
    RG_sev[RN] = F["severity"]; RG_cat[RN] = F["category"]
    RG_files[RN] = 0
    mpath = pth; sub(/\.yaml$/, ".manifest", mpath)
    mn = readfile(mpath, ML)
    if (mn >= 0) {                                  # the last manifest read is the changed-file set
      RG_files[RN] = 0; split("", MAN_path); split("", MAN_fp); MANN = 0
      for (j = 1; j <= mn; j++)
        if (match(ML[j], /\|[^|]*$/) && RSTART > 1) {
          RG_files[RN]++; MANN++
          MAN_path[MANN] = substr(ML[j], 1, RSTART - 1); MAN_fp[MANN] = substr(ML[j], RSTART + 1)
        }
      HASMAN = 1
    }
  }
  # 2. gate records, stable by seq
  for (i = 1; i <= RN; i++) K[i] = sprintf("%012d", RG_seq[i])
  order(K, RN, ord)
  terminal = (state() == "FAILED" || state() == "BLOCKED")
  lastreopen = 0
  for (i = 1; i <= RN; i++) {
    gi = ord[i]; GORD[i] = gi
    set("gate", i, "seq", RG_seq[gi]); set("gate", i, "gate", RG_gate[gi]); set("gate", i, "result", RG_result[gi])
    set("gate", i, "role", RG_role[gi]); set("gate", i, "patchSha256", RG_patch[gi]); set("gate", i, "report", RG_report[gi])
    set("gate", i, "reportSha256", RG_rsha[gi]); set("gate", i, "summary", RG_summary[gi]); set("gate", i, "at", RG_at[gi])
    set("gate", i, "boundToCurrentContract", DB(RG_bound[gi])); set("gate", i, "manifestFiles", RG_files[gi])
    n = split_list(RG_fscope[gi], pa)
    for (j = 1; j <= n; j++) ladd("gate", i, "fixScope", pa[j])
    if (RG_gate[gi] == "REOPEN") lastreopen = RG_seq[gi]
  }
  CNT["gate"] = RN
  # 3. one finding per failing gate record
  used = 0; FN = 0
  for (i = 1; i <= RN; i++) {
    gi = GORD[i]
    if (RG_result[gi] != "fail") continue
    if (RG_bound[gi] && RG_seq[gi] > lastreopen) used++
    FN++
    set("finding", FN, "id", "F-" RG_seq[gi]); set("finding", FN, "gate", RG_gate[gi]); set("finding", FN, "gateSeq", RG_seq[gi])
    set("finding", FN, "role", RG_role[gi]); set("finding", FN, "text", RG_finds[gi])
    set("finding", FN, "fixInstruction", RG_finstr[gi])
    set("finding", FN, "severity", R(RG_sev[gi])); set("finding", FN, "category", R(RG_cat[gi]))
    n = split_list(RG_fscope[gi], pa)
    for (j = 1; j <= n; j++) ladd("finding", FN, "fixScope", pa[j])
    st = "open"; res = U()
    for (j = i + 1; j <= RN; j++)
      if (RG_gate[GORD[j]] == RG_gate[gi] && RG_result[GORD[j]] == "pass") {
        st = "resolved"; res = DS(sprintf("gate %03d %s pass", RG_seq[GORD[j]], RG_gate[GORD[j]])); break
      }
    if (st == "open") {
      if (!RG_bound[gi]) { st = "superseded"; res = DS("contract amended after this finding") }
      else if (terminal) { st = "unresolved_at_termination"; res = DS("run ended " state()) }
      else res = DS("open")
    }
    set("finding", FN, "resolution", res); set("finding", FN, "state", st)
    if (RG_sev[gi] == "" || RG_sev[gi] == "PENDING" || RG_sev[gi] == "pending") note("findings.severity")
    if (RG_cat[gi] == "" || RG_cat[gi] == "PENDING" || RG_cat[gi] == "pending") note("findings.category")
  }
  CNT["finding"] = FN
  remediation(used)
}

# mode_value(path, key): the first indented `key: value` of a mode policy file.
function mode_value(path, key,   L, n, i) {
  n = readfile(path, L)
  for (i = 1; i <= n; i++) if (split_kv(trim(L[i]), ": ") && KV_K == key) return KV_V
  return ""
}

# remediation(used): one loop per failing gate record. Fix start and return come
# from the ledger only; without a ledger they stay unavailable.
function remediation(used,   mode, v, i, f, gateAt, started, k, e, pre) {
  set("remediation", 0, "failingGateRecords", used)
  set("remediation", 0, "maxFixes", U()); set("remediation", 0, "budgetExhausted", U())
  mode = RUN["execution.mode"]
  if (mode ~ /^[A-Za-z0-9_-]+$/) {
    v = mode_value(ROOT "/.agents/modes/" mode ".yaml", "max_bounded_fix_attempts")
    if (v != "") {
      set("remediation", 0, "maxFixes", R(v))
      if (v ~ /^[+-]?[0-9]+$/) set("remediation", 0, "budgetExhausted", DB(used > v + 0))
    }
  }
  for (f = 1; f <= FN; f++) {
    set("loop", f, "loop", f); set("loop", f, "gate", get("finding", f, "gate"))
    set("loop", f, "failedGateSeq", get("finding", f, "gateSeq")); set("loop", f, "finding", get("finding", f, "id"))
    set("loop", f, "fixStarted", U()); set("loop", f, "fixReturned", U())
    set("loop", f, "resolution", get("finding", f, "resolution"))
    if (!HASLED) continue
    set("loop", f, "fixStarted", DB(0)); set("loop", f, "fixReturned", DB(0))
    gateAt = 0
    pre = sprintf("%03d-%s", get("finding", f, "gateSeq"), get("finding", f, "gate"))
    for (i = 1; i <= LN; i++)
      if (index(LED_event[i], "gate:" get("finding", f, "gate") ":fail") == 1 && index(LED_detail[i], pre) == 1) gateAt = i
    started = 0
    for (i = gateAt + 1; gateAt > 0 && i <= LN; i++) {
      if (!started && LED_event[i] == "handoff:IMPLEMENTING" && LED_from[i] == "IMPLEMENTED") { started = i; set("loop", f, "fixStarted", DB(1)) }
      else if (started && LED_event[i] == "handoff:IMPLEMENTED") { set("loop", f, "fixReturned", DB(1)); break }
    }
  }
  CNT["loop"] = FN
}

# ---- criteria: requirement -> plan files -> QA scenarios -> results ----------

# plan_scope(): PLAN.md front matter `scope:` as PS_path[i], PS_crit[i] (joined list).
function plan_scope(   L, n, i, line, inb, cur, inner) {
  if (PS_DONE) return PS_OK
  PS_DONE = 1; PSN = 0
  n = readfile(RUNDIR "/PLAN.md", L)
  if (n < 0) { PS_OK = 0; return 0 }
  PS_OK = 1
  for (i = 1; i <= n; i++) {
    line = L[i]
    if (line == "scope:") { inb = 1; continue }
    if (inb && line == "---") break
    if (!inb) continue
    if (line ~ /^  - path: ./) cur = trim(substr(line, 11))
    else if (line ~ /^    criteria: \[.*\]$/ && cur != "") {
      inner = substr(line, 16, length(line) - 16)
      PSN++; PS_path[PSN] = cur; PS_crit[PSN] = inner; cur = ""
    }
  }
  return 1
}

# qa_note(rest): what follows PASS|FAIL: blanks, an optional run of em dash, colon
# and hyphen, one optional space; the remainder is the note.
function qa_note(rest,   c) {
  sub(/^[ \t]+/, "", rest)
  while (1) {
    if (substr(rest, 1, 3) == "—") rest = substr(rest, 4)
    else if ((c = substr(rest, 1, 1)) == ":" || c == "-") rest = substr(rest, 2)
    else break
  }
  if (substr(rest, 1, 1) == " ") rest = substr(rest, 2)
  return trim(rest)
}

# ac_tokens(s, OUT): every AC-... token of s; returns the count.
function ac_tokens(s, OUT,   n) {
  n = 0
  while (match(s, /AC-[A-Za-z0-9_-]*[A-Za-z0-9]/)) { OUT[++n] = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH) }
  return n
}

function link(from, to, kind, src) { LKN++; LK_from[LKN] = from; LK_to[LKN] = to; LK_kind[LKN] = kind; LK_src[LKN] = src }

function criteria(   L, n, i, line, m, id, ids, nids, txt, seen, K, O, fmap, nf, scen, ns, qres, qnote, qid, ac, acs, na, j, c,
                    refs, acref, rs, r, nr, EL, needqa, needev, pass, fail, sc, FLS, SCS, RSC, qaidx, nq, k, v) {
  needqa = vtrue(get("pipeline", 0, "qaPlanRequired")); needev = vtrue(get("pipeline", 0, "evidenceRequired"))
  # requirements
  n = readfile(RUNDIR "/TASK.md", L); nids = 0
  for (i = 1; i <= n; i++)
    if (match(L[i], /^- AC-[A-Za-z0-9_-]+:/)) {
      id = substr(L[i], 3, RLENGTH - 3)
      if (!(id in txt)) ids[++nids] = id
      m = substr(L[i], RLENGTH + 1); sub(/^ /, "", m); txt[id] = trim(m)
    }
  for (i = 1; i <= nids; i++) K[i] = natkey(ids[i])
  order(K, nids, O)
  for (i = 1; i <= nids; i++) CR_id[i] = ids[O[i]]
  set("task", 0, "requirementCount", nids)
  # plan scope
  if (plan_scope())
    for (i = 1; i <= PSN; i++) {
      nf = split_list(PS_crit[i], c)
      for (j = 1; j <= nf; j++) { fmap[c[j], ++FCNT[c[j]]] = PS_path[i]; link(c[j], PS_path[i], "scopes", "recorded") }
    }
  # QA report results
  n = readfile(RUNDIR "/QA_REPORT.md", L)
  for (i = 1; i <= n; i++)
    if (match(L[i], /^- QA-[A-Za-z0-9_-]+: (PASS|FAIL)/)) {
      m = substr(L[i], 1, RLENGTH); line = substr(L[i], RLENGTH + 1)
      if (line != "" && substr(line, 1, 1) ~ /[A-Za-z0-9_]/) continue          # \b after PASS|FAIL
      qid = substr(m, 3, index(m, ":") - 3)
      qres[qid] = R(substr(m, length(m) - 3)); qnote[qid] = qa_note(line)
    }
  # QA plan scenarios
  n = readfile(RUNDIR "/QA_PLAN.md", L); nq = 0
  for (i = 1; i <= n; i++)
    if (match(L[i], /^- QA-[A-Za-z0-9_-]+ \([^)]*\):/)) {
      m = substr(L[i], 1, RLENGTH); line = substr(L[i], RLENGTH + 1); sub(/^ /, "", line)
      qid = substr(m, 3); qid = substr(qid, 1, index(qid, " ") - 1)
      nq++; QA_id[nq] = qid; QA_plan[nq] = trim(line)
      v = substr(m, index(m, "(") + 1); v = substr(v, 1, index(v, ")") - 1)
      na = ac_tokens(v, acs)
      QA_ac[nq] = (na > 0) ? acs[1] : ""
      QA_res[nq] = (qid in qres) ? qres[qid] : U(); QA_note[nq] = (qid in qres) ? qnote[qid] : ""
      for (j = 1; j <= na; j++) { scen[acs[j], ++SCNT[acs[j]]] = qid; link(acs[j], qid, "covers", "recorded") }
    }
  for (i = 1; i <= nq; i++) K[i] = natkey(QA_id[i])
  order(K, nq, O)
  for (i = 1; i <= nq; i++) {
    j = O[i]
    set("qa", i, "id", QA_id[j]); set("qa", i, "criterion", QA_ac[j]); set("qa", i, "plan", QA_plan[j])
    set("qa", i, "result", QA_res[j]); set("qa", i, "note", QA_note[j])
    qaidx[QA_id[j]] = i; qaresult[QA_id[j]] = QA_res[j]
  }
  CNT["qa"] = nq
  # evidence references: only a line that names both an AC and a file:symbol links them
  n = readfile(RUNDIR "/EVIDENCE.md", L)
  for (i = 1; i <= n; i++) {
    line = L[i]; nr = 0
    while (match(line, REF_RE)) { rs[++nr] = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH) }
    if (nr == 0) continue
    na = ac_tokens(L[i], acs)
    for (r = 1; r <= nr; r++) { refs[rs[r]] = 1; for (j = 1; j <= na; j++) acref[acs[j], rs[r]] = 1 }
  }
  nr = sortedkeys(refs, rs)
  for (i = 1; i <= nr; i++) ladd("evidenceRefs", 0, "items", rs[i])
  # one criterion per requirement
  for (i = 1; i <= nids; i++) {
    id = CR_id[i]
    set("crit", i, "id", id); set("crit", i, "text", txt[id])
    split("", FLS); nf = 0; split("", SCS); ns = 0
    for (j = 1; j <= FCNT[id]; j++) { if (!((id SUBSEP "f" fmap[id, j]) in seen)) { seen[id SUBSEP "f" fmap[id, j]] = 1; FLS[++nf] = fmap[id, j] } }
    ssort(FLS, nf)
    for (j = 1; j <= nf; j++) ladd("crit", i, "files", FLS[j])
    for (j = 1; j <= SCNT[id]; j++) { if (!((id SUBSEP "s" scen[id, j]) in seen)) { seen[id SUBSEP "s" scen[id, j]] = 1; SCS[++ns] = scen[id, j] } }
    for (j = 1; j <= ns; j++) K[j] = natkey(SCS[j])
    order(K, ns, O)
    for (j = 1; j <= ns; j++) { RSC[j] = SCS[O[j]]; ladd("crit", i, "qaScenarios", RSC[j]) }
    split("", EL); k = 0
    for (j = 1; j <= nr; j++) if ((id SUBSEP rs[j]) in acref) { EL[++k] = rs[j]; ladd("crit", i, "evidenceRefs", rs[j]); link(id, rs[j], "informed_by", "derived") }
    set("crit", i, "qaResult", U())
    if (nf == 0) ladd("crit", i, "unavailable", "files")
    if (needqa && ns == 0) ladd("crit", i, "unavailable", "qaScenarios")
    if (k == 0 && needev) ladd("crit", i, "unavailable", "evidenceRefs")
    pass = 0; fail = 0
    for (j = 1; j <= ns; j++) {
      sc = vstr(qaresult[RSC[j]])
      if (sc == "PASS") pass++; else if (sc == "FAIL") fail++
    }
    if (fail > 0) set("crit", i, "qaResult", DS("FAIL"))
    else if (pass > 0 && pass == ns) set("crit", i, "qaResult", DS("PASS"))
    else if (ns > 0) ladd("crit", i, "unavailable", "qaResult")
  }
  CNT["crit"] = nids
  if (nids == 0) note("criteria")
}

# ---- files: changed paths from the newest gate manifest, plus plan scope ------

function files(   i, j, n, paths, np, p, pa, st, planned, nplan, SET, K, O, nf, all, a, d, tadd, tdel, ec, t) {
  commands_list()
  for (i = 1; i <= TN; i++) {
    n = split_list(T_targets[i], pa)
    for (j = 1; j <= n; j++) { ec[pa[j]]++; link(pa[j], T_phase[i] "-" T_seq[i], "evidenced_by", "recorded") }
  }
  if (HASMAN) {
    for (i = 1; i <= MANN; i++) CHG[MAN_path[i]] = (MAN_fp[i] == "missing") ? "deleted" : "changed"
  } else note("files.changed")
  np = sortedkeys(CHG, paths)
  nf = 0
  for (i = 1; i <= np; i++) { ALL[++nf] = paths[i]; ST[paths[i]] = CHG[paths[i]] }
  if (plan_scope()) {
    for (i = 1; i <= PSN; i++) if (!(PS_path[i] in CHG)) SET[PS_path[i]] = 1
    nplan = sortedkeys(SET, planned)
    for (i = 1; i <= nplan; i++) { ALL[++nf] = planned[i]; ST[planned[i]] = "planned" }
  }
  ssort(ALL, nf)
  for (i = 1; i <= nf; i++) {
    p = ALL[i]
    set("file", i, "path", p); set("file", i, "status", ST[p]); set("file", i, "source", "recorded")
    set("file", i, "added", U()); set("file", i, "deleted", U()); set("file", i, "evidenceRecords", ec[p] + 0)
  }
  CNT["file"] = nf
  n = 0
  for (i = 1; i <= nf; i++) if (ST[ALL[i]] != "planned") n++
  set("diffstat", 0, "files", n); set("diffstat", 0, "added", U()); set("diffstat", 0, "deleted", U())
  if (!vavail(get("task", 0, "baseSha")) || np == 0) { if (np > 0) note("diffstat"); return }
  if (DIFFSTATE != "ok") { note("diffstat"); return }
  tadd = 0; tdel = 0
  for (i = 1; i <= nf; i++) {
    p = ALL[i]
    if (ST[p] != "planned" && (p in DIFF_ADD)) {
      set("file", i, "added", DN(DIFF_ADD[p] + 0)); set("file", i, "deleted", DN(DIFF_DEL[p] + 0))
      tadd += DIFF_ADD[p]; tdel += DIFF_DEL[p]
    }
  }
  set("diffstat", 0, "added", DN(tadd)); set("diffstat", 0, "deleted", DN(tdel))
}

# commands_list(): worker evidence (RED GREEN REFACTOR FIX), read once, ordered by
# timestamp, then phase, then sequence.
function commands_list(   ph, phases, ip, i, b, n, K, O, F, TG, x, NP, PP, k, K2, O2, ts) {
  if (CL_DONE) return
  CL_DONE = 1; TN = 0
  split("RED GREEN REFACTOR FIX", phases, " ")
  for (ip = 1; ip <= 4; ip++) {
    ph = phases[ip]; n = 0
    for (i = 1; i <= NEVFILE; i++) {
      b = basename(EVFILE[i])
      if (b ~ /^(RED|GREEN|REFACTOR|FIX)-[0-9]+\.yaml$/ && substr(b, 1, length(ph) + 1) == ph "-") {
        n++; PP[n] = EVFILE[i]
        k = b; sub(/^[A-Z]+-/, "", k); sub(/\.yaml$/, "", k); sub(/^0+/, "", k)
        K[n] = substr("00000000000000000000", 1, 20 - length(k)) k "\034" b
      }
    }
    order(K, n, O)
    for (i = 1; i <= n; i++) {
      if (!flat_yaml(PP[O[i]], F)) continue
      b = basename(PP[O[i]]); k = b; sub(/^[A-Z]+-/, "", k); sub(/\.yaml$/, "", k)
      TN++
      T_phase[TN] = ph; T_seq[TN] = k + 0; T_role[TN] = F["role"]; T_command[TN] = F["command"]; T_result[TN] = R(F["result"])
      T_targets[TN] = F["target"]; T_expect[TN] = F["expected_failure"]; T_at[TN] = F["timestamp"]
      T_ord[TN] = ip
    }
  }
  for (i = 1; i <= TN; i++) K2[i] = T_at[i] "\001" T_ord[i] "\001" sprintf("%012d", T_seq[i])
  order(K2, TN, O2)
  for (i = 1; i <= TN; i++) {
    k = O2[i]
    set("test", i, "phase", T_phase[k]); set("test", i, "seq", T_seq[k]); set("test", i, "role", T_role[k])
    set("test", i, "command", T_command[k]); set("test", i, "result", T_result[k])
    n = split_list(T_targets[k], TG)
    for (x = 1; x <= n; x++) ladd("test", i, "targets", TG[x])
    set("test", i, "expectedFailure", T_expect[k]); set("test", i, "at", T_at[k]); set("test", i, "source", "recorded")
  }
  CNT["test"] = TN
}

# commands(): VERIFY.md `## Commands` bullets:  - `cmd` | exit=N
function commands(   L, n, i, inb, m, cmd, rest, res, vn, anyun) {
  commands_list()
  n = readfile(RUNDIR "/VERIFY.md", L); vn = 0
  for (i = 1; i <= n; i++) {
    if (substr(L[i], 1, 3) == "## ") { inb = (trim(L[i]) == "## Commands"); continue }
    if (!inb || !match(L[i], /^- `[^`]+`/)) continue
    cmd = substr(L[i], 4, RLENGTH - 4); rest = substr(L[i], RLENGTH + 1)
    res = U()
    if (rest ~ /^ *$/) { }
    else if (rest ~ /^ *\| *exit=-?[0-9]+ *$/) { sub(/^ *\| *exit=/, "", rest); sub(/ *$/, "", rest); res = R("exit=" rest) }
    else continue
    vn++
    set("verif", vn, "phase", "VERIFY"); set("verif", vn, "seq", vn); set("verif", vn, "role", "independent_verifier")
    set("verif", vn, "command", cmd); set("verif", vn, "result", res); set("verif", vn, "expectedFailure", "")
    set("verif", vn, "at", ""); set("verif", vn, "source", "recorded")
    if (!vavail(res)) anyun = 1
  }
  CNT["verif"] = vn
  if (vn == 0 && has_gate("VERIFY")) note("verification.commands")
  if (anyun) note("verification.results")
}

# ---- attempts and durations --------------------------------------------------

function attempts(   i, n, b, K, O, m, F, kv, A, j, dn, e, ph, s, t, file, L, line, ord) {
  n = 0
  for (i = 1; i <= NDECFILE; i++) {
    b = basename(DECFILE[i])
    if (b !~ /^[0-9]+-[A-Z]+-[0-9]+\.decision$/) continue
    n++; DP[n] = DECFILE[i]
    split(b, m, "-"); sub(/\.decision$/, "", m[3])
    D_epoch[n] = m[1] + 0; D_phase[n] = m[2]; D_seq[n] = m[3] + 0
    ord = (m[2] == "RED") ? 0 : (m[2] == "GREEN") ? 1 : (m[2] == "REFACTOR") ? 2 : (m[2] == "FIX") ? 3 : 0
    K[n] = sprintf("%012d", D_epoch[n]) "\001" ord "\001" sprintf("%012d", D_seq[n])
  }
  order(K, n, O)
  dn = 0
  for (i = 1; i <= n; i++) {
    j = O[i]
    split("", kv)
    e = readfile(DP[j], L)
    for (t = 1; t <= e; t++) if (split_kv(L[t], "=")) kv[KV_K] = KV_V
    set("attempt", i, "epoch", D_epoch[j]); set("attempt", i, "phase", D_phase[j]); set("attempt", i, "seq", D_seq[j])
    set("attempt", i, "attempt", R(kv["attempt"])); set("attempt", i, "outcome", R(kv["outcome"]))
    set("attempt", i, "durationSeconds", U())
    set("attempt", i, "model", R(kv["model"])); set("attempt", i, "effort", R(kv["effort"]))
    if (kv["duration_s"] ~ /^[+-]?[0-9]+(\.[0-9]*)?$/ || kv["duration_s"] ~ /^[+-]?\.[0-9]+$/) {
      set("attempt", i, "durationSeconds", R(kv["duration_s"]))
      dn++
      set("dur", dn, "label", D_epoch[j] "-" D_phase[j] "-" D_seq[j]); set("dur", dn, "seconds", sprintf("%.15g", kv["duration_s"] + 0)); set("dur", dn, "source", "recorded")
    }
  }
  CNT["attempt"] = n; CNT["dur"] = dn
  if (dn == 0) note("durations")
}

# ---- roles and delegation -----------------------------------------------------
#
# Three separate facts per role:
#   recorded     the run left records written by that role (gate record, worker
#                evidence, ledger entry). Only these prove the role acted.
#   expected     the pipeline or topology says the role takes part. This is
#                derived and is NOT proof that anything ran.
#   unavailable  expected but no record: there is no execution evidence.
# A delegation edge is recorded only when the delegate left records.

function role_seen(role, act) {
  if (role == "") return
  if (!((role SUBSEP act) in RACT)) { RACT[role SUBSEP act] = 1; RACTN[role]++; RACTL[role] = RACTL[role] (RACTL[role] == "" ? "" : SUB) act }
  RCOUNT[role]++
  RSEEN[role] = 1
}
function role_expect(role, by) { if (!(role in REXP)) REXP[role] = by; RALL[role] = 1 }

function roles(   i, e, ev, owners, g, gl, n, names, nm, r, a, na, j, srt, rec_n, st) {
  for (i = 1; i <= RN; i++) role_seen(get("gate", i, "role"), "gate " get("gate", i, "gate") " " get("gate", i, "result"))
  for (i = 1; i <= TN; i++) role_seen(get("test", i, "role"), "evidence " get("test", i, "phase"))
  for (i = 1; i <= LN; i++) {
    if (index(LED_event[i], "gate:") == 1) continue
    ev = LED_event[i]; sub(/:.*/, "", ev)
    role_seen(LED_role[i], "ledger " ev)
  }
  for (r in RSEEN) RALL[r] = 1
  role_expect("full_lifecycle", "lifecycle")
  if (topology() == "orchestrated") role_expect("implementation_worker", "topology")
  split("REVIEW:independent_reviewer QA:independent_qa VERIFY:independent_verifier", owners, " ")
  for (i = 1; i <= 3; i++) { split(owners[i], g, ":"); if (has_gate(g[1])) role_expect(g[2], "pipeline") }
  n = 0
  for (r in RALL) names[++n] = r
  ssort(names, n)
  for (i = 1; i <= n; i++) {
    r = names[i]; rec_n = RCOUNT[r] + 0
    set("role", i, "role", r)
    set("role", i, "expected", (r in REXP) ? "true" : "false")
    set("role", i, "expectedBy", (r in REXP) ? REXP[r] : "")
    set("role", i, "records", rec_n)
    na = lsplit(RACTL[r], a); split("", srt)
    for (j = 1; j <= na; j++) srt[j] = a[j]
    ssort(srt, na)
    for (j = 1; j <= na; j++) ladd("role", i, "activity", srt[j])
    set("role", i, "executed", rec_n > 0 ? "r:b:true" : U())
    set("role", i, "status", rec_n > 0 ? "recorded" : "expected_no_record")
    set("role", i, "source", rec_n > 0 ? "recorded" : "derived")
    ROLE_REC[r] = rec_n
  }
  CNT["role"] = n
  if (topology() == "orchestrated") {
    set("deleg", 1, "from", "full_lifecycle"); set("deleg", 1, "to", "implementation_worker"); set("deleg", 1, "via", "scripts/worker-run.sh")
    st = (ROLE_REC["implementation_worker"] > 0)
    set("deleg", 1, "status", st ? "recorded" : "expected"); set("deleg", 1, "source", st ? "recorded" : "derived")
    CNT["deleg"] = 1
  }
}

# ---- lifecycle: only the stages that apply to this run's pipeline --------------

function stage_add(name, status, isgate,   i) {
  i = ++SN
  set("stage", i, "stage", name); set("stage", i, "status", status); set("stage", i, "source", "derived")
  set("stage", i, "gate", isgate ? "true" : "false"); set("stage", i, "attempts", 0); set("stage", i, "findingsOpen", 0)
  return i
}
function frozen(k,   v) { v = RUN["freeze." k]; return v != "" && v != "PENDING" && v != "not_required" }

function gate_status(g,   i, s, r) {
  s = "pending"
  for (i = 1; i <= RN; i++)
    if (get("gate", i, "gate") == g && vtrue(get("gate", i, "boundToCurrentContract"))) {
      r = get("gate", i, "result"); s = (r == "pass") ? "passed" : (r == "fail") ? "failed" : ""
    }
  return s
}

function lifecycle(   hand, needev, disc, impl, g, gl, i, s, a, o, ks, know, terminal, k, gs) {
  hand = handoff(); terminal = state()
  needev = 1
  if (vavail(get("pipeline", 0, "evidenceRequired")) && vtyp(get("pipeline", 0, "evidenceRequired")) == "b") needev = vtrue(get("pipeline", 0, "evidenceRequired"))
  SN = 0
  disc = "pending"
  if (frozen("evidence_sha256") || (!needev && frozen("task_sha256"))) disc = "completed"
  else if (RUN["baseline.status"] == "captured") disc = "in_progress"
  stage_add("discover", disc, 0)
  if (needev) stage_add("evidence", frozen("evidence_sha256") ? "completed" : "pending", 0)
  stage_add("plan", frozen("plan_sha256") ? "completed" : "pending", 0)
  impl = "pending"
  if (hand == "IMPLEMENTING") impl = "in_progress"
  else if (hand == "IMPLEMENTED" || hand == "CODE_DONE" || hand == "DONE") impl = "completed"
  stage_add("implement", impl, 0)
  split("REVIEW QA VERIFY", gs, " ")
  for (k = 1; k <= 3; k++) {
    g = gs[k]
    if (!has_gate(g)) continue
    s = stage_add(tolower(g), gate_status(g), 1)
    a = 0; o = 0
    for (i = 1; i <= RN; i++) if (get("gate", i, "gate") == g && vtrue(get("gate", i, "boundToCurrentContract"))) a++
    for (i = 1; i <= FN; i++) if (get("finding", i, "gate") == g && get("finding", i, "state") == "open") o++
    set("stage", s, "attempts", a); set("stage", s, "findingsOpen", o)
  }
  stage_add("code_done", (hand == "CODE_DONE" || hand == "DONE") ? "completed" : "pending", 0)
  ks = vstr(get("status", 0, "knowledge")); know = "pending"
  if (ks == "KNOWLEDGE_DONE") know = "completed"; else if (ks == "not_applicable") know = "skipped"
  stage_add("knowledge", know, 0)
  stage_add("done", hand == "DONE" ? "completed" : "pending", 0)
  if (terminal == "FAILED" || terminal == "BLOCKED")
    for (i = 1; i <= SN; i++) {
      s = get("stage", i, "status")
      if (s == "pending" || s == "in_progress") { set("stage", i, "status", tolower(terminal)); break }
    }
  CNT["stage"] = SN
}

# ---- fingerprints, outcome ------------------------------------------------------

function not_required(k,   v) { v = RUN["freeze." k]; return (v == "not_required") ? RV("not_required") : R(v) }

function fingerprints(   i, last) {
  set("fp", 0, "implementedPatchSha256", R(RUN["handoff.implemented_patch_sha256"]))
  set("fp", 0, "codeDonePatchSha256", R(RUN["handoff.code_done_patch_sha256"]))
  last = U()
  for (i = 1; i <= RN; i++) if (get("gate", i, "patchSha256") != "") last = R(get("gate", i, "patchSha256"))
  set("fp", 0, "lastGatePatchSha256", last)
  set("frozen", 0, "task", not_required("task_sha256")); set("frozen", 0, "evidence", not_required("evidence_sha256"))
  set("frozen", 0, "plan", not_required("plan_sha256")); set("frozen", 0, "qaPlan", not_required("qa_plan_sha256"))
  set("frozen", 0, "policy", not_required("policy_sha256")); set("frozen", 0, "pipeline", not_required("pipeline"))
  if (!vavail(get("fp", 0, "implementedPatchSha256"))) note("fingerprint.implemented")
}

function outcome(   i, d, k, reason, ev, am, ro, s) {
  set("outcome", 0, "state", get("status", 0, "state"))
  set("outcome", 0, "failureReason", U()); set("outcome", 0, "failureEvidence", U())
  set("outcome", 0, "reportPublished", R(RUN["completion_report.published"]))
  set("outcome", 0, "adapter", R(RUN["completion_report.adapter"]))
  am = 0; ro = 0
  for (i = 1; i <= LN; i++) {
    if (LED_event[i] == "terminate") {
      d = LED_detail[i]; sub(/^reason: /, "", d)
      k = index(d, "; evidence: ")
      if (k > 0) { reason = substr(d, 1, k - 1); ev = substr(d, k + 12) } else { reason = d; ev = "" }
      set("outcome", 0, "failureReason", R(reason)); set("outcome", 0, "failureEvidence", R(ev))
    } else if (LED_event[i] == "REOPEN") ro++
    else if (LED_event[i] == "refreeze") am++
  }
  set("outcome", 0, "amendments", am); set("outcome", 0, "reopens", ro)
  s = vstr(get("outcome", 0, "state"))
  if ((s == "FAILED" || s == "BLOCKED") && !vavail(get("outcome", 0, "failureReason"))) note("outcome.failureReason")
}

# ---- finish: ordered links and the list of unavailable items ---------------------

function finish(   i, K, O, n, keys, nk) {
  for (i = 1; i <= LKN; i++) K[i] = LK_kind[i] "\035" natkey(LK_from[i]) "\035" natkey(LK_to[i])
  order(K, LKN, O)
  for (i = 1; i <= LKN; i++) {
    set("link", i, "from", LK_from[O[i]]); set("link", i, "to", LK_to[O[i]])
    set("link", i, "kind", LK_kind[O[i]]); set("link", i, "source", LK_src[O[i]])
  }
  CNT["link"] = LKN
  nk = sortedkeys(UNAV, keys)
  for (i = 1; i <= nk; i++) ladd("unavailable", 0, "items", keys[i])
}
