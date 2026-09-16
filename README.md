# schema-registry-forbidden-karapace

Минимальное, обезличенное воспроизведение ошибки старта продюсера при
`403 Forbidden` от managed Schema Registry (Karapace) в Yandex Cloud Managed Kafka.

```
validate points schema ID: schema ID is not registered for checkout.order.created.v2
[could not init kafka producer]
```

Перед этим в логах:

```
ошибка при регистрации схем | не удается получить уровень совместимости для subject
"checkout.order.created.v2-value"
(schema_registry_url="https://...", user="schema-service") | Forbidden
```

## Структура

| Путь | Что делает |
|------|------------|
| `*.tf` (корень) | Terraform: VPC + NAT-шлюз, Managed Kafka (с включённым Schema Registry) и Managed Kubernetes |
| `manifests/` | Шаблон Secret с кредами Kafka/Schema Registry, рендерится Terraform'ом |
| `chart/` | Helm-чарт продюсера (Deployment) |
| `app/` | Минимальный Go-продюсер, повторяющий цепочку `Compatibility -> Forbidden -> schema ID is not registered` |
| `traefik.tf` | Ingress-контроллер Traefik и публичный IP для kafbat-ui |
| `kafka-ui-values.yaml.tftpl` | Values kafbat-ui, рендерятся Terraform'ом в `kafka-ui-values.yaml` |
| `.github/workflows/docker.yml` | Semver-релиз + сборка и публикация образа в GHCR |

Go-образ собирается из `app/` и публикуется в GHCR
(`ghcr.io/patsevanton/schema-registry-forbidden-karapace`); тег образа — это
semver из workflow, а `chart/values.yaml` и `chart/Chart.yaml` пинят его
(`tag`, `appVersion`).

## Как воспроизводится ошибка

Генератор продюсера регистрирует value-subject `{topic}-value` и **первым**
запросом идёт в `GET /config/{subject}?defaultToGlobal=true&verbose=true`
(это `Compatibility()` из franz-go). При 403:

1. `registerSchemas()` ошибку только логирует и **не пишет ID** в память;
2. `RequireSchemaID` видит пустой ID и валит старт.

`app/main.go` повторяет ровно эту цепочку. Тест `TestStartupFailsWhenForbidden`
фиксирует поведение.

## Поднять инфраструктуру (Terraform)

```bash
cp terraform.tfvars.example terraform.tfvars   # заполнить folder_id, kafka_password
terraform init
terraform plan
terraform apply
```

Создаются:

- VPC + подсеть с NAT-шлюзом (ноды без публичных IP);
- `yandex_mdb_kafka_cluster` со `schema_registry = true`;
- `yandex_mdb_kafka_user` `schema-service` с `ACCESS_ROLE_PRODUCER` на топик,
  `ACCESS_ROLE_SCHEMA_READER` / `ACCESS_ROLE_SCHEMA_WRITER` на топик и на
  subject `{topic}-value`;
- сервисный аккаунт `sa-k8s-editor` + `yandex_kubernetes_cluster` + node group
  (прерываемые ноды, HDD-диски);
- `yandex_vpc_address` + Traefik (ingress-контроллер) для доступа к kafbat-ui;
- `yandex_mdb_kafka_user` `kafka-ui` с `ACCESS_ROLE_ADMIN` на `*`.

Пароль Kafka/Schema Registry не попадает в git: `terraform.tfvars` в `.gitignore`,
а Terraform рендерит Secret на диск (файл `manifests/kafka-credentials-secret.yaml`
тоже в `.gitignore`). Values kafbat-ui (`kafka-ui-values.yaml`) содержат пароль
пользователя UI и тоже в `.gitignore`.

### Как сломать ACL (воспроизвести 403)

Ошибка возникает, когда MDB-роли есть, но Karapace REST всё равно отвечает 403
на `/config` и `/subjects`. Чтобы гарантированно увидеть 403, достаточно
**убрать** `SCHEMA_*` permissions из `yandex_mdb_kafka_user.producer` и
`terraform apply`.

## Деплой продюсера

Kubeconfig:

```bash
terraform output -raw k8s_cluster_credentials_command | bash
```

Secret с кредами (рендерится Terraform'ом при `apply`):

```bash
kubectl apply -f manifests/kafka-credentials-secret.yaml
```

Helm-чарт продюсера:

```bash
helm upgrade --install producer ./chart \
  --namespace schema-registry-forbidden --create-namespace
```

## Деплой kafbat-ui

Traefik и публичный IP создаются Terraform'ом при `apply`. FQDN UI и IP:

```bash
terraform output -raw kafka_ui_url
terraform output -raw ingress_public_ip
```

Values kafbat-ui рендерятся Terraform'ом в `kafka-ui-values.yaml` (в `.gitignore`,
содержит пароль пользователя UI). Ставится через helm CLI:

```bash
helm repo add kafbat-ui https://kafbat.github.io/helm-charts
helm repo update kafbat-ui
helm upgrade --install kafbat-ui kafbat-ui/kafka-ui \
  --namespace kafka-ui --create-namespace \
  -f kafka-ui-values.yaml
```

UI открывается по адресу из `terraform output -raw kafka_ui_url`
(вида `http://kafka-ui.<ingress_public_ip>.sslip.io`).

## Собрать и прогнать Go-репродуктор локально

```bash
cd app
go mod tidy
go test ./...                       # TestStartupFailsWhenForbidden = зелёный при 403
go build -o producer .

SCHEMA_REGISTRY_URL=https://<broker>:443 \
KAFKA_USER=schema-service \
KAFKA_PASSWORD=<password> \
./producer
```

Ожидаемый вывод при 403:

```
error registering schema: cannot read compatibility for subject "checkout.order.created.v2-value" (url=..., user=schema-service): Forbidden
validate points schema ID: schema ID is not registered for checkout.order.created.v2
```

## Проверка "починилось"

После фикса ACL (и/или кода) `RequireSchemaID` проходит, продюсер стартует и
печатает `schema ID registered for ...: <id>`.
