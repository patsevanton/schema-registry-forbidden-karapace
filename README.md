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
| `terraform/` | Поднимает VPC, Managed Kafka (с включённым Schema Registry) и Managed Kubernetes |
| `k8s/` | Deployment продюсера + Secret с кредами |
| `go-app/` | Минимальный Go-продюсер, повторяющий цепочку `Compatibility -> Forbidden -> schema ID is not registered` |

## Как воспроизводится ошибка

Генератор продюсера регистрирует value-subject `{topic}-value` и **первым**
запросом идёт в `GET /config/{subject}?defaultToGlobal=true&verbose=true`
(это `Compatibility()` из franz-go). При 403:

1. `registerSchemas()` ошибку только логирует и **не пишет ID** в память;
2. `RequireSchemaID` видит пустой ID и валит старт.

`go-app/main.go` повторяет ровно эту цепочку. Тест `TestStartupFailsWhenForbidden`
фиксирует поведение.

## Поднять инфраструктуру (Terraform)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # заполнить folder_id, cloud_id, kafka_password, k8s_sa_id
terraform init
terraform plan
terraform apply
```

Создаются:

- `yandex_mdb_kafka_cluster` со `schema_registry = true`;
- `yandex_mdb_kafka_user` `schema-service` с `ACCESS_ROLE_PRODUCER` на топик
  и `ACCESS_ROLE_SCHEMA_READER` / `ACCESS_ROLE_SCHEMA_WRITER` на subject `{topic}-value`;
- `yandex_kubernetes_cluster` + node group.

### Как сломать ACL (воспроизвести 403)

Ошибка возникает, когда MDB-роли есть, но Karapace REST всё равно отвечает 403
на `/config` и `/subjects`. Чтобы гарантированно увидеть 403, достаточно
**убрать** `SCHEMA_*` permissions из `yandex_mdb_kafka_user.producer` и
`terraform apply`.

## Собрать и прогнать Go-репродуктор

```bash
cd go-app
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
