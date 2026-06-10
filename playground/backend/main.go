package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	compileTimeout = 10 * time.Second
	runTimeout     = 5 * time.Second
	maxOutputSize  = 64 * 1024 // 64KB
	maxCodeSize    = 64 * 1024 // 64KB
)

type CompileRequest struct {
	Code string `json:"code"`
}

type CompileResponse struct {
	Output  string `json:"output"`
	IsError bool   `json:"isError"`
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/compile", handleCompile)
	mux.HandleFunc("/health", handleHealth)
	mux.Handle("/", http.FileServer(http.Dir("./frontend")))

	log.Printf("Bux Playground server starting on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, cors(mux)))
}

func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func handleCompile(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Read code from body
	body, err := io.ReadAll(io.LimitReader(r.Body, maxCodeSize+1))
	if err != nil {
		writeError(w, "Failed to read request body")
		return
	}
	if len(body) > maxCodeSize {
		writeError(w, "Code exceeds maximum size (64KB)")
		return
	}

	code := strings.TrimSpace(string(body))
	if code == "" {
		writeError(w, "Empty code")
		return
	}

	// Create temp project directory
	tmpDir, err := os.MkdirTemp("", "bux-playground-*")
	if err != nil {
		writeError(w, "Failed to create temp directory")
		return
	}
	defer os.RemoveAll(tmpDir)

	// Write code to src/Main.bux
	srcDir := filepath.Join(tmpDir, "src")
	if err := os.MkdirAll(srcDir, 0755); err != nil {
		writeError(w, "Failed to create src directory")
		return
	}

	mainFile := filepath.Join(srcDir, "Main.bux")
	if err := os.WriteFile(mainFile, []byte(code), 0644); err != nil {
		writeError(w, "Failed to write source file")
		return
	}

	// Write bux.toml
	buxToml := `[Package]
Name = "playground"
Version = "0.1.0"
Type = "bin"

[Build]
Output = "Bin"
`
	if err := os.WriteFile(filepath.Join(tmpDir, "bux.toml"), []byte(buxToml), 0644); err != nil {
		writeError(w, "Failed to write bux.toml")
		return
	}

	// Run buxc2 build inside Docker sandbox
	output, isError := runInSandbox(tmpDir)

	// Truncate output if too large
	if len(output) > maxOutputSize {
		output = output[:maxOutputSize] + "\n... (output truncated)"
	}

	resp := CompileResponse{
		Output:  output,
		IsError: isError,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func runInSandbox(projectDir string) (string, bool) {
	// Check if running inside Docker (sandbox container available)
	sandboxImage := os.Getenv("SANDBOX_IMAGE")
	if sandboxImage == "" {
		sandboxImage = "bux-playground-sandbox"
	}

	// Determine if we use Docker or local buxc2
	useDocker := os.Getenv("USE_DOCKER") != "0"

	var cmd *exec.Cmd
	var ctx context.Context
	var cancel context.CancelFunc

	if useDocker {
		// Run compilation inside Docker container
		ctx, cancel = context.WithTimeout(context.Background(), compileTimeout)
		defer cancel()

		cmd = exec.CommandContext(ctx, "docker", "run",
			"--rm",
			"--network=none",
			"--memory=128m",
			"--memory-swap=128m",
			"--cpus=1.0",
			"--pids-limit=64",
			"--read-only",
			"--tmpfs", "/tmp:noexec,nosuid,size=50m",
			"-v", projectDir+":/project:ro",
			"-w", "/project",
			sandboxImage,
			"sh", "-c",
			"buxc2 build 2>&1 && timeout 5s ./build/playground 2>&1 || true",
		)
	} else {
		// Local mode (for development)
		ctx, cancel = context.WithTimeout(context.Background(), compileTimeout)
		defer cancel()

		buxc2Path := os.Getenv("BUXC2_PATH")
		if buxc2Path == "" {
			buxc2Path = "buxc2"
		}

		// First compile
		compileCmd := exec.CommandContext(ctx, buxc2Path, "build")
		compileCmd.Dir = projectDir
		compileCmd.Env = append(os.Environ(),
			"HOME=/tmp",
		)

		compileOut, compileErr := compileCmd.CombinedOutput()
		output := string(compileOut)
		if compileErr != nil {
			return output, true
		}

		// Then run the binary
		runCtx, runCancel := context.WithTimeout(context.Background(), runTimeout)
		defer runCancel()

		binPath := filepath.Join(projectDir, "build", "playground")
		runCmd := exec.CommandContext(runCtx, binPath)
		runCmd.Dir = projectDir
		runOut, runErr := runCmd.CombinedOutput()
		output += string(runOut)
		if runErr != nil && runCtx.Err() != context.DeadlineExceeded {
			output += "\nRuntime error: " + runErr.Error()
		}

		return output, false
	}

	// Run Docker command
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out

	err := cmd.Run()
	output := out.String()

	if ctx.Err() == context.DeadlineExceeded {
		output += "\nTimeout: compilation or execution took too long"
		return output, true
	}

	if err != nil {
		return output, true
	}

	return output, false
}

func writeError(w http.ResponseWriter, msg string) {
	resp := CompileResponse{
		Output:  msg,
		IsError: true,
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}
