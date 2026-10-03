# diffstat.awk: joins three lists into diffstat records. Numbers only: no diff text,
# no file content ever passes through here.
#   file 1  changed paths (from the newest gate manifest), one per line
#   file 2  tracked paths (git ls-files)
#   file 3  git diff --numstat output:  added TAB deleted TAB path
# Output:
#   diff US path US added US deleted     a tracked path git reports numbers for
#   untracked US path                    a path git does not track (counted by the caller)
# A tracked path without numbers (unchanged, or binary) produces nothing: it stays unavailable.
BEGIN { FS = "\t"; US = sprintf("%c", 31) }
FILENAME == ARGV[1] { want[$0] = 1; order[++n] = $0; next }
FILENAME == ARGV[2] { tracked[$0] = 1; next }
$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { path = $3; for (i = 4; i <= NF; i++) path = path FS $i; stat[path] = $1 US $2 }
END {
  for (i = 1; i <= n; i++) {
    p = order[i]
    if (p in stat) print "diff" US p US stat[p]
    else if (!(p in tracked)) print "untracked" US p
  }
}
