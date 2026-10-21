name: "Base PRP Template v2 - Context-Rich with Validation Loops"
description: |

## Purpose
Template optimized for AI agents to implement features with sufficient context and self-validation capabilities to achieve working code through iterative refinement.

## Core Principles
1. **Context is King**: Include ALL necessary documentation, examples, and caveats
2. **Validation Loops**: Provide executable tests/lints the AI can run and fix
3. **Information Dense**: Use keywords and patterns from the codebase
4. **Progressive Success**: Start simple, validate, then enhance
5. **Global rules**: Be sure to follow all rules in CLAUDE.md

---

## Goal
[What needs to be built - be specific about the end state and desires]

## Why
- [Business value and user impact]
- [Integration with existing features]
- [Problems this solves and for whom]

## What
[User-visible behavior and technical requirements]

### Success Criteria
- [ ] [Specific measurable outcomes]

## All Needed Context

### Documentation & References (list all context needed to implement the feature)
```yaml
# MUST READ - Include these in your context window
- url: [Official API docs URL]
  why: [Specific sections/methods you'll need]

- file: [app/Services/ExampleService.php]
  why: [Pattern to follow, gotchas to avoid]

- doc: [Library documentation URL]
  section: [Specific section about common pitfalls]
  critical: [Key insight that prevents common errors]

- docfile: [PRPs/ai_docs/file.md]
  why: [docs that the user has pasted in to the project]

```

### Current Codebase tree (run `tree` in the root of the project) to get an overview of the codebase
```bash

```

### Desired Codebase tree with files to be added and responsibility of file
```bash

```

### Known Gotchas of our codebase & Library Quirks
```php
// CRITICAL: [Library name] requires [specific setup]
// Example: Laravel requires CSRF tokens for POST requests
// Example: Eloquent chunks large datasets to avoid memory issues
// Example: We use Laravel 11 with Pest PHP for testing
```

## Implementation Blueprint

### Data models and structure

Create the core data models, we ensure type safety and consistency.
```php
Examples:
 - Eloquent models (app/Models/)
 - Form Requests for validation (app/Http/Requests/)
 - API Resources for responses (app/Http/Resources/)
 - Enums for type safety (app/Enums/)

```

### list of tasks to be completed to fullfill the PRP in the order they should be completed

```yaml
Task 1:
MODIFY app/Services/ExistingService.php:
  - FIND pattern: "class ExistingService"
  - INJECT after line containing "__construct"
  - PRESERVE existing method signatures

CREATE app/Services/NewFeatureService.php:
  - MIRROR pattern from: app/Services/SimilarService.php
  - MODIFY class name and core logic
  - KEEP error handling pattern identical

...(...)

Task N:
...

```


### Per task pseudocode as needed added to each task
```php
// Task 1
// Pseudocode with CRITICAL details - don't write entire code
public function newFeature(NewFeatureRequest $request): JsonResponse
{
    // PATTERN: Validation handled by Form Request (app/Http/Requests/)
    $validated = $request->validated();

    // PATTERN: Use database transactions for multi-step operations
    return DB::transaction(function () use ($validated) {
        // GOTCHA: Use queue for external API calls to avoid timeouts
        // PATTERN: Use existing Service class
        $result = $this->featureService->process($validated);

        // CRITICAL: External API returns 429 if >10 req/sec
        // Use RateLimiter facade or dispatch to queue

        // PATTERN: Standardized response with API Resource
        return new FeatureResource($result);  // see app/Http/Resources/
    });
}
```

### Integration Points
```yaml
DATABASE:
  - migration: "php artisan make:migration add_feature_enabled_to_users_table"
  - index: "$table->index('feature_id')"

CONFIG:
  - add to: config/features.php
  - pattern: "'timeout' => env('FEATURE_TIMEOUT', 30)"
  - update: .env.example with FEATURE_TIMEOUT=30

ROUTES:
  - add to: routes/api.php
  - pattern: "Route::apiResource('features', FeatureController::class)"
```

## Validation Loop

### Level 1: Syntax & Style
```bash
# Run these FIRST - fix any errors before proceeding
vendor/bin/pint                      # Auto-fix formatting (Laravel Pint)
php -l app/Services/NewFeature.php   # Syntax check

# Expected: No errors. If errors, READ the error and fix.
```

### Level 2: Unit Tests each new feature/file/function use existing test patterns
```php
// CREATE tests/Feature/NewFeatureTest.php with these test cases (Pest PHP):
it('processes valid input successfully', function () {
    $response = $this->postJson('/api/features', [
        'param' => 'valid_input',
    ]);

    $response->assertStatus(200)
        ->assertJson(['status' => 'success']);
});

it('returns validation error for invalid input', function () {
    $response = $this->postJson('/api/features', [
        'param' => '',
    ]);

    $response->assertStatus(422)
        ->assertJsonValidationErrors(['param']);
});

it('handles external api timeout gracefully', function () {
    Http::fake([
        'external-api.com/*' => Http::response([], 504),
    ]);

    $response = $this->postJson('/api/features', ['param' => 'valid']);

    $response->assertStatus(500)
        ->assertJson(['error' => 'timeout']);
});
```

```bash
# Run and iterate until passing:
php artisan test --filter=NewFeatureTest
# If failing: Read error, understand root cause, fix code, re-run (never mock to pass)
```

### Level 3: Integration Test
```bash
# Start the service
php artisan serve

# Test the endpoint
curl -X POST http://localhost:8000/api/features \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"param": "test_value"}'

# Expected: {"status": "success", "data": {...}}
# If error: Check logs at storage/logs/laravel.log for stack trace
```

## Final validation Checklist
- [ ] All tests pass: `php artisan test`
- [ ] Code formatted: `vendor/bin/pint`
- [ ] No N+1 queries: eager load with `with()`
- [ ] Manual test successful: [specific curl/command]
- [ ] Error cases handled gracefully
- [ ] Logs are informative but not verbose
- [ ] Migrations are reversible (if applicable)

---

## Anti-Patterns to Avoid
- ❌ Don't create new patterns when existing ones work
- ❌ Don't skip validation because "it should work"
- ❌ Don't ignore failing tests - fix them
- ❌ Don't use `env()` outside config files - use `config()` instead
- ❌ Don't hardcode values that should be in config
- ❌ Don't catch all exceptions - be specific
- ❌ Don't lazy load in loops - use eager loading with `with()`