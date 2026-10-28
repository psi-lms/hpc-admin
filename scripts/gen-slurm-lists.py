#!/usr/bin/env python3
"""
Derive the Slurm association lists from the grouping comments in
data-lms/compute_cluster.yaml, so aaa::users stays the single list.

Contract, enforced by --check: every entry under aaa::users sits under
exactly one `# <group>` header. Mapping: msd -> prio; lmi, lms, misc ->
normal; minus profile::hpc::slurm_excluded (service accounts).
Commented-out entries (`# - name`) are ignored.

Usage:
  gen-slurm-lists.py              # print PRIO_USERS / LMS_USERS lines
  gen-slurm-lists.py --check      # exit 1 if the mgmt yaml embeds
                                  # anything else (drift), or if any user
                                  # lacks a group header
"""

import re
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
DATA_LMS = HERE.parent.parent / "data-lms"
USERS_YAML = DATA_LMS / "compute_cluster.yaml"
MGMT_YAML = DATA_LMS / "compute_cluster" / "lms-mgmt.psi.ch.yaml"

PRIO_GROUPS = {"msd"}
NORMAL_GROUPS = {"lmi", "lms", "misc"}


def parse_grouped_users():
    text = USERS_YAML.read_text().splitlines()
    start = next(i for i, l in enumerate(text) if l.startswith("aaa::users:"))
    grouped = {}
    current = None
    for line in text[start + 1 :]:
        if re.match(r"^[a-z_]+::", line):
            break
        m = re.match(r"^  #\s*(\S+)\s*$", line)
        if m:
            current = m.group(1)
            continue
        m = re.match(r"^  - (\S+)\s*$", line)
        if m:
            if current is None:
                raise ValueError(f"user {m.group(1)} has no group header")
            if current not in PRIO_GROUPS | NORMAL_GROUPS:
                raise ValueError(f"unknown group header #{current}")
            grouped[m.group(1)] = current
    return grouped


def load_lists():
    base = yaml.safe_load(USERS_YAML.read_text())
    users = set(base["aaa::users"])
    excluded = set(base.get("profile::hpc::slurm_excluded", []))
    grouped = parse_grouped_users()
    ungrouped = sorted(users - set(grouped))
    if ungrouped:
        raise ValueError(f"users without group header: {ungrouped}")
    order = [u for u in base["aaa::users"] if u in grouped]
    prio = [u for u in order if grouped[u] in PRIO_GROUPS and u not in excluded]
    normal = [u for u in order if grouped[u] in NORMAL_GROUPS and u not in excluded]
    return prio, normal


def main():
    prio, normal = load_lists()
    prio_line = 'PRIO_USERS="' + " ".join(prio) + '"'
    normal_line = 'LMS_USERS="' + " ".join(normal) + '"'
    if "--check" in sys.argv:
        mgmt_text = MGMT_YAML.read_text()
        ok = True
        for line in (normal_line,):
            if line not in mgmt_text:
                print(f"DRIFT: not in {MGMT_YAML.name}: {line[:60]}...")
                ok = False
        # prio is live from AD at runtime; here we only print it so a
        # human can diff against `getent group unx-msd` on any node.
        print("expected prio (diff against `getent group unx-msd`):")
        print("  " + " ".join(prio))
        print("lists consistent" if ok else "lists inconsistent")
        sys.exit(0 if ok else 1)
    print(prio_line)
    print(normal_line)


if __name__ == "__main__":
    main()
