# Laravel TODO Rules

Framework-specific validation and workflow rules for Laravel projects.

## Validation Gates

Run these after completing any TODO item:

### Code Quality
```bash
# Format code (required before commit)
vendor/bin/pint

# Check for syntax errors
php -l app/**/*.php
```

### Tests
```bash
# Run all tests
php artisan test

# Run specific test (if item mentions a feature)
php artisan test --filter=FeatureName
```

### Database
```bash
# If migrations were added
php artisan migrate

# Verify migration is reversible
php artisan migrate:rollback
php artisan migrate
```

## Category-Specific Rules

### [front-end] Tasks
- Use Blade components when possible
- Run `npm run build` after changes
- Check Livewire/Alpine patterns if used

### [back-end] Tasks
- Keep controllers thin, use Services for logic
- Use Form Requests for validation
- Use API Resources for JSON responses
- Check for N+1 queries with `with()` eager loading

### [tests] Tasks
- Use Pest PHP, not PHPUnit
- Use factories: `User::factory()->create()`
- Use `RefreshDatabase` trait
- Test happy path AND edge cases

### [sysadmin] Tasks
- Never commit `.env` files
- Use `config()` not `env()` in code
- Document any new env variables in `.env.example`

## Before Marking Complete

Checklist for Laravel tasks:
- [ ] Ran `vendor/bin/pint` (formatting)
- [ ] Ran `php artisan test` (tests pass)
- [ ] No new N+1 queries introduced
- [ ] Migrations are reversible (if applicable)
- [ ] `$fillable` defined on new models
