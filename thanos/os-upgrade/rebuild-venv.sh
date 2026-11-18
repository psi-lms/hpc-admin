#!/usr/bin/env bash
# Rebuild one aiida-project venv on the SAME Python version it had before the
# OS upgrade, reusing checkouts already on disk instead of re-cloning.
#
#   ./rebuild-venv.sh <project>              # dry run, prints the plan, changes nothing
#   ./rebuild-venv.sh <project> --go         # rebuild
#   NO_DEPS=1 ./rebuild-venv.sh <project> --go
#
# NO_DEPS=1 installs the freeze exactly as written, without resolving
# dependencies. Use it when a project cannot be resolved because the ORIGINAL
# environment was already inconsistent: pip installs in order and merely warns
# about conflicting constraints, uv backtracks and refuses. A pip freeze is by
# definition a complete set, so --no-deps reproduces what was actually there.
#
# Why not `aiida-project create`: it only makes NEW projects, and `destroy`
# removes the project directory as well as the venv, which would take
# .aiida/config.json with it. So the venv is built with uv and the two lines
# aiida-project injects into bin/activate are reproduced here.
#
# Why not plain `uv pip install -r <freeze>.txt`: 17 of 20 freeze files contain
# editable installs, mostly private repos over git+ssh://. Re-cloning needs
# credentials that may no longer exist, so checkouts already on disk are used.
#
# The old venv is renamed to <project>.pre-noble, never deleted.
set -uo pipefail
export LC_ALL=C

PROJECT="${1:?usage: $0 <project> [--go]}"
GO=0; [[ "${2:-}" == "--go" ]] && GO=1

VENVS="${aiida_venv_dir:-$HOME/.aiida_venvs}"
PROJDIR="${aiida_project_dir:-$HOME/project}"
OLD="$VENVS/$PROJECT"
DEAD="$VENVS/$PROJECT.pre-noble"
FREEZE=$(ls -1 "$HOME"/monday-prep-*/venvs/"$PROJECT".txt 2>/dev/null | tail -1)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

command -v uv >/dev/null || { echo "uv not on PATH"; exit 1; }
command -v jq >/dev/null || { echo "jq not on PATH"; exit 1; }
[[ -f "$FREEZE" ]] || { echo "no freeze file for $PROJECT"; exit 1; }
[[ -d "$PROJDIR/$PROJECT" ]] || { echo "no project directory $PROJDIR/$PROJECT"; exit 1; }

BASE="$OLD"; [[ -d "$DEAD" ]] && BASE="$DEAD"
PYVER=$(grep -oP '^version\s*=\s*\K[0-9]+\.[0-9]+' "$BASE/pyvenv.cfg" 2>/dev/null)
PYVER="${PYVER:-3.10}"

# Split the freeze. Editable VCS lines are resolved to on-disk checkouts below.
grep -vE '^-e |^\s*$|^#| @ (file|git)' "$FREEZE"                    > "$WORK/plain.txt"
grep -E  '^-e /' "$FREEZE" | sed 's/^-e //'                         > "$WORK/ed_local.txt"
grep -E  ' @ file://' "$FREEZE" | sed -E 's|.* @ file://||'         > "$WORK/at_file.txt"
grep -E  ' @ (git\+|https?://)' "$FREEZE" | sed -E 's|.* @ ||'      > "$WORK/at_vcs.txt"
grep -E  '^-e git' "$FREEZE" | sed -E 's|.*#egg=||'                 > "$WORK/eggs.txt"

# Some packages that were on PyPI when these venvs were built have since been
# removed from the index, so the pinned line is unresolvable. overrides.txt maps
# such a line to somewhere it can still be fetched from.
OVERRIDES="$(dirname "$(readlink -f "$0")")/overrides.txt"
N_OVERRIDE=0
: > "$WORK/uv-overrides.txt"
if [[ -f "$OVERRIDES" ]]; then
  while IFS=$'\t' read -r old new; do
    [[ "$old" == \#* || -z "$old" ]] && continue
    if grep -qxF "$old" "$WORK/plain.txt"; then
      sed -i "s|^$(printf '%s' "$old" | sed 's/[][\.*^$/]/\\&/g')$|$new|" "$WORK/plain.txt"
      echo "  override  $old"
      echo "         -> $new"
      # Also feed uv a real --override entry, so the replacement applies to
      # TRANSITIVE requirements too, not just the top-level pinned line.
      echo "$new" >> "$WORK/uv-overrides.txt"
      ((N_OVERRIDE++))
    fi
  done < "$OVERRIDES"
fi

# Where the editable sources actually are: read them out of the old venv rather
# than guessing. Every editable install leaves a .pth in site-packages whose
# contents are the source directory. Naming varies by build backend
# (setuptools writes __editable__*.pth, hatchling/flit write <package>.pth,
# older setuptools writes <name>.egg-link), so harvest all of them.
#
# The freeze file cannot answer this: `pip install -e /local/git/checkout`
# renders in `pip freeze` as `-e git+<remote>@<sha>#egg=<name>`, describing the
# remote rather than recording the local path.
harvest_editables() {
  local sp d url root p line b
  for sp in "$BASE"/lib/python*/site-packages; do
    [[ -d "$sp" ]] || continue

    # Preferred: PEP 610. pip records every install here, and for editables it
    # gives the installable root directly.
    for d in "$sp"/*.dist-info/direct_url.json; do
      [[ -f "$d" ]] || continue
      url=$(jq -r 'select(.dir_info.editable == true) | .url // empty' "$d" 2>/dev/null)
      [[ -n "$url" ]] || continue
      root="${url#file://}"
      [[ -d "$root" ]] && echo "$root"
    done

    # Fallback for installs predating direct_url.json: every editable leaves a
    # .pth (or .egg-link) whose contents are a source path. Naming varies by
    # backend: setuptools writes __editable__*.pth, hatchling/flit <package>.pth.
    for p in "$sp"/*.pth "$sp"/*.egg-link; do
      [[ -f "$p" ]] || continue
      b=$(basename "$p"); [[ "$b" == "distutils-precedence.pth" ]] && continue
      while read -r line; do
        [[ "$line" == /* && -d "$line" ]] || continue
        root="$line"
        # src-layout: the .pth points at <root>/src, but pip installs <root>
        if [[ "$(basename "$root")" == "src" ]] && \
           [[ -f "$(dirname "$root")/pyproject.toml" || -f "$(dirname "$root")/setup.py" ]]; then
          root=$(dirname "$root")
        fi
        [[ -f "$root/pyproject.toml" || -f "$root/setup.py" || -f "$root/setup.cfg" ]] && echo "$root"
      done < "$p"
    done
  done | sort -u
}

echo "project          : $PROJECT"
echo "python           : $PYVER   (from pyvenv.cfg)"
echo "freeze           : $FREEZE"
echo "venv             : $OLD  ->  $DEAD"
echo "AIIDA_PATH       : $PROJDIR/$PROJECT"
echo "pinned reqs      : $(wc -l < "$WORK/plain.txt")"
[[ -s "$WORK/at_vcs.txt" ]] && { echo "direct URLs      : $(wc -l < "$WORK/at_vcs.txt")"; sed 's/^/                   /' "$WORK/at_vcs.txt"; }
echo

RESOLVED=0; UNRESOLVED=0
: > "$WORK/found.txt"
mapfile -t HARVESTED < <(harvest_editables)
for d in "${HARVESTED[@]}"; do
  printf '  editable  %-34s %s\n' "$(basename "$d")" "$d"
  echo "$d" >> "$WORK/found.txt"; ((RESOLVED++))
done

# Cross-check against the freeze so nothing is silently dropped.
while read -r egg; do
  [[ -z "$egg" ]] && continue
  alt="${egg//_/-}"
  # Informational only. A repo often provides a differently-named package, e.g.
  # aiida_tools.git#egg=aiida_error_inspector, so a name mismatch is not a miss.
  # Whether anything is genuinely absent is settled after installing, below.
  grep -qiE "/($egg|$alt)(/|$)" "$WORK/found.txt" || \
    printf '  note      %-34s (name differs from its directory, checked after install)\n' "$egg"
done < "$WORK/eggs.txt"

while read -r p; do [[ -z "$p" ]] && continue
  if [[ -d "$p" ]]; then grep -qxF "$p" "$WORK/found.txt" || { printf '  editable  %-34s %s\n' "(local)" "$p"; echo "$p" >> "$WORK/found.txt"; }
  else printf '  MISSING   %-34s %s\n' "(local)" "$p"; ((UNRESOLVED++)); fi
done < "$WORK/ed_local.txt"

while read -r p; do [[ -z "$p" ]] && continue
  if [[ -d "$p" ]]; then printf '  file://   %-34s %s\n' "(local)" "$p"
  else printf '  MISSING   %-34s %s\n' "(file://)" "$p"; ((UNRESOLVED++)); fi
done < "$WORK/at_file.txt"

echo
echo "resolved to a directory : $RESOLVED"
echo "unresolved              : $UNRESOLVED"
(( UNRESOLVED )) && echo "  ^ these will be skipped; the venv will be incomplete until they are dealt with"

if (( ! GO )); then echo; echo ">>> DRY RUN. Re-run with --go to rebuild."; exit 0; fi

set -e
VENV_ARGS=()
if [[ -d "$OLD" ]]; then
  if [[ -d "$DEAD" ]]; then
    # Retry after a failed run: the original is already safe at $DEAD, so the
    # half-built venv at $OLD can be replaced.
    echo ">>> $OLD exists and the original is preserved at $DEAD, recreating it"
    VENV_ARGS+=(--clear)
  else
    echo ">>> moving $OLD -> $DEAD"
    mv "$OLD" "$DEAD"
  fi
fi
BASE="$DEAD"

echo ">>> creating venv on Python $PYVER"
uv python install "$PYVER"
uv venv --python "$PYVER" "${VENV_ARGS[@]}" "$OLD"
PY="$OLD/bin/python"

echo ">>> installing pinned requirements"
# ONE resolution pass for everything.
#
# Installing the pinned set first and the editables afterwards does not work
# when aiida-core is itself editable: the freeze pins plumpy, psutil, pgsu and
# asyncssh at the versions that local aiida-core needs, so resolving the pinned
# set alone requires a PUBLISHED aiida-core compatible with those pins, and
# there is none. Passing the editables in the same invocation lets uv use the
# local checkout as the provider. Five of six failures were exactly this.
INSTALL_ARGS=(-r "$WORK/plain.txt")
if [[ "${NO_DEPS:-0}" == "1" ]]; then
  echo "    NO_DEPS=1: installing the freeze verbatim, no dependency resolution"
  INSTALL_ARGS+=(--no-deps)
fi
[[ -s "$WORK/uv-overrides.txt" ]] && INSTALL_ARGS+=(--override "$WORK/uv-overrides.txt")
while read -r d; do [[ -n "$d" ]] && INSTALL_ARGS+=(-e "$d"); done < "$WORK/found.txt"
while read -r p; do [[ -d "$p" ]] && INSTALL_ARGS+=("$p"); done < "$WORK/at_file.txt"
while read -r u; do [[ -n "$u" ]] && INSTALL_ARGS+=("$u"); done < "$WORK/at_vcs.txt"

echo ">>> installing everything in one resolution pass"
echo "    $(wc -l < "$WORK/plain.txt") pinned, $(wc -l < "$WORK/found.txt") editable"
PINNED_OK=1
uv pip install --python "$PY" "${INSTALL_ARGS[@]}" || { PINNED_OK=0; echo "    INSTALL FAILED, see above"; }

# Reproduce what aiida-project injects into bin/activate:
#   unset AIIDA_PATH   as the first line of deactivate()
#   export AIIDA_PATH  plus verdi completion, appended at the end
echo ">>> patching bin/activate the way aiida-project does"
# aiida-project anchors on the literal "deactivate () {" (recorded per project in
# ~/project/.aiida_projects/venv/<name>.json as shell_deactivate_mapping).
# uv writes its own activate script, so match the spacing loosely and then VERIFY,
# because a silently-skipped insert gives a venv that never unsets AIIDA_PATH.
sed -i -E '/^deactivate *\(\) *\{/a\    unset AIIDA_PATH' "$OLD/bin/activate"
cat >> "$OLD/bin/activate" <<EOF
export AIIDA_PATH=$PROJDIR/$PROJECT
eval "\$(_VERDI_COMPLETE=bash_source verdi)"
EOF

n_unset=$(grep -c '^\s*unset AIIDA_PATH' "$OLD/bin/activate")
n_export=$(grep -c "^export AIIDA_PATH=$PROJDIR/$PROJECT\$" "$OLD/bin/activate")
if [[ "$n_unset" != "1" || "$n_export" != "1" ]]; then
  echo "  ERROR: activate patch did not apply cleanly (unset=$n_unset export=$n_export)."
  echo "  Compare against the old one and fix by hand:"
  echo "    diff $DEAD/bin/activate $OLD/bin/activate"
  exit 1
fi
grep -n 'AIIDA_PATH' "$OLD/bin/activate"

echo ">>> checking nothing from the freeze went missing"
# PEP 503 normalisation: runs of -, _ and . all collapse to a single -,
# so `ruamel.yaml` in a freeze is `ruamel-yaml` in pip list.
norm() { tr 'A-Z' 'a-z' | sed -E 's/[-_.]+/-/g'; }
# `|| true` on every grep here: pipefail is on, and a grep that matches nothing
# (a project with no editables, say) would otherwise make set -e kill the script
# just before it reports its result.
{ uv pip list --python "$PY" --format=freeze 2>/dev/null || true; } \
  | sed -E 's/[=@ ].*//' | norm | sort -u > "$WORK/after.txt"
{ { grep -vE '^-e |^\s*$|^#' "$FREEZE" || true; } | sed -E 's/[=@ ].*//'
  { grep -E '^-e git' "$FREEZE" || true; } | sed -E 's|.*#egg=||'
} | norm | sort -u > "$WORK/before.txt"
MISSED=$(comm -23 "$WORK/before.txt" "$WORK/after.txt")
if [[ -n "$MISSED" ]]; then
  echo "  MISSING after rebuild:"; echo "$MISSED" | sed 's/^/    /'
else
  echo "  all $(wc -l < "$WORK/before.txt") packages from the freeze are present"
fi

# DO NOT run verdi unless the rebuild actually succeeded.
#
# A `verdi` from a NEWER aiida-core than the project expects will silently
# MIGRATE .aiida/config.json to a newer schema, after which the intended version
# cannot read it. This happened to mc3d-electronic on 2026-08-25: a failed
# rebuild left aiida-core 2.9.0 (the current PyPI stable) installed, and the
# closing `verdi status` migrated its config from version 9 to 10.
echo
if (( ! PINNED_OK )); then
  echo ">>> skipping verdi status: the install failed, and running verdi from a"
  echo "    mismatched aiida-core would migrate .aiida/config.json irreversibly"
else
  WANT=$(grep -oP '^aiida-core==\K.*' "$FREEZE" | head -1)
  GOT=$("$PY" -c 'import aiida; print(aiida.__version__)' 2>/dev/null || echo unknown)
  if [[ -n "$WANT" && "$WANT" != "$GOT" ]]; then
    echo ">>> skipping verdi status: freeze pins aiida-core==$WANT but $GOT is installed."
    echo "    Running verdi now could migrate .aiida/config.json to a newer schema."
  else
    echo ">>> verdi status  (aiida-core ${GOT})"
    ( unset AIIDA_PATH; export AIIDA_PATH="$PROJDIR/$PROJECT"; "$OLD/bin/verdi" status ) || true
  fi
fi
echo
echo "=============================================================="
if (( PINNED_OK )) && [[ -z "$MISSED" ]]; then
  echo "RESULT: $PROJECT rebuilt cleanly"
else
  echo "RESULT: $PROJECT NEEDS ATTENTION"
  (( PINNED_OK )) || { echo "  - the requirement set did not resolve"
                       [[ "${NO_DEPS:-0}" == "1" ]] || echo "    if the original environment was itself inconsistent, retry with NO_DEPS=1"; }
  [[ -z "$MISSED" ]] || echo "  - packages missing after rebuild (listed above)"
fi
echo "old venv kept at $DEAD. Delete only once this project is verified."
