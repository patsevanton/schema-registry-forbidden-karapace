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
//	  Compatibility(GET /config/{subject}?defaultToGlobal=true&verbose=true)
//	    -> HTTP 403 Forbidden
//	  -> ошибка только логируется, ID схемы никуда не сохраняется
//	-> RequireSchemaID видит пустой ID и жёстко падает на старте.
//
// Этот бинарь воспроизводит ровно то же поведение: регистрирует value-субъект
// для одного protobuf-топика, стартует с вызова Compatibility() и — при
// Forbidden — отказывается запускаться с той же ошибкой "schema ID is not
// registered", повторяя путь жёсткого падения генератора.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/twmb/franz-go/pkg/sr"
)

const (
	schemaType = sr.TypeProtobuf

	// Деперсонализированное имя топика/события.
	topic = "checkout.order.created.v2"
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

// registerSubject дословно воспроизводит сгенерированный поток registerSubject:
//
//	Compatibility(GET /config/{subject}) -> SetCompatibility -> CheckCompatibility -> CreateSchema
//
// 403 Forbidden на первом вызове НЕ является ошибкой "not found", поэтому
// возвращается как есть (а в сгенерированном продюсере просто логируется).
func (r *Registry) registerSubject(subject string) (int, error) {
	paramCtx := sr.WithParams(context.Background(), sr.DefaultToGlobal, sr.Verbose)

	res := r.client.Compatibility(paramCtx, subject)
	if len(res) != 1 {
		return 0, errors.New("expected exactly one compatibility result")
	}

	compatRes := res[0]
	if compatRes.Err != nil && !isNotFoundErr(compatRes.Err) {
		return 0, fmt.Errorf("cannot read compatibility for subject %q (url=%q, user=%q): %w",
			subject, r.URL, r.Username, compatRes.Err)
	}

	if compatRes.Level != sr.CompatBackwardTransitive {
		setRes := r.client.SetCompatibility(paramCtx, sr.SetCompatibility{Level: sr.CompatBackwardTransitive}, subject)
		if len(setRes) != 1 {
			return 0, errors.New("expected exactly one compatibility result")
		}
		if setRes[0].Err != nil {
			return 0, fmt.Errorf("cannot set compatibility for subject %q: %w", subject, setRes[0].Err)
		}
	}

	schema := sr.Schema{Schema: schemaText, Type: schemaType}

	checkCompatRes, err := r.client.CheckCompatibility(paramCtx, subject, -1, schema)
	if err != nil && !isNotFoundErr(err) {
		return 0, fmt.Errorf("cannot check compatibility for subject %q: %w", subject, err)
	}
	if err == nil && !checkCompatRes.Is {
		if len(checkCompatRes.Messages) == 0 {
			return 0, fmt.Errorf("schema for %s is incompatible with the previous version", subject)
		}
		return 0, fmt.Errorf("schema for %s is incompatible, reason: %s", subject, checkCompatRes.Messages[0])
	}

	created, err := r.client.CreateSchema(paramCtx, subject, schema)
	if err != nil {
		return 0, fmt.Errorf("cannot publish schema for subject %q (url=%q, user=%q): %w",
			subject, r.URL, r.Username, err)
	}

	return created.ID, nil
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

// isNotFoundErr повторяет сгенерированный код: только коды ошибок 404xx
// считаются "субъект ещё не существует"; 403 проходит как настоящая ошибка.
func isNotFoundErr(err error) bool {
	if err == nil {
		return false
	}
	var re *sr.ResponseError
	if !errors.As(err, &re) {
		return false
	}
	return re.ErrorCode == sr.ErrSubjectNotFound.Code ||
		re.ErrorCode == sr.ErrVersionNotFound.Code ||
		re.ErrorCode == sr.ErrSubjectLevelCompatibilityNotConfigured.Code
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
		fmt.Fprintln(os.Stderr, "validate points schema ID:", err)
		os.Exit(1)
	}

	fmt.Printf("schema ID registered for %s: %d\n", topic, registry.schemas[topic])
}
