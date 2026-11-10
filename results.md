# Результаты spike

Текущая фаза — локальная подготовка без доступа к VK Cloud. Инфраструктура не применялась; работа NetworkPolicy, LB, SG, PostgreSQL и S3 в облаке не проверена. Вывод о сегментации отсутствует.

## Локальные проверки

| Команда или проверка | Результат | Наблюдение |
|---|---|---|
| `cmp -s PLAN.md <приложенный план>` | Успех | Побайтовое совпадение. |
| `git check-ignore infra/spike.tfplan infra/terraform.tfvars.json` | Успех | План и рабочие переменные игнорируются; пример и lock-файл не игнорируются. |
| `/tmp/terraform-bin/terraform fmt -check -recursive infra`; в `infra/`: `/tmp/terraform-bin/terraform init -backend=false -input=false` и `/tmp/terraform-bin/terraform validate -no-color` | Успех | Изначальная ошибка `cidrcontains` исправлена; итоговый validate успешен. Инициализация без backend и обращения к VK Cloud; первая попытка запуска provider в sandbox не удалась, повтор вне sandbox прошёл. |
| `for f in scripts/*.sh; do bash -n "$f" || exit; done` | Успех | Синтаксис всех shell-скриптов, проверен при интеграции. |
| `TF_VARS_JSON="$PWD/infra/terraform.tfvars.SAMPLE.json" PATH="/tmp/terraform-bin:$PATH" OS_AUTH_URL=example OS_PROJECT_ID=example OS_AUTH_TOKEN=example scripts/cloud-terraform.sh plan`; повтор с тестовым `/tmp/spike-overlap.tfvars.json` | Ожидаемый отказ | Пример отклонён из-за placeholder region, пересечение LB/management — до вызова Terraform. |
| `python3 -c 'import ast; ast.parse(open("scripts/k8s-render.py").read())'` и запуск генератора без входов | Успех | Python AST прочитан; отсутствующие входы отклонены, как ожидалось. |
| `helm lint /tmp/cilium-1.16.19.tgz -f k8s/cilium-values.yaml` | Успех | 0 ошибок. |
| `helm template cilium /tmp/cilium-1.16.19.tgz -n kube-system -f k8s/cilium-values.yaml --kube-version 1.31.14` | Успех | 18 документов. |
| `/tmp/kubeconform/kubeconform -summary -strict -kubernetes-version 1.31.14 /tmp/spike-policies.json /tmp/spike-apps.json /tmp/cilium-render.yaml` | Успех | 28/28 valid, skipped 0: 18 chart и 10 собственных объектов, сгенерированных с тестовыми RFC 5737 адресами. CRD не входили в render; валидация схем CRD не выполнялась. |
| `kubectl` client dry-run | Не выполнен | Требует API; без кластера попытка подключения к localhost:8080 не прошла. |
| Исправления после review: `/tmp/terraform-bin/terraform fmt -check -recursive infra`, `terraform validate -no-color` в `infra/`, синтаксис `cloud-s3.sh` и `vm-postgres.sh` | Успех | Terraform закреплён на 1.10.5; точная версия пакетов PostgreSQL задаётся обязательным входом. |
| `S3_ENDPOINT=https://example.com:8443` при вызове `scripts/cloud-s3.sh` | Ожидаемый отказ | Нестандартный порт отклонён до aws. |
| `bash -n scripts/check-pod.sh` и локальные проверки URL с подставными `kubectl`/`curl` | Успех | URL без порта и с `:443` приняты; `:444`, userinfo, неверный host и HTTP отклонены. Сеть и S3 не проверялись. |
| Cloud plan/apply и живые сетевые проверки | Не выполнены | Нет входов и доступа к стенду. |

## Облачные проверки

Для каждой фактической пробы укажите источник и node, адрес и порт, ожидаемый и полученный результат, существенное наблюдение или вывод команды. После выполнения используйте PASS, FAIL или INCONCLUSIVE с причиной. При неполных данных PASS не ставится.

| № | Проверка | Источник и node → фактический адрес:порт | Ожидаемый результат | Полученный результат | Вывод команды или наблюдение |
|---|---|---|---|---|---|
| 1 | Административный путь и облачная граница | — | — | Не проверено | — |
| 2 | Входящий путь | — | — | Не проверено | — |
| 3 | Pod-ingress | — | — | Не проверено | — |
| 4 | Pod-egress | — | — | Не проверено | — |
| 5 | PostgreSQL | — | — | Не проверено | — |
| 6 | S3 | — | — | Не проверено | — |
| 7 | DNS и management | — | — | Не проверено | — |
| 8 | Перенос pod | — | — | Не проверено | — |

Планируемые версии: Terraform 1.10.5, VKCS provider 0.19.0, Kubernetes 1.31.14, Cilium 1.16.19, containerd 1.7.27. Точная версия Ubuntu пакетов `postgresql-14` и `postgresql-client-14` — обязательный вход `PG_PACKAGE_VERSION`, пока не определена; после установки записать вывод dpkg. Фактические версии, параметры CNI/SG, source IP, ограничения и оставленные ресурсы: не определены.
