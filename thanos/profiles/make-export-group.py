"""Collect a subset of a large group into its own group, ready for export.

Written to hand an external collaborator 10,000 of 33,191 workchains as an
archive. Runs the collaborator's own query verbatim, limited to the first N
successful workchains, and puts those workchains into a new group, so the
export can be addressed with a single ``-G``. The group travels inside the
archive, so the same query works on the other side with nothing changed but the
label.

Creating the group is the only write this makes to a production profile, and
``verdi group delete`` undoes it. The constants below are the values from the
September 2026 run; change them for a new export.

Run in the project venv (which also sets ``AIIDA_PATH``)::

    source /home/aiida/.aiida_venvs/mc3d-pbesol-v1/bin/activate
    python make-export-group.py            # report only, writes nothing
    python make-export-group.py --commit   # create the group

Context and measured sizes: ../profiles/archive-export-runbook.md
"""

import sys

from aiida import load_profile, orm

PROFILE = 'prod'
SOURCE_GROUP_UUID = '219b7062-6186-4f15-998d-01c02f9e4328'  # workchain/PBEsol/bands/lumi
# The label the September 2026 export actually used, kept verbatim because the
# group exists in the profile under this name. Change it for a new export.
TARGET_LABEL = 'workchain/PBEsol/bands/lumi/export/flaviano-10k'
LIMIT = 10000
BATCH = 500


def select_workchain_pks(limit: int) -> list[int]:
    """Return the pks of the workchains the collaborator's query yields, by pk.

    The joins are theirs: only workchains that have an ``scf`` child with a
    successful ``iteration_01`` calcjob are selected, so every exported
    workchain produces a row on their side.
    """
    qb = orm.QueryBuilder()
    qb.append(orm.Group, filters={'uuid': SOURCE_GROUP_UUID}, tag='group')
    qb.append(
        orm.WorkChainNode,
        tag='PwBandsWorkChain',
        with_group='group',
        project='id',
        filters={'attributes.process_label': 'PwBandsWorkChain', 'attributes.exit_status': 0},
    )
    qb.append(
        orm.WorkChainNode,
        tag='PwBaseWorkChainSCF',
        with_incoming='PwBandsWorkChain',
        edge_filters={'label': 'scf'},
    )
    qb.append(
        orm.CalcJobNode,
        tag='Calcjob',
        with_incoming='PwBaseWorkChainSCF',
        edge_filters={'label': 'iteration_01'},
        filters={'attributes.exit_status': 0},
    )
    qb.distinct()
    qb.order_by({'PwBandsWorkChain': {'id': 'asc'}})
    qb.limit(limit)
    return [pk for pk, in qb.all()]


def main() -> int:
    commit = '--commit' in sys.argv
    load_profile(PROFILE)

    pks = select_workchain_pks(LIMIT)
    print(f'selected {len(pks)} workchains (pk {pks[0]} .. {pks[-1]})')

    existing = orm.QueryBuilder().append(orm.Group, filters={'label': TARGET_LABEL}, project='*').first()
    if existing is not None:
        group = existing[0]
        print(f'group {TARGET_LABEL!r} already exists with {group.count()} nodes, nothing to do')
        return 0

    if not commit:
        print(f'would create group {TARGET_LABEL!r} with {len(pks)} nodes')
        print('re-run with --commit to write it')
        return 0

    group, _ = orm.Group.collection.get_or_create(label=TARGET_LABEL)
    group.description = f'First {len(pks)} successful PwBandsWorkChains, shared externally 2026-09'

    for start in range(0, len(pks), BATCH):
        chunk = pks[start : start + BATCH]
        nodes = orm.QueryBuilder().append(orm.WorkChainNode, filters={'id': {'in': chunk}}).all(flat=True)
        group.add_nodes(nodes)
        print(f'  added {start + len(chunk)}/{len(pks)}', end='\r')

    print(f'\ngroup {TARGET_LABEL!r} created with {group.count()} nodes, uuid {group.uuid}')
    print('\nnext:')
    print('  export TMPDIR=/home/aiida/exports/tmp && mkdir -p $TMPDIR')
    print(f'  verdi -p prod archive create --compress 0 --exclude-logs --exclude-comments \\')
    print(f'      -G {group.uuid} -- /home/aiida/exports/lumi-10k.aiida')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
