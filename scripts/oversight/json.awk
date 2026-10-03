# json.awk: model records -> the model as JSON (schema oversight-model/1).
# Key order is fixed by SPEC below; element order is the model's own order.
# The layout is two-space indented, one key per line.

BEGIN {
  lib_init()
  # field:type  with types  s string, n number, b bool, v Val, l list, lo/so omitted when empty
  SPEC["task"]      = "id:s taskSource:v baseSha:v branch:v mode:v requirementCount:n"
  SPEC["status"]    = "state:v handoff:v knowledge:v summary:v"
  SPEC["pipeline"]  = "classification:v review:v requiredGates:l evidenceRequired:v qaPlanRequired:v"
  SPEC["role"]      = "role:s expected:b expectedBy:s records:n activity:l executed:v status:s source:s"
  SPEC["deleg"]     = "from:s to:s via:s status:s source:s"
  SPEC["stage"]     = "stage:s status:s source:s gate:b attempts:n findingsOpen:n"
  SPEC["flow"]      = "seq:n event:s role:s from:s to:s at:s detail:s source:s"
  SPEC["attempt"]   = "epoch:n phase:s seq:n attempt:v outcome:v durationSeconds:v model:v effort:v"
  SPEC["gate"]      = "seq:n gate:s result:s role:s patchSha256:s report:s reportSha256:s summary:s at:s boundToCurrentContract:v manifestFiles:n fixScope:lo"
  SPEC["finding"]   = "id:s gate:s gateSeq:n role:s text:s severity:v category:v fixScope:l fixInstruction:s resolution:v state:s"
  SPEC["loop"]      = "loop:n gate:s failedGateSeq:n fixStarted:v fixReturned:v resolution:v finding:s"
  SPEC["crit"]      = "id:s text:s files:l qaScenarios:l evidenceRefs:l qaResult:v unavailable:l"
  SPEC["qa"]        = "id:s criterion:s plan:s result:v note:s"
  SPEC["link"]      = "from:s to:s kind:s source:s"
  SPEC["file"]      = "path:s status:s source:s added:v deleted:v evidenceRecords:n"
  SPEC["test"]      = "phase:s seq:n role:s command:s result:v targets:lo expectedFailure:so at:s source:s"
  SPEC["verif"]     = SPEC["test"]
  SPEC["dur"]       = "label:s seconds:n source:s"
  SPEC["diffstat"]  = "files:n added:v deleted:v"
  SPEC["frozen"]    = "task:v evidence:v plan:v qaPlan:v policy:v pipeline:v"
  SPEC["outcome"]   = "state:v failureReason:v failureEvidence:v reportPublished:v adapter:v amendments:n reopens:n"
}

END {
  print "{"
  top("schema", "\"oversight-model/1\"", 1)
  top("notice", "\"Projection of run state. Not evidence and not a gate. Verify with agent.sh.\"", 1)
  top("task", jobj("task", 0, SPEC["task"], "  "), 1)
  top("status", jobj("status", 0, SPEC["status"], "  "), 1)
  top("topology", jval("v", M["topology", 0, "value"], "  "), 1)
  top("pipeline", jobj("pipeline", 0, SPEC["pipeline"], "  "), 1)
  top("roles", jarr("role", "  "), 1)
  top("delegations", jarr("deleg", "  "), 1)
  top("lifecycle", jarr("stage", "  "), 1)
  top("flow", jarr("flow", "  "), 1)
  top("attempts", jarr("attempt", "  "), 1)
  top("gateRecords", jarr("gate", "  "), 1)
  top("findings", jarr("finding", "  "), 1)
  top("remediation", remediation("  "), 1)
  top("criteria", jarr("crit", "  "), 1)
  top("qaScenarios", jarr("qa", "  "), 1)
  top("links", jarr("link", "  "), 1)
  top("evidenceRefs", jlist(M["evidenceRefs", 0, "items"], "  "), 1)
  top("files", jarr("file", "  "), 1)
  top("diffstat", jobj("diffstat", 0, SPEC["diffstat"], "  "), 1)
  top("tests", jarr("test", "  "), 1)
  top("verification", jarr("verif", "  "), 1)
  top("fingerprint", fingerprint("  "), 1)
  top("outcome", jobj("outcome", 0, SPEC["outcome"], "  "), 1)
  top("durations", jarr("dur", "  "), 1)
  top("unavailable", jlist(M["unavailable", 0, "items"], "  "), 0)
  print "}"
}

function top(key, text, comma) { print "  \"" key "\": " text (comma ? "," : "") }

function jstr(s) { return "\"" jesc(s) "\"" }

# jval(type, raw, indent): one value of the given type.
function jval(typ, v, ind,   t, x, src) {
  if (typ == "s") return jstr(v)
  if (typ == "n") return (v == "" ? "0" : v)
  if (typ == "b") return (v == "true" ? "true" : "false")
  if (typ == "l" || typ == "lo") return jlist(v, ind)
  if (typ == "so") return jstr(v)
  # Val: {"value": ..., "source": ...}
  src = srcname(v)
  if (!vavail(v)) x = "null"
  else if (vtyp(v) == "s") x = jstr(vval(v))
  else x = vval(v)
  return "{\n" ind "  \"value\": " x ",\n" ind "  \"source\": \"" src "\"\n" ind "}"
}

function jlist(v, ind,   n, a, i, out) {
  n = lsplit(v, a)
  if (n == 0) return "[]"
  out = "[\n"
  for (i = 1; i <= n; i++) out = out ind "  " jstr(a[i]) (i < n ? "," : "") "\n"
  return out ind "]"
}

# jobj(kind, idx, spec, indent): an object whose keys follow spec.
function jobj(kind, idx, spec, ind,   n, fs, i, key, typ, v, out, sep, inner, c) {
  inner = ind "  "; n = split(spec, fs, " "); out = "{"; sep = "\n"
  for (i = 1; i <= n; i++) {
    c = index(fs[i], ":"); key = substr(fs[i], 1, c - 1); typ = substr(fs[i], c + 1)
    v = M[kind, idx, key]
    if ((typ == "lo" || typ == "so") && v == "") continue
    out = out sep inner "\"" key "\": " jval(typ, v, inner)
    sep = ",\n"
  }
  return out "\n" ind "}"
}

# jarr(kind, indent): an array with one object per record of that kind.
function jarr(kind, ind,   n, i, out) {
  n = N[kind] + 0
  if (n == 0) return "[]"
  out = "[\n"
  for (i = 1; i <= n; i++) out = out ind "  " jobj(kind, i, SPEC[kind], ind "  ") (i < n ? "," : "") "\n"
  return out ind "]"
}

function remediation(ind,   inner) {
  inner = ind "  "
  return "{\n" inner "\"loops\": " jarr("loop", inner) ",\n" \
    inner "\"maxFixes\": " jval("v", M["remediation", 0, "maxFixes"], inner) ",\n" \
    inner "\"failingGateRecords\": " jval("n", M["remediation", 0, "failingGateRecords"], inner) ",\n" \
    inner "\"budgetExhausted\": " jval("v", M["remediation", 0, "budgetExhausted"], inner) "\n" ind "}"
}

function fingerprint(ind,   inner) {
  inner = ind "  "
  return "{\n" inner "\"implementedPatchSha256\": " jval("v", M["fp", 0, "implementedPatchSha256"], inner) ",\n" \
    inner "\"codeDonePatchSha256\": " jval("v", M["fp", 0, "codeDonePatchSha256"], inner) ",\n" \
    inner "\"lastGatePatchSha256\": " jval("v", M["fp", 0, "lastGatePatchSha256"], inner) ",\n" \
    inner "\"frozen\": " jobj("frozen", 0, SPEC["frozen"], inner) "\n" ind "}"
}
