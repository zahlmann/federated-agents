package main

import (
	"bufio"
	"context"
	"fmt"
	"os"

	"federated-agents/receiverharness"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	client := receiverharness.NewHTTPResponseClient(os.Getenv("OPENAI_API_KEY"))
	bridge := receiverharness.NewBridgeRunner(os.Stdin, bufio.NewWriter(os.Stdout), client)

	if err := bridge.Run(context.Background()); err != nil {
		return fmt.Errorf("bridge: %w", err)
	}

	return nil
}
