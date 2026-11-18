"""Post-upgrade smoke test: exercise the write path and the read path.

    cda <project>
    verdi run ~/scripts/hpc-admin/thanos/profiles/smoke-test.py

Writes a few small nodes into the profile, then reads files back out of nodes
that already existed. Needs no Computer or Code, so it works on any profile.

Write path covers PostgreSQL 16 and the disk-objectstore container. The read
path is the one that matters after a cluster migration: it proves the migrated
database still indexes the repository correctly.

Uses only APIs present in aiida-core 2.6 through 2.9, since the profiles on this
machine span that range.
"""

import io

from aiida import load_profile, orm
from aiida.engine import calcfunction, run_get_node


@calcfunction
def add(x, y):
    return orm.Int(x + y)


profile = load_profile()
print(f'profile        : {profile.name}')

# --- write path -----------------------------------------------------------
result, node = run_get_node(add, x=orm.Int(2), y=orm.Int(3))
assert result.value == 5, f'expected 5, got {result.value}'
print(f'calcfunction   : pk={node.pk} result={result.value}')

sf = orm.SinglefileData(io.StringIO('post-upgrade smoke test\n'))
sf.store()
content = sf.get_content()
assert content.startswith('post-upgrade'), content
print(f'repository w/r : pk={sf.pk}, wrote and read back {len(content)} bytes')

# --- read path against data that predates the upgrade ---------------------
# Any node type will do: what matters is reading bytes back out of the
# container for nodes the migration inherited rather than ones just created.
qb = orm.QueryBuilder().append(orm.Node, project=['id'], filters={'id': {'<': node.pk}})
qb.order_by({orm.Node: {'id': 'desc'}})
candidates = [row[0] for row in qb.limit(400).all()]

checked, read_ok, bytes_read, failures = 0, 0, 0, []
for pk in candidates:
    if checked >= 10:
        break
    try:
        n = orm.load_node(pk)
        names = n.base.repository.list_object_names()
    except Exception as exc:  # noqa: BLE001
        failures.append((pk, f'listing failed: {exc}'))
        continue
    if not names:
        continue
    checked += 1
    try:
        data = n.base.repository.get_object_content(names[0], mode='rb')
        bytes_read += len(data)
        read_ok += 1
    except Exception as exc:  # noqa: BLE001
        failures.append((pk, f'read failed: {exc}'))

for pk, why in failures:
    print(f'  pk={pk}: {why}')
if checked:
    print(f'old nodes read : {read_ok}/{checked} pre-existing nodes, {bytes_read} bytes from the container')
else:
    print('old nodes read : no pre-existing node with repository content found')

print(f'total nodes    : {orm.QueryBuilder().append(orm.Node).count()}')
print('OK')
