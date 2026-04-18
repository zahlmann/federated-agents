package receiverharness

import (
	"encoding/json"
	"testing"
)

func TestDecodeFunctionArgumentsUnwrapsStringifiedPayload(t *testing.T) {
	t.Parallel()

	// OpenAI Responses API returns arguments as a JSON-encoded string.
	raw := json.RawMessage(`"{\"message\":\"hello\"}"`)

	var target struct {
		Message string `json:"message"`
	}

	if err := decodeFunctionArguments(raw, &target); err != nil {
		t.Fatalf("decodeFunctionArguments returned error: %v", err)
	}

	if target.Message != "hello" {
		t.Fatalf("unexpected message: %q", target.Message)
	}
}

func TestDecodeFunctionArgumentsAlsoAcceptsRawObject(t *testing.T) {
	t.Parallel()

	raw := json.RawMessage(`{"message":"hello"}`)

	var target struct {
		Message string `json:"message"`
	}

	if err := decodeFunctionArguments(raw, &target); err != nil {
		t.Fatalf("decodeFunctionArguments returned error: %v", err)
	}

	if target.Message != "hello" {
		t.Fatalf("unexpected message: %q", target.Message)
	}
}
