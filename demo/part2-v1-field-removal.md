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
