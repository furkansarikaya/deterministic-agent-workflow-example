# report.awk: model records -> one self-contained HTML page. Inline CSS and SVG, no script;
# no network, no fonts, no generation timestamp. Same model, same bytes. Every
# dynamic value goes through esc(); the page embeds no raw run content.
# -v DIR=<this directory> locates report.css.

BEGIN { lib_init() }

END { render() }

function put(s) { printf "%s", s }

# slurp(path): a file's lines joined by newlines, without a trailing newline.
function slurp(path,   s, line, n) {
  s = ""; n = 0
  while ((getline line < path) > 0) { s = s (n++ ? "\n" : "") line }
  close(path)
  return s
}

function render(   i, id, cls) {
  id = M["task", 0, "id"]
  put("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"color-scheme\" content=\"light dark\"><title>" esc("Oversight " id) "</title><style>" slurp(DIR "/report.css") "</style></head><body>")
  put("<header><div class=\"wrap\"><p class=\"eyebrow\">Oversight report · projection of run state</p>")
  put("<h1>" esc(id) "</h1><p class=\"chips\">" chip(or_dash(M["pipeline", 0, "classification"]), "info") " " chip(or_dash(M["status", 0, "summary"]), status_class(vstr(M["status", 0, "summary"]))) " " chip("topology " or_dash(M["topology", 0, "value"]), "pend") " " chip("handoff " or_dash(M["status", 0, "handoff"]), "pend") "</p>")
  put("<nav><a href=\"#overview\">Overview</a><a href=\"#flow\">Flow</a><a href=\"#remediation\">Remediation</a><a href=\"#criteria\">Criteria</a><a href=\"#files\">Files</a><a href=\"#findings\">Findings</a><a href=\"#verification\">Verification</a><a href=\"#provenance\">Provenance</a></nav></div></header><main class=\"wrap\">")
  overview(); flow_section(); remediation_section(); criteria_section(); files_section(); findings_section(); verification_section(); provenance_section()
  put("</main></body></html>")
}

function chip(s, class) { return "<span class=\"chip c-" class "\">" esc(s) "</span>" }
function or_dash(v,   s) { s = vstr(v); return s == "" ? "unavailable" : s }

function section(id, title, lead) {
  put("<section id=\"" id "\"><h2>" esc(title) "</h2>")
  if (lead != "") put("<p class=\"lead\">" esc(lead) "</p>")
}

# vtext(v): a scalar with its provenance: derived values are marked, unavailable says so.
function vtext(v) {
  if (!vavail(v)) return "<span class=\"na\">unavailable</span>"
  if (vsrc(v) == "d") return esc(vval(v)) "<sup class=\"d\" title=\"derived\">d</sup>"
  return esc(vval(v))
}
function short12(s) { return cut(s, 12) }
function short_val(v) {
  if (!vavail(v)) return vtext(v)
  return "<code title=\"" esc(vval(v)) "\">" esc(short12(vval(v))) "</code>"
}
function kpi(label, value) { put("<div class=\"kpi\"><b>" value "</b><span>" esc(label) "</span></div>") }
function kvrow(k, v) { put("<tr><th>" esc(k) "</th><td>" v "</td></tr>") }

function overview(   i, passed, open, rows) {
  section("overview", "Overview", "")
  passed = 0; open = 0
  for (i = 1; i <= N["stage"]; i++) {
    if (M["stage", i, "gate"] == "true" && M["stage", i, "status"] == "passed") passed++
    open += M["stage", i, "findingsOpen"]
  }
  put("<div class=\"kpis\">")
  kpi("gates passed", passed "/" lsplit(M["pipeline", 0, "requiredGates"], TMPG))
  kpi("open findings", open)
  kpi("remediation loops", N["loop"] + 0)
  kpi("files changed", M["diffstat", 0, "files"])
  kpi("lines added", vtext(M["diffstat", 0, "added"]))
  kpi("lines deleted", vtext(M["diffstat", 0, "deleted"]))
  put("</div><div class=\"grid2\"><table class=\"kv\">")
  kvrow("Task source", vtext(M["task", 0, "taskSource"])); kvrow("Base SHA", short_val(M["task", 0, "baseSha"]))
  kvrow("Branch", vtext(M["task", 0, "branch"])); kvrow("Mode", vtext(M["task", 0, "mode"]))
  kvrow("Execution state", vtext(M["status", 0, "state"])); kvrow("Knowledge", vtext(M["status", 0, "knowledge"]))
  kvrow("Required gates", esc(ljoin(M["pipeline", 0, "requiredGates"], ", "))); kvrow("Requirements", M["task", 0, "requirementCount"])
  kvrow("Application fingerprint", short_val(M["fp", 0, "implementedPatchSha256"]))
  put("</table><div>" roles_svg() "<p class=\"cap\">Roles and topology. A green box and a solid edge mean the role left records. A dashed box and a dashed edge mean the pipeline or topology expects the role and no record shows it ran.</p>")
  put("<table class=\"kv\">")
  for (i = 1; i <= N["role"]; i++) {
    if (M["role", i, "status"] == "recorded") kvrow(M["role", i, "role"], "recorded · " esc(M["role", i, "records"]) " records")
    else kvrow(M["role", i, "role"], "expected · no record")
  }
  put("</table></div></div></section>")
}

function flow_section(   i, d) {
  section("flow", "Execution flow", "Only stages that apply to this pipeline are drawn.")
  put(flow_svg())
  if ((N["flow"] + 0) == 0) { put("<p class=\"na\">Ledger unavailable: no ordered transition record exists for this run.</p></section>"); return }
  put("<details><summary>Recorded transitions (" N["flow"] ")</summary><div class=\"tw\"><table><thead><tr><th>#</th><th>At</th><th>Event</th><th>Role</th><th>From</th><th>To</th><th>Detail</th></tr></thead><tbody>")
  for (i = 1; i <= N["flow"]; i++)
    put("<tr><td>" M["flow", i, "seq"] "</td><td>" esc(M["flow", i, "at"]) "</td><td>" esc(M["flow", i, "event"]) "</td><td>" esc(M["flow", i, "role"]) "</td><td>" esc(M["flow", i, "from"]) "</td><td>" esc(M["flow", i, "to"]) "</td><td>" esc(trunc(M["flow", i, "detail"], 160)) "</td></tr>")
  put("</tbody></table></div></details>")
  if ((N["dur"] + 0) == 0) put("<p class=\"note\">Durations: <span class=\"na\">unavailable</span> (none recorded in run state).</p>")
  else {
    put("<p class=\"note\">Recorded durations: ")
    for (i = 1; i <= N["dur"]; i++) put((i > 1 ? ", " : "") esc(M["dur", i, "label"]) " " sprintf("%.0f", M["dur", i, "seconds"]) "s")
    put("</p>")
  }
  put("</section>")
}

function remediation_section(   i, svg) {
  section("remediation", "Remediation", "")
  put("<p class=\"note\">Failing gate records against the current plan: " M["remediation", 0, "failingGateRecords"] ". Fix budget: " vtext(M["remediation", 0, "maxFixes"]) ". Exhausted: " vtext(M["remediation", 0, "budgetExhausted"]) ".</p>")
  if ((N["loop"] + 0) == 0) { put("<p>No remediation loop is recorded: no gate has failed.</p></section>"); return }
  svg = remediation_svg()
  put(svg)
  if (REM_MORE > 0) put("<p class=\"note\">" REM_MORE " more loops are in the table.</p>")
  put("<div class=\"tw\"><table><thead><tr><th>Loop</th><th>Gate</th><th>Finding</th><th>Fix started</th><th>Returned</th><th>Resolution</th></tr></thead><tbody>")
  for (i = 1; i <= N["loop"]; i++)
    put("<tr><td>" M["loop", i, "loop"] "</td><td>" esc(M["loop", i, "gate"]) " #" M["loop", i, "failedGateSeq"] "</td><td>" esc(M["loop", i, "finding"]) "</td><td>" vtext(M["loop", i, "fixStarted"]) "</td><td>" vtext(M["loop", i, "fixReturned"]) "</td><td>" vtext(M["loop", i, "resolution"]) "</td></tr>")
  put("</tbody></table></div></section>")
}

function criteria_section(   i, svg, a, b) {
  section("criteria", "Acceptance criteria", "Links are drawn only where plan, QA plan, QA report or worker evidence states them.")
  if ((N["crit"] + 0) == 0) { put("<p class=\"na\">No acceptance criteria recorded in TASK.md.</p></section>"); return }
  svg = graph_svg()
  if (GRAPH_EDGES > 0) put(svg)
  else put("<p class=\"na\">No requirement links are recorded, so no graph is drawn.</p>")
  put("<div class=\"tw\"><table><thead><tr><th>ID</th><th>Requirement</th><th>Files</th><th>QA scenarios</th><th>QA result</th><th>Unavailable</th></tr></thead><tbody>")
  for (i = 1; i <= N["crit"]; i++)
    put("<tr><td>" esc(M["crit", i, "id"]) "</td><td>" esc(M["crit", i, "text"]) "</td><td>" lsplit(M["crit", i, "files"], a) "</td><td>" esc(ljoin(M["crit", i, "qaScenarios"], ", ")) "</td><td>" vtext(M["crit", i, "qaResult"]) "</td><td>" esc(ljoin(M["crit", i, "unavailable"], ", ")) "</td></tr>")
  put("</tbody></table></div></section>")
}

function files_section(   i) {
  section("files", "Changed files", "Paths and line counts only. No source content is read into this report.")
  put("<p class=\"note\">" M["diffstat", 0, "files"] " changed, diffstat +" vtext(M["diffstat", 0, "added"]) " −" vtext(M["diffstat", 0, "deleted"]) ".</p>")
  if ((N["file"] + 0) == 0) { put("<p class=\"na\">No files recorded.</p></section>"); return }
  put("<input class=\"flt\" data-for=\"ft\" placeholder=\"Filter files\" aria-label=\"Filter files\"><div class=\"tw\"><table id=\"ft\"><thead><tr><th>Path</th><th>Status</th><th>+</th><th>−</th><th>Evidence</th></tr></thead><tbody>")
  for (i = 1; i <= N["file"]; i++)
    put("<tr><td><code>" esc(M["file", i, "path"]) "</code></td><td>" esc(M["file", i, "status"]) "</td><td>" vtext(M["file", i, "added"]) "</td><td>" vtext(M["file", i, "deleted"]) "</td><td>" M["file", i, "evidenceRecords"] "</td></tr>")
  put("</tbody></table></div></section>")
}

function findings_section(   i, st) {
  section("findings", "Review and QA findings", "One finding per failing gate record, as the gate recorded it.")
  if ((N["finding"] + 0) == 0) { put("<p>No findings are recorded: no gate has failed.</p></section>"); return }
  put("<p class=\"btns\"><button data-state=\"\">all</button><button data-state=\"open\">open</button><button data-state=\"resolved\">resolved</button></p><div class=\"tw\"><table id=\"fd\"><thead><tr><th>ID</th><th>Gate</th><th>Severity</th><th>Category</th><th>State</th><th>Finding</th><th>Fix scope</th><th>Resolution</th></tr></thead><tbody>")
  for (i = 1; i <= N["finding"]; i++) {
    st = M["finding", i, "state"]
    put("<tr data-state=\"" esc(st) "\"><td>" esc(M["finding", i, "id"]) "</td><td>" esc(M["finding", i, "gate"]) "</td><td>" vtext(M["finding", i, "severity"]) "</td><td>" vtext(M["finding", i, "category"]) "</td><td>" chip(st, status_class(st)) "</td><td>" esc(M["finding", i, "text"]) "</td><td>" esc(ljoin(M["finding", i, "fixScope"], ", ")) "</td><td>" vtext(M["finding", i, "resolution"]) "</td></tr>")
  }
  put("</tbody></table></div></section>")
}

function command_rows(kind,   i) {
  for (i = 1; i <= N[kind]; i++)
    put("<tr><td>" esc(M[kind, i, "phase"]) "-" M[kind, i, "seq"] "</td><td>" esc(M[kind, i, "role"]) "</td><td><code>" esc(M[kind, i, "command"]) "</code></td><td>" vtext(M[kind, i, "result"]) "</td><td>" esc(M[kind, i, "at"]) "</td></tr>")
}

function verification_section(   i, r) {
  section("verification", "Verification", "Recorded commands and results. Gate records show who judged which tree.")
  put("<h3>Implementation evidence</h3>")
  if ((N["test"] + 0) == 0) put("<p class=\"na\">No implementation evidence recorded.</p>")
  else { put("<div class=\"tw\"><table><thead><tr><th>Record</th><th>Role</th><th>Command</th><th>Result</th><th>At</th></tr></thead><tbody>"); command_rows("test"); put("</tbody></table></div>") }
  put("<h3>Verifier commands</h3>")
  if ((N["verif"] + 0) == 0) put("<p class=\"na\">No verifier commands recorded in VERIFY.md (expected form: - `cmd` | exit=N).</p>")
  else { put("<div class=\"tw\"><table><thead><tr><th>Record</th><th>Role</th><th>Command</th><th>Result</th><th>At</th></tr></thead><tbody>"); command_rows("verif"); put("</tbody></table></div>") }
  put("<h3>Gate records</h3>")
  if ((N["gate"] + 0) == 0) put("<p class=\"na\">No gate records yet.</p>")
  else {
    put("<div class=\"tw\"><table><thead><tr><th>#</th><th>Gate</th><th>Result</th><th>Role</th><th>Tree</th><th>Bound to contract</th><th>At</th></tr></thead><tbody>")
    for (i = 1; i <= N["gate"]; i++) {
      r = M["gate", i, "result"]
      put("<tr><td>" M["gate", i, "seq"] "</td><td>" esc(M["gate", i, "gate"]) "</td><td>" chip(r, result_class(r)) "</td><td>" esc(M["gate", i, "role"]) "</td><td><code>" esc(short12(M["gate", i, "patchSha256"])) "</code></td><td>" vtext(M["gate", i, "boundToCurrentContract"]) "</td><td>" esc(M["gate", i, "at"]) "</td></tr>")
    }
    put("</tbody></table></div>")
  }
  put("</section>")
}

function provenance_section(   i, n, a) {
  section("provenance", "Provenance", "")
  put("<p class=\"warn\"><b>This report is not evidence.</b> It is a disposable projection of run state. It changes no run state, verifies no hash and passes no gate. Use <code>agent.sh verify-gates</code>, <code>validate</code> and <code>delivery-check</code> for proof.</p>")
  put("<ul class=\"legend\"><li><b>recorded</b>: read verbatim from run state.</li><li><b>derived</b><sup class=\"d\">d</sup>: computed from recorded values.</li><li><b class=\"na\">unavailable</b>: run state does not hold it.</li></ul>")
  put("<h3>Frozen contract and fingerprints</h3><table class=\"kv\">")
  kvrow("task", short_val(M["frozen", 0, "task"])); kvrow("evidence", short_val(M["frozen", 0, "evidence"])); kvrow("plan", short_val(M["frozen", 0, "plan"]))
  kvrow("QA plan", short_val(M["frozen", 0, "qaPlan"])); kvrow("policy", short_val(M["frozen", 0, "policy"]))
  kvrow("implemented tree", short_val(M["fp", 0, "implementedPatchSha256"])); kvrow("code-done tree", short_val(M["fp", 0, "codeDonePatchSha256"]))
  kvrow("last gate tree", short_val(M["fp", 0, "lastGatePatchSha256"]))
  kvrow("pipeline", vtext(M["frozen", 0, "pipeline"]))
  put("</table><h3>Outcome</h3><table class=\"kv\">")
  kvrow("state", vtext(M["outcome", 0, "state"])); kvrow("failure reason", vtext(M["outcome", 0, "failureReason"])); kvrow("failure evidence", vtext(M["outcome", 0, "failureEvidence"]))
  kvrow("completion report published", vtext(M["outcome", 0, "reportPublished"])); kvrow("adapter", vtext(M["outcome", 0, "adapter"]))
  put("<tr><th>amendments / reopens</th><td>" M["outcome", 0, "amendments"] " / " M["outcome", 0, "reopens"] "</td></tr></table><h3>Unavailable in this run</h3>")
  n = lsplit(M["unavailable", 0, "items"], a)
  if (n == 0) put("<p>Nothing is marked unavailable.</p>")
  else { put("<ul class=\"legend\">"); for (i = 1; i <= n; i++) put("<li class=\"na\">" esc(a[i]) "</li>"); put("</ul>") }
  put("</section>")
}
