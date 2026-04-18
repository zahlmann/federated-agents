package receiverharness

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"strings"
	"sync"
	"testing"
)

func TestBridgeRunnerForwardsToolCalls(t *testing.T) {
	t.Parallel()

	hostInput, bridgeStdin := io.Pipe()
	bridgeStdout, hostOutput := io.Pipe()

	client := &scriptedClient{
		responses: []*CreateResponseResponse{
			{
				ID: "resp_1",
				Output: []OutputItem{
					{
						ID:        "fc_1",
						Type:      "function_call",
						CallID:    "call_ask",
						Name:      "ask_user",
						Arguments: json.RawMessage(`{"title":"Pick one","prompt":"Which field?","placeholder":"name"}`),
					},
				},
			},
			{
				ID: "resp_2",
				Output: []OutputItem{
					{
						ID:        "fc_2",
						Type:      "function_call",
						CallID:    "call_submit",
						Name:      "submit_result",
						Arguments: json.RawMessage(`{"summary":"answered","payload":"{\"field\":\"department\"}"}`),
					},
				},
			},
			{
				ID:         "resp_3",
				OutputText: "done",
			},
		},
	}

	bridge := &BridgeRunner{
		Input:  hostInput,
		Output: hostOutput,
		Client: client,
		NewUUID: func() string {
			return "fixed-tool-id"
		},
	}

	done := make(chan error, 1)
	go func() {
		done <- bridge.Run(context.Background())
	}()

	startEnvelope := BridgeInbound{
		Type: "start",
		Start: &BridgeStartMessage{
			Model:           "gpt-5.4",
			ReasoningEffort: "medium",
			PackageMarkdown: "# package",
			SchemaMarkdown:  "# schema",
		},
	}

	encoded, err := json.Marshal(startEnvelope)
	if err != nil {
		t.Fatalf("marshal start: %v", err)
	}

	if _, err := bridgeStdin.Write(append(encoded, '\n')); err != nil {
		t.Fatalf("write start: %v", err)
	}

	reader := bufio.NewReader(bridgeStdout)

	toolRequest, err := readOutbound(reader, "tool_request")
	if err != nil {
		t.Fatalf("read tool_request: %v", err)
	}

	if toolRequest.ToolName != "ask_user" {
		t.Fatalf("unexpected tool name: %q", toolRequest.ToolName)
	}

	if toolRequest.ToolID == "" {
		t.Fatalf("tool_request missing id")
	}

	var args map[string]string
	if err := json.Unmarshal(toolRequest.Arguments, &args); err != nil {
		t.Fatalf("decode args: %v", err)
	}

	if args["title"] != "Pick one" || args["prompt"] != "Which field?" {
		t.Fatalf("unexpected args: %#v", args)
	}

	response := BridgeInbound{
		Type:   "tool_response",
		ToolID: toolRequest.ToolID,
		OK:     true,
		Result: json.RawMessage(`{"answer":"department"}`),
	}

	encoded, err = json.Marshal(response)
	if err != nil {
		t.Fatalf("marshal tool_response: %v", err)
	}

	if _, err := bridgeStdin.Write(append(encoded, '\n')); err != nil {
		t.Fatalf("write tool_response: %v", err)
	}

	submitRequest, err := readOutbound(reader, "tool_request")
	if err != nil {
		t.Fatalf("read submit tool_request: %v", err)
	}

	if submitRequest.ToolName != "submit_result" {
		t.Fatalf("expected submit_result tool call, got %q", submitRequest.ToolName)
	}

	submitResponse := BridgeInbound{
		Type:   "tool_response",
		ToolID: submitRequest.ToolID,
		OK:     true,
		Result: json.RawMessage(`{"status":"approved","message":"ok"}`),
	}

	encoded, err = json.Marshal(submitResponse)
	if err != nil {
		t.Fatalf("marshal submit tool_response: %v", err)
	}

	if _, err := bridgeStdin.Write(append(encoded, '\n')); err != nil {
		t.Fatalf("write submit tool_response: %v", err)
	}

	finalMessage, err := readOutbound(reader, "final")
	if err != nil {
		t.Fatalf("read final: %v", err)
	}

	if finalMessage.Text != "done" {
		t.Fatalf("unexpected final text: %q", finalMessage.Text)
	}

	if err := bridgeStdin.Close(); err != nil {
		t.Fatalf("close stdin: %v", err)
	}

	if err := <-done; err != nil {
		t.Fatalf("bridge returned error: %v", err)
	}

	firstCallID := client.capturedFunctionCallID()
	if firstCallID != "call_ask" {
		t.Fatalf("expected follow-up to reference call_ask, got %q", firstCallID)
	}

	firstReply := client.capturedFunctionCallOutput()
	if !strings.Contains(firstReply, "department") {
		t.Fatalf("expected function_call_output to include answer, got %q", firstReply)
	}
}

func readOutbound(reader *bufio.Reader, wantType string) (*BridgeOutbound, error) {
	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			return nil, err
		}

		var outbound BridgeOutbound
		if err := json.Unmarshal(line, &outbound); err != nil {
			return nil, err
		}

		if outbound.Type == wantType {
			return &outbound, nil
		}
	}
}

type scriptedClient struct {
	mu        sync.Mutex
	calls     int
	responses []*CreateResponseResponse
	recorded  []CreateResponseRequest
}

func (s *scriptedClient) CreateResponse(
	_ context.Context,
	request CreateResponseRequest,
) (*CreateResponseResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.recorded = append(s.recorded, request)
	response := s.responses[s.calls]
	s.calls++
	return response, nil
}

func (s *scriptedClient) capturedFunctionCallID() string {
	s.mu.Lock()
	defer s.mu.Unlock()

	if len(s.recorded) < 2 {
		return ""
	}

	for _, item := range s.recorded[1].Input {
		if item.Type == "function_call_output" {
			return item.CallID
		}
	}

	return ""
}

func (s *scriptedClient) capturedFunctionCallOutput() string {
	s.mu.Lock()
	defer s.mu.Unlock()

	if len(s.recorded) < 2 {
		return ""
	}

	for _, item := range s.recorded[1].Input {
		if item.Type == "function_call_output" {
			return item.Output
		}
	}

	return ""
}
