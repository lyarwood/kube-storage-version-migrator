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
