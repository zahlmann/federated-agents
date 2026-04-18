package receiverharness

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// decodeFunctionArguments unmarshals a function call's arguments into target.
// The OpenAI Responses API returns function_call.arguments as a JSON-encoded
// string (e.g. "\"{\\\"key\\\":1}\""). Older tests also pass raw JSON objects.
// We support both shapes.
func decodeFunctionArguments(raw json.RawMessage, target any) error {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return fmt.Errorf("empty function arguments")
	}

	if trimmed[0] == '"' {
		var unwrapped string
		if err := json.Unmarshal(trimmed, &unwrapped); err != nil {
			return fmt.Errorf("unwrap stringified arguments: %w", err)
		}

		if strings.TrimSpace(unwrapped) == "" {
			return fmt.Errorf("empty function arguments")
		}

		return json.Unmarshal([]byte(unwrapped), target)
	}

	return json.Unmarshal(trimmed, target)
}

const DefaultModel = "gpt-5.4"

type ToolHandler func(ctx context.Context, call FunctionCall) (any, error)

type ToolRegistry struct {
	definitions []ToolDefinition
	handlers    map[string]ToolHandler
}

type SessionConfig struct {
	Model           string
	Instructions    string
	InitialInput    string
	ReasoningEffort string
	Store           bool
	ToolRegistry    *ToolRegistry
}

type SessionResult struct {
	LastResponse *CreateResponseResponse
	Responses    []*CreateResponseResponse
	FinalText    string
}

type ReceiverCallbacks struct {
	SendMessage  func(ctx context.Context, message string) error
	AskUser      func(ctx context.Context, title string, prompt string, placeholder string) (string, error)
	RunSafeQuery func(ctx context.Context, sql string, why string) (any, error)
	SubmitResult func(ctx context.Context, summary string, payload json.RawMessage) (any, error)
}

func NewToolRegistry() *ToolRegistry {
	return &ToolRegistry{
		definitions: make([]ToolDefinition, 0),
		handlers:    make(map[string]ToolHandler),
	}
}

func (r *ToolRegistry) Register(definition ToolDefinition, handler ToolHandler) {
	r.definitions = append(r.definitions, definition)
	r.handlers[definition.Name] = handler
}

func (r *ToolRegistry) Definitions() []ToolDefinition {
	definitions := make([]ToolDefinition, 0, len(r.definitions))
	definitions = append(definitions, r.definitions...)
	return definitions
}

func (r *ToolRegistry) Handle(ctx context.Context, call FunctionCall) (string, error) {
	handler, ok := r.handlers[call.Name]
	if !ok {
		return "", fmt.Errorf("no handler registered for tool %q", call.Name)
	}

	result, err := handler(ctx, call)
	if err != nil {
		return encodeToolOutput(map[string]any{
			"ok":    false,
			"error": err.Error(),
		})
	}

	return encodeToolOutput(result)
}

func NewReceiverToolRegistry(callbacks ReceiverCallbacks) *ToolRegistry {
	registry := NewToolRegistry()

	registry.Register(progressToolDefinition(), func(ctx context.Context, call FunctionCall) (any, error) {
		var args struct {
			Message string `json:"message"`
		}

		if err := decodeFunctionArguments(call.Arguments, &args); err != nil {
			return nil, fmt.Errorf("decode send_message arguments: %w", err)
		}

		if callbacks.SendMessage == nil {
			return nil, fmt.Errorf("send_message callback is not wired")
		}

		if err := callbacks.SendMessage(ctx, args.Message); err != nil {
			return nil, err
		}

		return map[string]any{
			"ok":     true,
			"status": "sent",
		}, nil
	})

	registry.Register(askUserToolDefinition(), func(ctx context.Context, call FunctionCall) (any, error) {
		var args struct {
			Title       string `json:"title"`
			Prompt      string `json:"prompt"`
			Placeholder string `json:"placeholder"`
		}

		if err := decodeFunctionArguments(call.Arguments, &args); err != nil {
			return nil, fmt.Errorf("decode ask_user arguments: %w", err)
		}

		if callbacks.AskUser == nil {
			return nil, fmt.Errorf("ask_user callback is not wired")
		}

		answer, err := callbacks.AskUser(ctx, args.Title, args.Prompt, args.Placeholder)
		if err != nil {
			return nil, err
		}

		return map[string]any{
			"answer": answer,
		}, nil
	})

	registry.Register(safeQueryToolDefinition(), func(ctx context.Context, call FunctionCall) (any, error) {
		var args struct {
			SQL string `json:"sql"`
			Why string `json:"why"`
		}

		if err := decodeFunctionArguments(call.Arguments, &args); err != nil {
			return nil, fmt.Errorf("decode run_safe_query arguments: %w", err)
		}

		if callbacks.RunSafeQuery == nil {
			return nil, fmt.Errorf("run_safe_query callback is not wired")
		}

		return callbacks.RunSafeQuery(ctx, args.SQL, args.Why)
	})

	registry.Register(submitResultToolDefinition(), func(ctx context.Context, call FunctionCall) (any, error) {
		var args struct {
			Summary string `json:"summary"`
			Payload string `json:"payload"`
		}

		if err := decodeFunctionArguments(call.Arguments, &args); err != nil {
			return nil, fmt.Errorf("decode submit_result arguments: %w", err)
		}

		if callbacks.SubmitResult == nil {
			return nil, fmt.Errorf("submit_result callback is not wired")
		}

		payload := json.RawMessage(args.Payload)
		if len(payload) == 0 {
			payload = json.RawMessage("{}")
		}

		return callbacks.SubmitResult(ctx, args.Summary, payload)
	})

	return registry
}

func RunSession(
	ctx context.Context,
	client ResponseClient,
	config SessionConfig,
) (*SessionResult, error) {
	if client == nil {
		return nil, fmt.Errorf("response client is required")
	}

	if config.ToolRegistry == nil {
		return nil, fmt.Errorf("tool registry is required")
	}

	if strings.TrimSpace(config.Instructions) == "" {
		return nil, fmt.Errorf("instructions are required")
	}

	if strings.TrimSpace(config.InitialInput) == "" {
		return nil, fmt.Errorf("initial input is required")
	}

	model := config.Model
	if strings.TrimSpace(model) == "" {
		model = DefaultModel
	}

	request := CreateResponseRequest{
		Model:        model,
		Instructions: config.Instructions,
		Input: []InputItem{
			UserMessage(config.InitialInput),
		},
		Store:     boolPointer(config.Store),
		Tools:     config.ToolRegistry.Definitions(),
		Reasoning: reasoningConfig(config.ReasoningEffort),
	}

	result := &SessionResult{
		Responses: make([]*CreateResponseResponse, 0),
	}

	for {
		response, err := client.CreateResponse(ctx, request)
		if err != nil {
			return nil, err
		}

		result.LastResponse = response
		result.Responses = append(result.Responses, response)

		functionCalls := response.FunctionCalls()
		if len(functionCalls) == 0 {
			result.FinalText = response.FinalText()
			return result, nil
		}

		followUpInput := make([]InputItem, 0, len(functionCalls))

		for _, functionCall := range functionCalls {
			output, err := config.ToolRegistry.Handle(ctx, functionCall)
			if err != nil {
				return nil, err
			}

			followUpInput = append(followUpInput, FunctionCallOutput(functionCall.CallID, output))
		}

		request = CreateResponseRequest{
			Model:              model,
			Instructions:       config.Instructions,
			PreviousResponseID: response.ID,
			Input:              followUpInput,
			Store:              boolPointer(config.Store),
			Tools:              config.ToolRegistry.Definitions(),
			Reasoning:          reasoningConfig(config.ReasoningEffort),
		}
	}
}

func boolPointer(value bool) *bool {
	return &value
}

func reasoningConfig(effort string) *ReasoningConfig {
	if strings.TrimSpace(effort) == "" {
		return nil
	}

	return &ReasoningConfig{
		Effort: effort,
	}
}

func encodeToolOutput(value any) (string, error) {
	switch typed := value.(type) {
	case string:
		return typed, nil
	case []byte:
		return string(typed), nil
	default:
		encoded, err := json.Marshal(typed)
		if err != nil {
			return "", fmt.Errorf("encode tool output: %w", err)
		}

		return string(encoded), nil
	}
}

func progressToolDefinition() ToolDefinition {
	return ToolDefinition{
		Type:        "function",
		Name:        "send_message",
		Description: "Send a short user-facing progress update to the receiver UI.",
		Parameters: objectSchema(
			map[string]any{
				"message": stringSchema("A concise progress update for the receiver."),
			},
			"message",
		),
		Strict: boolPointer(true),
	}
}

func askUserToolDefinition() ToolDefinition {
	return ToolDefinition{
		Type:        "function",
		Name:        "ask_user",
		Description: "Ask the receiver one focused clarification question and wait for the answer.",
		Parameters: objectSchema(
			map[string]any{
				"title":       stringSchema("Short title for the question card."),
				"prompt":      stringSchema("The full question to show the receiver."),
				"placeholder": stringSchema("Optional answer hint. Pass an empty string when none."),
			},
			"title",
			"prompt",
			"placeholder",
		),
		Strict: boolPointer(true),
	}
}

func safeQueryToolDefinition() ToolDefinition {
	return ToolDefinition{
		Type:        "function",
		Name:        "run_safe_query",
		Description: "Run a privacy-safe aggregate query against approved data and return only sanitized results.",
		Parameters: objectSchema(
			map[string]any{
				"sql": stringSchema("Aggregate-safe SQL to evaluate."),
				"why": stringSchema("One short sentence explaining why this query is needed. Pass an empty string when not applicable."),
			},
			"sql",
			"why",
		),
		Strict: boolPointer(true),
	}
}

func submitResultToolDefinition() ToolDefinition {
	return ToolDefinition{
		Type:        "function",
		Name:        "submit_result",
		Description: "Stage the final privacy-safe result for receiver review and approval.",
		Parameters: objectSchema(
			map[string]any{
				"summary": stringSchema("Short summary of what the staged result contains."),
				"payload": stringSchema("JSON-encoded payload matching the output contract. Must be a valid JSON string; serialize the object before calling."),
			},
			"summary",
			"payload",
		),
		Strict: boolPointer(true),
	}
}

func objectSchema(properties map[string]any, required ...string) map[string]any {
	return map[string]any{
		"type":                 "object",
		"properties":           properties,
		"required":             required,
		"additionalProperties": false,
	}
}

func stringSchema(description string) map[string]any {
	return map[string]any{
		"type":        "string",
		"description": description,
	}
}
