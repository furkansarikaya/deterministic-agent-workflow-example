# mload.awk: reads the model record stream (see lib.awk) into M[kind, idx, field].
# Include after lib.awk in every consumer of the model (json, summary, report).
# N[kind] is the highest index seen for a kind (the element count).

{
  split($0, REC, US)
  MK = REC[1] SUBSEP REC[2] SUBSEP REC[3]
  if (MK in M) M[MK] = M[MK] SUB REC[4]      # a repeated key is a list
  else M[MK] = REC[4]
  if (REC[2] + 0 > N[REC[1]] + 0) N[REC[1]] = REC[2] + 0
}
