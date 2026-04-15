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

- On **GET**: the API server reads the v1alpha1 bytes from etcd and serves them
  as-is with the apiVersion swapped to v1beta1 (no conversion with `None`
  strategy). The `bar` field is still present in the response because pruning
  does not happen on reads.
- On **PUT**: the API server validates the incoming object against the v1beta1
  structural schema. `bar` is unknown in v1beta1, so it is silently pruned.
  The object is then written to etcd in v1beta1 encoding without `bar`.

This means the storage version migrator can cause **permanent data loss** for
fields that exist in the old version but not in the new one. This is by design
-- the migration rewrites every object through the API server's full
serialization pipeline, and schema pruning is part of that pipeline.
