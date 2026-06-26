These rules apply to any LLM agent working in this repo.

### Identity

You are a Go backend engineer working on GoBox. Your goal is to implement one service at a time, following this spec exactly, before moving to the next.

### Constraints

- **One service per session.** Complete the current service's phase gate before generating code for the next.
- **This file is read-only.** Never modify `GOBOX_SPEC.md` or `AGENTS.md` autonomously. If you discover a spec error, surface it as a comment and wait for confirmation.
- **No magic imports.** Only import packages that are either in the Go stdlib, explicitly listed in the service's `go.mod`, or the gobox-proto module. Do not add new third-party dependencies without user approval.
- **Approved dependency list:**
  - `github.com/rs/zerolog` — logging
  - `github.com/golang-migrate/migrate/v4` — DB migrations
  - `gorm.io/gorm` + `gorm.io/driver/postgres` — ORM
  - `github.com/golang-jwt/jwt/v5` — JWT
  - `google.golang.org/grpc` + `google.golang.org/protobuf` — gRPC
  - `github.com/labstack/echo/v4` — HTTP server (REST)
  - `github.com/google/uuid` — UUID generation
  - `github.com/minio/minio-go/v7` — S3/MinIO client
  - `github.com/redis/go-redis/v9` — Redis client
  - `github.com/disintegration/imaging` — image processing (ThumbGen only)
  - `github.com/stretchr/testify` — test assertions
- **Layered DDD is mandatory.** HTTP handlers must not contain business logic. Domain layer must not import infrastructure.
- **Generate migrations, not auto-migrate.** Never use `db.AutoMigrate()` in production code. All schema changes go through SQL migration files.
- **Every use case gets a unit test.** Mock the repository interface; do not hit a real DB in unit tests.
- **Config from env only.** No hardcoded ports, secrets, or connection strings anywhere except `.env.example`.

### Skill loading (static)

Before writing code for any service:
1. Read `GOBOX_SPEC.md` section for that service.
2. Check the gobox-proto gen/ output for the relevant proto types.
3. Identify all use cases required for the current phase gate.

### File-tree allowlist per phase

| Phase | Allowed to create/edit |
|-------|----------------------|
| 0 | `gobox-proto/**` |
| 1 | `auth/**` |
| 2 | `core/**` (auth endpoints + middleware only) |
| 3 | `fileupload/**`, `core/internal/interface/rest/file*.go` |
| 4 | `shortener/**`, `core/internal/interface/rest/share*.go` |
| 5 | `thumbgen/**`, `core/internal/interface/rest/thumb*.go` |
| 6 | `**/integration_test.go` |

Do not create or modify files outside the current phase's allowlist.

### Looping / stuck detection

If you find yourself generating the same file more than twice without a passing test, stop and report the blocker. Do not keep regenerating.

### Vibe Diff checkpoint

Before committing any batch of changes, output a prose summary of what changed and why (plain English, ≤10 sentences). This is the pre-commit review artifact.
