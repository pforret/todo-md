# Golang TODO Rules

Framework-specific validation and workflow rules for Go projects.

## Validation Gates

Run these after completing any TODO item:

### Code Quality
```bash
# Format code
go fmt ./...

# Vet for suspicious constructs
go vet ./...

# Static analysis (if installed)
staticcheck ./...

# Lint (if golangci-lint installed)
golangci-lint run
```

### Tests
```bash
# Run all tests
go test ./...

# Run with verbose output
go test -v ./...

# Run with coverage
go test -cover ./...

# Run specific package tests
go test -v ./pkg/mypackage/...
```

### Build
```bash
# Verify it builds
go build ./...

# Check for module issues
go mod tidy
go mod verify
```

## Category-Specific Rules

### [front-end] Tasks (if applicable)
- Use `html/template` for HTML output (auto-escaping)
- Validate template rendering
- Check static file embedding with `embed`

### [back-end] Tasks
- Handle errors explicitly, don't ignore `err`
- Use context for cancellation and timeouts
- Close resources with `defer`
- Use interfaces for testability
- Document exported functions and types

### [tests] Tasks
- Use table-driven tests for multiple cases
- Use `testing.T.Run` for subtests
- Use `testify` assertions if preferred
- Mock external dependencies with interfaces

### [sysadmin] Tasks
- Use environment variables for configuration
- Support graceful shutdown with signal handling
- Document build and deployment in README

## Before Marking Complete

Checklist for Go tasks:
- [ ] Ran `go fmt ./...` (formatting)
- [ ] Ran `go vet ./...` (static analysis)
- [ ] Ran `go test ./...` (tests pass)
- [ ] Ran `go mod tidy` (clean dependencies)
- [ ] Errors are handled, not ignored
- [ ] Exported items have documentation comments
