#!/usr/bin/env python3
"""Render baseline policies and workloads; stdout is a Kubernetes List in JSON."""
import ipaddress
import json
import os
import re
import sys

if len(sys.argv) != 2 or sys.argv[1] not in ('policies', 'apps'):
    sys.exit(f'usage: {sys.argv[0]} policies|apps')
required = ('WORKER_A', 'WORKER_B', 'WORKER_ECHO', 'PG_IP', 'S3_IP', 'EXTERNAL_IP', 'LB_SOURCE_CIDR')
missing = [x for x in required if not os.getenv(x)]
if missing:
    sys.exit('Missing required environment variables: ' + ', '.join(missing))
for name in required[:3]:
    if not re.fullmatch(r'[a-z0-9]([-a-z0-9.]*[a-z0-9])?', os.environ[name]):
        sys.exit(f'Invalid Kubernetes node name: {name}')
try:
    ips = {name: ipaddress.IPv4Address(os.environ[name]) for name in required[3:6]}
    lb = [ipaddress.IPv4Network(x.strip(), strict=True) for x in os.environ['LB_SOURCE_CIDR'].split(',')]
except ValueError as e:
    sys.exit(str(e))
if len(set(ips.values())) != 3:
    sys.exit('PG_IP, S3_IP and EXTERNAL_IP must be distinct')
if any(n.overlaps(ipaddress.IPv4Network('10.244.0.0/16')) or n.prefixlen == 0 for n in lb):
    sys.exit('LB_SOURCE_CIDR must be narrow and must not overlap pod CIDR')
ns = 'segmentation-spike'
def obj(kind, name, spec, api='v1'):
    return {'apiVersion': api, 'kind': kind, 'metadata': {'name': name, 'namespace': ns}, 'spec': spec}
def labels(**kw):
    return {'matchLabels': kw}
def policy(name, spec):
    return obj('NetworkPolicy', name, spec, 'networking.k8s.io/v1')
def port(n, proto='TCP'):
    return {'protocol': proto, 'port': n}
if sys.argv[1] == 'policies':
    items = [{'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {'name': ns}}]
    items += [policy('default-deny', {'podSelector': {}, 'policyTypes': ['Ingress', 'Egress']})]
    items += [policy('dns', {'podSelector': labels(role='client'), 'policyTypes': ['Egress'], 'egress': [{'to': [{'namespaceSelector': labels(**{'kubernetes.io/metadata.name': 'kube-system'}), 'podSelector': labels(**{'k8s-app': 'kube-dns'})}], 'ports': [port(53), port(53, 'UDP')]}]})]
    items += [policy('clients-to-echo', {'podSelector': labels(role='client'), 'policyTypes': ['Egress'], 'egress': [{'to': [{'podSelector': labels(app='echo')}], 'ports': [port(8080)]}]})]
    items += [policy('echo-ingress', {'podSelector': labels(app='echo'), 'policyTypes': ['Ingress'], 'ingress': [{'from': [{'podSelector': labels(client='a')}] + [{'ipBlock': {'cidr': str(n)}} for n in lb], 'ports': [port(8080)]}]})]
    items += [policy('a-egress', {'podSelector': labels(client='a'), 'policyTypes': ['Egress'], 'egress': [{'to': [{'ipBlock': {'cidr': str(ip) + '/32'}}], 'ports': [port(p)]} for ip, p in ((ips['PG_IP'], 5432), (ips['S3_IP'], 443), (ips['EXTERNAL_IP'], 443))]})]
else:
    security = {'runAsNonRoot': True, 'runAsUser': 1000, 'allowPrivilegeEscalation': False, 'capabilities': {'drop': ['ALL']}, 'seccompProfile': {'type': 'RuntimeDefault'}}
    items = []
    for client, node in [('a', os.environ['WORKER_A']), ('b', os.environ['WORKER_B'])]:
        items.append(obj('Pod', client, {'nodeName': node, 'containers': [{'name': 'tools', 'image': 'nicolaka/netshoot:v0.13', 'command': ['sleep', 'infinity'], 'securityContext': security}, {'name': 'postgres', 'image': 'postgres:16.6', 'command': ['sleep', 'infinity'], 'securityContext': security}] }))
        items[-1]['metadata']['labels'] = {'role': 'client', 'client': client}
    items.append(obj('Pod', 'echo', {'nodeName': os.environ['WORKER_ECHO'], 'containers': [{'name': 'echo', 'image': 'nginxinc/nginx-unprivileged:1.27.3', 'ports': [{'containerPort': 8080}], 'readinessProbe': {'httpGet': {'path': '/', 'port': 8080}}, 'securityContext': {**security, 'runAsUser': 101}}]}))
    items[-1]['metadata']['labels'] = {'app': 'echo'}
    items.append(obj('Service', 'echo', {'type': 'NodePort', 'selector': {'app': 'echo'}, 'ports': [{'port': 8080, 'targetPort': 8080, 'nodePort': 30080}]}))
print(json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': items}, indent=2))
