# Python TODO Rules

Framework-specific validation and workflow rules for Python projects.

## Validation Gates

Run these after completing any TODO item:

### Code Quality
```bash
# Lint and auto-fix
ruff check --fix .

# Type checking
mypy .

# Format code
ruff format .
```

### Tests
```bash
# Run all tests
pytest

# Run with coverage
pytest --cov=src --cov-report=term-missing

# Run specific test
pytest tests/test_feature.py -v
```

### Dependencies
```bash
# If using uv
uv pip compile requirements.in -o requirements.txt

# If using pip
pip freeze > requirements.txt
```

## Category-Specific Rules

### [front-end] Tasks (if applicable)
- Use Jinja2 templates properly
- Check static file handling
- Validate HTML output

### [back-end] Tasks
- Use type hints for function signatures
- Handle exceptions appropriately
- Use dataclasses or Pydantic for data structures
- Document public APIs with docstrings

### [tests] Tasks
- Use pytest fixtures for common setup
- Use `@pytest.mark.parametrize` for multiple test cases
- Mock external services (use responses, httpx-mock)
- Test async code with `pytest-asyncio`

### [sysadmin] Tasks
- Never commit secrets or `.env` files
- Use environment variables for configuration
- Document setup in README or INSTALL.md

## Before Marking Complete

Checklist for Python tasks:
- [ ] Ran `ruff check --fix .` (linting)
- [ ] Ran `ruff format .` (formatting)
- [ ] Ran `mypy .` (type checking, if used)
- [ ] Ran `pytest` (tests pass)
- [ ] Updated requirements.txt if dependencies changed
- [ ] Added type hints to new functions
