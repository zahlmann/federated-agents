package receiverharness

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"sync"
	"time"
)

// BridgeStartMessage is the first message the host sends to the bridge on stdin.
// It carries everything the harness needs to open a session.
type BridgeStartMessage struct {
	Model           string `json:"model"`
	ReasoningEffort string `json:"reasoningEffort"`
	Instructions    string `json:"instructions"`
	PackageMarkdown string `json:"packageMarkdown"`
	SchemaMarkdown  string `json:"schemaMarkdown"`
}

// BridgeInbound is anything the host writes to the bridge on stdin.
type BridgeInbound struct {
	Type   string              `json:"type"`
	Start  *BridgeStartMessage `json:"start,omitempty"`
	ToolID string              `json:"id,omitempty"`
	OK     bool                `json:"ok,omitempty"`
	Error  string              `json:"error,omitempty"`
	Result json.RawMessage     `json:"result,omitempty"`
}

// BridgeOutbound is anything the bridge writes to the host on stdout.
type BridgeOutbound struct {
	Type      string          `json:"type"`
	Message   string          `json:"message,omitempty"`
	ToolID    string          `json:"id,omitempty"`
	ToolName  string          `json:"name,omitempty"`
	Arguments json.RawMessage `json:"arguments,omitempty"`
	Text      string          `json:"text,omitempty"`
	Channel   string          `json:"channel,omitempty"`
	Payload   json.RawMessage `json:"payload,omitempty"`
	Timestamp string          `json:"timestamp,omitempty"`
}

// BridgeRunner wires up stdin/stdout NDJSON transport around a RunSession call.
// It is deliberately small: the host app owns everything that is not the model loop.
type BridgeRunner struct {
	Input     io.Reader
	Output    io.Writer
	Client    ResponseClient
	NewUUID   func() string
	Now       func() time.Time

	writeMutex sync.Mutex
	pending    sync.Map // toolID -> chan pendingToolReply
}

type pendingToolReply struct {
	ok     bool
	result json.RawMessage
	errMsg string
}

func NewBridgeRunner(input io.Reader, output io.Writer, client ResponseClient) *BridgeRunner {
	return &BridgeRunner{
		Input:   input,
		Output:  output,
		Client:  client,
		NewUUID: newUUID,
		Now:     time.Now,
	}
}

// Run drives the bridge to completion: it waits for a start message, launches
// RunSession, forwards tool calls, and emits a final or error event.
func (b *BridgeRunner) Run(ctx context.Context) error {
	reader := bufio.NewReader(b.Input)

	start, err := b.waitForStart(reader)
	if err != nil {
		b.emitError(err)
		return err
	}

	inboundCtx, cancelInbound := context.WithCancel(ctx)
	defer cancelInbound()

	go b.pumpInbound(inboundCtx, reader)

	instructions := start.Instructions
	if instructions == "" {
		instructions = BuildReceiverInstructions()
	}

	registry := b.buildRegistry()
	client := &tracingResponseClient{inner: b.Client, emit: b.emitTrace}

	b.emitStatus("session starting")

	initialInput := BuildReceiverInput(start.PackageMarkdown, start.SchemaMarkdown)
	b.emitTrace("initial_input", map[string]string{"input": initialInput})
	b.emitTrace("instructions", map[string]string{"instructions": instructions})

	result, err := RunSession(ctx, client, SessionConfig{
		Model:           start.Model,
		Instructions:    instructions,
		InitialInput:    initialInput,
		ReasoningEffort: start.ReasoningEffort,
		Store:           true,
		ToolRegistry:    registry,
	})
	if err != nil {
		b.emitError(err)
		return err
	}

	b.emitTrace("final_text", map[string]string{"text": result.FinalText})
	b.emit(BridgeOutbound{Type: "final", Text: result.FinalText})
	return nil
}

func (b *BridgeRunner) waitForStart(reader *bufio.Reader) (*BridgeStartMessage, error) {
	for {
		line, err := reader.ReadBytes('\n')
		if err != nil && len(line) == 0 {
			return nil, fmt.Errorf("read start message: %w", err)
		}

		if len(line) == 0 {
			continue
		}

		var inbound BridgeInbound
		if err := json.Unmarshal(line, &inbound); err != nil {
			return nil, fmt.Errorf("decode start envelope: %w", err)
		}

		if inbound.Type != "start" || inbound.Start == nil {
			return nil, fmt.Errorf("first bridge message must be a start message, got %q", inbound.Type)
		}

		return inbound.Start, nil
	}
}

func (b *BridgeRunner) pumpInbound(ctx context.Context, reader *bufio.Reader) {
	for {
		if ctx.Err() != nil {
			return
		}

		line, err := reader.ReadBytes('\n')
		if err != nil {
			return
		}

		if len(line) == 0 {
			continue
		}

		var inbound BridgeInbound
		if err := json.Unmarshal(line, &inbound); err != nil {
			continue
		}

		if inbound.Type != "tool_response" {
			continue
		}

		raw, ok := b.pending.LoadAndDelete(inbound.ToolID)
		if !ok {
			continue
		}

		channel, ok := raw.(chan pendingToolReply)
		if !ok {
			continue
		}

		channel <- pendingToolReply{
			ok:     inbound.OK,
			result: inbound.Result,
			errMsg: inbound.Error,
		}
	}
}

func (b *BridgeRunner) buildRegistry() *ToolRegistry {
	return NewReceiverToolRegistry(ReceiverCallbacks{
		SendMessage: func(ctx context.Context, message string) error {
			_, err := b.dispatchTool(ctx, "send_message", map[string]any{"message": message})
			return err
		},
		AskUser: func(ctx context.Context, title string, prompt string, placeholder string) (string, error) {
			reply, err := b.dispatchTool(ctx, "ask_user", map[string]any{
				"title":       title,
				"prompt":      prompt,
				"placeholder": placeholder,
			})
			if err != nil {
				return "", err
			}

			var decoded struct {
				Answer string `json:"answer"`
			}

			if err := json.Unmarshal(reply, &decoded); err != nil {
				return string(reply), nil
			}

			return decoded.Answer, nil
		},
		RunSafeQuery: func(ctx context.Context, sql string, why string) (any, error) {
			reply, err := b.dispatchTool(ctx, "run_safe_query", map[string]any{
				"sql": sql,
				"why": why,
			})
			if err != nil {
				return nil, err
			}

			var decoded any
			if err := json.Unmarshal(reply, &decoded); err != nil {
				return string(reply), nil
			}

			return decoded, nil
		},
		SubmitResult: func(ctx context.Context, summary string, payload json.RawMessage) (any, error) {
			reply, err := b.dispatchTool(ctx, "submit_result", map[string]any{
				"summary": summary,
				"payload": payload,
			})
			if err != nil {
				return nil, err
			}

			var decoded any
			if err := json.Unmarshal(reply, &decoded); err != nil {
				return string(reply), nil
			}

			return decoded, nil
		},
	})
}

func (b *BridgeRunner) dispatchTool(ctx context.Context, name string, arguments any) (json.RawMessage, error) {
	encodedArguments, err := json.Marshal(arguments)
	if err != nil {
		return nil, fmt.Errorf("encode tool arguments for %s: %w", name, err)
	}

	toolID := b.NewUUID()
	replyChannel := make(chan pendingToolReply, 1)
	b.pending.Store(toolID, replyChannel)

	b.emitTrace("tool_request", map[string]any{
		"id":        toolID,
		"name":      name,
		"arguments": json.RawMessage(encodedArguments),
	})

	if err := b.emit(BridgeOutbound{
		Type:      "tool_request",
		ToolID:    toolID,
		ToolName:  name,
		Arguments: encodedArguments,
	}); err != nil {
		b.pending.Delete(toolID)
		return nil, err
	}

	select {
	case <-ctx.Done():
		b.pending.Delete(toolID)
		return nil, ctx.Err()
	case reply := <-replyChannel:
		b.emitTrace("tool_response", map[string]any{
			"id":     toolID,
			"name":   name,
			"ok":     reply.ok,
			"error":  reply.errMsg,
			"result": reply.result,
		})

		if !reply.ok {
			if reply.errMsg == "" {
				return nil, fmt.Errorf("host rejected tool %s", name)
			}

			return nil, fmt.Errorf("%s", reply.errMsg)
		}

		if len(reply.result) == 0 {
			return json.RawMessage(`{"ok":true}`), nil
		}

		return reply.result, nil
	}
}

func (b *BridgeRunner) emit(message BridgeOutbound) error {
	b.writeMutex.Lock()
	defer b.writeMutex.Unlock()

	now := b.Now
	if now == nil {
		now = time.Now
	}

	if message.Timestamp == "" {
		message.Timestamp = now().UTC().Format(time.RFC3339Nano)
	}

	encoded, err := json.Marshal(message)
	if err != nil {
		return fmt.Errorf("encode bridge message: %w", err)
	}

	if _, err := b.Output.Write(append(encoded, '\n')); err != nil {
		return fmt.Errorf("write bridge message: %w", err)
	}

	if flusher, ok := b.Output.(interface{ Flush() error }); ok {
		if err := flusher.Flush(); err != nil {
			return fmt.Errorf("flush bridge message: %w", err)
		}
	}

	return nil
}

func (b *BridgeRunner) emitError(err error) {
	_ = b.emit(BridgeOutbound{Type: "error", Message: err.Error()})
}

func (b *BridgeRunner) emitStatus(message string) {
	_ = b.emit(BridgeOutbound{Type: "status", Message: message})
}

func (b *BridgeRunner) emitTrace(channel string, payload any) {
	encoded, err := json.Marshal(payload)
	if err != nil {
		encoded = []byte(fmt.Sprintf("%q", err.Error()))
	}

	_ = b.emit(BridgeOutbound{
		Type:    "trace",
		Channel: channel,
		Payload: encoded,
	})
}

func newUUID() string {
	buffer := make([]byte, 16)
	if _, err := rand.Read(buffer); err != nil {
		return fmt.Sprintf("tool-%d", time.Now().UnixNano())
	}

	return hex.EncodeToString(buffer)
}

type tracingResponseClient struct {
	inner ResponseClient
	emit  func(channel string, payload any)
}

func (c *tracingResponseClient) CreateResponse(
	ctx context.Context,
	request CreateResponseRequest,
) (*CreateResponseResponse, error) {
	c.emit("api_request", request)

	response, err := c.inner.CreateResponse(ctx, request)
	if err != nil {
		c.emit("api_error", map[string]string{"error": err.Error()})
		return nil, err
	}

	c.emit("api_response", response)
	return response, nil
}
