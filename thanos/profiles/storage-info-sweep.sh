#!/usr/bin/env bash
# `verdi storage info` for every profile of every project, using each project's
# own venv and AIIDA_PATH.
#
#   ./storage-info-sweep.sh              # plain, fast
#   DETAILED=1 ./storage-info-sweep.sh   # adds --detailed: a full aggregate over
#                                        # the node table per profile. On the big
#                                        # ones (aiida-test_2 is 137 GB) this is
#                                        # tens of minutes each. Run under screen.
#
# Read-only, but note it invokes `verdi`, which MIGRATES .aiida/config.json if
# the venv's aiida-core is newer than the config schema. Every venv here was
# rebuilt from its own freeze so they match, and the guard below re-checks.
set -uo pipefail
export LC_ALL=C

VENVS="${aiida_venv_dir:-$HOME/.aiida_venvs}"
PROJDIR="${aiida_project_dir:-$HOME/project}"
OUT="${OUT:-$HOME/storage-info-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
ARGS=(); [[ "${DETAILED:-0}" == "1" ]] && ARGS+=(--detailed)

SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
echo "output: $OUT"
echo "summary: $SUMMARY"
echo

for d in "$VENVS"/*/; do
  n=$(basename "$d"); [[ "$n" == *.pre-noble ]] && continue
  py="$d/bin/python"; verdi="$d/bin/verdi"
  [[ -x "$verdi" ]] || { printf '%-18s no verdi\n' "$n"; continue; }
  cfg="$PROJDIR/$n/.aiida/config.json"
  [[ -f "$cfg" ]] || { printf '%-18s no config\n' "$n"; continue; }

  av=$("$py" -c 'import aiida;print(aiida.__version__)' 2>/dev/null || echo none)
  # 2.9 migrates config v9 -> v10 on load; refuse to touch anything with it.
  case "$av" in 2.9.*|none) printf '%-18s %-14s SKIPPED (would migrate config)\n' "$n" "$av"; continue;; esac

  mapfile -t profiles < <(python3 -c "
import json,sys
print('\n'.join(json.load(open(sys.argv[1])).get('profiles',{})))" "$cfg" 2>/dev/null)

  for p in "${profiles[@]}"; do
    [[ -z "$p" ]] && continue
    f="$OUT/$n.$p.txt"
    printf '%-18s %-22s ' "$n" "$p"
    t0=$SECONDS
    ( unset AIIDA_PATH; export AIIDA_PATH="$PROJDIR/$n"
      "$verdi" -p "$p" storage info "${ARGS[@]}" ) > "$f" 2>&1
    rc=$?
    dt=$(( SECONDS - t0 ))
    # Pull the headline numbers out so the summary is useful on its own.
    nodes=$(grep -A1 '^  Nodes:' "$f" | grep -oP 'count: \K[0-9]+' | head -1)
    links=$(grep -A1 '^  Links:' "$f" | grep -oP 'count: \K[0-9]+' | head -1)
    packed=$(grep -oP 'packed: \K[0-9]+' "$f" | head -1)
    loose=$(grep -oP 'loose: \K[0-9]+' "$f" | head -1)
    size=$(grep -oP 'total_size_packed: \K[0-9.]+' "$f" | head -1)
    if (( rc == 0 )); then
      line=$(printf '%-18s %-22s ok   %5ds  nodes=%-10s links=%-11s packed=%-10s loose=%-6s MB=%s' \
        "$n" "$p" "$dt" "${nodes:--}" "${links:--}" "${packed:--}" "${loose:--}" "${size:--}")
    else
      line=$(printf '%-18s %-22s FAIL %5ds  %s' "$n" "$p" "$dt" "$(head -2 "$f" | tr '\n' ' ' | cut -c1-70)")
    fi
    # stdout already carries the "<project> <profile> " prefix from above, so
    # print only the result part there; the summary file gets the full line.
    printf '%s\n' "$line" >> "$SUMMARY"
    printf '%s\n' "${line#"$n"*"$p"}" | sed 's/^ *//'   
  done
done

echo
echo "results in $OUT"
