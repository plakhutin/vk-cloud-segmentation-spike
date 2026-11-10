#!/usr/bin/env bash
set -euo pipefail
: "${TF_VARS_JSON:?Set TF_VARS_JSON to the absolute path of the private JSON tfvars file}"
[[ "$TF_VARS_JSON" = /* && -r "$TF_VARS_JSON" ]] || { echo 'TF_VARS_JSON must be an absolute readable file' >&2; exit 1; }
for c in terraform python3; do command -v "$c" >/dev/null || { echo "Missing $c" >&2; exit 1; }; done
: "${OS_AUTH_URL:?Set VK Cloud OS_AUTH_URL}"
: "${OS_PROJECT_ID:?Set VK Cloud OS_PROJECT_ID}"
if [[ -z "${OS_AUTH_TOKEN:-}" ]]; then
  : "${OS_USERNAME:?Set VK Cloud OS_USERNAME}"
  : "${OS_PASSWORD:?Set VK Cloud OS_PASSWORD}"
fi
python3 - "$TF_VARS_JSON" <<'PY'
import ipaddress, json, sys
with open(sys.argv[1], encoding='utf-8') as f: v = json.load(f)
required = ['region','availability_zone','image_id','small_flavor_id','large_flavor_id','volume_type','external_network_id','floating_ip_pool','ssh_public_key','ssh_source_cidr','management_cidr','kubernetes_cidr','database_cidr','lb_backend_source_cidrs']
for k in required:
    x = v.get(k)
    if not x or 'REPLACE' in str(x).upper() or 'SAMPLE' in str(x).upper():
        raise SystemExit(f'Missing or placeholder input: {k}')
if not v['ssh_public_key'].startswith(('ssh-ed25519 ', 'ssh-rsa ', 'ecdsa-sha2-')):
    raise SystemExit('ssh_public_key must be an OpenSSH public key')
try:
    nets = [ipaddress.IPv4Network(v[k], strict=True) for k in ('management_cidr','kubernetes_cidr','database_cidr')]
    fixed = [ipaddress.IPv4Network('10.244.0.0/16'), ipaddress.IPv4Network('10.96.0.0/12')]
    ipaddress.IPv4Network(v['ssh_source_cidr'], strict=True)
    sources = [ipaddress.IPv4Network(c, strict=True) for c in v['lb_backend_source_cidrs']]
except (ValueError, TypeError) as e:
    raise SystemExit(f'Invalid IPv4 CIDR: {e}')
if any(a.overlaps(b) for i,a in enumerate(nets + fixed) for b in (nets + fixed)[i+1:]):
    raise SystemExit('VM, pod and service CIDRs must not overlap')
if not sources or any(s.prefixlen == 0 or s.overlaps(nets[0]) for s in sources):
    raise SystemExit('LB and health source CIDRs must be nonempty and disjoint from management')
PY
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case "${1:-}" in
  plan) terraform -chdir="$ROOT/infra" plan -input=false -var-file="$TF_VARS_JSON" -out="$ROOT/infra/spike.tfplan" ;;
  apply) [[ -r "$ROOT/infra/spike.tfplan" ]] || { echo 'Run plan first' >&2; exit 1; }; terraform -chdir="$ROOT/infra" apply -input=false "$ROOT/infra/spike.tfplan" ;;
  destroy) terraform -chdir="$ROOT/infra" destroy -var-file="$TF_VARS_JSON" ;;
  *) echo "Usage: $0 plan|apply|destroy" >&2; exit 2 ;;
esac
