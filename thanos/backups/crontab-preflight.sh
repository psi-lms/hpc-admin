#!/usr/bin/env bash
# Pre-flight for crontab-new.txt. Read-only: checks that every project has a
# venv and that every named profile exists in that project's config.json.
# Runs no backups.
#
#   bash crontab-preflight.sh crontab-new.txt
set -uo pipefail
export LC_ALL=C

CRON="${1:?usage: $0 <crontab-file>}"
VENV_DIR="${aiida_venv_dir:-$HOME/.aiida_venvs}"
PROJ_DIR="${aiida_project_dir:-$HOME/project}"
fail=0

# Pull "-n <project> -p "<profiles>"" pairs out of the cron file.
while read -r project profiles; do
  printf '%-18s ' "$project"

  if [[ ! -x "$VENV_DIR/$project/bin/verdi" ]]; then
    echo "MISSING venv: $VENV_DIR/$project/bin/verdi"; fail=1; continue
  fi

  cfg="$PROJ_DIR/$project/.aiida/config.json"
  if [[ ! -f "$cfg" ]]; then
    echo "MISSING config: $cfg"; fail=1; continue
  fi

  known=$(python3 -c "import json,sys; print(' '.join(json.load(open(sys.argv[1])).get('profiles',{})))" "$cfg")
  missing=()
  for p in $profiles; do
    [[ " $known " == *" $p "* ]] || missing+=("$p")
  done

  if (( ${#missing[@]} )); then
    echo "venv ok, but profiles not in config: ${missing[*]}  (known: $known)"; fail=1
  else
    echo "ok  ($(wc -w <<<"$profiles") profiles)"
  fi
done < <(grep -oP '(?<=-n )\S+\s+-p "[^"]*"' "$CRON" | sed -E 's/\s+-p "/ /; s/"$//')

echo
if (( fail )); then
  echo "PRE-FLIGHT FAILED. Fix the above before installing the crontab."
else
  echo "Pre-flight clean. Safe to install."
fi
exit $fail
