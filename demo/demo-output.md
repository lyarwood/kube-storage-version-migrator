# Storage Version Migration Demo

Annotated walkthroughs showing how `kube-storage-version-migrator` affects
data in etcd, with a focus on field pruning, schema changes, and the risks
of skip-level upgrades.

Run `demo.sh` to reproduce Parts 1–4 against a kind cluster. Part 5 is a
static analysis of the KubeVirt project.

## Parts

1. **[Storage Version Migration](part1-storage-version-migration.md)** —
   Migrating from v1alpha1 to v1beta1 prunes fields removed in the new
   version's schema. Shows the basic GET + PUT mechanism and raw etcd diffs.

2. **[v1 Field Removal](part2-v1-field-removal.md)** — Removing a field from
   a single-version v1 CRD does not rewrite existing objects. The field
   persists in etcd as a ghost until something writes to the object.

3. **[Skip-Level Upgrades](part3-skip-level-upgrades.md)** — A skip-level
   upgrade from N to N+5 compounds all intermediate field removals into a
   single migration, pruning every field removed across N+2, N+3, and N+4
   at once.

4. **[Conversion Webhooks](part4-conversion-webhooks.md)** — Conversion
   webhooks can preserve data by transforming fields during incremental
   upgrades, but a skip-level upgrade that bypasses the webhook loses the
   data entirely instead of converting it.

5. **[KubeVirt Analysis](part5-kubevirt-analysis.md)** — Applies the
   findings from Parts 1–4 to the KubeVirt project (v1.4.0 – v1.8.0).
   KubeVirt uses `NoneConverter` for all CRDs and relies on application-level
   Go conversion that does not run during storage version migration, creating
   a gap where field restructuring (e.g. `PreferredUseEfi` → `PreferredEfi`)
   will cause data loss when deprecated fields are removed.
