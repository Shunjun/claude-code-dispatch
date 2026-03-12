# Prompt Guide for Claude Code Dispatch

Best practices and examples for writing effective dispatch prompts.

## Principles

1. **Be specific** — Describe the exact outcome, not just the general idea
2. **Include acceptance criteria** — What does "done" look like?
3. **Mention test requirements** — Claude Code works best when told to verify its work
4. **Reference existing code** — Point to files/patterns to follow
5. **Set boundaries** — What should NOT be changed

## Basic Examples

### Build a feature
```bash
nohup bash scripts/dispatch.sh \
  -p "Build a REST API for user management with FastAPI:
- CRUD endpoints: POST/GET/PUT/DELETE /api/users
- SQLite database with SQLAlchemy
- Pydantic models for request/response validation
- Write tests with pytest, run them, fix any failures
- Add a README with setup instructions" \
  -n "user-api" \
  --permission-mode bypassPermissions \
  --workdir $HOME/projects/user-api \
  > /tmp/dispatch-user-api.log 2>&1 &
```

### Fix a bug
```bash
nohup bash scripts/dispatch.sh \
  -p "Fix the authentication timeout bug:
- Error: 'Token expired' after 5 minutes even with remember-me checked
- Look at src/auth/token.ts and src/middleware/auth.ts
- The refresh token logic seems to not extend the session
- Write a regression test before fixing
- Run the full test suite after" \
  -n "fix-auth-timeout" \
  --permission-mode bypassPermissions \
  --workdir $HOME/projects/my-app \
  > /tmp/dispatch-fix.log 2>&1 &
```

### Code review
```bash
nohup bash scripts/dispatch.sh \
  -p "Review the codebase for security issues:
- Focus on: input validation, SQL injection, XSS, auth bypass
- Check all API endpoints in src/routes/
- Report findings as a markdown file at SECURITY_REVIEW.md
- Include severity (critical/high/medium/low) and fix suggestions" \
  -n "security-review" \
  --permission-mode plan \
  --workdir $HOME/projects/my-app \
  > /tmp/dispatch-review.log 2>&1 &
```

## Advanced Examples

### With cost control
```bash
nohup bash scripts/dispatch.sh \
  -p "Refactor the database layer to use connection pooling" \
  -n "db-refactor" \
  --max-budget-usd 5.00 \
  --max-turns 50 \
  --permission-mode bypassPermissions \
  --workdir $HOME/projects/my-app \
  > /tmp/dispatch-refactor.log 2>&1 &
```

### With fallback model
```bash
nohup bash scripts/dispatch.sh \
  -p "Add comprehensive error handling to all API endpoints" \
  -n "error-handling" \
  --model opus \
  --fallback-model sonnet \
  --permission-mode bypassPermissions \
  --workdir $HOME/projects/my-app \
  > /tmp/dispatch-errors.log 2>&1 &
```

### With Agent Teams (structured subagents)
```bash
nohup bash scripts/dispatch.sh \
  -p "Build a full-stack todo app with React frontend and Express backend" \
  -n "todo-app" \
  --agent-teams \
  --teammate-mode in-process \
  --permission-mode bypassPermissions \
  --workdir $HOME/projects/todo-app \
  > /tmp/dispatch-todo.log 2>&1 &
```

### With custom subagents
```bash
nohup bash scripts/dispatch.sh \
  -p "Build a CLI tool for file encryption" \
  -n "encrypt-cli" \
  --agents-json '{
    "security-reviewer": {
      "description": "Reviews code for cryptographic correctness and security best practices",
      "prompt": "You are a security expert. Review all crypto implementations for correctness, timing attacks, key management issues, and OWASP compliance.",
      "tools": ["Read", "Grep", "Glob", "Bash"],
      "model": "opus"
    },
    "testing-agent": {
      "description": "Writes and runs comprehensive tests",
      "prompt": "You are a testing specialist. Write unit tests, integration tests, and edge case tests. Always run tests after writing them.",
      "tools": ["Read", "Edit", "Write", "Bash", "Glob", "Grep"],
      "model": "sonnet"
    }
  }' \
  --agent-teams \
  --permission-mode bypassPermissions \
  --workdir $HOME/projects/encrypt-cli \
  > /tmp/dispatch-encrypt.log 2>&1 &
```

### With git worktree isolation
```bash
nohup bash scripts/dispatch.sh \
  -p "Implement the new dashboard feature from the spec in docs/dashboard-spec.md" \
  -n "dashboard-feature" \
  --worktree dashboard-feature \
  --permission-mode bypassPermissions \
  --workdir $HOME/projects/my-app \
  > /tmp/dispatch-dashboard.log 2>&1 &
```

### With MCP servers
```bash
nohup bash scripts/dispatch.sh \
  -p "Read the Jira tickets tagged 'sprint-42' and implement the highest priority one" \
  -n "jira-sprint42" \
  --mcp-config ./mcp-servers.json \
  --permission-mode bypassPermissions \
  --workdir $HOME/projects/my-app \
  > /tmp/dispatch-jira.log 2>&1 &
```

### With system prompt customization
```bash
nohup bash scripts/dispatch.sh \
  -p "Refactor the codebase to follow our style guide" \
  -n "style-refactor" \
  --append-system-prompt "Always use TypeScript strict mode. Prefer functional patterns. Use Bun instead of npm." \
  --permission-mode bypassPermissions \
  --workdir $HOME/projects/my-app \
  > /tmp/dispatch-style.log 2>&1 &
```

### With system prompt from file
```bash
# Create a reusable prompt file
cat > /tmp/team-conventions.txt << 'EOF'
Follow these team conventions:
- Use Bun, not npm
- All functions must have JSDoc comments
- Use zod for runtime validation
- Error messages must be user-friendly
- Run bun test before marking as done
EOF

nohup bash scripts/dispatch.sh \
  -p "Add input validation to all API routes" \
  -n "validation" \
  --append-system-prompt-file /tmp/team-conventions.txt \
  --permission-mode bypassPermissions \
  --workdir $HOME/projects/my-app \
  > /tmp/dispatch-validation.log 2>&1 &
```

## Tips

### Prompt length
- Short prompts (<1500 chars): passed as CLI args
- Long prompts: automatically piped via stdin
- Very complex prompts: use `--prompt-file` for reliability

### Agent Teams vs single agent
- **Single agent**: Simple tasks, bug fixes, code review
- **Agent Teams**: Multi-module features, full-stack work, tasks needing parallel exploration
- Agent Teams use significantly more tokens — use `--max-budget-usd` to cap costs

### Permission modes
| Mode | When to use |
|------|-------------|
| `bypassPermissions` | Trusted tasks, background dispatch (most common for dispatch) |
| `plan` | Read-only analysis, code review, security audit |
| `acceptEdits` | Allow file edits but prompt for shell commands |
| `default` | Interactive use (not recommended for dispatch) |

### Model selection
- **Default (inherit)**: Uses whatever Claude Code is configured with
- **`--model opus`**: Complex architecture, multi-file refactors
- **`--model sonnet`**: Standard tasks, good balance of speed/quality
- **`--model haiku`**: Simple fixes, formatting, quick lookups
- **`--fallback-model sonnet`**: Auto-fallback when primary model is overloaded
