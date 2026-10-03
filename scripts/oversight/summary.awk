# summary.awk: model records -> the concise CLI summary. Reads the model and nothing else.
# -v REPORT=<path> names a generated report; empty means none exists.

BEGIN {
  lib_init()
  MARK["completed"] = "ok"; MARK["passed"] = "ok"; MARK["failed"] = "FAIL"; MARK["blocked"] = "BLOCKED"
  MARK["in_progress"] = ".."; MARK["pending"] = "-"; MARK["skipped"] = "skip"
}

function or_dash(v,   s) { s = vstr(v); return s == "" ? "unavailable" : s }

# role_label(i): how one role appears. "expected" is never shown as having run.
function role_label(i,   st) {
  st = M["role", i, "status"]
  if (st == "recorded") return M["role", i, "role"] "[recorded " M["role", i, "records"] "]"
  return M["role", i, "role"] "[expected · no record]"
}

END {
  printf "%s  %s  %s  topology=%s\n", M["task", 0, "id"], or_dash(M["pipeline", 0, "classification"]), or_dash(M["status", 0, "summary"]), or_dash(M["topology", 0, "value"])
  printf "state=%s handoff=%s knowledge=%s\n", or_dash(M["status", 0, "state"]), or_dash(M["status", 0, "handoff"]), or_dash(M["status", 0, "knowledge"])
  for (i = 1; i <= N["stage"]; i++)
    if (M["stage", i, "gate"] == "true")
      printf "gate %-6s %-7s attempts=%d open_findings=%d\n", M["stage", i, "stage"], MARK[M["stage", i, "status"]], M["stage", i, "attempts"], M["stage", i, "findingsOpen"]
  changed = 0
  for (i = 1; i <= N["file"]; i++) if (M["file", i, "status"] != "planned") changed++
  if (vavail(M["diffstat", 0, "added"])) ds = "+" vval(M["diffstat", 0, "added"]) " -" vval(M["diffstat", 0, "deleted"]); else ds = "unavailable"
  printf "files: %d changed, %d planned; diffstat %s\n", changed, N["file"] - changed, ds
  red = 0; green = 0; other = 0
  for (i = 1; i <= N["test"]; i++) {
    ph = M["test", i, "phase"]
    if (ph == "RED") red++; else if (ph == "GREEN") green++; else other++
  }
  okc = 0
  for (i = 1; i <= N["verif"]; i++) if (vstr(M["verif", i, "result"]) == "exit=0") okc++
  printf "tests: RED=%d GREEN=%d other=%d; verify commands: %d recorded, %d exit=0\n", red, green, other, N["verif"], okc
  printf "remediation: %d loops, %d failing gates, max fixes %s\n", N["loop"], M["remediation", 0, "failingGateRecords"], or_dash(M["remediation", 0, "maxFixes"])
  line = ""
  for (i = 1; i <= N["role"]; i++) line = line (i > 1 ? ", " : "") role_label(i)
  printf "roles: %s\n", line
  line = ""
  for (i = 1; i <= N["stage"]; i++) line = line (i > 1 ? " > " : "") M["stage", i, "stage"] "[" MARK[M["stage", i, "status"]] "]"
  printf "flow: %s\n", line
  if (vavail(M["outcome", 0, "failureReason"])) printf "failure: %s\n", oneline(vval(M["outcome", 0, "failureReason"]))
  if (M["unavailable", 0, "items"] != "") printf "unavailable: %s\n", ljoin(M["unavailable", 0, "items"], ", ")
  if (REPORT != "") printf "report: %s\n", REPORT
}
