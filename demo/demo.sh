#!/usr/bin/env bash

# Demonstrates that kube-storage-version-migrator rewrites objects in etcd
# through the API server's conversion pipeline, which prunes fields that
# are not present in the new storage version's schema.
#
# Requirements: kind, kubectl, go, python3, container runtime (podman or docker)
#
# Set KIND_EXPERIMENTAL_PROVIDER=podman if using podman instead of docker.
#
# What this does:
#   1. Creates a kind cluster
#   2. Installs the StorageVersionMigration CRD
#   3. Installs a demo CRD (Foo) with v1alpha1 (has field "bar") as storage
#   4. Creates sample Foo objects with "bar" set
#   5. Snapshots raw etcd data
#   6. Switches storage to v1beta1 (no "bar" in schema)
#   7. Runs the migrator
#   8. Snapshots raw etcd data again and diffs against the before snapshot

set -o errexit
set -o nounset
set -o pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${DEMO_DIR}/.."
CLUSTER_NAME="svm-demo"
KUBECONFIG_PATH=""
DIFF_DIR=""

# -- helpers --

info()  { echo "==> $*"; }
error() { echo "ERROR: $*" >&2; exit 1; }

etcdctl_get() {
  local key="$1"
  kubectl exec -n kube-system etcd-"${CLUSTER_NAME}"-control-plane -- \
    etcdctl \
      --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key \
      get "$key" --print-value-only 2>/dev/null
}

etcdctl_get_prefix() {
  local prefix="$1"
  kubectl exec -n kube-system etcd-"${CLUSTER_NAME}"-control-plane -- \
    etcdctl \
      --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key \
      get "$prefix" --prefix --keys-only 2>/dev/null
}

# Dump a single etcd key as pretty-printed JSON, stripping volatile fields
# (resourceVersion, generation, managedFields, last-applied-configuration,
# uid, creationTimestamp) so that the diff only shows meaningful changes.
dump_etcd_json() {
  local key="$1"
  local out="$2"
  etcdctl_get "$key" \
    | strings \
    | python3 -c '
import json, sys
obj = json.load(sys.stdin)
meta = obj.get("metadata", {})
for f in ["resourceVersion", "generation", "uid", "creationTimestamp", "managedFields"]:
    meta.pop(f, None)
annotations = meta.get("annotations", {})
annotations.pop("kubectl.kubernetes.io/last-applied-configuration", None)
if not annotations:
    meta.pop("annotations", None)
json.dump(obj, sys.stdout, indent=2, sort_keys=True)
print()
' > "$out"
}

wait_for_migration() {
  local name="$1"
  local timeout="${2:-120}"
  info "Waiting for migration ${name} to complete (timeout: ${timeout}s)..."
  local elapsed=0
  while [ $elapsed -lt "$timeout" ]; do
    local status
    status=$(kubectl get storageversionmigration "$name" \
      -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)
    case "$status" in
      *Succeeded*)
        info "Migration succeeded"
        return 0
        ;;
      *Failed*)
        error "Migration failed: $(kubectl get storageversionmigration "$name" \
          -o jsonpath='{.status.conditions[?(@.type=="Failed")].message}')"
        ;;
    esac
    sleep 2
    elapsed=$((elapsed + 2))
  done
  error "Migration timed out after ${timeout}s"
}

cleanup() {
  info "Cleaning up kind cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true
  if [ -n "${KUBECONFIG_PATH}" ] && [ -f "${KUBECONFIG_PATH}" ]; then
    rm -f "${KUBECONFIG_PATH}"
  fi
  if [ -n "${DIFF_DIR}" ] && [ -d "${DIFF_DIR}" ]; then
    rm -rf "${DIFF_DIR}"
  fi
  rm -f "${DEMO_DIR}/migrator"
}

# -- preflight --

for cmd in kind kubectl go python3; do
  command -v "$cmd" >/dev/null 2>&1 || error "'$cmd' is required but not found"
done

trap cleanup EXIT

DIFF_DIR=$(mktemp -d "${TMPDIR:-/tmp}/svm-demo-diff.XXXXXX")
mkdir -p "${DIFF_DIR}/before" "${DIFF_DIR}/after"

# -- step 1: create kind cluster --

info "Creating kind cluster '${CLUSTER_NAME}'..."
KUBECONFIG_PATH=$(mktemp "${TMPDIR:-/tmp}/svm-demo-kubeconfig.XXXXXX")
kind create cluster --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_PATH}" --wait 60s
export KUBECONFIG="${KUBECONFIG_PATH}"

info "Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s

# -- step 2: install StorageVersionMigration CRD + RBAC --

info "Installing StorageVersionMigration CRD..."
kubectl apply -f "${PROJECT_ROOT}/manifests/storage_migration_crd.yaml"
kubectl apply -f "${PROJECT_ROOT}/manifests/storage_state_crd.yaml"

# -- step 3: install demo CRD with v1alpha1 as storage --

info "Installing demo CRD (v1alpha1 as storage, has field 'bar')..."
kubectl apply -f "${DEMO_DIR}/crd-v1alpha1-storage.yaml"
kubectl wait --for=condition=Established crd foos.demo.example.com --timeout=30s

# -- step 4: create sample objects --

info "Creating sample Foo objects with 'bar' field set..."
kubectl apply -f "${DEMO_DIR}/sample-foos.yaml"

# -- step 5: snapshot raw etcd data (before) --

info "Snapshotting raw etcd data (before migration)..."
ETCD_PREFIX="/registry/demo.example.com/foos/default"
for key in $(etcdctl_get_prefix "${ETCD_PREFIX}" | grep -v '^$'); do
  name=$(basename "$key")
  dump_etcd_json "$key" "${DIFF_DIR}/before/${name}.json"
  info "  captured ${name}"
done

# -- step 6: switch storage to v1beta1 --

info "Switching CRD storage version to v1beta1 (no 'bar' in schema)..."
kubectl apply -f "${DEMO_DIR}/crd-v1beta1-storage.yaml"
sleep 2

# -- step 7: build and run the migrator --

info "Building the migrator..."
(cd "${PROJECT_ROOT}" && go build -o "${DEMO_DIR}/migrator" ./cmd/migrator/)

info "Creating StorageVersionMigration resource..."
kubectl apply -f "${DEMO_DIR}/migration.yaml"

info "Starting migrator (runs locally against the kind cluster)..."
timeout 60 "${DEMO_DIR}/migrator" --kubeconfig "${KUBECONFIG_PATH}" &
MIGRATOR_PID=$!

# Give the migrator a moment to pick up the migration CR
sleep 3

wait_for_migration "demo-foo-migration"

# Stop the migrator
kill $MIGRATOR_PID 2>/dev/null || true
wait $MIGRATOR_PID 2>/dev/null || true

# -- step 8: snapshot raw etcd data (after) and diff --

info "Snapshotting raw etcd data (after migration)..."
for key in $(etcdctl_get_prefix "${ETCD_PREFIX}" | grep -v '^$'); do
  name=$(basename "$key")
  dump_etcd_json "$key" "${DIFF_DIR}/after/${name}.json"
  info "  captured ${name}"
done

info ""
info "=========================================="
info "  etcd diff (before vs after migration)"
info "=========================================="
info ""

for before_file in "${DIFF_DIR}/before/"*.json; do
  name=$(basename "$before_file")
  after_file="${DIFF_DIR}/after/${name}"
  if [ ! -f "$after_file" ]; then
    info "${name}: DELETED from etcd"
    continue
  fi
  echo "--- ${name} ---"
  diff --unified --color=always "$before_file" "$after_file" || true
  echo ""
done

info ""
info "Demo complete. The 'bar' field has been pruned from etcd by the"
info "storage version migration. The API server's schema pruning removed"
info "the field during the migrator's no-op PUT through the v1beta1 endpoint."

# cleanup via trap
