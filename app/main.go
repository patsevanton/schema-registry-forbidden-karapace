// Package main — минимальная, деперсонализированная репродукция сбоя запуска
// Kafka-продюсера при работе с управляемым Schema Registry (Karapace).
//
// Реальный сервис падает на старте с ошибкой:
//
//	validate points schema ID: schema ID is not registered for checkout.order.created.v2
//	[could not init kafka producer]
//
// Цепочка первопричин:
//
//	registerSchemas() -> registerSubject() ->
//	  RegisterSchema(POST /subjects/{subject}/versions)
//	    -> HTTP 403 Forbidden
//	  -> ошибка только логируется, ID схемы никуда не сохраняется
//	-> RequireSchemaID видит пустой ID и жёстко падает на старте.
//
// Этот бинарь воспроизводит ровно то же поведение: регистрирует value-субъект
// для одного protobuf-топика через RegisterSchema и при Forbidden не получает
// ID схемы. Вместо жёсткого падения он логирует ошибку и остаётся в фоне,
// периодически повторяя полный цикл registerSubject.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/twmb/franz-go/pkg/sr"
)

const (
	schemaType = sr.TypeProtobuf

	// Деперсонализированное имя топика/события.
	topic = "checkout.order.created.v2"

	// pollInterval — период фоновой перерегистрации схемы.
	pollInterval = time.Minute
)

// valueSubject — субъект Schema Registry, для которого продюсер регистрирует схему.
func valueSubject(topicName string) string {
	return topicName + "-value"
}

// schemaText — минимальная proto3-схема, которая в реальном сервисе
// получалась бы из дескриптора сгенерированного protobuf-сообщения.
const schemaText = `syntax = "proto3";

package checkout.order.created.v2;

message OrderCreated {
  string order_id = 1;
}
`

// Registry повторяет SchemaRegistry сгенерированного продюсера: URL + basic
// auth и мапу топик -> зарегистрированный ID схемы.
type Registry struct {
	URL      string
	Username string
	Password string

	client  *sr.Client
	schemas map[string]int
}

// newRegistry создаёт sr.Client так же, как это делает сгенерированный код.
func newRegistry(url, username, password string) (*Registry, error) {
	opts := []sr.ClientOpt{sr.URLs(url)}
	if username != "" && password != "" {
		opts = append(opts, sr.BasicAuth(username, password))
	}

	client, err := sr.NewClient(opts...)
	if err != nil {
		return nil, fmt.Errorf("create schema registry client (url=%q, user=%q): %w", url, username, err)
	}

	return &Registry{
		URL:      url,
		Username: username,
		Password: password,
		client:   client,
		schemas:  make(map[string]int),
	}, nil
}

// registerSubject регистрирует схему одним вызовом RegisterSchema, как это
// делает продюсер в prod. В отличие от сгенерированного цикла
// Compatibility -> SetCompatibility -> CheckCompatibility -> CreateSchema,
// здесь нет подготовительных запросов к /config, поэтому 403 от Karapace
// приходит сразу на POST /subjects/{subject}/versions и возвращается как есть.
func (r *Registry) registerSubject(subject string) (int, error) {
	schema := sr.Schema{Schema: schemaText, Type: schemaType}

	id, err := r.client.RegisterSchema(context.Background(), subject, schema, -1, -1)
	if err != nil {
		return 0, fmt.Errorf("cannot register schema for subject %q (url=%q, user=%q): %w",
			subject, r.URL, r.Username, err)
	}

	return id, nil
}

// registerSchemas регистрирует value-субъект для единственного топика и
// сохраняет полученный ID. При ошибке возвращает её (реальный генератор
// логирует и продолжает; мы пробрасываем её наружу, чтобы вызывающий код мог
// воспроизвести жёсткое падение).
func (r *Registry) registerSchemas() error {
	id, err := r.registerSubject(valueSubject(topic))
	if err != nil {
		return err
	}
	r.schemas[topic] = id
	return nil
}

// requireSchemaID воспроизводит жёсткое падение сгенерированного RequireSchemaID.
func (r *Registry) requireSchemaID(topicName string) error {
	if r == nil || r.client == nil {
		return fmt.Errorf("schema registry is required for %s", topicName)
	}
	id, ok := r.schemas[topicName]
	if !ok || id <= 0 {
		return fmt.Errorf("schema ID is not registered for %s", topicName)
	}
	return nil
}

// runBackground держит процесс запущенным и периодически повторяет полный цикл
// registerSubject. Ошибки (в том числе 403 Forbidden от Karapace) только
// логируются — процесс не завершается, а ждёт следующего тика. Возвращается
// при отмене ctx по SIGINT/SIGTERM.
func (r *Registry) runBackground(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			fmt.Println("background schema poller stopped")
			return
		case <-ticker.C:
			id, err := r.registerSubject(valueSubject(topic))
			if err != nil {
				fmt.Fprintf(os.Stderr, "background re-registration failed: %v\n", err)
				continue
			}
			r.schemas[topic] = id
			fmt.Printf("background re-registration ok for %s: %d\n", topic, id)
		}
	}
}

func main() {
	registryURL := os.Getenv("SCHEMA_REGISTRY_URL")
	username := os.Getenv("KAFKA_USER")
	password := os.Getenv("KAFKA_PASSWORD")

	if registryURL == "" {
		fmt.Fprintln(os.Stderr, "SCHEMA_REGISTRY_URL is empty")
		os.Exit(2)
	}

	registry, err := newRegistry(registryURL, username, password)
	if err != nil {
		fmt.Fprintln(os.Stderr, "could not init kafka producer:", err)
		os.Exit(1)
	}

	if err := registry.registerSchemas(); err != nil {
		// Сгенерированный продюсер только логирует эту ошибку и не записывает
		// ID схемы в свою мапу. Мы делаем то же: ничего не сохраняем.
		fmt.Fprintf(os.Stderr, "error registering schema: %v\n", err)
	}

	if err := registry.requireSchemaID(topic); err != nil {
		// Реальное жёсткое падение генератора здесь заменено: вместо выхода
		// процесс уходит в фоновый цикл и продолжает попытки.
		fmt.Fprintln(os.Stderr, "validate points schema ID:", err)
	} else {
		fmt.Printf("schema ID registered for %s: %d\n", topic, registry.schemas[topic])
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	registry.runBackground(ctx, pollInterval)
}
