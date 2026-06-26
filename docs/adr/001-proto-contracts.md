# ADR 001 — Protobuf Contract Conventions for GoBox Services

**Status:** Draft  
**Date:** 2026-06-26  
**Author:** Architect  
**Reviewers:** (none yet)  
**Phase:** 0 (gobox-proto)

---

## Table of Contents

1. [Decision](#decision)
2. [Context](#context)
3. [Options considered](#options-considered)
4. [Chosen approach](#chosen-approach)
   1. [Package naming](#41-package-naming)
   2. [Timestamp handling](#42-timestamp-handling)
   3. [Pagination pattern](#43-pagination-pattern)
   4. [Enum conventions](#44-enum-conventions)
   5. [Error propagation](#45-error-propagation)
   6. [UUID representation](#46-uuid-representation)
   7. [Empty responses](#47-empty-responses)
   8. [User identity propagation](#48-user-identity-propagation)
5. [Per-service message contract sketches](#5-per-service-message-contract-sketches)
   1. [Auth (`gobox.auth.v1`)](#51-auth-goboxauthv1)
   2. [File Upload (`gobox.fileupload.v1`)](#52-file-upload-goboxfileuploadv1)
   3. [Link Shortener (`gobox.shortener.v1`)](#53-link-shortener-goboxshortenerv1)
   4. [Thumbnail Generator (`gobox.thumbgen.v1`)](#54-thumbnail-generator-goboxthumbgenv1)
6. [Constraints and risks](#6-constraints-and-risks)
7. [Appendix: gRPC status code mapping](#7-appendix-grpc-status-code-mapping)

---

## 1. Decision

Adopt a consistent set of protobuf conventions across all four GoBox gRPC services, covering package naming, timestamp types, pagination, enums, error handling, UUID representation, and user identity propagation. These conventions apply to every `.proto` file in the `gobox-proto` repository and must be reviewed as a block before any single service's proto file is written.

---

## 2. Context

GoBox has four internal gRPC services (Auth, FileUpload, Shortener, ThumbGen), all consumed by the Core API. The proto contracts live in a shared `gobox-proto` repo. Without upfront conventions, each service's proto file could evolve independently, leading to:

- Inconsistent field naming and types for the same concepts (e.g., timestamps, UUIDs).
- Divergent pagination mechanisms that force the Core API to implement multiple cursor strategies.
- Enum value collisions or unclear zero-value semantics.
- Mixed error-handling styles (custom error messages vs. standard gRPC status codes).
- Opaque request messages where it's unclear which fields come from JWT context vs. client input.

The spec (`GOBOX_SPEC.md` §6) defines the directory layout and codegen command but leaves message-level design details open.

---

## 3. Options considered

### 3.1 Package naming

| Option | Pros | Cons |
|--------|------|------|
| **`gobox.{service}.v1`** (Google AIP-style) | Clear hierarchy, versioned, discoverable in `buf` registry; matches directory path | Slightly verbose for internal-only services |
| `{service}.v1` | Shorter | Ambiguous without prefix; risks collision if other orgs share a registry |
| `gobox_v1_{service}` | Flat, no nesting | Non-standard; harder to map to directory structure |

**Decision:** `gobox.{service}.v1` — it matches the std protobuf package naming convention and aligns with the spec's directory layout.

### 3.2 Timestamps

| Option | Pros | Cons |
|--------|------|------|
| **`google.protobuf.Timestamp`** | Standard WKT; correct timezone handling; native Go conversion via `timestamppb` | Requires importing WKT; slightly more verbose in proto |
| `int64 unix_seconds` | Simple; no imports needed | No standard proto semantic; ambiguous units (seconds vs ms); no timezone context |
| `string` (RFC 3339) | Human-readable | Parsing overhead; no standard validation in proto |

**Decision:** `google.protobuf.Timestamp` — the only correct choice for microservice contracts. Provides nanosecond precision, standard wire format, and first-class support in every gRPC language.

### 3.3 Pagination

| Option | Pros | Cons |
|--------|------|------|
| **`page_size` + `page_token`** (Google AIP-158) | Industry standard; token is opaque, supports cursor-based pagination | Token encoding/decoding logic |
| `page_size` + `page_number` | Simpler; offset-based | Inconsistent results if rows inserted/deleted between pages; not suitable for large datasets |
| `page_size` + `last_seen_id` | Efficient for UUID-based tables | Leaks implementation details in the API contract |

**Decision:** `page_size` + `page_token` with `next_page_token` in the response. The token is an opaque string (typically base64-encoded cursor). An empty `next_page_token` signals the last page.

### 3.4 Enum conventions

| Option | Pros | Cons |
|--------|------|------|
| **`PREFIX_UNSPECIFIED = 0` + `PREFIX_{VALUE} = N`** | Zero value explicitly invalid; matches protobuf best practice | Verbose enum value names |
| `{Value} = 0` for a valid default | Simpler | Zero-value trap: unset fields silently get a valid default, which is semantically wrong |
| Use `string` instead of enum | Flexible; no wire compatibility issues | No validation at the protobuf level; typos become runtime errors |

**Decision:** Use proto enums with an `UNSPECIFIED = 0` sentinel value. Enum values are prefixed with the enum name (protobuf requirement for C++ scoping). Example: `FILE_STATUS_UNSPECIFIED = 0; FILE_STATUS_PENDING = 1;`.

### 3.5 Error propagation

| Option | Pros | Cons |
|--------|------|------|
| **Standard gRPC status codes** | Built into gRPC; interop with HTTP mapping; no additional proto messages needed | Limited to ~16 codes; lossy if fine-grained error details are needed |
| Custom error message in every response | Full control over error payload | Every RPC must define a response envelope; doubles message count; non-standard |
| `google.rpc.Status` with `ErrorInfo` | Rich error model; used by Google APIs | Requires `google/rpc/error_details.proto` import; over-engineered for current needs |

**Decision:** Use standard gRPC status codes (`codes.Code`) via `status.Error()` / `status.Errorf()`. Do not define custom error messages in proto. If rich error details become necessary in a future iteration, `google.rpc.Status` can be added without breaking wire compatibility (gRPC status details are a side channel).

### 3.6 UUID representation

| Option | Pros | Cons |
|--------|------|------|
| **`string`** | Human-readable; logs/debugging easy; standard UUID format `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` | 36 bytes per field; no semantic type in proto |
| `bytes` (16 bytes binary) | Compact (16 bytes per field) | Opaque in logs; requires conversion code everywhere |
| `google.protobuf.StringValue` wrapping string | Allows null/nil UUIDs | Wrappers are deprecated in newer proto APIs; unnecessary complexity |

**Decision:** `string` for all UUID fields. The 36-byte overhead is negligible for internal gRPC. Services validate UUID format at the application layer. No well-known UUID proto type exists, and custom proto types add friction.

### 3.7 Empty responses

| Option | Pros | Cons |
|--------|------|------|
| **`google.protobuf.Empty`** | Standard WKT; unambiguous | Requires WKT import |
| Custom empty message per service | No import needed | Over-engineered; multiple identical empty messages |
| No return value (stream-only) | Not applicable | |

**Decision:** Use `google.protobuf.Empty` for RPCs that return no data (e.g., `DeleteFile`, `DeleteLink`).

### 3.8 User identity propagation

| Option | Pros | Cons |
|--------|------|------|
| **Explicit `user_id` field in request messages** | Self-documenting contract; no dependency on gRPC interceptor correctness | Slightly more bytes on the wire; redundant with JWT |
| gRPC metadata (`x-user-id` header) | Clean separation of concerns; no schema changes | Contract is invisible in proto file; interceptors must be correct everywhere; harder to test |
| JWT token in gRPC metadata | Full identity context without extra fields | Every gRPC handler must parse JWT; defeats Core API's stateless validation |

**Decision:** Pass `user_id` as an explicit `string` field in every request message that operates on behalf of a user. Rationale: the proto file is the contract, and hiding user identity in transport metadata makes the API contract incomplete. The Core API can inject this from its JWT validation without re-parsing the token. Backend services SHOULD also validate that the caller's authenticated identity (from gRPC metadata) matches the `user_id` field as a defence-in-depth measure.

---

## 4. Chosen approach

### 4.1 Package naming

Every `.proto` file uses the following declaration:

```protobuf
syntax = "proto3";

package gobox.{service}.v1;

option go_package = "github.com/aligh/gobox-proto/gen/{service}/v1;{service}v1";
```

Where `{service}` is one of: `auth`, `fileupload`, `shortener`, `thumbgen`.

The `go_package` option uses the `path;name` form so that:
- The import path is `github.com/aligh/gobox-proto/gen/{service}/v1`
- The Go package name is `{service}v1` (e.g., `authv1`, `fileuploadv1`)

This avoids package name collisions when multiple generated packages are imported in the same binary.

### 4.2 Timestamp handling

- **Proto type:** `google.protobuf.Timestamp`
- **Go conversion:**
  - `time.Time` → `*timestamppb.Timestamp`: `timestamppb.New(t)`
  - `*timestamppb.Timestamp` → `time.Time`: `t.AsTime()`
- **Nil guard:** Generated `*timestamppb.Timestamp` is a pointer. All service code must check for nil before calling `.AsTime()` on response fields. Request fields with `google.protobuf.Timestamp` should be validated at the application layer.

Field naming follows the spec:
- `created_at` (creation time, set by server)
- `updated_at` (last modification time, set by server)
- `expires_at` (optional expiry time, set by client or server)

### 4.3 Pagination pattern

Applied to all `List*` RPCs:

```protobuf
message List{X}Request {
    string user_id = 1;       // Owner of the resources
    int32 page_size = 2;      // Max items per page; server may cap this
    string page_token = 3;    // Opaque cursor from previous response; empty for first page
}

message List{X}Response {
    repeated {X} items = 1;   // The page of results
    string next_page_token = 2;  // Empty string signals last page
}
```

**Rules:**
- `page_size` defaults to 50 when left at 0; maximum is 200 (server-enforced cap).
- `page_token` is opaque to clients. The server encodes a cursor (typically the `created_at` timestamp or UUID of the last item on the previous page) using base64.
- An empty `next_page_token` (not absent, explicitly empty) means no more pages.
- The response `items` may be empty even when `next_page_token` is non-empty (sparse page).

### 4.4 Enum conventions

```protobuf
enum FileStatus {
    FILE_STATUS_UNSPECIFIED = 0;  // Sentinal: field not set or invalid
    FILE_STATUS_PENDING = 1;
    FILE_STATUS_READY = 2;
    FILE_STATUS_FAILED = 3;
}
```

**Rules:**
- All enum values are prefixed with the enum name in UPPER_SNAKE_CASE.
- The zero value is always `{ENUM_NAME}_UNSPECIFIED = 0`.
- Never assign semantic meaning to the zero value — it must mean "unknown / not set".
- When a client sends a message without setting the enum field, proto3 defaults to 0, which `UNSPECIFIED` catches as invalid.
- Enum values in responses are always a valid defined value (never `UNSPECIFIED` in success cases).

Enums defined per service:

| Enum | Service | Values |
|------|---------|--------|
| `FileStatus` | FileUpload | `PENDING`, `READY`, `FAILED` |
| `JobStatus` | ThumbGen | `QUEUED`, `PROCESSING`, `DONE`, `FAILED` |

These are kept in their respective service proto files. If a future service needs to reference a foreign enum, it should import the defining proto package.

### 4.5 Error propagation

**The contract:** gRPC status codes only. No custom error messages in proto.

**Mapping table** (domain sentinel → gRPC status → HTTP):

| Domain sentinel | gRPC code | HTTP | Condition |
|----------------|-----------|------|-----------|
| `ErrNotFound` | `NotFound` (5) | 404 | Entity does not exist |
| `ErrAlreadyExists` | `AlreadyExists` (6) | 409 | Duplicate creation |
| `ErrInvalidArgument` | `InvalidArgument` (3) | 400 | Validation failure, malformed UUID, etc. |
| `ErrUnauthenticated` | `Unauthenticated` (16) | 401 | Missing or expired JWT |
| `ErrPermissionDenied` | `PermissionDenied` (7) | 403 | JWT valid but not owner |
| `ErrInternal` | `Internal` (13) | 500 | Unexpected server failure |
| `ErrDeadlineExceeded` | `DeadlineExceeded` (4) | 504 | Downstream gRPC call timeout |
| `ErrUnavailable` | `Unavailable` (14) | 503 | DB down, S3 unavailable |

**Implementation pattern (Go, in gRPC server layer):**

```go
import (
    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/status"
)

func (s *server) GetFile(ctx context.Context, req *pb.GetFileRequest) (*pb.FileResponse, error) {
    file, err := s.fileUseCase.GetFile(ctx, req.UserId, req.FileId)
    if err != nil {
        switch {
        case errors.Is(err, domain.ErrNotFound):
            return nil, status.Error(codes.NotFound, "file not found")
        case errors.Is(err, domain.ErrPermissionDenied):
            return nil, status.Error(codes.PermissionDenied, "access denied")
        default:
            return nil, status.Error(codes.Internal, "internal error")
        }
    }
    return fileToProto(file), nil
}
```

**Rules:**
- Never leak internal error details (stack traces, SQL queries, S3 keys) in gRPC error messages.
- Log the full error server-side with a correlation ID; the gRPC message contains only a user-safe summary.
- The Core API (REST gateway) maps gRPC status codes to HTTP status codes using the standard [gRPC-to-HTTP mapping](https://grpc.io/docs/guides/error/).

### 4.6 UUID representation

- **Proto type:** `string`
- **Format:** Standard 8-4-4-4-12 hex: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
- **Server-side validation:** Reject invalid UUIDs with `InvalidArgument` status error.
- **Go package:** `github.com/google/uuid` for parsing and generation.

### 4.7 Empty responses

Use `google.protobuf.Empty` for RPCs with no response data:

```protobuf
import "google/protobuf/empty.proto";

rpc DeleteFile(DeleteFileRequest) returns (google.protobuf.Empty);
```

### 4.8 User identity propagation

Every gRPC request that acts on behalf of a user includes an explicit `user_id` string field. This field is populated by the Core API (which extracts it from the JWT `sub` claim after local validation). Backend services trust this value when the call comes from within the cluster but SHOULD implement a defence-in-depth check against the authenticated context if gRPC mTLS or per-request JWT is added later.

---

## 5. Per-service message contract sketches

The following sections define the full message types for each service. These are design sketches — the `.proto` files will be the source of truth once written.

### 5.1 Auth (`gobox.auth.v1`)

**File:** `proto/auth/v1/auth.proto`

```protobuf
package gobox.auth.v1;
option go_package = "github.com/aligh/gobox-proto/gen/auth/v1;authv1";

import "google/protobuf/timestamp.proto";
import "google/protobuf/empty.proto";

service AuthService {
    // GetUser returns user profile by ID.
    // Used by Core API to serve GET /api/v1/me.
    rpc GetUser(GetUserRequest) returns (UserResponse);

    // ValidateSession checks whether a session is still valid (not revoked, not expired).
    // Used by Core API for sensitive operations (optional hardening).
    rpc ValidateSession(ValidateSessionRequest) returns (ValidateSessionResponse);

    // GetPublicKey returns the current RSA public key(s) in JWKS format.
    // Called by other services at startup to seed the key cache.
    rpc GetPublicKey(google.protobuf.Empty) returns (PublicKeyResponse);
}

message GetUserRequest {
    string user_id = 1;  // UUID
}

message UserResponse {
    string id = 1;                              // UUID
    string email = 2;
    string name = 3;
    google.protobuf.Timestamp created_at = 4;
    google.protobuf.Timestamp updated_at = 5;
}

message ValidateSessionRequest {
    string session_id = 1;  // UUID
}

message ValidateSessionResponse {
    bool valid = 1;
    string user_id = 2;     // UUID, populated only if valid=true
}

message PublicKeyResponse {
    string jwks_json = 1;   // JWKS JSON payload containing one or more keys
}

// Note: Register, Login, RefreshToken, Logout, LogoutAll, ChangePassword
// are REST-only endpoints on the Auth service's HTTP port (8080).
// They do NOT go through gRPC. Only GetUser, ValidateSession, GetPublicKey are gRPC.
```

**Design notes:**
- Registration and login are REST endpoints (public), not gRPC. Only read/validate operations are gRPC.
- `PublicKeyResponse` returns JWKS JSON instead of raw PEM. JWKS is the standard format for key distribution and supports key rotation via `kid` field.
- `ValidateSessionResponse` returns `valid` as a boolean rather than an error code, making it trivial for the caller to check.

### 5.2 File Upload (`gobox.fileupload.v1`)

**File:** `proto/fileupload/v1/file.proto`

```protobuf
package gobox.fileupload.v1;
option go_package = "github.com/aligh/gobox-proto/gen/fileupload/v1;fileuploadv1";

import "google/protobuf/timestamp.proto";
import "google/protobuf/empty.proto";

service FileService {
    rpc InitiateUpload(InitiateUploadRequest) returns (InitiateUploadResponse);
    rpc ConfirmUpload(ConfirmUploadRequest) returns (FileResponse);
    rpc GetFile(GetFileRequest) returns (FileResponse);
    rpc ListFiles(ListFilesRequest) returns (ListFilesResponse);
    rpc DeleteFile(DeleteFileRequest) returns (google.protobuf.Empty);
    rpc GetDownloadURL(GetDownloadURLRequest) returns (DownloadURLResponse);
}

enum FileStatus {
    FILE_STATUS_UNSPECIFIED = 0;
    FILE_STATUS_PENDING = 1;
    FILE_STATUS_READY = 2;
    FILE_STATUS_FAILED = 3;
}

message InitiateUploadRequest {
    string user_id = 1;     // UUID, from JWT
    string name = 2;        // Original file name
    int64 size = 3;         // Expected file size in bytes
    string mime_type = 4;   // e.g., "image/jpeg"
}

message InitiateUploadResponse {
    string file_id = 1;                     // UUID, newly created File record
    string upload_url = 2;                  // Presigned S3 PUT URL
    map<string, string> upload_headers = 3; // e.g., {"Content-Type": "image/jpeg"}
}

message ConfirmUploadRequest {
    string file_id = 1;     // UUID
    string user_id = 2;     // UUID, for ownership validation
    string storage_key = 3; // S3 object key (optional — server may derive it)
    int64 size = 4;         // Actual uploaded size, for verification
}

message FileResponse {
    string id = 1;
    string user_id = 2;
    string name = 3;
    int64 size = 4;
    string mime_type = 5;
    FileStatus status = 6;
    google.protobuf.Timestamp created_at = 7;
    google.protobuf.Timestamp updated_at = 8;
}

message GetFileRequest {
    string file_id = 1;  // UUID
    string user_id = 2;  // UUID, for ownership validation
}

message ListFilesRequest {
    string user_id = 1;     // UUID
    int32 page_size = 2;    // Max results (default 50, max 200)
    string page_token = 3;  // Opaque cursor
}

message ListFilesResponse {
    repeated FileResponse files = 1;
    string next_page_token = 2;
}

message DeleteFileRequest {
    string file_id = 1;  // UUID
    string user_id = 2;  // UUID, for ownership validation
}

message GetDownloadURLRequest {
    string file_id = 1;      // UUID
    uint32 ttl_seconds = 2;  // Presigned URL TTL (default 300, max 3600)
}

message DownloadURLResponse {
    string url = 1;
    google.protobuf.Timestamp expires_at = 2;
}
```

**Design notes:**
- `InitiateUploadResponse` returns a presigned URL and optional headers. The client PUTs directly to S3/MinIO.
- `ConfirmUploadRequest` includes `storage_key` and `size` so the server can verify the upload before marking it `READY`.
- `GetDownloadURLRequest` lets the caller specify a TTL for the presigned GET URL. Default is 5 minutes, max 1 hour.
- `FileStatus` enum aligns with the spec's `pending → ready → failed` lifecycle.
- `DeleteFile` uses `google.protobuf.Empty` — no data returned.

### 5.3 Link Shortener (`gobox.shortener.v1`)

**File:** `proto/shortener/v1/shortener.proto`

```protobuf
package gobox.shortener.v1;
option go_package = "github.com/aligh/gobox-proto/gen/shortener/v1;shortenerv1";

import "google/protobuf/timestamp.proto";
import "google/protobuf/empty.proto";

service ShortenerService {
    rpc CreateLink(CreateLinkRequest) returns (ShortLinkResponse);
    rpc GetLink(GetLinkRequest) returns (ShortLinkResponse);
    rpc DeleteLink(DeleteLinkRequest) returns (google.protobuf.Empty);
    rpc ListLinks(ListLinksRequest) returns (ListLinksResponse);
}

message CreateLinkRequest {
    string user_id = 1;     // UUID
    string file_id = 2;     // UUID of the file to share
    string target_url = 3;  // Presigned download URL for the file
    google.protobuf.Timestamp expires_at = 4;  // Optional: link expiry (null = never)
}

message ShortLinkResponse {
    string id = 1;                              // UUID
    string file_id = 2;                         // UUID
    string user_id = 3;                         // UUID
    string slug = 4;                            // e.g., "aB3kR9"
    string target_url = 5;                      // The URL the slug redirects to
    google.protobuf.Timestamp created_at = 6;
    google.protobuf.Timestamp expires_at = 7;   // Nullable: null = never expires
    int64 hit_count = 8;
}

message GetLinkRequest {
    string slug = 1;    // The short slug, e.g., "aB3kR9"
    // Note: GetLink is used by the public redirect handler (HTTP),
    // so it does not require user_id.
}

message DeleteLinkRequest {
    string link_id = 1;  // UUID
    string user_id = 2;  // UUID, for ownership validation
}

message ListLinksRequest {
    string user_id = 1;
    int32 page_size = 2;
    string page_token = 3;
}

message ListLinksResponse {
    repeated ShortLinkResponse links = 1;
    string next_page_token = 2;
}
```

**Design notes:**
- `GetLinkRequest` uses the `slug` (not UUID) because the public redirect handler only has the slug from the URL path.
- `CreateLinkRequest` takes a `target_url` (presigned URL) at creation time. The redirect handler may regenerate this on each redirect to keep URLs fresh.
- `expires_at` is nullable (`google.protobuf.Timestamp` can be `null` in proto3). A null value means the link never expires.
- `hit_count` is returned in responses but is write-once (incremented server-side on redirect).

### 5.4 Thumbnail Generator (`gobox.thumbgen.v1`)

**File:** `proto/thumbgen/v1/thumbgen.proto`

```protobuf
package gobox.thumbgen.v1;
option go_package = "github.com/aligh/gobox-proto/gen/thumbgen/v1;thumbgenv1";

import "google/protobuf/timestamp.proto";

service ThumbGenService {
    // EnqueueJob creates a thumbnail generation job and returns immediately.
    // Processing happens asynchronously by the worker pool.
    rpc EnqueueJob(EnqueueJobRequest) returns (JobResponse);

    // GetJobStatus returns the current status of a thumbnail job.
    rpc GetJobStatus(GetJobStatusRequest) returns (JobResponse);

    // GetThumbnail returns metadata for a completed thumbnail (or NotFound if not ready).
    rpc GetThumbnail(GetThumbnailRequest) returns (ThumbnailResponse);
}

enum JobStatus {
    JOB_STATUS_UNSPECIFIED = 0;
    JOB_STATUS_QUEUED = 1;
    JOB_STATUS_PROCESSING = 2;
    JOB_STATUS_DONE = 3;
    JOB_STATUS_FAILED = 4;
}

message EnqueueJobRequest {
    string file_id = 1;      // UUID
    string user_id = 2;      // UUID
    string input_key = 3;    // S3 key of the source file
    string mime_type = 4;    // Content type for format detection
}

message JobResponse {
    string id = 1;                              // Job UUID
    string file_id = 2;                         // UUID
    string user_id = 3;                         // UUID
    JobStatus status = 4;
    string input_key = 5;                       // S3 key of source
    string output_key = 6;                      // S3 key of thumbnail (empty until DONE)
    string error_msg = 7;                       // Populated only when status = FAILED
    google.protobuf.Timestamp created_at = 8;
    google.protobuf.Timestamp updated_at = 9;
}

message GetJobStatusRequest {
    string job_id = 1;  // UUID
}

message GetThumbnailRequest {
    string file_id = 1;  // UUID — lookup thumbnail by file, not job
    // Assumes one thumbnail per file. If multiple sizes are added later,
    // add a width/height filter field.
}

message ThumbnailResponse {
    string id = 1;
    string file_id = 2;
    string job_id = 3;
    int32 width = 4;
    int32 height = 5;
    string format = 6;          // e.g., "webp"
    int64 size = 7;             // Thumbnail file size in bytes
    string storage_key = 8;     // S3 key
    string download_url = 9;    // Presigned GET URL for the thumbnail
    google.protobuf.Timestamp created_at = 10;
}
```

**Design notes:**
- `EnqueueJobRequest` includes `input_key` and `mime_type` so the worker knows what to fetch from S3 and how to decode it.
- `JobResponse` is the common response type for both `EnqueueJob` and `GetJobStatus`. The `error_msg` field is only populated when `status = FAILED`.
- `GetThumbnailRequest` takes `file_id` (not `job_id`) because the Core API wants to fetch a thumbnail for a specific file and shouldn't need to track job IDs.
- `ThumbnailResponse` includes a presigned `download_url` so the Core API can return it directly.
- There is no `ListThumbnails` RPC — thumbnails are 1:1 with files in the current design.

---

## 6. Constraints and risks

### 6.1 Constraints

1. **No custom proto options or extensions.** All proto files use only standard proto3 syntax and well-known types. This avoids dependency on custom protoc plugins.
2. **All proto files must compile with the codegen command in GOBOX_SPEC.md §6.** The command uses `protoc` with `--go_out` and `--go-grpc_out` with `paths=source_relative`.
3. **Generated Go code is committed.** The `gen/` directory is checked in so service builds don't require `protoc`.
4. **Maximum one service per proto package.** No shared proto packages across services. If common types are needed later, introduce a `gobox.common.v1` package.
5. **Proto field numbers are sequential starting at 1 per message.** Do not skip numbers; start at 1 for each message.

### 6.2 Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **Wire-incompatible enum changes** (reordering values, removing values) | Medium | High — silent data corruption on mixed-version deployments | Never renumber or repurpose enum values. Deprecate with `reserved` before removal. |
| **Opaque page_token changes between releases** | Low | High — broken pagination during rolling updates | `page_token` format is internal. Servers must handle tokens from one version behind gracefully (decode → validate → fallback to empty token on failure). |
| **google.protobuf.Empty replaced in future API revisions** | Low | Low — Empty is a WKT, unlikely to change | If the need arises, define a service-specific `Empty` or use a stream. This risk is acceptable. |
| **String UUIDs break if formats diverge** (with vs without hyphens) | Medium | Medium — lookup failures | Service code must canonicalize UUIDs to lowercase with hyphens before DB queries. Reject non-conforming UUIDs at the gRPC boundary. |
| **Timestamp nil pointer panics in Go** (for nullable `expires_at` fields) | Medium | High — nil dereference crash | All service code must guard `t.AsTime()` with `if t != nil` before use. Establish this as a code review gate. |

---

## 7. Appendix: gRPC status code mapping

This table is the single source of truth for mapping domain errors to gRPC codes. It must be implemented consistently in the gRPC server layer of every service.

| Domain condition | gRPC code | gRPC number | User-facing message |
|---|---|---|---|
| Entity not found | `NotFound` | 5 | `"{entity} not found"` |
| Already exists (duplicate) | `AlreadyExists` | 6 | `"{entity} already exists"` |
| Malformed input / validation failure | `InvalidArgument` | 3 | `"invalid {field}: {reason}"` |
| Missing or expired credentials | `Unauthenticated` | 16 | `"unauthenticated"` |
| Valid identity but not authorized | `PermissionDenied` | 7 | `"permission denied"` |
| Unexpected server error | `Internal` | 13 | `"internal error"` |
| Upstream call timeout | `DeadlineExceeded` | 4 | `"upstream deadline exceeded"` |
| Dependency unavailable (DB, S3) | `Unavailable` | 14 | `"service temporarily unavailable"` |

**Convention:** Use the user-facing message verbatim from the rightmost column in `status.Error()`. Do not include stack traces, request IDs, or internal state in the gRPC error string. Log those server-side.

---

*This ADR defines the contract baseline. All four service `.proto` files must conform to these conventions before Phase 0 can be considered complete.*

---

Design complete. Ready for Librarian.
