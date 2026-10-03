# svg.awk: deterministic SVG diagrams from the model. Layout is plain arithmetic on
# the model, so the same model gives the same bytes. Every label is HTML-escaped.
# Colors come from CSS classes (the page theme applies); state is also written as
# text, never by color alone. Each *_svg() function returns the SVG as a string.

function sv(s) { SV = SV s }
function cv_open(id, label, w, h) {
  SV = ""
  sv("<svg class=\"dg\" viewBox=\"0 0 " w " " h "\" role=\"img\" aria-label=\"" esc(label) "\" xmlns=\"http://www.w3.org/2000/svg\">")
  sv("<defs><marker id=\"" id "\" viewBox=\"0 0 8 8\" refX=\"7\" refY=\"4\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto\"><path d=\"M0,0 L8,4 L0,8 z\" class=\"ah\"/></marker></defs>")
}
function cv_close() { sv("</svg>"); return SV }

# cv_node(x, y, w, h, class, title, subt, tip): a rounded box with one or two text lines.
function cv_node(x, y, w, h, class, title, subt, tip) {
  sv("<g class=\"nd " class "\"><title>" esc(tip) "</title><rect x=\"" x "\" y=\"" y "\" width=\"" w "\" height=\"" h "\" rx=\"6\"/>")
  if (subt == "")
    sv("<text x=\"" x + int(w / 2) "\" y=\"" y + int(h / 2) "\" class=\"t1\" text-anchor=\"middle\" dominant-baseline=\"central\">" esc(title) "</text>")
  else
    sv("<text x=\"" x + int(w / 2) "\" y=\"" y + int(h / 2) - 3 "\" class=\"t1\" text-anchor=\"middle\">" esc(title) "</text><text x=\"" x + int(w / 2) "\" y=\"" y + int(h / 2) + 12 "\" class=\"t2\" text-anchor=\"middle\">" esc(subt) "</text>")
  sv("</g>")
}
function cv_line(path, class, marker) { sv("<path d=\"" path "\" class=\"ed " class "\" marker-end=\"url(#" marker ")\"/>") }
function cv_text(x, y, s, class) { sv("<text x=\"" x "\" y=\"" y "\" class=\"" class "\">" esc(s) "</text>") }

function status_class(s) {
  if (s == "completed" || s == "passed" || s == "PASS" || s == "resolved") return "ok"
  if (s == "failed" || s == "FAIL" || s == "open" || s == "unresolved_at_termination" || s == "blocked" || s == "failed_terminal") return "bad"
  if (s == "in_progress") return "run"
  if (s == "skipped" || s == "superseded") return "skip"
  return "pend"
}
function result_class(r) { return status_class(r == "pass" ? "PASS" : (r == "fail" ? "FAIL" : "")) }
function or_default(s, d) { return s == "" ? d : s }
function min2(a, b) { return a < b ? a : b }
function max2(a, b) { return a > b ? a : b }

# flow_svg: the lifecycle stages that apply, five per row.
function flow_svg(   nw, nh, gx, gy, per, pad, n, rows, w, h, i, x, y, x2, y2, subt, st, g) {
  nw = 118; nh = 54; gx = 30; gy = 40; per = 5; pad = 12
  n = N["stage"] + 0
  rows = int((n + per - 1) / per)
  w = per * nw + (per - 1) * gx + 2 * pad
  h = rows * nh + (rows - 1) * gy + 2 * pad
  cv_open("fa", "Lifecycle flow", w, h)
  for (i = 1; i <= n; i++) {
    x = pad + ((i - 1) % per) * (nw + gx); y = pad + int((i - 1) / per) * (nh + gy)
    if (i < n) {
      x2 = pad + (i % per) * (nw + gx); y2 = pad + int(i / per) * (nh + gy)
      if (y2 == y) cv_line("M" x + nw "," y + int(nh / 2) " H" x2, "", "fa")
      else cv_line("M" x + int(nw / 2) "," y + nh " V" y + nh + int(gy / 2) " H" x2 + int(nw / 2) " V" y2, "", "fa")
    }
    st = M["stage", i, "status"]; g = (M["stage", i, "gate"] == "true")
    subt = toupper(st); gsub(/_/, " ", subt)
    if (g) subt = (st == "passed" ? "OK" : toupper(st)) " · att " M["stage", i, "attempts"] " · open " M["stage", i, "findingsOpen"]
    cv_node(x, y, nw, nh, status_class(st), M["stage", i, "stage"], subt, M["stage", i, "stage"] ": " st " (" M["stage", i, "source"] ")")
  }
  return cv_close()
}

# remediation_svg: one row per failing gate: fail, diagnosis, fix, rerun, result.
# REM_MORE is set to the number of loops left out of the picture.
function remediation_svg(   total, shown, bw, bh, gx, gy, pad, w, h, i, y, k, res, rc, fs, fb) {
  total = N["loop"] + 0; shown = min2(total, 24)
  bw = 150; bh = 30; gx = 24; gy = 10; pad = 10
  w = 5 * bw + 4 * gx + 2 * pad
  h = shown * (bh + gy) - gy + 2 * pad
  cv_open("ra", "Remediation loops", w, h)
  for (i = 1; i <= shown; i++) {
    y = pad + (i - 1) * (bh + gy)
    fs = M["loop", i, "fixStarted"]; fb = M["loop", i, "fixReturned"]
    res = vstr(M["loop", i, "resolution"])
    if (index(res, "gate ") == 1) rc = "ok"
    else if (res == "open" || index(res, "run ended") == 1) rc = "bad"
    else if (res != "") rc = "skip"
    else rc = "pend"
    cv_node(pad, y, bw, bh, "bad", "#" M["loop", i, "loop"] " " M["loop", i, "gate"] " fail " M["loop", i, "finding"], "", M["loop", i, "finding"])
    cv_node(pad + (bw + gx), y, bw, bh, "pend", "diagnosis", "", "orchestrator diagnosis")
    cv_node(pad + 2 * (bw + gx), y, bw, bh, tri_class(fs), tri_label(fs, "fix started", "no fix yet"), "", "bounded fix")
    cv_node(pad + 3 * (bw + gx), y, bw, bh, tri_class(fb), tri_label(fb, "back to IMPLEMENTED", "not returned"), "", "return to gates")
    cv_node(pad + 4 * (bw + gx), y, bw, bh, rc, trunc(or_default(res, "unavailable"), 22), "", res)
    for (k = 0; k < 4; k++) cv_line("M" pad + k * (bw + gx) + bw "," y + int(bh / 2) " H" pad + (k + 1) * (bw + gx), "", "ra")
  }
  REM_MORE = total - shown
  return cv_close()
}
function tri_class(v) { return vtrue(v) ? "run" : (vfalse(v) ? "pend" : "na") }
function tri_label(v, yes, no) { return vtrue(v) ? yes : (vfalse(v) ? no : "n/a") }

# graph_add(col, id, label, class, tip, total): add a node unless the column is full.
function graph_add(col, id, label, class, tip, total) {
  if (GN[col] < 16) { GN[col]++; GID[col, GN[col]] = id; GLAB[col, GN[col]] = label; GCLS[col, GN[col]] = class; GTIP[col, GN[col]] = tip }
  else GMORE[col] = total - 16
}

# graph_svg: QA scenario | criterion | plan file | evidence record. An edge is drawn
# only where the model holds a link. GRAPH_EDGES is the number of edges drawn.
function graph_svg(   nw, nh, gy, gx, pad, i, c, cl, linked, maxn, rowsmax, w, h, ci, titles, a, b, x1, x2, y1, y2, mid, kind, id, nf, tid, res) {
  nw = 150; nh = 22; gy = 8; gx = 70; pad = 10
  split("", GN); split("", GID); split("", GLAB); split("", GCLS); split("", GTIP); split("", GMORE); split("", GIDX)
  for (c = 0; c < 4; c++) GN[c] = 0
  for (i = 1; i <= N["qa"]; i++) {
    res = vstr(M["qa", i, "result"])
    graph_add(0, M["qa", i, "id"], M["qa", i, "id"] " " or_default(res, "n/a"), status_class(res), M["qa", i, "plan"], N["qa"])
  }
  for (i = 1; i <= N["crit"]; i++) {
    res = vstr(M["crit", i, "qaResult"])
    graph_add(1, M["crit", i, "id"], M["crit", i, "id"] " " trunc(M["crit", i, "text"], 14), res != "" ? status_class(res) : "pend", M["crit", i, "text"], N["crit"])
  }
  split("", linked); nf = 0
  for (i = 1; i <= N["link"]; i++) if (M["link", i, "kind"] == "scopes") linked[M["link", i, "to"]] = 1
  for (i = 1; i <= N["file"]; i++) if (M["file", i, "path"] in linked) nf++
  c = 0
  for (i = 1; i <= N["file"]; i++)
    if (M["file", i, "path"] in linked) graph_add(2, M["file", i, "path"], trunc(M["file", i, "path"], 24), "pend", M["file", i, "path"], nf)
  for (i = 1; i <= N["test"]; i++) {
    tid = M["test", i, "phase"] "-" M["test", i, "seq"]; res = vstr(M["test", i, "result"])
    graph_add(3, tid, tid " " res, result_class(res), M["test", i, "command"], N["test"])
  }
  maxn = 0
  for (c = 0; c < 4; c++) { maxn = max2(maxn, GN[c]); for (i = 1; i <= GN[c]; i++) GIDX[c, GID[c, i]] = i }
  rowsmax = maxn
  for (c = 0; c < 4; c++) if (GMORE[c] > 0) rowsmax = max2(rowsmax, maxn + 1)
  w = 4 * nw + 3 * gx + 2 * pad
  h = max2(rowsmax, 1) * (nh + gy) + 2 * pad + 18
  cv_open("ga", "Acceptance criteria evidence graph", w, h)
  split("QA scenario|Criterion|Plan file|Evidence record", titles, "|")
  for (c = 0; c < 4; c++) cv_text(pad + c * (nw + gx), pad + 9, titles[c + 1], "col")
  GRAPH_EDGES = 0
  for (i = 1; i <= N["link"]; i++) {
    kind = M["link", i, "kind"]
    if (kind == "covers") { if (((1 SUBSEP M["link", i, "from"]) in GIDX) && ((0 SUBSEP M["link", i, "to"]) in GIDX)) graph_edge(1, M["link", i, "from"], 0, M["link", i, "to"], pad + 1 * (nw + gx), pad + 0 * (nw + gx) + nw, nh, gy, pad) }
    else if (kind == "scopes") { if (((1 SUBSEP M["link", i, "from"]) in GIDX) && ((2 SUBSEP M["link", i, "to"]) in GIDX)) graph_edge(1, M["link", i, "from"], 2, M["link", i, "to"], pad + 1 * (nw + gx) + nw, pad + 2 * (nw + gx), nh, gy, pad) }
    else if (kind == "evidenced_by") { if (((2 SUBSEP M["link", i, "from"]) in GIDX) && ((3 SUBSEP M["link", i, "to"]) in GIDX)) graph_edge(2, M["link", i, "from"], 3, M["link", i, "to"], pad + 2 * (nw + gx) + nw, pad + 3 * (nw + gx), nh, gy, pad) }
  }
  for (c = 0; c < 4; c++) {
    for (i = 1; i <= GN[c]; i++) cv_node(pad + c * (nw + gx), pad + 18 + (i - 1) * (nh + gy), nw, nh, GCLS[c, i], trunc(GLAB[c, i], 26), "", GTIP[c, i])
    if (GMORE[c] > 0) cv_text(pad + c * (nw + gx), pad + 18 + GN[c] * (nh + gy) + 15, "+" GMORE[c] " more (see tables)", "t2")
  }
  return cv_close()
}
# graph_edge: a curve from node (ca, ida) at x1 to node (cb, idb) at x2.
function graph_edge(ca, ida, cb, idb, x1, x2, nh, gy, pad,   a, b, y1, y2, mid) {
  a = GIDX[ca, ida]; b = GIDX[cb, idb]
  y1 = pad + 18 + (a - 1) * (nh + gy) + int(nh / 2); y2 = pad + 18 + (b - 1) * (nh + gy) + int(nh / 2)
  mid = int((x1 + x2) / 2)
  cv_line("M" x1 "," y1 " C" mid "," y1 " " mid "," y2 " " x2 "," y2, "", "ga")
  GRAPH_EDGES++
}

# role_class / role_sub: what a role node shows. A role is drawn as having run only
# when it left records. "expected" comes from the pipeline or topology and proves nothing.
function role_class(i) { return M["role", i, "status"] == "recorded" ? "ok" : "na" }
function role_sub(i) { return M["role", i, "status"] == "recorded" ? M["role", i, "records"] " records (recorded)" : "expected · no record" }

# roles_svg: the orchestrator, the implementation owner and the gate roles. A solid
# edge needs records from the role; a dashed edge is an expectation only.
function roles_svg(   nw, nh, pad, i, n, gr, ng, wk, orch, rows, h, w, midy, subt, y, cl, x0, x1, x2, rec) {
  nw = 190; nh = 44; pad = 12
  ng = 0; wk = 0; orch = 0
  for (i = 1; i <= N["role"]; i++) {
    if (M["role", i, "role"] == "full_lifecycle") orch = i
    else if (M["role", i, "role"] == "implementation_worker") wk = i
    else gr[++ng] = i
  }
  rows = max2(ng, 2)
  h = rows * (nh + 12) + 2 * pad
  w = 3 * nw + 2 * 90 + 2 * pad
  cv_open("ro", "Roles and topology", w, h)
  midy = int(h / 2) - int(nh / 2)
  x0 = pad; x1 = pad + nw + 90; x2 = pad + 2 * (nw + 90)
  if (orch > 0 && M["role", orch, "status"] == "recorded") {
    subt = "implements (standalone)"
    if (vstr(M["topology", 0, "value"]) == "orchestrated") subt = "delegates implementation"
    else if (!vavail(M["topology", 0, "value"])) subt = "topology unavailable"
    cv_node(x1, midy, nw, nh, "run", "full_lifecycle", subt, "Orchestrator: owns the lifecycle, declares DONE. " M["role", orch, "records"] " records")
  } else cv_node(x1, midy, nw, nh, "na", "full_lifecycle", "expected · no record", "Orchestrator: expected by the lifecycle; no record names it")
  if (wk > 0) {
    cv_node(x0, midy, nw, nh, role_class(wk), "implementation_worker", role_sub(wk), "scripts/worker-run.sh")
    if (M["deleg", 1, "status"] == "recorded") {
      cv_line("M" x1 "," midy + int(nh / 2) - 8 " H" x0 + nw, "", "ro")
      cv_text(x0 + nw + 6, midy + int(nh / 2) - 14, "delegates", "t2")
    } else {
      cv_line("M" x1 "," midy + int(nh / 2) - 8 " H" x0 + nw, "dash", "ro")
      cv_text(x0 + nw + 6, midy + int(nh / 2) - 14, "expected", "t2")
    }
  }
  for (i = 1; i <= ng; i++) {
    y = pad + (i - 1) * (nh + 12)
    rec = (M["role", gr[i], "status"] == "recorded")
    cv_node(x2, y, nw, nh, role_class(gr[i]), M["role", gr[i], "role"], role_sub(gr[i]), ljoin(M["role", gr[i], "activity"], ", "))
    cv_line("M" x2 "," y + int(nh / 2) " C" pad + 2 * nw + 60 "," y + int(nh / 2) " " pad + 2 * nw + 60 "," midy + int(nh / 2) " " x1 + nw "," midy + int(nh / 2), rec ? "" : "dash", "ro")
  }
  return cv_close()
}
