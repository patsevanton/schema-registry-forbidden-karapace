package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// forbiddenServer отвечает 403 Forbidden на каждый запрос, воспроизводя
// поведение Karapace REST, когда MDB ACL не применён к эндпоинтам /config
// и /subjects.
func forbiddenServer() *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "Forbidden", http.StatusForbidden)
	}))
}

func TestRegisterSubjectForbidden(t *testing.T) {
	srv := forbiddenServer()
	defer srv.Close()

	registry, err := newRegistry(srv.URL, "schema-service", "secret")
	if err != nil {
		t.Fatalf("newRegistry: %v", err)
	}

	_, err = registry.registerSubject(valueSubject(topic))
	if err == nil {
		t.Fatal("expected error for 403 Forbidden")
	}
}

// TestStartupFailsWhenForbidden — сквозная репродукция: реестр отвечает 403,
// поэтому ID схемы не сохраняется, и requireSchemaID жёстко падает с той же
// ошибкой "schema ID is not registered" из инцидента.
func TestStartupFailsWhenForbidden(t *testing.T) {
	srv := forbiddenServer()
	defer srv.Close()

	registry, err := newRegistry(srv.URL, "schema-service", "secret")
	if err != nil {
		t.Fatalf("newRegistry: %v", err)
	}

	// Реальный генератор только логирует ошибку регистрации и оставляет мапу
	// пустой; повторяем это здесь.
	_ = registry.registerSchemas()

	err = registry.requireSchemaID(topic)
	if err == nil {
		t.Fatal("expected requireSchemaID to fail")
	}

	want := "schema ID is not registered for " + topic
	if err.Error() != want {
		t.Fatalf("got %q, want %q", err.Error(), want)
	}
}
