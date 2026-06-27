# ADR 002 — Auth Proto Extension: gRPC RPCs for User Operations

**Status:** Draft  
**Date:** 2026-06-27  
**Author:** Architect  
**Supersedes:** ADR 001 §5.1 (the note stating Register/Login/etc. are REST-only)  
**Phase:** 0 (gobox-proto)

---

## Table of Contents

1. [Decision](#decision)
2. [Context](#context)
3. [Options considered](#options-considered)
4. [Chosen approach](#chosen-approach)
   1. [New RPCs on AuthService](#41-new-rpcs-on-authservice)
   2. [New message: TokenPair](#42-new-message-tokenpair)
   3. [Register RPC: RegisterRequest / RegisterResponse](#43-register-rpc)
   4. [Login RPC: LoginRequest / LoginResponse](#44-login-rpc)
   5. [RefreshToken RPC: RefreshTokenRequest / RefreshTokenResponse](#45-refreshtoken-rpc)
   6. [Logout RPC: LogoutRequest](#46-logout-rpc)
   7. [LogoutAll RPC: LogoutAllRequest](#47-logoutall-rpc)
   8. [UpdateProfile RPC: UpdateProfileRequest / UpdateProfileResponse](#48-updateprofile-rpc)
   9. [ChangePassword RPC: ChangePasswordRequest](#49-changepassword-rpc)
   10. [ValidateSession fix: check Session.revoked in DB](#410-validatesession-fix-check-sessionrevoked-in-db)
   11. [Summary: full AuthService contract](#411-summary-full-authservice-contract)
5. [Constraints and risks](#5-constraints-and-risks)

---

## 1. Decision

Add **seven new gRPC RPCs** to `AuthService` in `proto/auth/v1/auth.proto`:

| RPC | Purpose |
|-----|---------|
| `Register` | Create a new user account |
| `Login` | Authenticate user, issue token pair, create session |
| `RefreshToken` | Rotate refresh token, issue new access token |
| `Logout` | Revoke a single session by session_id |
| `LogoutAll` | Revoke all sessions for a user |
| `UpdateProfile` | Update display name |
| `ChangePassword` | Change password (requires old password) |

Add a **`TokenPair` message** as the standard response envelope for any RPC returning access + refresh tokens.

**Fix `ValidateSession`** to check the `Session.revoked` flag and `Session.expires_at` in the database instead of always returning `valid = true`.

Remove the note in ADR 001 §5.1 that designated Register, Login, RefreshToken, Logout, LogoutAll, ChangePassword as REST-only. These RPCs replace the hypothetical REST endpoints on Auth's HTTP port (8080). Post-ADR 002, Auth's HTTP port (8080) serves only `GET /health` and `GET /auth/v1/.well-known/jwks.json`.

---

## 2. Context

### 2.1 Current state

`proto/auth/v1/auth.proto` defines three RPCs on `AuthService`:
- `GetUser` — read-only user lookup
- `ValidateSession` — stub that always returns `valid = true`
- `GetPublicKey` — JWKS key distribution

ADR 001 §5.1 explicitly states:
> *Note: Register, Login, RefreshToken, Logout, LogoutAll, ChangePassword are REST-only endpoints on the Auth service's HTTP port (8080). They do NOT go through gRPC. Only GetUser, ValidateSession, GetPublicKey are gRPC.*

`GOBOX_SPEC.md` §5.2 lists these REST endpoints on the Core API:
```
POST   /api/v1/auth/register
POST   /api/v1/auth/login
POST   /api/v1/auth/refresh
DELETE /api/v1/auth/logout
GET    /api/v1/me
PUT    /api/v1/me
PUT    /api/v1/me/password
```

### 2.2 The problem

The current design would force the following architecture:

```
Client → Core API (REST) → Auth HTTP (REST on port 8080)
```

This violates three architectural principles established in GOBOX_SPEC.md §3:

1. **Inter-service communication must be gRPC-only** (GOBOX_SPEC.md §3: "Internal (service → service): gRPC only — no REST between services"). Having Core API call Auth via HTTP creates a REST-on-REST dependency that bypasses the gRPC contract layer.

2. **Auth would have two public surfaces**: gRPC (port 8081) for GetUser/ValidateSession/GetPublicKey, and HTTP (port 8080) for Register/Login/RefreshToken/Logout/LogoutAll/UpdateProfile/ChangePassword. This duplicates authentication middleware, rate-limiting, observability, and error-handling logic across both stacks.

3. **The proto file is the contract**. If user lifecycle operations are not in the proto, there is no single source of truth for what Auth can do. The Core API team must read both the proto file and a separate REST API doc to understand Auth's capabilities.

### 2.3 Forensic audit finding

The Forensic audit (Finding 2) identified that the Core API, being a stateless gateway, must proxy all user operations to Auth. If those operations live on Auth's HTTP endpoint instead of gRPC, the Core API must maintain two separate clients (gRPC + HTTP) and Auth must maintain two server stacks. The audit recommends making every user operation a gRPC RPC.

### 2.4 ValidateSession stub

The current `ValidateSession` implementation always returns `valid = true` regardless of the session state. The `Session` domain model (GOBOX_SPEC.md §5.1) includes a `revoked bool` field and an `expires_at` timestamp. A production ValidateSession must query the database, verify the session record exists, check `revoked = false`, and check `expires_at > now()`. Without this fix, a logged-out user's tokens would continue to be accepted for sensitive operations.

---

## 3. Options considered

### 3.1 Keep REST on Auth, fix the contract documentation

| Option | Pros | Cons |
|--------|------|------|
| Keep Auth HTTP endpoints for user ops | No proto changes; Auth team can implement independently | Two public surfaces; violates gRPC-only inter-service rule; Core must maintain two clients; no contract in proto |
| **Move all user ops to gRPC** (chosen) | Single contract in proto; Core has one client type; Auth has one server stack; aligns with GOBOX_SPEC §3 | Proto changes; Auth must generate new gRPC stubs |
| Hybrid: Auth-only ops (Register, etc.) on gRPC, public-facing JWKS/health on HTTP | Best of both | Slightly more Auth server code, but each stack does one thing |

**Decision:** Move all user lifecycle operations to gRPC. Auth's HTTP port (8080) serves only `GET /health` and `GET /auth/v1/.well-known/jwks.json` — stateless, cache-friendly endpoints that do not need gRPC.

### 3.2 TokenPair as dedicated message vs. inline fields

| Option | Pros | Cons |
|--------|------|------|
| **Dedicated `TokenPair` message** (chosen) | Reusable across Register, Login, RefreshToken; single field to document; consistent expiration semantics | One extra message definition |
| Inline `access_token`, `refresh_token`, `expires_in` in each response | No extra type | Duplicated fields across 3+ response messages; drifts over time |
| Flat `LoginResponse` with embedded `TokenPair` as a field | Reuse + explicit grouping | Slightly more nesting in proto |

**Decision:** Define a `TokenPair` message and embed it in responses. This makes the access/refresh token pattern a first-class concept in the contract.

### 3.3 ValidateSession: return boolean vs. gRPC status

| Option | Pros | Cons |
|--------|------|------|
| **Keep `bool valid` field** (chosen) | Caller does a single field check; no error handling for the "invalid" case; matches ADR 001 design | Caller must still distinguish "not found" from "revoked" externally if needed |
| Return `NotFound` gRPC status when session doesn't exist | Cleaner for the "not found" case | Makes every ValidateSession call have two modes (ok==true with valid==false vs. error); more complex caller logic |
| Encode status in a `google.rpc.Status` field | Full flexibility | Over-engineered for a simple boolean check |

**Decision:** Keep `bool valid` in `ValidateSessionResponse`. The only change is in the server implementation: query the DB for the session record, check `revoked` and `expires_at`, then set `valid` accordingly. No proto field changes to `ValidateSessionRequest` or `ValidateSessionResponse`.

### 3.4 UpdateProfile: full user object vs. partial update

| Option | Pros | Cons |
|--------|------|------|
| **Full `UserResponse` in response** (chosen) | Caller gets updated state; standard pattern in REST/gRPC | Slightly more data on the wire |
| `google.protobuf.Empty` | Minimal response | Caller would need a follow-up `GetUser` to see changes |
| Partial `UpdateProfileResponse` with only changed fields | Bandwidth-efficient | Non-standard; complicates client logic |

**Decision:** `UpdateProfileResponse` returns the full `UserResponse` after the update. This follows the same pattern as `RegisterResponse` and `LoginResponse`.

### 3.5 ChangePassword: require old password

| Option | Pros | Cons |
|--------|------|------|
| **Require `old_password` field** (chosen) | Standard security; prevents a stolen access token from changing the password without knowing the old one | More fields in request; caller must collect old password from user |
| Only require `new_password` | Simpler request | If access token leaks, attacker changes password immediately; no defence in depth |

**Decision:** Require `old_password` in `ChangePasswordRequest`. The Auth service verifies `old_password` against the stored bcrypt hash before updating. If verification fails, return `PermissionDenied`.

---

## 4. Chosen approach

### 4.1 New RPCs on AuthService

Add the following RPCs to the existing `AuthService` in `proto/auth/v1/auth.proto`:

```protobuf
service AuthService {
    // --- existing RPCs (unchanged) ---
    rpc GetUser(GetUserRequest) returns (GetUserResponse);
    rpc ValidateSession(ValidateSessionRequest) returns (ValidateSessionResponse);
    rpc GetPublicKey(google.protobuf.Empty) returns (GetPublicKeyResponse);

    // --- new RPCs (phase 2+) ---
    // Register creates a new user account and returns tokens.
    rpc Register(RegisterRequest) returns (RegisterResponse);
    // Login authenticates a user and returns tokens with a new session.
    rpc Login(LoginRequest) returns (LoginResponse);
    // RefreshToken rotates a refresh token and returns a new token pair.
    rpc RefreshToken(RefreshTokenRequest) returns (RefreshTokenResponse);
    // Logout revokes a single session.
    rpc Logout(LogoutRequest) returns (google.protobuf.Empty);
    // LogoutAll revokes all sessions for a user.
    rpc LogoutAll(LogoutAllRequest) returns (google.protobuf.Empty);
    // UpdateProfile updates the user's display name.
    rpc UpdateProfile(UpdateProfileRequest) returns (UpdateProfileResponse);
    // ChangePassword changes the user's password.
    rpc ChangePassword(ChangePasswordRequest) returns (google.protobuf.Empty);
}
```

**Rationale for `google.protobuf.Empty` returns:** Logout, LogoutAll, and ChangePassword have no data to return. Using `Empty` avoids defining a custom empty message and is consistent with ADR 001 §3.7.

### 4.2 New message: TokenPair

```protobuf
// TokenPair contains an access token (JWT) and its associated refresh token.
message TokenPair {
    // access_token is the JWT (RS256-signed), valid for expires_in seconds.
    string access_token = 1;
    // refresh_token is an opaque random string for token rotation.
    string refresh_token = 2;
    // expires_in is the access token TTL in seconds (typically 900).
    int32 expires_in = 3;
}
```

**Design notes:**
- `access_token` is a JWT string. Services other than Auth validate it locally using the cached JWKS public key.
- `refresh_token` is an opaque random string (e.g., 32 bytes base64-encoded). Auth stores a bcrypt hash of it in the `Session.refresh_token` field. It is never decoded by other services.
- `expires_in` is the access token TTL in seconds. The client can use this to pre-emptively refresh before expiry. Default value is 900 (15 minutes).
- `TokenPair` does not include a `token_type` field. All tokens are Bearer tokens as defined in GOBOX_SPEC.md §3.

### 4.3 Register RPC

```protobuf
message RegisterRequest {
    string email = 1;    // User's email address (must be unique)
    string name = 2;     // Display name
    string password = 3; // Plaintext password (bcrypt-hashed server-side)
}

message RegisterResponse {
    UserResponse user = 1;        // The newly created user
    TokenPair token_pair = 2;     // Access + refresh token
    string session_id = 3;        // UUID of the newly created session
}
```

**Design notes:**
- `password` is sent in plaintext over gRPC (localhost / mTLS). Auth hashes it with bcrypt before persisting.
- `RegisterResponse` includes a `session_id` so the caller (Core API) can construct logout URLs or expose session management in the future.
- `UserResponse` is the existing message (defined in ADR 001 §5.1), reused here to avoid duplication.
- Duplicate email returns `AlreadyExists` gRPC status.
- The server sets `user_id` — there is no input `user_id` because the user does not exist yet.

### 4.4 Login RPC

```protobuf
message LoginRequest {
    string email = 1;    // User's email address
    string password = 2; // Plaintext password
}

message LoginResponse {
    UserResponse user = 1;        // Authenticated user
    TokenPair token_pair = 2;     // Access + refresh token
    string session_id = 3;        // UUID of the created session
}
```

**Design notes:**
- Invalid email or password returns `Unauthenticated` gRPC status. Do not distinguish between "email not found" and "wrong password" in the error message to prevent email enumeration.
- Login creates a new `Session` record in the Auth DB (with `user_agent` and `ip` coming from gRPC metadata, passed through from the Core API's HTTP request headers).
- `session_id` is returned so the Core API can return it to the client for use in `DELETE /api/v1/auth/logout`.
- The existing `Session` model (GOBOX_SPEC.md §5.1) is sufficient: no proto changes needed for the session struct itself.

### 4.5 RefreshToken RPC

```protobuf
message RefreshTokenRequest {
    // refresh_token is the opaque token from a previous Login or RefreshToken response.
    string refresh_token = 1;
}

message RefreshTokenResponse {
    TokenPair token_pair = 1;  // New access + rotated refresh token
}
```

**Design notes:**
- Refresh implements **token rotation**: each `RefreshToken` call invalidates the old refresh token and returns a new pair. This limits the window for stolen refresh tokens.
- `RefreshTokenRequest` does not include `user_id` or `session_id`. The server looks up the session by the bcrypt hash of the refresh token.
- If the refresh token is invalid or expired, return `Unauthenticated`.
- If the session is revoked, return `PermissionDenied`.
- `RefreshTokenResponse` returns only the `TokenPair`. The caller does not need user data; it already has the JWT which contains `sub` and `sid`.

### 4.6 Logout RPC

```protobuf
message LogoutRequest {
    // session_id is the UUID of the session to revoke.
    string session_id = 1;
}
```

**Design notes:**
- `Logout` sets `revoked = true` on the Session record.
- The response is `google.protobuf.Empty` — no data returned.
- If the session does not exist, return `NotFound`.
- The caller (Core API) should ensure the caller's `user_id` matches the session owner. Auth may optionally validate this as defence-in-depth.
- No `user_id` field needed — the session_id uniquely identifies the session.

### 4.7 LogoutAll RPC

```protobuf
message LogoutAllRequest {
    // user_id is the UUID of the user whose sessions should be revoked.
    string user_id = 1;
}
```

**Design notes:**
- Sets `revoked = true` on every non-revoked Session for the given user.
- Response is `google.protobuf.Empty`.
- The `user_id` field follows ADR 001 §4.8 (user identity propagation): Core API injects the JWT `sub` claim. Auth SHOULD verify the caller's authenticated identity matches `user_id` as defence-in-depth.

### 4.8 UpdateProfile RPC

```protobuf
message UpdateProfileRequest {
    string user_id = 1;     // UUID of the user to update
    string name = 2;        // New display name
}

message UpdateProfileResponse {
    UserResponse user = 1;  // Updated user record
}
```

**Design notes:**
- Only `name` is updatable in this iteration. Email changes are not supported (would require email verification).
- Returns the full updated `UserResponse` so the Core API can return it directly in `PUT /api/v1/me`.
- If `user_id` does not exist, return `NotFound`.
- Auth validates the caller's authenticated identity against `user_id` as defence-in-depth.

### 4.9 ChangePassword RPC

```protobuf
message ChangePasswordRequest {
    string user_id = 1;       // UUID of the user
    string old_password = 2;  // Current password (for verification)
    string new_password = 3;  // New password (bcrypt-hashed server-side)
}
```

**Design notes:**
- `old_password` is verified against the stored bcrypt hash. If it doesn't match, return `PermissionDenied`.
- `new_password` is bcrypt-hashed before storage. The plaintext never leaves the Auth service's memory.
- Response is `google.protobuf.Empty` — no data returned, no token rotation required. The existing tokens remain valid until their natural expiry.
- Password strength validation is a server-side concern. Auth should enforce minimum length (e.g., 8 characters) and return `InvalidArgument` for weak passwords.
- Token revocation on password change is optional and can be added in a future iteration (`LogoutAll` is the explicit mechanism).

### 4.10 ValidateSession fix: check Session.revoked in DB

**Current behaviour (to be replaced):**
```go
func (s *server) ValidateSession(ctx context.Context, req *pb.ValidateSessionRequest) (*pb.ValidateSessionResponse, error) {
    return &pb.ValidateSessionResponse{Valid: true, UserId: "always-valid"}, nil
}
```

**Required behaviour:**
```go
func (s *server) ValidateSession(ctx context.Context, req *pb.ValidateSessionRequest) (*pb.ValidateSessionResponse, error) {
    session, err := s.sessionRepo.FindByID(ctx, req.SessionId)
    if err != nil {
        if errors.Is(err, domain.ErrNotFound) {
            return &pb.ValidateSessionResponse{Valid: false}, nil  // session not found → not valid
        }
        return nil, status.Error(codes.Internal, "internal error")
    }
    if session.Revoked {
        return &pb.ValidateSessionResponse{Valid: false}, nil  // revoked → not valid
    }
    if time.Now().After(session.ExpiresAt) {
        return &pb.ValidateSessionResponse{Valid: false}, nil  // expired → not valid
    }
    return &pb.ValidateSessionResponse{Valid: true, UserId: session.UserID.String()}, nil
}
```

**Proto contract impact:** None. `ValidateSessionRequest` and `ValidateSessionResponse` messages remain unchanged. Only the server implementation changes.

**Edge cases:**
- Session not found: `valid = false` (not an error — the caller treats it as "not authenticated")
- Session expired: `valid = false`
- Session revoked: `valid = false`
- DB unavailable: return `Unavailable` gRPC status (caller can treat this as a transient failure)

### 4.11 Summary: full AuthService contract

The complete `AuthService` after ADR 002:

```protobuf
syntax = "proto3";

package auth.v1;

option go_package = "gen/auth/v1";

import "google/protobuf/timestamp.proto";
import "google/protobuf/empty.proto";

// AuthService provides user identity management and session validation.
service AuthService {
    // --- existing RPCs ---
    rpc GetUser(GetUserRequest) returns (GetUserResponse);
    rpc ValidateSession(ValidateSessionRequest) returns (ValidateSessionResponse);
    rpc GetPublicKey(google.protobuf.Empty) returns (GetPublicKeyResponse);

    // --- new RPCs ---
    rpc Register(RegisterRequest) returns (RegisterResponse);
    rpc Login(LoginRequest) returns (LoginResponse);
    rpc RefreshToken(RefreshTokenRequest) returns (RefreshTokenResponse);
    rpc Logout(LogoutRequest) returns (google.protobuf.Empty);
    rpc LogoutAll(LogoutAllRequest) returns (google.protobuf.Empty);
    rpc UpdateProfile(UpdateProfileRequest) returns (UpdateProfileResponse);
    rpc ChangePassword(ChangePasswordRequest) returns (google.protobuf.Empty);
}

// --- existing messages (unchanged) ---

message GetUserRequest {
    string user_id = 1;
}

message GetUserResponse {
    string id = 1;
    string email = 2;
    string name = 3;
    google.protobuf.Timestamp created_at = 4;
    google.protobuf.Timestamp updated_at = 5;
}

message ValidateSessionRequest {
    string session_id = 1;
}

message ValidateSessionResponse {
    bool valid = 1;
    string user_id = 2;
}

message GetPublicKeyResponse {
    string jwks_json = 1;
}

// --- new messages ---

message TokenPair {
    string access_token = 1;
    string refresh_token = 2;
    int32 expires_in = 3;
}

message RegisterRequest {
    string email = 1;
    string name = 2;
    string password = 3;
}

message RegisterResponse {
    GetUserResponse user = 1;
    TokenPair token_pair = 2;
    string session_id = 3;
}

message LoginRequest {
    string email = 1;
    string password = 2;
}

message LoginResponse {
    GetUserResponse user = 1;
    TokenPair token_pair = 2;
    string session_id = 3;
}

message RefreshTokenRequest {
    string refresh_token = 1;
}

message RefreshTokenResponse {
    TokenPair token_pair = 1;
}

message LogoutRequest {
    string session_id = 1;
}

message LogoutAllRequest {
    string user_id = 1;
}

message UpdateProfileRequest {
    string user_id = 1;
    string name = 2;
}

message UpdateProfileResponse {
    GetUserResponse user = 1;
}

message ChangePasswordRequest {
    string user_id = 1;
    string old_password = 2;
    string new_password = 3;
}
```

**Key design choices in the summary:**
- `RegisterResponse` and `LoginResponse` reuse `GetUserResponse` as the `user` field type rather than defining a separate `UserResponse` — this avoids a duplicate message.
- `RefreshTokenResponse`, `LogoutRequest` (and LogoutAll, ChangePassword) do NOT include a `user_id` field. Rationale: RefreshToken is identified by the token itself (not the user), and the remaining RPCs have a specific identity scope. Core API can pass `user_id` via gRPC metadata if Auth needs it for auditing.
- `UpdateProfileResponse` reuses `GetUserResponse` as the `user` field to avoid duplication and to remain consistent with Register/Login.

---

## 5. Constraints and risks

### 5.1 Constraints

1. **No new dependencies.** All new messages use only proto3 primitives, `google.protobuf.Timestamp`, `google.protobuf.Empty`, or existing messages (`GetUserResponse`). No new proto imports are needed beyond what auth.proto already declares.

2. **Backward wire compatibility.** The three existing RPCs (GetUser, ValidateSession, GetPublicKey) are unchanged. Services that already import the generated Go code will not break. They will need regenerating to pick up the new RPC stubs, but existing callers are unaffected.

3. **Package naming stays as `auth.v1`.** The existing proto file uses `package auth.v1; option go_package = "gen/auth/v1";`. This ADR does not change the package name. The `gobox.auth.v1` convention from ADR 001 §3.1 was not adopted in the actual proto files; this ADR aligns with the current state.

4. **Proto field numbers** follow sequential ordering starting at 1 for each new message, consistent with ADR 001 §6.1 rule 5.

### 5.2 Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **Password in gRPC request logged in plaintext** | Medium | High — credential leak in logs | Ensure Auth service redacts `password` fields in request logging. Zero-log the password before passing to the use case. |
| **Token rotation on RefreshToken creates orphaned sessions if client drops the response** | Medium | Low — old token still works until its natural expiry; rotation window is short | The old refresh token's session record is NOT deleted on rotation; it is replaced atomically in a transaction. If the client retries with the old token, Auth detects the reuse attempt and can revoke all sessions for that user (indication of token theft). |
| **ValidateSession becomes a hot path if Core API calls it on every request** | High | High — DB load spike; defeats purpose of JWT (local validation) | ValidateSession is explicitly for **sensitive operations only** (password change, profile update, etc.). Core API's normal request flow validates JWT locally. The Core API middleware must not call ValidateSession on every request. |
| **UpdateProfile overwrites name with empty string** | Low | Low — valid user action, just a display issue | Auth should validate `name` is non-empty before updating (return `InvalidArgument` if empty). |
| **ChangePassword old_password brute-force via gRPC** | Low | Medium — attacker enumerates passwords | Auth implements rate limiting on Login and ChangePassword endpoints. gRPC interceptor or application-layer throttle per `user_id`. |
| **User identity mismatch: Core API sends wrong `user_id` in UpdateProfileRequest** | Medium | Medium — user A can modify user B's profile | Auth MUST validate caller identity against `user_id` as defence-in-depth (gRPC metadata check). Core API must also ensure JWT `sub` matches `user_id`. Both layers enforce this. |
| **Session not found in ValidateSession vs. session revoked — same response** | Low | Low — caller only needs boolean | If finer-grained diagnostics are needed in the future, add a `reason` enum to `ValidateSessionResponse`. This is backward-compatible (new field, existing callers ignore it). |

### 5.3 Supersedes note

This ADR supersedes the following text in ADR 001 §5.1:

> *Note: Register, Login, RefreshToken, Logout, LogoutAll, ChangePassword are REST-only endpoints on the Auth service's HTTP port (8080). They do NOT go through gRPC. Only GetUser, ValidateSession, GetPublicKey are gRPC.*

The replacement text:

> *All user lifecycle operations (Register, Login, RefreshToken, Logout, LogoutAll, UpdateProfile, ChangePassword) are gRPC RPCs on AuthService. Auth's HTTP port (8080) serves only `GET /health` and `GET /auth/v1/.well-known/jwks.json`. The Core API proxies all auth-related REST endpoints to Auth via gRPC.*

---

Design complete. Ready for Librarian.
