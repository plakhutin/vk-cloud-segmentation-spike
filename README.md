# Spike сетевой сегментации VK Cloud

Проверяется одна конфигурация IPv4: облачные security groups и Kubernetes NetworkPolicy для потоков из [PLAN.md](PLAN.md). Подтверждённый отрицательный результат также завершает spike. Текущая фаза — **локальная подготовка без доступа к VK Cloud**: ресурсы не созданы, проверки сети не выполнены. Их результаты фиксируются в [results.md](results.md).

Ниже — будущий порядок запуска; не выполнять его до получения входов и согласования создания ресурсов. Используются Terraform 1.10.5, VKCS provider 0.19.0, Ubuntu 22.04 amd64, Kubernetes 1.31.14, containerd 1.7.27, runc 1.2.6, CNI plugins 1.6.2, Helm 3.16.4 и Cilium 1.16.19. Cilium: VXLAN, kube-proxy включён, pod CIDR `10.244.0.0/16`, service CIDR `10.96.0.0/12`; Hubble Relay/UI не устанавливаются. PostgreSQL — Ubuntu 22.04, пакеты `postgresql-14` и `postgresql-client-14` одной точной версии, задаваемой входом `PG_PACKAGE_VERSION`. До запуска проверить доступность версий, образов и репозиториев с VM, совместимость kernel, квоты и маршрутизацию.

## Входы и локальная проверка

До любых изменяющих действий определить project, region, AZ, квоты на шесть VM, сети, volumes, floating IP, LB и bucket; Ubuntu image, flavors, volume type, external network и floating IP pool; SSH-доступ и ключи; точную доступную в репозитории Ubuntu 22.04 версию `PG_PACKAGE_VERSION` обоих пакетов PostgreSQL; credentials VKCS и S3; уникальный новый bucket, публичный S3 HTTPS endpoint и живой внешний HTTPS endpoint без общей приватной маршрутизации. Подготовить отдельный живой внешний IP вне allowlist и адрес внешнего DNS resolver для отрицательных контролей. Согласовать сохранение или удаление ресурсов. Проверить доступность Terraform, Python 3, jq, SSH, AWS CLI, kubectl и Helm на управляющей машине.

Скопировать `infra/terraform.tfvars.SAMPLE.json` в защищённое место **вне репозитория**, заменить все значения и экспортировать абсолютный путь в `TF_VARS_JSON`. Три приватных CIDR не должны пересекаться между собой, с pod/service CIDR и существующей маршрутизацией. `lb_backend_source_cidrs` — подтверждённые документацией или измерением IPv4 источники LB и health checks на backend, не пересекающиеся с management; это не обязательно источник, видимый pod после NodePort/NAT. Примерные адреса из SAMPLE не являются реальными входами. Экспортировать `OS_AUTH_URL`, `OS_PROJECT_ID` и либо `OS_AUTH_TOKEN`, либо `OS_USERNAME` и `OS_PASSWORD`, а также остальные параметры авторизации проекта VKCS. Защитить секреты и локальный state; не помещать их в репозиторий и отчёт.

```bash
terraform -chdir=infra fmt -check
terraform -chdir=infra init -backend=false
terraform -chdir=infra validate
for f in scripts/*.sh; do bash -n "$f" || exit; done
python3 -c 'import ast; ast.parse(open("scripts/k8s-render.py").read())'
```

`init -backend=false` загружает provider, но не обращается к VK Cloud. `cloud-terraform.sh` перед plan/apply/destroy проверяет входы, пересечения и авторизацию; он не проверяет доступность сервиса и полноту всех входов последующих шагов. Поэтому до создания вручную проверить весь список выше, включая S3 и внешние endpoints.

## Создание стенда и доступ

Один исполнитель выполняет Terraform. После timeout сначала определить исход операции по state и облаку, не повторять apply вслепую. `plan` создаёт локальный `infra/spike.tfplan`, содержащий чувствительные данные; после проверки плана тот же исполнитель применяет его.

```bash
scripts/cloud-terraform.sh plan
scripts/cloud-terraform.sh apply
terraform -chdir=infra output -json > /tmp/spike-outputs.json
chmod 600 /tmp/spike-outputs.json
export BASTION=$(jq -r '.bastion_public_ip.value' /tmp/spike-outputs.json)
export ADMIN=$(jq -r '.private_ips.value.admin' /tmp/spike-outputs.json)
export CP_IP=$(jq -r '.private_ips.value.cp' /tmp/spike-outputs.json)
export WORKER1_IP=$(jq -r '.private_ips.value.worker1' /tmp/spike-outputs.json)
export WORKER2_IP=$(jq -r '.private_ips.value.worker2' /tmp/spike-outputs.json)
export PG_IP=$(jq -r '.private_ips.value.pg' /tmp/spike-outputs.json)
export LB_IP=$(jq -r '.lb_public_ip.value' /tmp/spike-outputs.json)
```

Все адреса VM брать только из outputs после apply. Экспортировать `SSH_USER` (пользователь image) и `SSH_KEY` (путь к приватному ключу). Обеспечить использование этого ключа на всём пути bastion → admin → private VM; проверить host keys. `scripts/vm-postgres.sh` использует именно этот путь, Terraform outputs и `PG_PASSWORD_FILE` (непустой защищённый файл). После проверки всех входов экспортировать `PG_PASSWORD_FILE` и `PG_PACKAGE_VERSION` и выполнить `scripts/vm-postgres.sh`. Скрипт запрашивает указанную версию обоих пакетов; его вывод фактических версий dpkg записать в `results.md`. Создаются database/user `spike`, TCP/5432.

Для bucket экспортировать `S3_ENDPOINT` (HTTPS origin без порта или с `:443`), `S3_BUCKET`, `AWS_DEFAULT_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`; затем `scripts/cloud-s3.sh create`. Это создаёт выделенный bucket и объект `spike.txt`; credentials и подписанные URL передавать проверяющему защищённо, не включать в результаты. Проверить фактические SG/привязки и автоматические правила, источники LB и health checks. Для pod-egress SG должны пропускать проверяемый путь, иначе облачная блокировка маскирует отсутствие CNI enforcement.

## Kubernetes и политики

Задать `SSH_USER` и `SSH_KEY`, затем создать временный SSH config с адресами из outputs. Проверить host keys при первом подключении; приватный ключ должен быть доступен локальному SSH для всех переходов.

```bash
export SPIKE_SSH_CONFIG=$(mktemp)
chmod 600 "$SPIKE_SSH_CONFIG"
cat > "$SPIKE_SSH_CONFIG" <<CONFIG
Host *
  User $SSH_USER
  IdentityFile $SSH_KEY
  IdentitiesOnly yes
Host spike-bastion
  HostName $BASTION
Host spike-admin
  HostName $ADMIN
  ProxyJump spike-bastion
Host spike-cp
  HostName $CP_IP
  ProxyJump spike-admin
Host spike-worker1
  HostName $WORKER1_IP
  ProxyJump spike-admin
Host spike-worker2
  HostName $WORKER2_IP
  ProxyJump spike-admin
CONFIG
for host in spike-cp spike-worker1 spike-worker2; do
  scp -F "$SPIKE_SSH_CONFIG" scripts/k8s-node-setup.sh "$host:/tmp/k8s-node-setup.sh"
  ssh -F "$SPIKE_SSH_CONFIG" "$host" sudo bash /tmp/k8s-node-setup.sh --install
done
ssh -F "$SPIKE_SSH_CONFIG" spike-cp sudo kubeadm init --apiserver-advertise-address "$CP_IP" --pod-network-cidr 10.244.0.0/16 --service-cidr 10.96.0.0/12 --kubernetes-version v1.31.14
```

Получить join-команду и выполнить её с sudo на обоих worker без записи токена в журнал или историю команд:

```bash
JOIN_COMMAND=$(ssh -F "$SPIKE_SSH_CONFIG" spike-cp sudo kubeadm token create --print-join-command)
for host in spike-worker1 spike-worker2; do ssh -F "$SPIKE_SSH_CONFIG" "$host" "sudo $JOIN_COMMAND"; done
unset JOIN_COMMAND
export KUBECONFIG=$(mktemp)
chmod 600 "$KUBECONFIG"
ssh -F "$SPIKE_SSH_CONFIG" spike-cp sudo cat /etc/kubernetes/admin.conf > "$KUBECONFIG"
ssh -F "$SPIKE_SSH_CONFIG" -f -N -L 127.0.0.1:6443:127.0.0.1:6443 spike-cp
kubectl config set-cluster kubernetes --server=https://127.0.0.1:6443
```

Kubeconfig содержит credentials: защищать его, затем удалить. Для SSH-туннеля локальный порт 6443 должен быть свободен; по окончании закрыть его. Установить Helm 3.16.4 и затем:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
helm upgrade --install cilium cilium/cilium --version 1.16.19 --namespace kube-system -f k8s/cilium-values.yaml
kubectl -n kube-system rollout status ds/cilium
kubectl get nodes -o wide
```

Выбрать точные имена двух worker из `kubectl get nodes -o wide`. Начальное размещение всех трёх pod на первом worker нужно для группы 3. Получить подписанный URL объекта без вывода credentials и извлечь hostname именно из него: при virtual-hosted стиле это может быть поддомен bucket, отличный от `S3_ENDPOINT`. Получить текущие IPv4 снимки и выбрать по одному адресу S3 и внешнего HTTPS; оба должны отличаться от `PG_IP` и друг от друга. `LB_SOURCE_CIDR` — разделённый запятыми список минимальных CIDR источников, видимых pod, без пересечения с pod CIDR; он отличается от SG LB source. Для начального наблюдения допустим временный `/32` worker, это не утверждение о фактическом источнике.

```bash
read -r -p 'Имя первого Kubernetes worker: ' WORKER_FIRST
read -r -p 'Имя второго Kubernetes worker: ' WORKER_SECOND
export WORKER_A="$WORKER_FIRST" WORKER_B="$WORKER_FIRST" WORKER_ECHO="$WORKER_FIRST"
S3_URL=$(aws --endpoint-url "$S3_ENDPOINT" s3 presign "s3://$S3_BUCKET/spike.txt" --expires-in 900)
export S3_HOST=$(python3 -c 'import sys,urllib.parse; u=urllib.parse.urlsplit(sys.stdin.read().strip()); assert u.scheme == "https" and u.hostname and u.port in (None,443); print(u.hostname)' <<< "$S3_URL")
read -r -p 'Hostname внешнего HTTPS endpoint: ' EXTERNAL_HOST
export EXTERNAL_HOST
dig +short A "$S3_HOST"
dig +short A "$EXTERNAL_HOST"
read -r -p 'Выбранный IPv4 S3 из снимка: ' S3_IP
read -r -p 'Выбранный IPv4 внешнего HTTPS из снимка: ' EXTERNAL_IP
read -r -p 'LB_SOURCE_CIDR для наблюдения: ' LB_SOURCE_CIDR
export S3_IP EXTERNAL_IP LB_SOURCE_CIDR
```

Записать оба DNS-снимка. Доступность объекта и credentials проверить при выполнении группы 6. Если URL истёк, получить новый до проверки и проверить его hostname той же командой извлечения; он должен совпадать с `S3_HOST`, а `S3_IP` — с разрешённым в policy адресом. При изменении hostname/IP сначала скорректировать конфигурацию до начала фиксированного прогона.

Сначала сгенерировать оба файла, затем применить политики **до приложений**:

```bash
scripts/k8s-render.py policies > /tmp/spike-policies.json
scripts/k8s-render.py apps > /tmp/spike-apps.json
kubectl apply -f /tmp/spike-policies.json
kubectl apply -f /tmp/spike-apps.json
kubectl -n segmentation-spike wait --for=condition=Ready pod/a pod/b pod/echo --timeout=180s
kubectl -n segmentation-spike get pod -o wide
```

Получить фактический post-NAT источник LB на узле echo через Cilium drop monitor или tcpdump и запрос к LB; отдельно подтвердить источники health checks и SG. Экспортировать подтверждённый `LB_SOURCE_CIDR`, повторно сгенерировать и применить policies и дождаться распространения. Не считать успешным LB-тест, если источник или health неизвестны. После фиксации правил не менять их во время восьми групп проверок; контрольную конфигурацию при необходимости применять отдельным шагом и возвращать итоговые правила до отрицательной пробы.

## Восемь групп проверок

Ожидания и правила доказательства — в разделе 7 [PLAN.md](PLAN.md). Перед каждым отрицательным тестом подтвердить тот же IP/протокол/порт разрешённым клиентом. Использовать новые соединения, записывать source/node, адрес, порт, результат и подтверждение. Timeout, HTTP 403, ошибка пароля или TLS сами по себе не доказывают блокировку. В HTTPS сохранить hostname/SNI при фиксированном IP; S3 DNS snapshot относится только к этому прогону. В случае неполных доказательств — INCONCLUSIVE.

Для наблюдения drop открыть отдельный терминал. Для ingress группы 3 выбрать node **echo**, для egress — node клиента; после переноса повторно определить node и Cilium pod:

```bash
POD=echo # для egress заменить на a или b
NODE=$(kubectl -n segmentation-spike get pod "$POD" -o jsonpath='{.spec.nodeName}')
CILIUM_POD=$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName="$NODE" -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec -it "$CILIUM_POD" -- cilium-dbg monitor --type drop
```

Зафиксировать IP pod, destination, направление и причину события. Для вызовов ниже требуется рабочий kubeconfig; значения hostname/IP и credentials заданы на этапе входов, без записи секретов в историю и логи.

1. **Административный путь и SG.** Проверить SSH от bastion к admin и от admin к PostgreSQL на 22; от bastion к тому же PG IP:22 — блокировка. Сопоставить контроль, SG и packet evidence; один timeout недостаточен. Использовать bastion → admin для нужных private endpoints.
2. **Вход.** `curl -sv --connect-timeout 5 "http://$LB_IP/"`; проверить health в провайдере и `kubectl -n segmentation-spike logs echo`. С admin с маршрутом проверить `curl -sv --connect-timeout 5 "http://$WORKER1_IP:30080/"`: путь в обход LB должен блокироваться. Живой backend, SG и packet evidence обязательны; записать реальный source.
3. **Pod-ingress.** A, B и echo первоначально размещены на первом worker; получить `export ECHO_IP=$(kubectl -n segmentation-spike get pod echo -o jsonpath='{.status.podIP}')`, выполнить `scripts/check-pod.sh a echo` затем `scripts/check-pod.sh b echo`. Наблюдать ingress drop на node echo. Перенести echo на другой worker: выполнить `export WORKER_ECHO="$WORKER_SECOND"`, затем `scripts/k8s-render.py apps > /tmp/spike-apps.json`, `kubectl -n segmentation-spike delete pod echo`, `kubectl apply -f /tmp/spike-apps.json`, дождаться Ready через `kubectl -n segmentation-spike wait --for=condition=Ready pod/echo --timeout=180s`, заново получить `ECHO_IP` и повторить A/B. Egress обоих клиентов к echo разрешён.
4. **Pod-egress.** На одном worker выполнить `scripts/check-pod.sh a external` и `scripts/check-pod.sh b external` с одинаковыми `EXTERNAL_IP` и `EXTERNAL_HOST`. Для B записать Cilium drop на node клиента. Проверить с admin живой `DENIED_HOST`/`DENIED_IP` вне allowlist командой `curl -sv --resolve "$DENIED_HOST:443:$DENIED_IP" "https://$DENIED_HOST/"`, затем из A `EXTERNAL_IP=$DENIED_IP EXTERNAL_HOST=$DENIED_HOST scripts/check-pod.sh a external` с наблюдением drop.
5. **PostgreSQL.** `export PG_USER=spike PG_DATABASE=spike`; `scripts/check-pod.sh a pg`, затем `scripts/check-pod.sh b pg`. Ввести пароль интерактивно; сохранить `inet_client_addr()` успешного SQL и событие блокировки B.
6. **S3.** Использовать `S3_HOST` и `S3_IP`, экспортированные до рендера policies, и передать подписанный URL через stdin: `printf '%s\n' "$S3_URL" | scripts/check-pod.sh a s3 | sha256sum`, сравнить с `printf 'VK Cloud segmentation spike test object\n' | sha256sum`, затем `printf '%s\n' "$S3_URL" | scripts/check-pod.sh b s3` и записать drop. URL и токены не логировать. Проверить действительность credentials и URL.
7. **DNS и management.** `export DNS_IP=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')`; выполнить `for p in a b; do scripts/check-pod.sh "$p" dns-udp; scripts/check-pod.sh "$p" dns-tcp; done`. На admin подтвердить доступность выбранного `LIVE_RESOLVER_IP` по UDP/TCP (`dig @"$LIVE_RESOLVER_IP" kubernetes.io A` и с `+tcp`), затем выполнить из A и B `for p in a b; do kubectl -n segmentation-spike exec "$p" -c tools -- dig +time=3 +tries=1 @"$LIVE_RESOLVER_IP" kubernetes.io A; kubectl -n segmentation-spike exec "$p" -c tools -- dig +tcp +time=3 +tries=1 @"$LIVE_RESOLVER_IP" kubernetes.io A; done` и записать drop. После разрешённого SSH контроля к выбранному `MGMT_IP:22` с источника, имеющего разрешённый SG маршрут, выполнить для обоих pod `TARGET_IP=$MGMT_IP TARGET_PORT=22 scripts/check-pod.sh a ip-port` и аналогично для b; фиксировать drop.
8. **Перенос.** Выполнить `export WORKER_A="$WORKER_SECOND" WORKER_B="$WORKER_SECOND"`, не меняя `WORKER_ECHO`; `scripts/k8s-render.py apps > /tmp/spike-apps.json`, `kubectl -n segmentation-spike delete pod a b`, `kubectl apply -f /tmp/spike-apps.json`, `kubectl -n segmentation-spike wait --for=condition=Ready pod/a pod/b --timeout=180s` и `kubectl -n segmentation-spike get pods -o wide`. На новом node повторить группу 4 и PostgreSQL группу 5 с новыми source IP и Cilium monitor.

Независимый reviewer проверяет выводы и повторяет только неоднозначные пробы; исправления требуют повтора затронутых случаев. Зафиксировать ограничения, фактические версии, правила SG/CNI и source IP в `results.md`.

## Завершение

Сохранить результаты и согласовать keep/teardown. При удалении сначала удалить выделенный объект и bucket, затем инфраструктуру:

```bash
CONFIRM_S3_BUCKET="$S3_BUCKET" scripts/cloud-s3.sh destroy
scripts/cloud-terraform.sh destroy
```

Закрыть SSH-туннель, удалить временные kubeconfig и SSH config и очистить чувствительные переменные. До завершения сохранить локальный state защищённо; после удаления указать оставшиеся ресурсы. Не добавлять state, tfplan, рабочие tfvars, kubeconfig, пароли или credentials в репозиторий и отчёт.
