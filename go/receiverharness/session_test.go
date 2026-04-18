package receiverharness

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func TestRunSessionHandlesToolLoop(t *testing.T) {
	t.Parallel()

	client := &fakeResponseClient{
		responses: []*CreateResponseResponse{
			{
				ID: "resp_1",
				Output: []OutputItem{
					{
						ID:        "fc_1",
						Type:      "function_call",
						CallID:    "call_1",
						Name:      "send_message",
						Arguments: json.RawMessage(`{"message":"Starting analysis."}`),
					},
				},
			},
			{
				ID:         "resp_2",
				OutputText: "Analysis complete.",
			},
		},
	}

	var sentMessages []string
	registry := NewReceiverToolRegistry(ReceiverCallbacks{
		SendMessage: func(_ context.Context, message string) error {
			sentMessages = append(sentMessages, message)
			return nil
		},
		AskUser: func(_ context.Context, title string, prompt string, choices []string) (string, string, error) {
			return "", "", nil
		},
		RunSafeQuery: func(_ context.Context, sql string, why string) (any, error) {
			return map[string]any{"rows": []any{}}, nil
		},
		SubmitResult: func(_ context.Context, summary string, payload json.RawMessage) (any, error) {
			return map[string]any{"status": "approved"}, nil
		},
	})

	result, err := RunSession(context.Background(), client, SessionConfig{
		Model:           DefaultModel,
		Instructions:    BuildReceiverInstructions(),
		InitialInput:    BuildReceiverInput("# Package", "# Schema"),
		ReasoningEffort: "medium",
		Store:           true,
		ToolRegistry:    registry,
	})
	if err != nil {
		t.Fatalf("RunSession returned error: %v", err)
	}

	if result.FinalText != "Analysis complete." {
		t.Fatalf("unexpected final text: %q", result.FinalText)
	}

	if len(sentMessages) != 1 || sentMessages[0] != "Starting analysis." {
		t.Fatalf("unexpected sent messages: %#v", sentMessages)
	}

	if len(client.requests) != 2 {
		t.Fatalf("expected 2 requests, got %d", len(client.requests))
	}

	firstRequest := client.requests[0]
	if firstRequest.PreviousResponseID != "" {
		t.Fatalf("first request should not include previous_response_id")
	}

	secondRequest := client.requests[1]
	if secondRequest.PreviousResponseID != "resp_1" {
		t.Fatalf("unexpected previous_response_id: %q", secondRequest.PreviousResponseID)
	}

	if secondRequest.Instructions == "" {
		t.Fatalf("follow-up request should repeat instructions")
	}

	if len(secondRequest.Tools) != 4 {
		t.Fatalf("follow-up request should repeat tool definitions")
	}

	if len(secondRequest.Input) != 1 || secondRequest.Input[0].Type != "function_call_output" {
		t.Fatalf("unexpected follow-up input: %#v", secondRequest.Input)
	}
}

func TestBuildReceiverInputIncludesPackageAndSchema(t *testing.T) {
	t.Parallel()

	input := BuildReceiverInput("package body", "schema body")

	if want := "# Packaged Request"; !strings.HasPrefix(input, want) {
		t.Fatalf("input should begin with packaged request heading, got %q", input)
	}

	if !strings.Contains(input, "package body") || !strings.Contains(input, "schema body") {
		t.Fatalf("input should include package and schema text: %q", input)
	}
}

type fakeResponseClient struct {
	requests  []CreateResponseRequest
	responses []*CreateResponseResponse
}

func (f *fakeResponseClient) CreateResponse(
	_ context.Context,
	request CreateResponseRequest,
) (*CreateResponseResponse, error) {
	f.requests = append(f.requests, request)

	response := f.responses[0]
	f.responses = f.responses[1:]
	return response, nil
}
