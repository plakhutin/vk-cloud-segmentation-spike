#!/usr/bin/env bash
set -euo pipefail
# One new connection per invocation; results require the independent controls in PLAN.md.
usage() { echo "Usage: $0 a|b echo|external|s3|pg|dns-udp|dns-tcp|ip-port" >&2; exit 2; }
[[ $# == 2 && ( $1 == a || $1 == b ) ]] || usage
pod=$1; kind=$2
need() { for n in "$@"; do [[ -n ${!n:-} ]] || { echo "Missing $n" >&2; exit 2; }; done; }
case $kind in
 echo) need ECHO_IP; kubectl -n segmentation-spike exec "$pod" -c tools -- curl -sv --connect-timeout 5 --max-time 10 "http://${ECHO_IP}:8080/" ;;
 external) need EXTERNAL_IP EXTERNAL_HOST; kubectl -n segmentation-spike exec "$pod" -c tools -- curl -sv --noproxy '*' --connect-timeout 5 --max-time 10 --resolve "${EXTERNAL_HOST}:443:${EXTERNAL_IP}" "https://${EXTERNAL_HOST}/" ;;
 s3) need S3_IP S3_HOST; [[ $S3_HOST =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || { echo "Invalid S3_HOST" >&2; exit 2; }; [[ -t 0 ]] && { echo 'Pipe the presigned HTTPS object URL to stdin; do not log it.' >&2; exit 2; }; kubectl -n segmentation-spike exec -i "$pod" -c tools -- sh -c 'IFS= read -r url; case "$url" in https://"$1"/*|https://"$1":443/*) ;; *) echo "S3 URL must use the supplied HTTPS host" >&2; exit 2;; esac; exec curl -fsS --noproxy "*" --connect-timeout 5 --max-time 15 --resolve "$1:443:$2" -w "%{stderr}HTTP %{http_code}\n" "$url"' sh "$S3_HOST" "$S3_IP" ;;
 pg) need PG_IP PG_USER PG_DATABASE; kubectl -n segmentation-spike exec -it "$pod" -c postgres -- env PGCONNECT_TIMEOUT=5 psql -h "$PG_IP" -p 5432 -U "$PG_USER" -d "$PG_DATABASE" -W -c 'SELECT inet_client_addr(), current_user, current_database();' ;;
 dns-udp|dns-tcp) need DNS_IP; flag=(); [[ $kind == dns-tcp ]] && flag=(+tcp); kubectl -n segmentation-spike exec "$pod" -c tools -- dig +time=3 +tries=1 "${flag[@]}" "@$DNS_IP" kubernetes.default.svc.cluster.local A ;;
 ip-port) need TARGET_IP TARGET_PORT; kubectl -n segmentation-spike exec "$pod" -c tools -- nc -vz -w 5 "$TARGET_IP" "$TARGET_PORT" ;;
 *) usage ;;
esac
