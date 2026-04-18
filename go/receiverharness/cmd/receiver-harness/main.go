package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"federated-agents/receiverharness"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	var (
		model                 = flag.String("model", receiverharness.DefaultModel, "Model name to use for the Responses API session.")
		instructionsFile      = flag.String("instructions-file", "", "Optional file that overrides the default harness instructions.")
		packageFile           = flag.String("package-file", "", "Markdown file describing the packaged request.")
		schemaFile            = flag.String("schema-file", "", "Markdown file describing the approved schema.")
		safeQueryResponseFile = flag.String("safe-query-response-file", "", "Optional JSON file returned for every run_safe_query call.")
	)

	flag.Parse()

	if strings.TrimSpace(*packageFile) == "" {
		return fmt.Errorf("--package-file is required")
	}

	if strings.TrimSpace(*schemaFile) == "" {
		return fmt.Errorf("--schema-file is required")
	}

	instructions := receiverharness.BuildReceiverInstructions()
	if *instructionsFile != "" {
		override, err := os.ReadFile(*instructionsFile)
		if err != nil {
			return fmt.Errorf("read instructions file: %w", err)
		}

		instructions = string(override)
	}

	packageMarkdown, err := os.ReadFile(*packageFile)
	if err != nil {
		return fmt.Errorf("read package file: %w", err)
	}

	schemaMarkdown, err := os.ReadFile(*schemaFile)
	if err != nil {
		return fmt.Errorf("read schema file: %w", err)
	}

	client := receiverharness.NewHTTPResponseClient(os.Getenv("OPENAI_API_KEY"))
	registry := receiverharness.NewReceiverToolRegistry(receiverharness.ReceiverCallbacks{
		SendMessage: func(_ context.Context, message string) error {
			fmt.Printf("agent> %s\n", message)
			return nil
		},
		AskUser: func(_ context.Context, title string, prompt string, choices []string) (string, string, error) {
			fmt.Printf("question> %s\n%s\n", title, prompt)
			for i, choice := range choices {
				fmt.Printf("  [%d] %s\n", i+1, choice)
			}

			fmt.Print("receiver (number)> ")
			raw, err := bufio.NewReader(os.Stdin).ReadString('\n')
			if err != nil {
				return "", "", fmt.Errorf("read receiver answer: %w", err)
			}

			trimmed := strings.TrimSpace(raw)
			if trimmed == "" {
				return choices[0], "", nil
			}

			return trimmed, "", nil
		},
		RunSafeQuery: func(_ context.Context, sql string, why string) (any, error) {
			fmt.Printf("safe-query> %s\n", sql)
			if why != "" {
				fmt.Printf("why> %s\n", why)
			}

			if *safeQueryResponseFile == "" {
				return map[string]any{
					"status":  "rejected",
					"message": "standalone CLI demo has no privacy query engine wired",
				}, nil
			}

			payload, err := os.ReadFile(*safeQueryResponseFile)
			if err != nil {
				return nil, fmt.Errorf("read safe query response file: %w", err)
			}

			var decoded any
			if err := json.Unmarshal(payload, &decoded); err != nil {
				return nil, fmt.Errorf("decode safe query response file: %w", err)
			}

			return decoded, nil
		},
		SubmitResult: func(_ context.Context, summary string, payload json.RawMessage) (any, error) {
			fmt.Printf("result-summary> %s\n", summary)
			fmt.Printf("result-payload> %s\n", string(payload))

			return map[string]any{
				"status":  "approved",
				"message": "standalone CLI demo auto-approved the result",
			}, nil
		},
	})

	result, err := receiverharness.RunSession(context.Background(), client, receiverharness.SessionConfig{
		Model:           *model,
		Instructions:    instructions,
		InitialInput:    receiverharness.BuildReceiverInput(string(packageMarkdown), string(schemaMarkdown)),
		ReasoningEffort: "medium",
		Store:           true,
		ToolRegistry:    registry,
	})
	if err != nil {
		return err
	}

	fmt.Printf("final> %s\n", result.FinalText)
	return nil
}
