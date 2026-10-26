package main

import (
	"io"
	"net/http"
	"strings"
	"testing"
)

type bridgeTestTransport func(*http.Request) (*http.Response, error)

func (f bridgeTestTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

func TestBridgeMetricsNeverFollowsRedirect(t *testing.T) {
	client := bridgeMetricsClient()
	calls := 0
	client.Transport = bridgeTestTransport(func(request *http.Request) (*http.Response, error) {
		calls++
		if request.URL.Host != "127.0.0.1:31080" {
			t.Fatal("metrics escaped fixed local endpoint")
		}
		return &http.Response{StatusCode: 302, Header: http.Header{"Location": {"https://fixture.invalid/redirect"}}, Body: io.NopCloser(strings.NewReader("")), Request: request}, nil
	})
	response, err := client.Get("http://127.0.0.1:31080/debug/vars")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != 302 || calls != 1 {
		t.Fatalf("followed metrics redirect: calls=%d", calls)
	}
}
