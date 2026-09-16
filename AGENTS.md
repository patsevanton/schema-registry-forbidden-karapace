# Правила коммитов

Префикс `feat` используется только при изменениях, связанных с Dockerfile, Go-кодом и образами (image). Все прочие изменения коммитить с другими префиксами (`fix`, `docs`, `chore`, `refactor`, `ci` и т.д.).

Повышение версий image (и соответствующие коммиты с префиксами `feat`, `chore`, `fix` и другими) делается только при изменении кода Go, Dockerfile и т.д. Без изменения исходного кода bump версий image не выполняется.

Изменение кода в `chart/` (включая `appVersion` в `Chart.yaml` и `tag` в `values.yaml`) не считается повышением версии image и не требует изменения Go-кода или Dockerfile. Такие изменения коммитятся с подходящим префиксом (`chore`, `fix` и т.д.), а не `feat`.

# Проверка тега образа

Перед деплоем продюсера сверять `tag` в `chart/values.yaml` с последним доступным тегом образа в GHCR. Если в GHCR есть более новый тег, обновить `tag` в `chart/values.yaml` и `appVersion` в `chart/Chart.yaml` на него.

Список тегов GHCR:

```bash
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:patsevanton/schema-registry-forbidden-karapace:pull&service=ghcr.io" | sed -E 's/.*"token":"([^"]+)".*/\1/')
curl -s -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/patsevanton/schema-registry-forbidden-karapace/tags/list"
```
