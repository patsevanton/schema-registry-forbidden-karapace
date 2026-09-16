// Package main is a minimal, de-identified reproduction of a Kafka producer
// startup failure against a managed Schema Registry (Karapace).
//
// The real service fails to start with:
//
//	validate points schema ID: schema ID is not registered for checkout.order.created.v2
//	[could not init kafka producer]
//
// The root cause chain is:
//
//	registerSchemas() -> registerSubject() ->
//	  Compatibility(GET /config/{subject}?defaultToGlobal=true&verbose=true)
//	    -> HTTP 403 Forbidden
//	  -> error is only logged, schema ID is never stored
//	-> RequireSchemaID sees an empty ID and hard-fails startup.
//
// This binary keeps exactly that behaviour: it registers the value subject for
// a single protobuf topic, starts with the Compatibility() call, and — on
// Forbidden — refuses to start with the same "schema ID is not registered"
// error, mirroring the generator's hard-fail path.
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

	// De-identified topic/event name.
	topic = "checkout.order.created.v2"
)

// valueSubject is the Schema Registry subject the producer registers against.
func valueSubject(topicName string) string {
	return topicName + "-value"
}

// schemaText is a minimal proto3 schema that would be derived from the
// generated protobuf message descriptor in the real service.
const schemaText = `syntax = "proto3";

package checkout.order.created.v2;

message OrderCreated {
  string order_id = 1;
}
`

// Registry mirrors the generated producer's SchemaRegistry: URL + basic auth
// and a map of topic -> registered schema ID.
type Registry struct {
	URL      string
	Username string
	Password string

	client  *sr.Client
	schemas map[string]int
}

// newRegistry builds the sr.Client the same way the generated code does.
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

// registerSubject reproduces the generated registerSubject flow verbatim:
//
//	Compatibility(GET /config/{subject}) -> SetCompatibility -> CheckCompatibility -> CreateSchema
//
// A 403 Forbidden on the first call is NOT a not-found error, so it is
// returned as-is (and, in the generated producer, merely logged).
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

// registerSchemas registers the value subject for the single topic and stores
// the resulting ID. On error it returns the error (the real generator logs and
// continues; we surface it so the caller can reproduce the hard-fail).
func (r *Registry) registerSchemas() error {
	id, err := r.registerSubject(valueSubject(topic))
	if err != nil {
		return err
	}
	r.schemas[topic] = id
	return nil
}

// requireSchemaID reproduces the generated RequireSchemaID hard-fail.
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

// isNotFoundErr mirrors the generated code: only 404xx error codes are treated
// as "subject does not exist yet"; a 403 passes through as a real error.
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
		// The generated producer only logs this error and does not write the
		// schema ID into its map. We do the same: do not store anything.
		fmt.Fprintf(os.Stderr, "error registering schema: %v\n", err)
	}

	if err := registry.requireSchemaID(topic); err != nil {
		fmt.Fprintln(os.Stderr, "validate points schema ID:", err)
		os.Exit(1)
	}

	fmt.Printf("schema ID registered for %s: %d\n", topic, registry.schemas[topic])
}
