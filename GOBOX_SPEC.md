# GoBox — Project Specification & Agent Guide

> Version 0.1 — initial design  
> This file is the single source of truth for agentic coding sessions.  
> Treat it as a security artifact: never autonomously overwrite it.

---

## Table of contents

1. [Project overview](#1-project-overview)
2. [Monorepo layout](#2-monorepo-layout)
3. [Communication contracts](#3-communication-contracts)
4. [Architecture: layered DDD](#4-architecture-layered-ddd)
5. [Service specifications](#5-service-specifications)
   - 5.1 Auth service
   - 5.2 Core API
   - 5.3 File Upload Center
   - 5.4 Link Shortener
   - 5.5 Thumbnail Generator
6. [gobox-proto repo](#6-gobox-proto-repo)
7. [Cross-cutting concerns](#7-cross-cutting-concerns)
8. [Build order and completion gates](#8-build-order-and-completion-gates)
9. [Agent operating rules (AGENTS.md)](#9-agent-operating-rules-agentsmd)

---

## 1. Project overview

GoBox is a Dropbox-like backend built as five independent Go microservices.  
Users interact exclusively through the **Core API** via REST.  
All inter-service communication uses **gRPC**.  
Authentication is JWT with RSA key pairs so every service can verify tokens locally — no auth round-trip on every request.

### Non-goals (out of scope)
- Frontend / web UI
- Real-time sync (WebSocket push)
- Per-user share permissions (all shares are public links)
- Admin panel

---

## 2. Monorepo layout

```
gobox/                        ← git root, go.work lives here
├── go.work                   ← workspace: lists all service modules
├── go.work.sum
├── auth/
│   ├── go.mod                ← module: github.com/aligh/gobox/auth
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── .env.example
│   └── ...
├── core/
│   ├── go.mod                ← module: github.com/aligh/gobox/core
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── .env.example
│   └── ...
├── fileupload/
│   ├── go.mod
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── .env.example
│   └── ...
├── shortener/
│   ├── go.mod
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── .env.example
│   └── ...
└── thumbgen/
    ├── go.mod
    ├── Dockerfile
    ├── docker-compose.yml
    ├── .env.example
    └── ...
```

`go.work` example:

```
go 1.23

use (
    ./auth
    ./core
    ./fileupload
    ./shortener
    ./thumbgen
)
```

gobox-proto lives in a **separate Git repo**: `github.com/aligh/gobox-proto`  
Each service imports it as a normal Go module dependency in its `go.mod`.

---

## 3. Communication contracts

### External (client → Core API)
- REST over HTTPS
- JSON request/response bodies
- Bearer JWT in `Authorization` header on every authenticated request

### Internal (service → service)
- gRPC only — no REST between services
- mTLS optional (add in a later iteration); for now, JWT is the trust boundary
- Core API is the **only** service with a public port; all others are cluster-internal

### JWT design
- Algorithm: **RS256** (RSA 2048-bit minimum)
- Auth service holds the **private key** — signs tokens only
- Auth service exposes the **JWKS endpoint** (`GET /auth/v1/.well-known/jwks.json`) so other services can fetch and cache public keys at startup
- Every other service **validates tokens locally** from the cached public key — no gRPC call to Auth on each request
- Token fields:
  ```json
  {
    "sub":   "user-uuid",
    "email": "user@example.com",
    "name":  "Ali",
    "iat":   1234567890,
    "exp":   1234567890,
    "jti":   "unique-token-id",     // for revocation
    "sid":   "session-uuid"         // links to a live session record
  }
  ```
- Access token TTL: 15 minutes
- Refresh token: opaque random string, stored in Auth DB, TTL 30 days

### Session management
- Each login creates a `Session` record in Auth's Postgres DB
- Session stores: `id`, `user_id`, `refresh_token_hash`, `user_agent`, `ip`, `created_at`, `last_used_at`, `expires_at`, `revoked`
- Logout revokes the session; token revocation propagates via short access-token TTL
- Core API and other services **do not** call Auth to validate sessions — they only verify the JWT signature and expiry
- `jti` blacklist (optional future hardening): Auth can expose a gRPC endpoint to check if a `jti` is revoked for sensitive operations

---

## 4. Architecture: layered DDD

Every service follows the same four-layer structure:

```
service/
├── cmd/
│   └── main.go               ← wire everything, start servers
├── internal/
│   ├── domain/               ← LAYER 1: pure business logic
│   │   ├── model/            ←   entities, value objects
│   │   ├── repository/       ←   repository interfaces (ports)
│   │   └── service/          ←   domain services (pure logic, no I/O)
│   ├── application/          ← LAYER 2: use cases / orchestration
│   │   └── usecase/          ←   one file per use case
│   ├── infrastructure/       ← LAYER 3: adapters (DB, storage, gRPC clients)
│   │   ├── postgres/         ←   GORM repository implementations
│   │   ├── s3/               ←   MinIO/S3 adapter (where relevant)
│   │   └── grpcclient/       ←   generated gRPC client wrappers
│   └── interface/            ← LAYER 4: delivery (REST handlers, gRPC server)
│       ├── rest/             ←   HTTP handlers, middleware
│       └── grpc/             ←   gRPC server implementations
├── pkg/                      ← shared utilities internal to this service
│   ├── config/               ←   env-based config struct
│   ├── logger/               ←   structured zerolog/zap wrapper
│   └── jwtutil/              ←   JWT parsing/validation (non-auth services)
├── migrations/               ← SQL migration files (golang-migrate)
├── Dockerfile
├── docker-compose.yml
└── .env.example
```

### Dependency rule
Imports flow **inward only**:  
`interface → application → domain` ✓  
`domain → application` ✗  
`infrastructure` implements `domain/repository` interfaces — it never calls application or domain directly.

---

## 5. Service specifications

---

### 5.1 Auth service

**Module:** `github.com/aligh/gobox/auth`  
**Public port:** 8081 (gRPC) + 8080 (HTTP for JWKS + health only)  
**DB:** Postgres

#### Domain model

```
User
  id            uuid PK
  email         string UNIQUE NOT NULL
  name          string
  password_hash string        (bcrypt)
  created_at    timestamp
  updated_at    timestamp

Session
  id              uuid PK
  user_id         uuid FK → User
  refresh_token   string   (stored as bcrypt hash)
  user_agent      string
  ip              string
  created_at      timestamp
  last_used_at    timestamp
  expires_at      timestamp
  revoked         bool DEFAULT false
```

#### Use cases

| Use case | Input | Output |
|----------|-------|--------|
| Register | email, name, password | User, AccessToken, RefreshToken |
| Login | email, password | User, AccessToken, RefreshToken, Session |
| RefreshToken | refresh_token | new AccessToken, new RefreshToken (rotation) |
| Logout | session_id | — |
| LogoutAll | user_id | — (revoke all sessions) |
| GetUser | user_id | User |
| UpdateProfile | user_id, name | User |
| ChangePassword | user_id, old_pass, new_pass | — |

#### gRPC service (exposed to Core API and others)

```protobuf
service AuthService {
  rpc GetUser(GetUserRequest) returns (UserResponse);
  rpc ValidateSession(ValidateSessionRequest) returns (ValidateSessionResponse);
  rpc GetPublicKey(Empty) returns (PublicKeyResponse);   // PEM-encoded public key
}
```

#### HTTP endpoints (public, no auth)

```
GET  /auth/v1/.well-known/jwks.json   → JWKS for other services
GET  /health
```

#### JWT signing

- Private key loaded from env var `JWT_PRIVATE_KEY_PATH` (PEM file mounted as a secret)
- Key rotation: new key pair generates a new `kid`; JWKS serves both old and new for the overlap window

---

### 5.2 Core API

**Module:** `github.com/aligh/gobox/core`  
**Public port:** 8080 (REST)  
**DB:** none (stateless gateway)  
**gRPC clients to:** Auth, FileUpload, Shortener, ThumbGen

Core API is a thin orchestrator. It validates JWT locally (no gRPC to Auth), then calls downstream services via gRPC.

#### Middleware stack (in order)

1. Request ID injection
2. Structured logger
3. JWT validation (RS256, JWKS cached in-memory, refreshed every 5 min)
4. Rate limiter (per user_id, optional: token bucket)
5. CORS

#### REST endpoints

```
POST   /api/v1/auth/register
POST   /api/v1/auth/login
POST   /api/v1/auth/refresh
DELETE /api/v1/auth/logout

GET    /api/v1/me
PUT    /api/v1/me
PUT    /api/v1/me/password

POST   /api/v1/files                   ← proxy upload initiation to FileUpload
GET    /api/v1/files                   ← list user's files
GET    /api/v1/files/{id}              ← file metadata
DELETE /api/v1/files/{id}

POST   /api/v1/files/{id}/share        ← calls Shortener, returns short URL
GET    /api/v1/files/{id}/thumbnail    ← fetch thumbnail URL from ThumbGen

GET    /health
```

#### Error envelope

```json
{
  "error": {
    "code":    "UNAUTHORIZED",
    "message": "token expired"
  }
}
```

HTTP status codes follow gRPC status → HTTP mapping conventions.

---

### 5.3 File Upload Center

**Module:** `github.com/aligh/gobox/fileupload`  
**Public port:** none (internal gRPC only — port 9090)  
**DB:** Postgres (metadata) + MinIO/S3 (blobs)

#### Domain model

```
File
  id            uuid PK
  user_id       uuid           (from JWT sub — no FK to Auth DB)
  name          string
  size          int64
  mime_type     string
  storage_key   string         (object key in S3/MinIO)
  status        enum(pending, ready, failed)
  created_at    timestamp
  updated_at    timestamp
```

#### Use cases

| Use case | Notes |
|----------|-------|
| InitiateUpload | creates File record in pending state, returns presigned PUT URL |
| ConfirmUpload | marks File as ready after client completes upload |
| GetFile | fetch metadata |
| ListFiles | paginated list for a user |
| DeleteFile | soft-delete; purge object from S3 async |
| GetDownloadURL | returns presigned GET URL (time-limited) |

#### gRPC service

```protobuf
service FileService {
  rpc InitiateUpload(InitiateUploadRequest) returns (InitiateUploadResponse);
  rpc ConfirmUpload(ConfirmUploadRequest)   returns (FileResponse);
  rpc GetFile(GetFileRequest)               returns (FileResponse);
  rpc ListFiles(ListFilesRequest)           returns (ListFilesResponse);
  rpc DeleteFile(DeleteFileRequest)         returns (Empty);
  rpc GetDownloadURL(GetDownloadURLRequest) returns (DownloadURLResponse);
}
```

#### Upload flow

```
Client → Core API (POST /files)
  → FileUpload gRPC: InitiateUpload
    ← presigned S3 PUT URL + file_id
  ← 202 Accepted: { file_id, upload_url }

Client → S3/MinIO (PUT upload_url, raw bytes)
  ← 200 OK from S3

Client → Core API (POST /files/{id}/confirm)
  → FileUpload gRPC: ConfirmUpload
    ← FileResponse (status=ready)
  ← 200 OK: file metadata

Core API → ThumbGen gRPC: EnqueueJob (async, fire-and-forget)
```

---

### 5.4 Link Shortener

**Module:** `github.com/aligh/gobox/shortener`  
**Public port:** none internally; Core API proxies creation; redirect is public  
**Port:** 9091 (gRPC internal) + 8082 (HTTP for public redirects only)  
**DB:** Postgres + Redis (redirect cache)

#### Domain model

```
ShortLink
  id          uuid PK
  file_id     uuid           (reference to FileUpload)
  user_id     uuid
  slug        string UNIQUE  (e.g. "aB3kR9")
  target_url  string         (presigned download URL, regenerated on redirect)
  created_at  timestamp
  expires_at  timestamp NULL (NULL = never expires)
  hit_count   int DEFAULT 0
```

#### Slug generation

- 6-character base62 random string
- Collision retry up to 5 times; fail with error if exhausted
- Slugs are **case-sensitive**

#### gRPC service

```protobuf
service ShortenerService {
  rpc CreateLink(CreateLinkRequest)   returns (ShortLinkResponse);
  rpc GetLink(GetLinkRequest)         returns (ShortLinkResponse);
  rpc DeleteLink(DeleteLinkRequest)   returns (Empty);
  rpc ListLinks(ListLinksRequest)     returns (ListLinksResponse);
}
```

#### Public HTTP redirect (no auth, high cache)

```
GET /s/{slug}
  → lookup slug in Redis (TTL 5 min)
  → on miss: lookup Postgres, populate Redis
  → call FileUpload gRPC: GetDownloadURL (fresh presigned URL)
  → 302 redirect to presigned URL
  → increment hit_count async
```

---

### 5.5 Thumbnail Generator

**Module:** `github.com/aligh/gobox/thumbgen`  
**Public port:** none (gRPC only — port 9092)  
**DB:** Postgres (job queue) + MinIO/S3 (thumbnail blobs)  
**Workers:** configurable pool (default 3)

#### Domain model

```
ThumbnailJob
  id          uuid PK
  file_id     uuid
  user_id     uuid
  status      enum(queued, processing, done, failed)
  input_key   string    (S3 key of the source file)
  output_key  string    (S3 key of the thumbnail; NULL until done)
  error_msg   string
  created_at  timestamp
  updated_at  timestamp

Thumbnail
  id          uuid PK
  job_id      uuid FK → ThumbnailJob
  file_id     uuid
  width       int
  height      int
  format      string    (webp)
  size        int64
  storage_key string
  created_at  timestamp
```

#### Processing

- Supported inputs: JPEG, PNG, GIF, WebP, MP4, MOV, AVI (first frame)
- Output: 256×256 WebP (maintain aspect ratio, pad to square)
- Library: `github.com/disintegration/imaging` for images; `ffmpeg` CLI via `exec.Command` for video
- Worker poll interval: 2s (or use Postgres `LISTEN/NOTIFY` for instant pickup)
- Max retries: 3; after that, set status=failed

#### gRPC service

```protobuf
service ThumbGenService {
  rpc EnqueueJob(EnqueueJobRequest)       returns (JobResponse);
  rpc GetJobStatus(GetJobStatusRequest)   returns (JobResponse);
  rpc GetThumbnail(GetThumbnailRequest)   returns (ThumbnailResponse);
}
```

---

## 6. gobox-proto repo

**Repo:** `github.com/aligh/gobox-proto`  
**Imported by:** all services

```
gobox-proto/
├── go.mod              ← module: github.com/aligh/gobox-proto
├── proto/
│   ├── auth/
│   │   └── v1/
│   │       └── auth.proto
│   ├── fileupload/
│   │   └── v1/
│   │       └── file.proto
│   ├── shortener/
│   │   └── v1/
│   │       └── shortener.proto
│   └── thumbgen/
│       └── v1/
│           └── thumbgen.proto
└── gen/                ← generated Go code (committed)
    ├── auth/v1/
    ├── fileupload/v1/
    ├── shortener/v1/
    └── thumbgen/v1/
```

Codegen command (run from proto root):

```bash
protoc \
  --go_out=gen --go_opt=paths=source_relative \
  --go-grpc_out=gen --go-grpc_opt=paths=source_relative \
  -I proto \
  proto/**/**/*.proto
```

Generated code is **committed to the repo** so service builds don't need protoc installed.

---

## 7. Cross-cutting concerns

### Configuration

Every service reads config from environment variables. `.env.example` documents all vars.  
No config files in the binary — 12-factor.

Key env vars per service:

| Var | Used by |
|-----|---------|
| `DATABASE_URL` | all |
| `GRPC_PORT` | all |
| `JWT_PUBLIC_KEY_PATH` | core, fileupload, shortener, thumbgen |
| `JWT_PRIVATE_KEY_PATH` | auth |
| `S3_ENDPOINT`, `S3_BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY` | fileupload, thumbgen |
| `REDIS_URL` | shortener |
| `AUTH_GRPC_ADDR` | core |
| `FILEUPLOAD_GRPC_ADDR` | core, thumbgen |
| `SHORTENER_GRPC_ADDR` | core |
| `THUMBGEN_GRPC_ADDR` | core |
| `WORKER_POOL_SIZE` | thumbgen |

### Logging

Use `github.com/rs/zerolog`. All logs are structured JSON to stdout.  
Log level set by `LOG_LEVEL` env var (debug/info/warn/error).

### Database migrations

Use `github.com/golang-migrate/migrate/v4`.  
Migrations run **automatically at startup** (`migrate.Up()`).  
SQL files live in `migrations/`.

### Error handling

- Domain errors: typed sentinel errors (`var ErrNotFound = errors.New("not found")`)
- gRPC: map domain errors to status codes in the gRPC server layer
- REST: map gRPC status codes to HTTP status in Core API handler

### Health checks

Every service exposes `GET /health → 200 OK {"status":"ok"}` on its HTTP port.  
Docker Compose `healthcheck` uses this endpoint.

### Dockerfile pattern (multi-stage)

```dockerfile
FROM golang:1.23-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /bin/service ./cmd/

FROM gcr.io/distroless/static-debian12
COPY --from=builder /bin/service /service
ENTRYPOINT ["/service"]
```

Note: ThumbGen needs a different base image that includes ffmpeg.

---

## 8. Build order and completion gates

Build one service completely before starting the next.  
"Complete" means: compiles, tests pass, docker-compose up works end-to-end.

### Phase 0 — gobox-proto

Gate: `go build ./gen/...` passes, proto files compile with protoc.

### Phase 1 — Auth service

Gate: all use cases have unit tests; gRPC server responds correctly; JWKS endpoint returns valid keys; docker-compose up spins postgres + auth, POST /auth/v1/register returns a valid JWT.

### Phase 2 — Core API (auth endpoints only)

Gate: register, login, refresh, logout work end-to-end through Core → Auth gRPC; JWT validation middleware rejects expired/invalid tokens with 401.

### Phase 3 — File Upload Center

Gate: InitiateUpload returns a presigned URL pointing at local MinIO; ConfirmUpload marks file ready; ListFiles returns paginated results; Core API file endpoints work.

### Phase 4 — Link Shortener

Gate: CreateLink returns a short URL; GET /s/{slug} redirects to a presigned download URL; Redis cache hit verified.

### Phase 5 — Thumbnail Generator

Gate: EnqueueJob creates a job; worker picks it up within 5s; output WebP stored in MinIO; GetThumbnail returns URL.

### Phase 6 — Integration

Gate: full happy-path E2E test: register → upload file → confirm → create share link → access share link → thumbnail appears.

---

## 9. Agent operating rules (AGENTS.md)

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
