# Part 5: KubeVirt Skip-Level Upgrade Risk Analysis

## Context

[VIRTSTRAT-627](https://redhat.atlassian.net/browse/VIRTSTRAT-627) tracks
EUS-to-EUS upgrade support from OCP 4.22/4.23 to OCP 5.2. This is an N+3
skip-level upgrade for the KubeVirt operator:

| OCP | KubeVirt | Role |
|---|---|---|
| 4.22 | 1.8 | Starting EUS release |
| 4.23 / 5.0 | 1.9 | Skipped (bridge release) |
| 5.1 | 1.10 | Skipped |
| 5.2 | 1.11 | Target EUS release |

Parts 1–4 of this demo showed that storage version migration prunes fields
removed from CRD schemas, and that conversion webhooks are the only mechanism
to transform (rather than drop) fields during migration. This part applies
those findings to KubeVirt, examining what happens to CRD data during the
1.8 → 1.11 jump.

## KubeVirt Does Not Use Conversion Webhooks

Every KubeVirt CRD sets `Strategy: NoneConverter`:

```go
// pkg/virt-operator/resource/generate/components/crds.go
Conversion: &extv1.CustomResourceConversion{
    Strategy: extv1.NoneConverter,
},
```

This appears 10 times across all multi-version CRDs (snapshot,
snapshotcontent, restore, instancetype, clusterinstancetype, preference,
clusterpreference, export). The clone CRD omits the `Conversion` field
entirely, defaulting to None.

This means KubeVirt is exposed to a **variant of the Part 4 scenario**: there
is no webhook to bypass during a skip-level upgrade because there was never a
webhook to begin with. Field restructuring relies entirely on
application-level Go code in virt-controller, which only runs when
virt-controller reconciles objects at runtime — not during storage version
migration.

## Risks Already Present in KubeVirt 1.8

These risks exist today and will compound across the 1.8 → 1.11 jump if
the deprecated fields are removed in any of the intermediate releases.

### PreferredUseEfi / PreferredUseSecureBoot → PreferredEfi

**Status:** Deprecated since v1.4.0, removal planned for v1beta2 or v1.

```go
// staging/src/kubevirt.io/api/instancetype/v1beta1/types.go

// Deprecated: Will be removed with v1beta2 or v1
DeprecatedPreferredUseEfi *bool `json:"preferredUseEfi,omitempty"`

// Deprecated: Will be removed with v1beta2 or v1
DeprecatedPreferredUseSecureBoot *bool `json:"preferredUseSecureBoot,omitempty"`

PreferredEfi *v1.EFI `json:"preferredEfi,omitempty"`
```

The old fields are booleans. The replacement is a structured object. If these
deprecated fields are removed in any release between 1.9 and 1.11, the
skip-level migration will prune `preferredUseEfi` and `preferredUseSecureBoot`
without populating `preferredEfi`. VMs referencing affected preferences would
silently lose their EFI boot configuration.

**This is the highest-risk item for the EUS jump.** Preference objects are
standalone CRs — the application-level ControllerRevision conversion pattern
does not apply to them. Only a conversion webhook could preserve this data
during migration.

| | Incremental (with conversion) | Skip-level (no conversion) |
|---|---|---|
| `preferredUseEfi: true` | → `preferredEfi: {secureBoot: false}` | Pruned |
| `preferredUseSecureBoot: true` | → `preferredEfi: {secureBoot: true}` | Pruned |
| **EFI boot config** | Preserved | **Lost** |

### Deprecated PreferredCPUTopology Constants

**Status:** Deprecated since v1.4.0.

```go
DeprecatedPreferCores   PreferredCPUTopology = "preferCores"
DeprecatedPreferSockets PreferredCPUTopology = "preferSockets"
DeprecatedPreferThreads PreferredCPUTopology = "preferThreads"
DeprecatedPreferSpread  PreferredCPUTopology = "preferSpread"
DeprecatedPreferAny     PreferredCPUTopology = "preferAny"
```

These are enum value renames (e.g., `preferCores` → `cores`). If the old
values are removed from the CRD's OpenAPI validation, stored preference
objects using them would fail validation on write. Lower risk than the EFI
fields since these are value changes, not structural field removals.

### Snapshot Indications → SourceIndications

**Status:** Deprecated, not yet removed.

```go
// staging/src/kubevirt.io/api/snapshot/v1beta1/types.go

// Deprecated: Use SourceIndications instead. This field will be removed in a future version.
Indications []Indication `json:"indications,omitempty"`

SourceIndications []SourceIndication `json:"sourceIndications,omitempty"`
```

The old field is a flat string list. The replacement is a structured list
pairing each indication with a description message. If `Indications` is
removed between 1.9 and 1.11, existing snapshots would lose their indication
data during migration — `SourceIndications` would not be populated.

### Clone API v1alpha1

**Status:** v1alpha1 still served alongside v1beta1 (since v1.5.0).

If v1alpha1 is dropped in any release between 1.9 and 1.11, objects still
stored as v1alpha1 in etcd would be served through v1beta1 with schema
pruning. Currently the JSON schemas are field-identical, so this is low risk
unless fields diverge.

### Pool API v1alpha1

**Status:** v1alpha1 still served alongside v1beta1 (since v1.8.0).

Same situation as clone — currently field-identical, low risk unless schemas
diverge.

## New Risks Identified on main (Targeting 1.9)

Changes already merged to main since v1.8.0 that affect the 1.8 → 1.11 path:

### Export API: v1alpha1 Removed, v1 Added

Already landed on main:
- `d0e650fc4d` — Add `export.kubevirt.io/v1` API group
- `6ec644cce7` — Remove deprecated export v1alpha1 API

The export CRD now has v1beta1 (deprecated, still served) and v1 (storage).
The v1 and v1beta1 schemas have identical JSON field names, so this transition
is safe — no data loss during migration.

However, any objects still stored as v1alpha1 in etcd from before v1.8.0 would
need to have been migrated before this change. If a user skips from a version
where v1alpha1 was storage to 1.9+, those objects would be served through the
v1 endpoint with schema pruning.

### Backup API: Custom Condition → metav1.Condition

Already landed on main:
- `1b0909d8c1` — Replace custom `Condition` type with `metav1.Condition`

The old custom type had a `lastProbeTime` field. The new `metav1.Condition`
does not have `lastProbeTime` but adds `observedGeneration`. The shared fields
(`type`, `status`, `lastTransitionTime`, `reason`, `message`) have identical
JSON names.

```diff
- LastProbeTime metav1.Time `json:"lastProbeTime,omitempty"`    // old, will be pruned
+ ObservedGeneration int64 `json:"observedGeneration,omitempty"` // new, not populated
```

**Risk:** During migration, `lastProbeTime` will be pruned from stored backup
conditions. This is a status field loss, not a spec field loss, so it's lower
severity — but it means historical probe timing data is permanently gone after
migration.

### Snapshot: PartialSnapshot Indication Added

- `745ca9a085` — Add `PartialSnapshot` indication for excluded snapshottable volumes

This is additive (new enum value), not a removal. No risk.

## Review Checklist for 1.9 – 1.11

Each intermediate release (1.9, 1.10, 1.11) should be reviewed for:

### CRD Schema Changes

- [ ] Are any fields removed from CRD schemas?
- [ ] Are any API versions removed from CRDs (`Served: false` or dropped)?
- [ ] Are any API versions added with different field shapes?
- [ ] Does the storage version change for any CRD?
- [ ] Are any deprecated fields finally removed?
- [ ] Are enum values removed from OpenAPI validation?

### Conversion Safety

- [ ] For each removed field: is it simply deleted, or is there a replacement?
- [ ] For each replacement field: is there a conversion webhook or
      application-level code that populates the new field from the old?
- [ ] Does that conversion code run during storage version migration, or only
      at runtime when virt-controller processes the object?
- [ ] Are there standalone CRs (not embedded in ControllerRevisions) that
      would be affected? These cannot rely on virt-controller's upgrade handler.

### Skip-Level Compound Effects

- [ ] What is the cumulative diff between the 1.8 CRD schemas and the 1.11
      CRD schemas? All field removals across 1.9, 1.10, and 1.11 will be
      applied in a single migration.
- [ ] Are any conversion webhooks introduced in intermediate releases and
      then removed before 1.11? (Part 4 scenario — currently not applicable
      since KubeVirt uses `NoneConverter` throughout, but worth checking if
      this changes.)
- [ ] Is the ordering of virt-controller reconciliation vs storage version
      migration guaranteed? If the migrator runs before virt-controller has
      reconciled all objects, application-level conversion will not have
      completed.

### Specific Items to Track

| Item | Risk | When to check | What to look for |
|---|---|---|---|
| `preferredUseEfi` / `preferredUseSecureBoot` removal | **High** | Each release 1.9–1.11 | Field removed from v1beta1 schema |
| `Indications` removal from snapshot API | Medium | Each release 1.9–1.11 | Field removed from v1beta1 schema |
| `PreferredCPUTopology` deprecated enum values | Medium | Each release 1.9–1.11 | Old values removed from OpenAPI validation |
| Clone v1alpha1 removal | Medium | Each release 1.9–1.11 | Version removed from CRD |
| Pool v1alpha1 removal | Medium | Each release 1.9–1.11 | Version removed from CRD |
| Export v1beta1 removal | Low | Each release 1.9–1.11 | Version removed from CRD (schemas are identical) |
| Backup `Condition` type change | Low | 1.9 (already on main) | `lastProbeTime` pruned on migration |
| Any new conversion webhooks | Low | Each release 1.9–1.11 | `NoneConverter` changed to `Webhook` |

## The Application-Level Conversion Gap

KubeVirt's conversion architecture creates a gap that is specific to
skip-level upgrades:

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

The Go conversion code in `pkg/instancetype/compatibility/` can transform
objects between API versions — but only when virt-controller reconciles a VM.
The migrator goes through the API server, which can only prune. If the
migrator runs before virt-controller has processed all objects, data that could
have been converted is instead pruned.

For standalone CRs (preferences, snapshots), virt-controller's upgrade handler
does not apply at all. These objects can only be preserved during migration by
a conversion webhook — which KubeVirt does not have.

## Recommendation

Before the OCP 4.22 → 5.2 EUS upgrade path is certified, the cumulative CRD
schema diff between KubeVirt 1.8 and 1.11 should be audited for any field that
is both **(a)** removed from the schema and **(b)** has a replacement field
that requires conversion logic to populate. Each such field is a data loss risk
during skip-level migration.

For the `PreferredUseEfi` → `PreferredEfi` transition specifically: if these
deprecated fields are removed in any release within the 1.8 → 1.11 window,
either a conversion webhook must be added, or virt-operator must ensure it
populates `preferredEfi` from the deprecated fields before the storage version
migration runs.
