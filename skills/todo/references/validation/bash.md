# Bash TODO Rules

Framework-specific validation and workflow rules for Bash/shell projects.

## Validation Gates

Run these after completing any TODO item:

### Code Quality
```bash
# Syntax check
bash -n script.sh

# ShellCheck static analysis
shellcheck script.sh

# For bashew projects, check all scripts
shellcheck *.sh
```

### Tests
```bash
# If using bats (Bash Automated Testing System)
bats tests/

# Manual smoke test
./script.sh --help
./script.sh --version
```

### Permissions
```bash
# Ensure scripts are executable
chmod +x script.sh
```

## Category-Specific Rules

### Bashew Projects

If project uses bashew patterns (IO:debug, Str:digest, etc.):
- Follow existing function naming conventions
- Use `IO:` prefix for output functions
- Use `Str:` prefix for string manipulation
- Use local variables inside functions
- Quote all variable expansions: `"${var}"`

### General Bash Best Practices

- Use `set -euo pipefail` at script start
- Use `$(command)` not backticks
- Use `[[` for conditionals, not `[`
- Quote variables: `"${var}"` not `$var`
- Use long options: `--recursive` not `-r`
- Use functions for repeated code

### [sysadmin] Tasks
- Add logging with timestamps
- Handle signals for cleanup (trap)
- Validate input arguments
- Exit with meaningful codes

## Before Marking Complete

Checklist for Bash tasks:
- [ ] Ran `bash -n script.sh` (syntax check)
- [ ] Ran `shellcheck script.sh` (linting)
- [ ] Script has `#!/usr/bin/env bash` shebang
- [ ] Script has `set -euo pipefail`
- [ ] Variables are quoted: `"${var}"`
- [ ] Script is executable: `chmod +x`
- [ ] Tested `--help` output
