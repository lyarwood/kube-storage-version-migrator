# Part 5: KubeVirt — Real-World Skip-Level Upgrade Risks

Parts 1–4 demonstrated field pruning mechanics using synthetic CRDs. This part
applies the same analysis to the [KubeVirt](https://kubevirt.io/) project,
examining its last five releases (v1.4.0 – v1.8.0) for risks that match the
patterns shown earlier.

## KubeVirt Does Not Use Conversion Webhooks

Every KubeVirt CRD sets `Strategy: NoneConverter`:

```go
// pkg/virt-operator/resource/generate/components/crds.go
Conversion: &extv1.CustomResourceConversion{
    Strategy: extv1.NoneConverter,
},
```

This appears 10 times — for VirtualMachineSnapshot, VirtualMachineSnapshotContent,
VirtualMachineRestore, VirtualMachineInstancetype, VirtualMachineClusterInstancetype,
VirtualMachinePreference, VirtualMachineClusterPreference, and the export CRDs.

The VirtualMachineClone CRD omits the `Conversion` field entirely (defaulting
to None).

This means KubeVirt is exposed to a **variant of the Part 4 scenario**: there
is no webhook to bypass during a skip-level upgrade because **there was never a
webhook to begin with**. Field restructuring relies on application-level Go
code in virt-controller rather than Kubernetes conversion webhooks. That code
runs when virt-controller processes objects at runtime — not during storage
version migration. So the migrator can only prune fields, never convert them.

## Risks Identified Across v1.4.0 – v1.8.0

### 1. Instancetype API v1alpha1/v1alpha2 Removal

**Versions affected:** v1.6.0 (stopped serving), v1.7.0 (fully removed)

| Release | Change |
|---|---|
| v1.6.0 | v1alpha1 and v1alpha2 stopped being served (`Served: false`) |
| v1.7.0 | v1alpha1 and v1alpha2 removed from the CRD entirely |

Today only v1beta1 exists in the instancetype CRD.

**Application-level conversion existed** — Go functions in
`pkg/instancetype/compatibility/` could decode v1alpha1/v1alpha2
ControllerRevisions and convert them to v1beta1 at runtime. But this
conversion only ran when virt-controller processed a VM referencing those
revisions. It was never wired as a Kubernetes conversion webhook.

**Skip-level risk:** A user upgrading from v1.4.0 (v1alpha1 as storage)
directly to v1.7.0+ would find that v1alpha1 is no longer served by the CRD.
Any objects still stored in v1alpha1 encoding in etcd would become
inaccessible — the API server cannot serve a version that is no longer in the
CRD spec. This is worse than pruning: the data isn't lost from etcd, but it
cannot be read or written through the API.

**Mitigation:** KubeVirt's upgrade handler (`pkg/instancetype/upgrade/handler.go`)
upgrades ControllerRevisions to v1beta1 at runtime, so VMs that have been
reconciled by virt-controller before the upgrade would already have their
revisions converted. The risk is for objects that were never reconciled.

### 2. PreferredUseEfi / PreferredUseSecureBoot → PreferredEfi

**Versions affected:** v1.4.0+ (deprecated), planned removal in v1beta2 or v1

This is the clearest Part 4 analogue in KubeVirt. The field is not just
removed — it is being **replaced with a structured alternative**:

```go
// staging/src/kubevirt.io/api/instancetype/v1beta1/types.go

// Deprecated: Will be removed with v1beta2 or v1
DeprecatedPreferredUseEfi *bool `json:"preferredUseEfi,omitempty"`

// Deprecated: Will be removed with v1beta2 or v1
DeprecatedPreferredUseSecureBoot *bool `json:"preferredUseSecureBoot,omitempty"`

PreferredEfi *v1.EFI `json:"preferredEfi,omitempty"`
```

The old fields are booleans (`preferredUseEfi: true`). The replacement is a
structured object (`preferredEfi: {secureBoot: true}`).

**What happens when the deprecated fields are removed:**

Without a conversion webhook, the storage version migration will prune
`preferredUseEfi` and `preferredUseSecureBoot` from etcd but will **not**
populate `preferredEfi`. This is identical to the Part 4 demo:

| | With conversion (hypothetical) | Without conversion (actual) |
|---|---|---|
| `preferredUseEfi: true` | Converted to `preferredEfi: {secureBoot: false}` | Pruned |
| `preferredUseSecureBoot: true` | Converted to `preferredEfi: {secureBoot: true}` | Pruned |
| `preferredEfi` after migration | Populated | **Missing** |
| **EFI boot configuration** | Preserved | **Lost** |

VMs referencing affected preference objects would silently lose their EFI boot
configuration. The VM would still boot — but potentially with BIOS instead of
EFI, which could cause boot failures or security policy violations.

### 3. Snapshot Indications → SourceIndications

**Versions affected:** current (deprecated, not yet removed)

```go
// staging/src/kubevirt.io/api/snapshot/v1beta1/types.go

// Deprecated: Use SourceIndications instead. This field will be removed in a future version.
Indications []Indication `json:"indications,omitempty"`

SourceIndications []SourceIndication `json:"sourceIndications,omitempty"`
```

The old field is a flat list of indication strings. The replacement is a
structured list that pairs each indication with a description message.

**When `Indications` is removed:** Snapshots that only have `Indications`
populated (created before the introduction of `SourceIndications`) will have
that field pruned. `SourceIndications` will not be populated because no
conversion webhook exists to map the old values to the new structured format.
Tooling or controllers that rely on `SourceIndications` will see an empty list.

### 4. Clone API v1alpha1 → v1beta1

**Versions affected:** v1.5.0+ (v1beta1 introduced, v1alpha1 still served)

```go
// pkg/virt-operator/resource/generate/components/crds.go

Versions: []extv1.CustomResourceDefinitionVersion{
    {
        Name:    "v1alpha1",
        Served:  true,
        Storage: false,
    },
    {
        Name:    "v1beta1",
        Served:  true,
        Storage: true,
    },
},
```

Both versions are still served. The clone CRD notably has **no `Conversion`
field at all** — not even an explicit `NoneConverter`.

**When v1alpha1 is eventually removed:** Any clone objects still stored as
v1alpha1 in etcd become inaccessible, as with the instancetype case. A storage
version migration should be run before the version is dropped, but since there
is no conversion webhook, any fields present in v1alpha1 but absent from
v1beta1 would be pruned rather than converted.

## The Application-Level Conversion Pattern

KubeVirt uses a pattern that is distinct from conversion webhooks:

```
                  ┌─────────────┐
                  │   etcd      │
                  │ (v1alpha1)  │
                  └──────┬──────┘
                         │
                    API server
                  (None conversion,
                   schema pruning)
                         │
              ┌──────────┴──────────┐
              │                     │
     ┌────────▼────────┐   ┌───────▼────────┐
     │  virt-controller │   │    migrator     │
     │  (Go conversion) │   │  (no conversion)│
     │  Can transform   │   │  Can only prune │
     │  fields at       │   │  fields via API │
     │  runtime         │   │  server schema  │
     └─────────────────┘   └────────────────┘
```

The Go conversion code in `pkg/instancetype/compatibility/` and
`pkg/instancetype/upgrade/` can transform objects between API versions:

```go
// pkg/instancetype/compatibility/compatibility.go
decodedObj, err := runtime.Decode(
    generatedscheme.Codecs.UniversalDeserializer(),
    revision.Data.Raw,
)
```

This uses the internal Go type scheme to convert old versions to v1beta1. But
this conversion only runs when:

1. virt-controller reconciles a VM that references instancetype/preference
   ControllerRevisions
2. The upgrade handler (`pkg/instancetype/upgrade/handler.go`) is called during
   the VM sync loop

It does **not** run during storage version migration. The migrator uses the
Kubernetes dynamic client and goes through the API server, which applies schema
pruning — not Go-level conversion.

## Key Concern

The gap between application-level conversion and storage-level migration
creates a window for data loss:

1. **Before upgrade:** Objects stored as v1alpha1/v1alpha2 with old field shapes
2. **During upgrade:** virt-controller reconciles VMs and converts
   ControllerRevisions at runtime — but only for VMs it touches
3. **Storage migration runs:** The migrator rewrites all objects through the API
   server, pruning fields not in the new schema — regardless of whether
   virt-controller has had a chance to convert them

If step 3 runs before step 2 has completed for all objects, data is lost for
the objects that virt-controller hasn't reached yet.

For the `PreferredUseEfi` → `PreferredEfi` transition, this is especially
concerning because preference objects are standalone CRs (not embedded in
ControllerRevisions), so the application-level conversion pattern doesn't
apply to them at all. When those deprecated fields are removed from the schema,
the only thing that could preserve the data is a conversion webhook — which
KubeVirt does not have.
