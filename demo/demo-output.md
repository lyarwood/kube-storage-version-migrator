# Storage Version Migration Demo: Field Pruning in etcd

This document walks through a live demonstration of how
`kube-storage-version-migrator` rewrites objects in etcd when the storage
version of a CRD changes, and how fields removed from the new version's schema
are permanently pruned from storage.

## Background

The `kube-storage-version-migrator` performs a no-op GET + PUT for every
instance of a resource. It does not modify the object itself. However, because
the PUT goes through the API server's validation and serialization pipeline, the
API server applies schema pruning for the target version, silently dropping any
fields that are not defined in that version's structural schema.

## Setup

### CRD Definition

The demo uses a `Foo` CRD (`demo.example.com`) with two versions:

- **v1alpha1** -- has `spec.name` (string) and `spec.bar` (string)
- **v1beta1** -- has `spec.name` (string) only, `spec.bar` is not defined

The CRD uses `None` conversion strategy (no webhook required). Both versions
are served, so clients can read/write via either endpoint.

### Cluster

A kind cluster running Kubernetes v1.30.0:

```
$ kubectl get nodes -o wide
NAME                     STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION            CONTAINER-RUNTIME
svm-demo-control-plane   Ready    control-plane   84s   v1.30.0   10.89.0.5     <none>        Debian GNU/Linux 12 (bookworm)   6.19.10-200.fc43.x86_64   containerd://1.7.15
```

## Step 1: Install CRDs

Install the `StorageVersionMigration` CRD (from this project) and the demo
`Foo` CRD with **v1alpha1 as the storage version**:

```
$ kubectl apply -f manifests/storage_migration_crd.yaml -f manifests/storage_state_crd.yaml
customresourcedefinition.apiextensions.k8s.io/storageversionmigrations.migration.k8s.io created
customresourcedefinition.apiextensions.k8s.io/storagestates.migration.k8s.io created

$ kubectl apply -f demo/crd-v1alpha1-storage.yaml
customresourcedefinition.apiextensions.k8s.io/foos.demo.example.com created
```

Confirm the version layout -- v1alpha1 is the storage version:

```
$ kubectl get crd foos.demo.example.com -o jsonpath='{range .spec.versions[*]}version={.name} served={.served} storage={.storage}{"\n"}{end}'
version=v1alpha1 served=true storage=true
version=v1beta1 served=true storage=false
```

## Step 2: Create Sample Objects

Create three `Foo` objects via the v1alpha1 endpoint, each with `spec.bar` set:

```
$ kubectl apply -f demo/sample-foos.yaml
foo.demo.example.com/test-foo-1 created
foo.demo.example.com/test-foo-2 created
foo.demo.example.com/test-foo-3 created

$ kubectl get foos.v1alpha1.demo.example.com -o custom-columns='NAME:.metadata.name,SPEC.NAME:.spec.name,SPEC.BAR:.spec.bar'
NAME         SPEC.NAME   SPEC.BAR
test-foo-1   first       this-should-be-dropped
test-foo-2   second      this-too
test-foo-3   third       and-this
```

## Step 3: Snapshot etcd (Before Migration)

Read the raw JSON stored in etcd for each object using `etcdctl`. Volatile
metadata fields (`resourceVersion`, `uid`, `managedFields`, etc.) are stripped
for readability -- the remaining JSON is exactly what the API server persisted.

**test-foo-1.json:**
```json
{
  "apiVersion": "demo.example.com/v1alpha1",
  "kind": "Foo",
  "metadata": {
    "name": "test-foo-1",
    "namespace": "default"
  },
  "spec": {
    "bar": "this-should-be-dropped",
    "name": "first"
  }
}
```

**test-foo-2.json:**
```json
{
  "apiVersion": "demo.example.com/v1alpha1",
  "kind": "Foo",
  "metadata": {
    "name": "test-foo-2",
    "namespace": "default"
  },
  "spec": {
    "bar": "this-too",
    "name": "second"
  }
}
```

**test-foo-3.json:**
```json
{
  "apiVersion": "demo.example.com/v1alpha1",
  "kind": "Foo",
  "metadata": {
    "name": "test-foo-3",
    "namespace": "default"
  },
  "spec": {
    "bar": "and-this",
    "name": "third"
  }
}
```

> All three objects are stored as `v1alpha1` and include `spec.bar`.

## Step 4: Switch Storage Version to v1beta1

Update the CRD so that `v1beta1` becomes the storage version. This tells the
API server to encode any **new writes** as v1beta1, but existing objects in etcd
are **not touched** -- they remain in their original v1alpha1 encoding.

```
$ kubectl apply -f demo/crd-v1beta1-storage.yaml
customresourcedefinition.apiextensions.k8s.io/foos.demo.example.com configured

$ kubectl get crd foos.demo.example.com -o jsonpath='{range .spec.versions[*]}version={.name} served={.served} storage={.storage}{"\n"}{end}'
version=v1alpha1 served=true storage=false
version=v1beta1 served=true storage=true
```

Verify that etcd is still unchanged -- the objects are still v1alpha1 with `bar`
present:

```
apiVersion: demo.example.com/v1alpha1
spec.bar: this-should-be-dropped
```

> This is the problem that the storage version migrator solves: old objects
> linger in the previous encoding until something rewrites them.

## Step 5: Run the Migration

Create a `StorageVersionMigration` resource that targets `foos` at `v1beta1`,
then start the migrator:

```
$ kubectl apply -f demo/migration.yaml
storageversionmigration.migration.k8s.io/demo-foo-migration created
```

The migration resource tells the migrator what to do:

```yaml
spec:
  resource:
    group: demo.example.com
    version: v1beta1
    resource: foos
```

The migrator is built from source and run locally against the kind cluster:

```
$ go build -o demo/migrator ./cmd/migrator/
$ demo/migrator --kubeconfig $KUBECONFIG
```

The migrator picks up the `StorageVersionMigration` CR, lists all `Foo` objects
via the `v1beta1` endpoint, and PUTs each one back unchanged. After a few
seconds:

```
$ kubectl get storageversionmigration demo-foo-migration -o jsonpath='{.status.conditions[?(@.status=="True")].type}'
Succeeded
```

## Step 6: Snapshot etcd (After Migration) and Diff

Read the raw etcd data again and diff against the before snapshot.

> Volatile metadata fields are stripped from both snapshots so the diff only
> shows semantically meaningful changes.

### test-foo-1

```diff
 {
-  "apiVersion": "demo.example.com/v1alpha1",
+  "apiVersion": "demo.example.com/v1beta1",
   "kind": "Foo",
   "metadata": {
     "name": "test-foo-1",
     "namespace": "default"
   },
   "spec": {
-    "bar": "this-should-be-dropped",
     "name": "first"
   }
 }
```

### test-foo-2

```diff
 {
-  "apiVersion": "demo.example.com/v1alpha1",
+  "apiVersion": "demo.example.com/v1beta1",
   "kind": "Foo",
   "metadata": {
     "name": "test-foo-2",
     "namespace": "default"
   },
   "spec": {
-    "bar": "this-too",
     "name": "second"
   }
 }
```

### test-foo-3

```diff
 {
-  "apiVersion": "demo.example.com/v1alpha1",
+  "apiVersion": "demo.example.com/v1beta1",
   "kind": "Foo",
   "metadata": {
     "name": "test-foo-3",
     "namespace": "default"
   },
   "spec": {
-    "bar": "and-this",
     "name": "third"
   }
 }
```

Each object has exactly two changes:

1. **`apiVersion`** changed from `v1alpha1` to `v1beta1` -- the object is now
   stored in the new encoding.
2. **`spec.bar`** was removed -- the API server's structural schema pruning
   silently dropped the field on the PUT because `bar` is not defined in the
   v1beta1 schema.

## Step 7: Verify via the API Server

After migration, the `bar` field is gone from both API endpoints:

```
$ kubectl get foos.v1alpha1.demo.example.com -o custom-columns='NAME:.metadata.name,SPEC.NAME:.spec.name,SPEC.BAR:.spec.bar'
NAME         SPEC.NAME   SPEC.BAR
test-foo-1   first       <none>
test-foo-2   second      <none>
test-foo-3   third       <none>

$ kubectl get foos.v1beta1.demo.example.com -o custom-columns='NAME:.metadata.name,SPEC.NAME:.spec.name'
NAME         SPEC.NAME
test-foo-1   first
test-foo-2   second
test-foo-3   third
```

> Even reading through the v1alpha1 endpoint returns `<none>` for `bar` --
> the data no longer exists in etcd, so there is nothing to serve regardless
> of which version the client requests.

## How It Works

The migrator itself is simple (`pkg/migrator/core.go`):

1. **List** all objects using the target GVR (v1beta1) in chunks of 500
2. For each object, **PUT** it back to the API server unchanged

The migrator uses a dynamic client with `unstructured.Unstructured` objects --
it treats everything as opaque JSON and never modifies a single field. The field
pruning happens entirely in the API server:

- On **GET**: the API server reads the raw bytes from etcd, applies the
  structural schema for the requested version, and prunes any fields not
  defined in that schema. So the response to the migrator already omits `bar`.
- On **PUT**: the API server writes the object (now without `bar`) to etcd in
  the new storage version encoding.

This means the storage version migrator can cause **permanent data loss** for
fields that exist in the old version but not in the new one. This is by design
-- the migration rewrites every object through the API server's full
serialization pipeline, and schema pruning is part of that pipeline.

---

# Part 2: Removing a Field from a Single-Version v1 CRD

Part 1 showed what happens during a storage version migration across API
versions. But what if a field is simply removed from a CRD that only has a
single version (e.g. `v1`)? There is no storage version change, so the migrator
is not involved.

## Setup

The demo uses a `Widget` CRD (`demo.example.com`) with a single version:

- **v1** -- initially has `spec.name` (string) and `spec.baz` (string)

## Step 8: Create Widget CRD and Objects

Install the Widget CRD with `baz` in the schema and create three objects:

```
$ kubectl apply -f demo/crd-v1-with-baz.yaml
customresourcedefinition.apiextensions.k8s.io/widgets.demo.example.com created

$ kubectl apply -f demo/sample-widgets.yaml
widget.demo.example.com/test-widget-1 created
widget.demo.example.com/test-widget-2 created
widget.demo.example.com/test-widget-3 created

$ kubectl get widgets -o custom-columns='NAME:.metadata.name,SPEC.NAME:.spec.name,SPEC.BAZ:.spec.baz'
NAME            SPEC.NAME   SPEC.BAZ
test-widget-1   first       this-should-survive
test-widget-2   second      so-should-this
test-widget-3   third       and-this
```

## Step 9: Snapshot etcd (Before Schema Change)

**test-widget-1.json:**
```json
{
  "apiVersion": "demo.example.com/v1",
  "kind": "Widget",
  "metadata": {
    "name": "test-widget-1",
    "namespace": "default"
  },
  "spec": {
    "baz": "this-should-survive",
    "name": "first"
  }
}
```

> All three objects are stored as `v1` and include `spec.baz`.

## Step 10: Remove `baz` from the v1 Schema

Update the CRD to remove `baz` from the v1 schema. This is a schema-only
change — there is no storage version change and the migrator is not involved.

```
$ kubectl apply -f demo/crd-v1-without-baz.yaml
customresourcedefinition.apiextensions.k8s.io/widgets.demo.example.com configured
```

Immediately check etcd — all three objects are **unchanged**:

```
test-widget-1: UNCHANGED
test-widget-2: UNCHANGED
test-widget-3: UNCHANGED
```

> Updating a CRD schema does not rewrite existing objects. The old data
> (including `baz`) remains in etcd byte-for-byte.

However, the API server now prunes `baz` on reads — it no longer appears in
API responses even though it is still stored in etcd:

```
$ kubectl get widgets -o custom-columns='NAME:.metadata.name,SPEC.NAME:.spec.name,SPEC.BAZ:.spec.baz'
NAME            SPEC.NAME   SPEC.BAZ
test-widget-1   first       <none>
test-widget-2   second      <none>
test-widget-3   third       <none>
```

```
$ kubectl get widget test-widget-1 -o json | jq .spec
{
  "name": "first"
}
```

> The API server applies the structural schema on reads as well as writes.
> `baz` is no longer in the schema, so it is stripped from API responses.
> But the raw bytes in etcd still contain it.

## Step 11: No-op Write on a Single Object

Perform a GET + PUT on `test-widget-1` only — the same operation the migrator
does, but done manually with `kubectl replace`:

```
$ kubectl get widget test-widget-1 -o json | kubectl replace -f -
widget.demo.example.com/test-widget-1 replaced
```

Since the GET already omits `baz` (pruned by the API server on read), the
PUT writes the object back without it, and `baz` is now gone from etcd for
that one object.

## Step 12: Diff — Only the Written Object Lost `baz`

```
--- test-widget-1 ---
```
```diff
   "spec": {
-    "baz": "this-should-survive",
     "name": "first"
   }
```
```
--- test-widget-2 ---
(no changes — object was not rewritten)

--- test-widget-3 ---
(no changes — object was not rewritten)
```

Only `test-widget-1` was affected. The other two objects still have `baz` in
etcd — it will remain there until something writes to those objects (a
controller, a user edit, or a future migration).

## Key Takeaways

| Scenario | What removes the field from etcd? |
|---|---|
| Storage version change (v1alpha1 → v1beta1) | The **migrator** rewrites every object, triggering API server pruning on all of them at once |
| Field removed from a single-version CRD (v1) | **Nothing automatic** — each object is only pruned when it is next written by any client |

In both cases the mechanism is the same: the API server's structural schema
pruning drops unknown fields during writes. The difference is whether something
triggers a write on every object (the migrator) or whether writes happen
organically over time (controllers, users).

> A field removed from a v1 CRD schema becomes invisible through the API
> immediately (pruned on read), but the data persists in etcd as a ghost until
> something rewrites the object.

---

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

---

# Part 4: Conversion Webhooks — When Skip-Level Upgrades Lose Data

Part 3 showed that skip-level upgrades drop removed fields in bulk. But those
fields were simply deleted — there was no replacement. In practice, CRD
upgrades often **rename or restructure** fields, with a conversion webhook
handling the transformation. A skip-level upgrade that bypasses the webhook
loses data that an incremental upgrade would have preserved.

## Scenario

A `Converter` CRD evolves across cluster versions:

| Cluster version | What changes | Conversion | Storage |
|---|---|---|---|
| **N** | v1alpha1 introduced with `spec.legacyPort` (integer) | None | v1alpha1 |
| **N+2** | v1beta1 added with `spec.portConfig.port` and `spec.portConfig.protocol`. A **webhook** converts `legacyPort: 8080` → `portConfig: {port: 8080, protocol: "TCP"}` | Webhook | v1beta1 |
| **N+5** | v1 added (same schema as v1beta1). Webhook removed — v1alpha1 no longer expected in etcd | None | v1 |

The conversion webhook is the key. It doesn't just drop a field — it
**transforms** it into a new shape. But the webhook only exists in N+2 through
N+4. By N+5 it has been removed.

## Phase A: Incremental Upgrade (N → N+2) — Data Preserved

### Setup

A conversion webhook is deployed in the cluster. It handles `ConversionReview`
requests and maps `legacyPort` to/from `portConfig`:

```
$ kubectl apply -f demo/webhook-deployment.yaml
deployment.apps/converter-webhook created
service/converter-webhook created
```

The Converter CRD starts at version N (v1alpha1 only, None conversion):

```
$ kubectl apply -f demo/crd-converter-vN.yaml
customresourcedefinition.apiextensions.k8s.io/converters.demo.example.com created

$ kubectl apply -f demo/sample-converters.yaml
converter.demo.example.com/test-converter-1 created
converter.demo.example.com/test-converter-2 created
```

**etcd before:**
```json
{
  "apiVersion": "demo.example.com/v1alpha1",
  "kind": "Converter",
  "metadata": {
    "name": "test-converter-1",
    "namespace": "default"
  },
  "spec": {
    "legacyPort": 8080,
    "name": "webserver"
  }
}
```

### Incremental Upgrade to N+2

Apply the N+2 CRD (v1beta1 as storage, webhook conversion) and migrate:

```
$ kubectl apply -f demo/crd-converter-vN2.yaml  # with caBundle injected
customresourcedefinition.apiextensions.k8s.io/converters.demo.example.com configured

$ kubectl apply -f demo/migration-converters-v1beta1.yaml
storageversionmigration.migration.k8s.io/demo-converter-migration-v1beta1 created

$ kubectl get storageversionmigration demo-converter-migration-v1beta1 -o jsonpath='{.status.conditions[?(@.status=="True")].type}'
Succeeded
```

### Diff — Webhook Converts legacyPort to portConfig

```diff
 {
-  "apiVersion": "demo.example.com/v1alpha1",
+  "apiVersion": "demo.example.com/v1beta1",
   "kind": "Converter",
   "metadata": {
     "name": "test-converter-1",
     "namespace": "default"
   },
   "spec": {
-    "legacyPort": 8080,
-    "name": "webserver"
+    "name": "webserver",
+    "portConfig": {
+      "port": 8080,
+      "protocol": "TCP"
+    }
   }
 }
```

```diff
 {
-  "apiVersion": "demo.example.com/v1alpha1",
+  "apiVersion": "demo.example.com/v1beta1",
   "kind": "Converter",
   "metadata": {
     "name": "test-converter-2",
     "namespace": "default"
   },
   "spec": {
-    "legacyPort": 9090,
-    "name": "api-gateway"
+    "name": "api-gateway",
+    "portConfig": {
+      "port": 9090,
+      "protocol": "TCP"
+    }
   }
 }
```

> The webhook ran during the migration and converted `legacyPort: 8080` into
> `portConfig: {port: 8080, protocol: "TCP"}`. The data is preserved — it
> moved from one field to another. Port 8080 is now in `portConfig.port`.

## Phase B: Skip-Level Upgrade (N → N+5) — Data Lost

### Setup

Fresh start: the converter objects are recreated at v1alpha1, and the webhook
is **removed** to simulate a skip-level upgrade where the webhook no longer
ships with the cluster.

```
$ kubectl delete converters --all
$ kubectl delete deployment converter-webhook
$ kubectl delete service converter-webhook
```

The CRD is reverted to version N and new objects are created:

```
$ kubectl apply -f demo/crd-converter-vN.yaml
$ kubectl apply -f demo/sample-converters.yaml
converter.demo.example.com/test-converter-1 created
converter.demo.example.com/test-converter-2 created
```

**etcd before (identical to Phase A starting point):**
```json
{
  "apiVersion": "demo.example.com/v1alpha1",
  "spec": {
    "legacyPort": 8080,
    "name": "webserver"
  }
}
```

### Skip to N+5

Apply the N+5 CRD (v1 as storage, `None` conversion — no webhook):

```
$ kubectl apply -f demo/crd-converter-vN5.yaml
customresourcedefinition.apiextensions.k8s.io/converters.demo.example.com configured

$ kubectl apply -f demo/migration-converters-v1.yaml
storageversionmigration.migration.k8s.io/demo-converter-migration-v1 created

$ kubectl get storageversionmigration demo-converter-migration-v1 -o jsonpath='{.status.conditions[?(@.status=="True")].type}'
Succeeded
```

### Diff — legacyPort Pruned, portConfig Never Populated

```diff
 {
-  "apiVersion": "demo.example.com/v1alpha1",
+  "apiVersion": "demo.example.com/v1",
   "kind": "Converter",
   "metadata": {
     "name": "test-converter-1",
     "namespace": "default"
   },
   "spec": {
-    "legacyPort": 8080,
     "name": "webserver"
   }
 }
```

```diff
 {
-  "apiVersion": "demo.example.com/v1alpha1",
+  "apiVersion": "demo.example.com/v1",
   "kind": "Converter",
   "metadata": {
     "name": "test-converter-2",
     "namespace": "default"
   },
   "spec": {
-    "legacyPort": 9090,
     "name": "api-gateway"
   }
 }
```

> `legacyPort` was pruned (not in v1 schema) and `portConfig` was **never
> populated** (no webhook to convert). The port configuration is permanently
> lost. Compare this to Phase A where the same starting data was successfully
> converted to `portConfig`.

## Side-by-Side Comparison

Starting from the same etcd state (`legacyPort: 8080`):

| | Phase A: Incremental (N → N+2) | Phase B: Skip-level (N → N+5) |
|---|---|---|
| **Webhook** | Running | Removed |
| **Conversion** | `legacyPort` → `portConfig` | None |
| **`legacyPort` after migration** | Removed (converted) | Removed (pruned) |
| **`portConfig` after migration** | `{port: 8080, protocol: "TCP"}` | Missing |
| **Data preserved?** | Yes — transformed to new shape | **No — permanently lost** |

## Key Takeaway

The conversion webhook is the mechanism that bridges old and new field
schemas. Without it, the API server can only prune unknown fields — it
cannot populate new fields from old ones. Skip-level upgrades that bypass
intermediate conversion webhooks cause **silent, irrecoverable data loss**
for any fields that were restructured (not just removed) during the skipped
versions.

> The migrator does not convert data. The webhook does. If the webhook is
> gone, the conversion never happens.
