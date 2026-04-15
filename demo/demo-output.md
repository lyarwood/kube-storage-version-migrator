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
