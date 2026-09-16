package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// forbiddenServer answers 403 Forbidden to every request, reproducing the
// Karapace REST behaviour when the MDB ACL is not applied to /config and
// /subjects endpoints.
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

// TestStartupFailsWhenForbidden is the end-to-end reproduction: the registry
// answers 403, so no schema ID is stored, and requireSchemaID hard-fails with
// the exact "schema ID is not registered" error from the incident.
func TestStartupFailsWhenForbidden(t *testing.T) {
	srv := forbiddenServer()
	defer srv.Close()

	registry, err := newRegistry(srv.URL, "schema-service", "secret")
	if err != nil {
		t.Fatalf("newRegistry: %v", err)
	}

	// The real generator only logs the registration error and leaves the map
	// empty; mirror that here.
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
