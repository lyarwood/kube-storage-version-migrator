# Part 3: Skip-Level Upgrades — Compounded Data Loss

Parts 1 and 2 showed individual field removals. In practice, CRD APIs evolve
across multiple cluster versions — fields are deprecated, removed, and
eventually the API version itself is replaced. A user who upgrades
incrementally loses fields one-by-one at each migration. A user who does a
**skip-level upgrade** loses all of them in a single migration.

## Scenario

A `Gadget` CRD evolves across cluster versions N through N+5:

| Cluster version | What changes | API versions available | Fields in newest version |
|---|---|---|---|
| **N** | v1alpha1 introduced | v1alpha1 (storage) | `name`, `debugMode`, `legacyPort`, `internalRef` |
| **N+2** | v1beta1 added, `debugMode` removed (was experimental) | v1alpha1, v1beta1 (storage) | `name`, `legacyPort`, `internalRef` |
| **N+3** | `legacyPort` removed from v1beta1 (replaced by a Service) | v1alpha1, v1beta1 (storage) | `name`, `internalRef` |
| **N+4** | v1 added, `internalRef` removed (moved to status) | v1alpha1, v1beta1, v1 (storage) | `name` |
| **N+5** | v1 becomes storage | v1alpha1, v1beta1, v1 (storage) | `name` |

A user running cluster version N upgrades directly to N+5.

## Step 13: Create Gadget CRD at Version N

Install the Gadget CRD with v1alpha1 as the only version (version N) and
create two objects with all four fields populated:

```
$ kubectl apply -f demo/crd-gadget-vN.yaml
customresourcedefinition.apiextensions.k8s.io/gadgets.demo.example.com created

$ kubectl apply -f demo/sample-gadgets.yaml
gadget.demo.example.com/test-gadget-1 created
gadget.demo.example.com/test-gadget-2 created

$ kubectl get gadgets.v1alpha1.demo.example.com -o custom-columns='NAME:.metadata.name,NAME_FIELD:.spec.name,DEBUG:.spec.debugMode,PORT:.spec.legacyPort,REF:.spec.internalRef'
NAME            NAME_FIELD   DEBUG   PORT   REF
test-gadget-1   sensor       true    8080   ns/configmap-abc
test-gadget-2   actuator     false   9090   ns/configmap-def
```

## Step 14: Snapshot etcd (Version N)

```json
{
  "apiVersion": "demo.example.com/v1alpha1",
  "kind": "Gadget",
  "metadata": {
    "name": "test-gadget-1",
    "namespace": "default"
  },
  "spec": {
    "debugMode": true,
    "internalRef": "ns/configmap-abc",
    "legacyPort": 8080,
    "name": "sensor"
  }
}
```

> All four fields are present in etcd. This is the state a cluster at version N
> would have.

## Step 15: Simulate Skip-Level Upgrade to N+5

Apply the N+5 CRD, which adds v1beta1 and v1 and makes v1 the storage version:

```
$ kubectl apply -f demo/crd-gadget-vN5.yaml
customresourcedefinition.apiextensions.k8s.io/gadgets.demo.example.com configured

$ kubectl get crd gadgets.demo.example.com -o jsonpath='{range .spec.versions[*]}version={.name} served={.served} storage={.storage}{"\n"}{end}'
version=v1alpha1 served=true storage=false
version=v1beta1 served=true storage=false
version=v1 served=true storage=true
```

Before running the migration, the API server already prunes fields on read
according to each version's schema. Reading the **same object** through
different API version endpoints shows progressive field loss:

```
$ kubectl get gadget test-gadget-1 -o json  # via v1alpha1
spec: { "debugMode": true, "internalRef": "ns/configmap-abc", "legacyPort": 8080, "name": "sensor" }

$ kubectl get gadgets.v1beta1.demo.example.com test-gadget-1 -o json
spec: { "internalRef": "ns/configmap-abc", "name": "sensor" }

$ kubectl get gadgets.v1.demo.example.com test-gadget-1 -o json
spec: { "name": "sensor" }
```

> The underlying etcd data is identical in all three cases — only `name` is
> returned through v1 because the v1 schema does not define `debugMode`,
> `legacyPort`, or `internalRef`. The read-time pruning foreshadows what the
> migration will make permanent.

## Step 16: Run the Migration

```
$ kubectl apply -f demo/migration-gadgets.yaml
storageversionmigration.migration.k8s.io/demo-gadget-migration created

$ kubectl get storageversionmigration demo-gadget-migration -o jsonpath='{.status.conditions[?(@.status=="True")].type}'
Succeeded
```

The migrator listed all Gadget objects via the **v1 endpoint**, received them
with only `spec.name` (everything else pruned on read), and PUT them back.
The API server wrote them to etcd as v1.

## Step 17: Diff — All Intermediate Removals Compounded

### test-gadget-1

```diff
 {
-  "apiVersion": "demo.example.com/v1alpha1",
+  "apiVersion": "demo.example.com/v1",
   "kind": "Gadget",
   "metadata": {
     "name": "test-gadget-1",
     "namespace": "default"
   },
   "spec": {
-    "debugMode": true,
-    "internalRef": "ns/configmap-abc",
-    "legacyPort": 8080,
     "name": "sensor"
   }
 }
```

### test-gadget-2

```diff
 {
-  "apiVersion": "demo.example.com/v1alpha1",
+  "apiVersion": "demo.example.com/v1",
   "kind": "Gadget",
   "metadata": {
     "name": "test-gadget-2",
     "namespace": "default"
   },
   "spec": {
-    "debugMode": false,
-    "internalRef": "ns/configmap-def",
-    "legacyPort": 9090,
     "name": "actuator"
   }
 }
```

Three fields removed in a single migration:

| Field | Removed in | Would have been pruned at |
|---|---|---|
| `debugMode` | N+2 (v1beta1 added) | Incremental migration N → N+2 |
| `legacyPort` | N+3 (removed from v1beta1) | Incremental migration N+2 → N+3 |
| `internalRef` | N+4 (v1 added) | Incremental migration N+3 → N+4 |

With an incremental upgrade path, a user would have had the opportunity to
observe and react to each field removal individually. With the skip-level
upgrade, all three are gone at once.

## Incremental vs Skip-Level: What's Different?

The **end state is identical** — after a full upgrade from N to N+5, the same
fields are gone regardless of the path taken. The difference is **when** the
data loss occurs and whether the user has visibility into it:

| Upgrade path | Migrations | Data loss pattern |
|---|---|---|
| N → N+1 → N+2 → ... → N+5 | One per storage version change | Gradual: one field per migration, observable at each step |
| N → N+5 | Single migration | All at once: three fields gone in one operation |

The risk with skip-level upgrades is that fields which could have been
preserved or migrated to new locations during intermediate steps are silently
dropped in bulk. If a conversion webhook at N+2 would have mapped `debugMode`
to a new field, that mapping never runs when you skip from N to N+5 — the
data is simply gone.

> Skip-level upgrades compound the data loss of every intermediate storage
> version migration into a single operation. The migrator has no knowledge of
> the intermediate versions — it only sees the current schema at the target
> version.
