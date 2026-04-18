package receiverharness

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const defaultBaseURL = "https://api.openai.com/v1"

type ResponseClient interface {
	CreateResponse(ctx context.Context, request CreateResponseRequest) (*CreateResponseResponse, error)
}

type HTTPResponseClient struct {
	apiKey     string
	baseURL    string
	httpClient *http.Client
	projectID  string
}

type APIError struct {
	StatusCode int
	Body       string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("openai api error %d: %s", e.StatusCode, strings.TrimSpace(e.Body))
}

func NewHTTPResponseClient(apiKey string) *HTTPResponseClient {
	return &HTTPResponseClient{
		apiKey:  apiKey,
		baseURL: defaultBaseURL,
		httpClient: &http.Client{
			Timeout: 2 * time.Minute,
		},
	}
}

func (c *HTTPResponseClient) WithProject(projectID string) *HTTPResponseClient {
	c.projectID = projectID
	return c
}

func (c *HTTPResponseClient) CreateResponse(
	ctx context.Context,
	request CreateResponseRequest,
) (*CreateResponseResponse, error) {
	if strings.TrimSpace(c.apiKey) == "" {
		return nil, fmt.Errorf("missing OPENAI_API_KEY")
	}

	body, err := json.Marshal(request)
	if err != nil {
		return nil, fmt.Errorf("marshal response request: %w", err)
	}

	httpRequest, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		c.baseURL+"/responses",
		bytes.NewReader(body),
	)
	if err != nil {
		return nil, fmt.Errorf("build response request: %w", err)
	}

	httpRequest.Header.Set("Authorization", "Bearer "+c.apiKey)
	httpRequest.Header.Set("Content-Type", "application/json")

	if c.projectID != "" {
		httpRequest.Header.Set("OpenAI-Project", c.projectID)
	}

	httpResponse, err := c.httpClient.Do(httpRequest)
	if err != nil {
		return nil, fmt.Errorf("post response request: %w", err)
	}
	defer httpResponse.Body.Close()

	responseBody, err := io.ReadAll(httpResponse.Body)
	if err != nil {
		return nil, fmt.Errorf("read response body: %w", err)
	}

	if httpResponse.StatusCode >= http.StatusMultipleChoices {
		return nil, &APIError{
			StatusCode: httpResponse.StatusCode,
			Body:       string(responseBody),
		}
	}

	var response CreateResponseResponse
	if err := json.Unmarshal(responseBody, &response); err != nil {
		return nil, fmt.Errorf("decode response body: %w", err)
	}

	return &response, nil
}

type CreateResponseRequest struct {
	Model              string            `json:"model"`
	Instructions       string            `json:"instructions,omitempty"`
	Input              []InputItem       `json:"input,omitempty"`
	PreviousResponseID string            `json:"previous_response_id,omitempty"`
	Store              *bool             `json:"store,omitempty"`
	Reasoning          *ReasoningConfig  `json:"reasoning,omitempty"`
	Tools              []ToolDefinition  `json:"tools,omitempty"`
	Metadata           map[string]string `json:"metadata,omitempty"`
}

type ReasoningConfig struct {
	Effort string `json:"effort,omitempty"`
}

type InputItem struct {
	Type    string `json:"type,omitempty"`
	Role    string `json:"role,omitempty"`
	Content string `json:"content,omitempty"`
	CallID  string `json:"call_id,omitempty"`
	Output  string `json:"output,omitempty"`
}

func UserMessage(content string) InputItem {
	return InputItem{
		Role:    "user",
		Content: content,
	}
}

func FunctionCallOutput(callID string, output string) InputItem {
	return InputItem{
		Type:   "function_call_output",
		CallID: callID,
		Output: output,
	}
}

type ToolDefinition struct {
	Type        string         `json:"type"`
	Name        string         `json:"name"`
	Description string         `json:"description,omitempty"`
	Parameters  map[string]any `json:"parameters,omitempty"`
	Strict      *bool          `json:"strict,omitempty"`
}

type CreateResponseResponse struct {
	ID         string       `json:"id"`
	Output     []OutputItem `json:"output"`
	OutputText string       `json:"output_text"`
}

type OutputItem struct {
	ID        string          `json:"id"`
	Type      string          `json:"type"`
	CallID    string          `json:"call_id,omitempty"`
	Name      string          `json:"name,omitempty"`
	Arguments json.RawMessage `json:"arguments,omitempty"`
	Content   []ContentItem   `json:"content,omitempty"`
}

type ContentItem struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
}

type FunctionCall struct {
	ID        string
	CallID    string
	Name      string
	Arguments json.RawMessage
}

func (r *CreateResponseResponse) FunctionCalls() []FunctionCall {
	calls := make([]FunctionCall, 0)

	for _, item := range r.Output {
		if item.Type != "function_call" {
			continue
		}

		calls = append(calls, FunctionCall{
			ID:        item.ID,
			CallID:    item.CallID,
			Name:      item.Name,
			Arguments: item.Arguments,
		})
	}

	return calls
}

func (r *CreateResponseResponse) FinalText() string {
	if strings.TrimSpace(r.OutputText) != "" {
		return strings.TrimSpace(r.OutputText)
	}

	parts := make([]string, 0)

	for _, item := range r.Output {
		if item.Type != "message" {
			continue
		}

		for _, content := range item.Content {
			if content.Type != "output_text" {
				continue
			}

			text := strings.TrimSpace(content.Text)
			if text == "" {
				continue
			}

			parts = append(parts, text)
		}
	}

	return strings.Join(parts, "\n\n")
}
