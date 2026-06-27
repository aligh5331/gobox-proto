# SPEC: Auth Service gRPC Contracts (extended per ADR 002)
# BUDGET: medium (5-10K)
# SCOPE: proto/auth/v1/auth.proto
# STATUS: draft

Feature: Auth Service — gRPC contract validation
  The Auth service exposes ten gRPC RPCs: GetUser, ValidateSession, GetPublicKey,
  Register, Login, RefreshToken, Logout, LogoutAll, UpdateProfile, and ChangePassword.
  The first three are the original contract (Phase 0). The remaining seven were added
  per ADR 002 (Phase 2+) so the Core API can proxy all user operations via gRPC.

  Background:
    Given the Auth gRPC server is running on port 8081
    And a valid JWT with user_id "f47ac10b-58cc-4372-a567-0e02b2c3d479" is available for authenticated calls

  # ---------------------------------------------------------------------------
  # GetUser
  # ---------------------------------------------------------------------------

  Scenario: GetUser returns user profile when user_id exists
    Given a registered user with id "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    When a GetUser request is sent with user_id "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    Then the response status code is OK
    And the response UserResponse has:
      | Field      | Value                                |
      | id         | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | email      | ali@example.com                      |
      | name       | Ali                                  |
    And the response UserResponse created_at is a valid google.protobuf.Timestamp
    And the response UserResponse updated_at is a valid google.protobuf.Timestamp

  Scenario: GetUser returns NotFound for non-existent user_id
    Given no user exists with id "00000000-0000-0000-0000-000000000000"
    When a GetUser request is sent with user_id "00000000-0000-0000-0000-000000000000"
    Then the response status code is NotFound
    And the error message is "user not found"

  Scenario: GetUser returns InvalidArgument for empty user_id
    When a GetUser request is sent with user_id ""
    Then the response status code is InvalidArgument
    And the error message contains "invalid user_id"

  Scenario: GetUser returns InvalidArgument for malformed user_id
    When a GetUser request is sent with user_id "not-a-uuid"
    Then the response status code is InvalidArgument
    And the error message contains "invalid user_id"

  # ---------------------------------------------------------------------------
  # ValidateSession
  # ---------------------------------------------------------------------------

  Scenario: ValidateSession returns valid=true for an active session
    Given an active session with id "b47ac10b-58cc-4372-a567-0e02b2c3d480" for user "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    When a ValidateSession request is sent with session_id "b47ac10b-58cc-4372-a567-0e02b2c3d480"
    Then the response status code is OK
    And the response ValidateSessionResponse has:
      | Field   | Value                                |
      | valid   | true                                 |
      | user_id | f47ac10b-58cc-4372-a567-0e02b2c3d479 |

  Scenario: ValidateSession returns valid=false for a revoked session
    Given a revoked session with id "c47ac10b-58cc-4372-a567-0e02b2c3d481"
    When a ValidateSession request is sent with session_id "c47ac10b-58cc-4372-a567-0e02b2c3d481"
    Then the response status code is OK
    And the response ValidateSessionResponse valid is false

  Scenario: ValidateSession returns valid=false for an expired session
    Given an expired session with id "d47ac10b-58cc-4372-a567-0e02b2c3d482"
    When a ValidateSession request is sent with session_id "d47ac10b-58cc-4372-a567-0e02b2c3d482"
    Then the response status code is OK
    And the response ValidateSessionResponse valid is false

  Scenario: ValidateSession returns valid=false for non-existent session
    Given no session exists with id "00000000-0000-0000-0000-000000000000"
    When a ValidateSession request is sent with session_id "00000000-0000-0000-0000-000000000000"
    Then the response status code is OK
    And the response ValidateSessionResponse valid is false
    And the response ValidateSessionResponse user_id is empty

  Scenario: ValidateSession returns InvalidArgument for empty session_id
    When a ValidateSession request is sent with session_id ""
    Then the response status code is InvalidArgument
    And the error message contains "invalid session_id"

  # ---------------------------------------------------------------------------
  # GetPublicKey
  # ---------------------------------------------------------------------------

  Scenario: GetPublicKey returns JWKS JSON with at least one key
    Given the Auth service has an RSA key pair configured
    When a GetPublicKey request is sent with an Empty message
    Then the response status code is OK
    And the response PublicKeyResponse jwks_json is valid JWKS JSON
    And the JWKS response contains at least one key
    And each key has a "kid" field
    And each key has a "kty" field with value "RSA"

  Scenario: GetPublicKey returns a JWKS with multiple keys during rotation
    Given the Auth service has two RSA key pairs (old and new) during rotation window
    When a GetPublicKey request is sent with an Empty message
    Then the response status code is OK
    And the JWKS response contains exactly 2 keys
    And each key has a distinct "kid" field

  Scenario: GetPublicKey returns Internal when no keys are configured
    Given the Auth service has no RSA key pair configured
    When a GetPublicKey request is sent with an Empty message
    Then the response status code is Internal
    And the error message is "internal error"

  # ===========================================================================
  # ADR 002 EXTENSION — User Lifecycle RPCs
  # STATUS: draft
  # ===========================================================================

  # ---------------------------------------------------------------------------
  # Register
  # ---------------------------------------------------------------------------

  Scenario: Register creates a new user and returns TokenPair with session
    Given a new email "new@example.com" and password "securePass123!" and name "New User" are not yet registered
    When a Register request is sent with email "new@example.com" and password "securePass123!" and name "New User"
    Then the response status code is OK
    And the response RegisterResponse user has:
      | Field      | Value           |
      | email      | new@example.com |
      | name       | New User        |
    And the response RegisterResponse user id is a valid UUID
    And the response RegisterResponse user created_at is a valid google.protobuf.Timestamp
    And the response RegisterResponse user updated_at is a valid google.protobuf.Timestamp
    And the response RegisterResponse token_pair access_token is a non-empty string
    And the response RegisterResponse token_pair refresh_token is a non-empty string
    And the response RegisterResponse token_pair expires_in is a positive integer
    And the response RegisterResponse session_id is a valid UUID

  Scenario: Register returns AlreadyExists for duplicate email
    Given a registered user with email "dupe@example.com"
    When a Register request is sent with email "dupe@example.com" and password "securePass123!" and name "Duplicate"
    Then the response status code is AlreadyExists
    And the error message contains "already exists"

  Scenario: Register returns InvalidArgument for weak password
    When a Register request is sent with email "weak@example.com" and password "123" and name "Weak"
    Then the response status code is InvalidArgument
    And the error message contains "password"

  # ---------------------------------------------------------------------------
  # Login
  # ---------------------------------------------------------------------------

  Scenario: Login authenticates user and returns TokenPair with session
    Given a registered user with email "ali@example.com" and password "correctPass1!"
    When a Login request is sent with email "ali@example.com" and password "correctPass1!"
    Then the response status code is OK
    And the response LoginResponse user has:
      | Field      | Value                                |
      | id         | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | email      | ali@example.com                      |
      | name       | Ali                                  |
    And the response LoginResponse token_pair access_token is a non-empty string
    And the response LoginResponse token_pair refresh_token is a non-empty string
    And the response LoginResponse token_pair expires_in is a positive integer
    And the response LoginResponse session_id is a valid UUID

  Scenario: Login returns Unauthenticated for wrong password
    Given a registered user with email "ali@example.com" and password "correctPass1!"
    When a Login request is sent with email "ali@example.com" and password "wrongPass2@"
    Then the response status code is Unauthenticated
    And the error message is "unauthenticated"

  Scenario: Login returns Unauthenticated for non-existent email
    When a Login request is sent with email "nobody@example.com" and password "anyPass1!"
    Then the response status code is Unauthenticated
    And the error message is "unauthenticated"

  # ---------------------------------------------------------------------------
  # RefreshToken
  # ---------------------------------------------------------------------------

  Scenario: RefreshToken rotates tokens and returns new TokenPair
    Given a valid session with refresh_token "valid-refresh-token-abc"
    When a RefreshToken request is sent with refresh_token "valid-refresh-token-abc"
    Then the response status code is OK
    And the response RefreshTokenResponse token_pair access_token is a non-empty string
    And the response RefreshTokenResponse token_pair refresh_token is a non-empty string
    And the response RefreshTokenResponse token_pair refresh_token is not "valid-refresh-token-abc"
    And the response RefreshTokenResponse token_pair expires_in is a positive integer

  Scenario: RefreshToken returns Unauthenticated for invalid refresh token
    When a RefreshToken request is sent with refresh_token "invalid-fake-token"
    Then the response status code is Unauthenticated
    And the error message is "unauthenticated"

  Scenario: RefreshToken returns PermissionDenied for revoked session
    Given a revoked session with refresh_token "revoked-session-token-xyz"
    When a RefreshToken request is sent with refresh_token "revoked-session-token-xyz"
    Then the response status code is PermissionDenied
    And the error message is "permission denied"

  # ---------------------------------------------------------------------------
  # Logout
  # ---------------------------------------------------------------------------

  Scenario: Logout revokes session successfully
    Given an active session with id "b47ac10b-58cc-4372-a567-0e02b2c3d480" for user "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    When a Logout request is sent with session_id "b47ac10b-58cc-4372-a567-0e02b2c3d480"
    Then the response status code is OK
    And the response body is an Empty message

  Scenario: Logout returns NotFound for non-existent session
    When a Logout request is sent with session_id "00000000-0000-0000-0000-000000000000"
    Then the response status code is NotFound
    And the error message is "session not found"

  # ---------------------------------------------------------------------------
  # LogoutAll
  # ---------------------------------------------------------------------------

  Scenario: LogoutAll revokes all sessions for a user
    Given a user "f47ac10b-58cc-4372-a567-0e02b2c3d479" with 2 active sessions
    When a LogoutAll request is sent with user_id "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    Then the response status code is OK
    And the response body is an Empty message

  Scenario: LogoutAll returns NotFound for non-existent user
    When a LogoutAll request is sent with user_id "00000000-0000-0000-0000-000000000000"
    Then the response status code is NotFound
    And the error message is "user not found"

  # ---------------------------------------------------------------------------
  # UpdateProfile
  # ---------------------------------------------------------------------------

  Scenario: UpdateProfile updates name and returns updated UserResponse
    Given a registered user with id "f47ac10b-58cc-4372-a567-0e02b2c3d479" and name "Ali"
    When an UpdateProfile request is sent with user_id "f47ac10b-58cc-4372-a567-0e02b2c3d479" and name "AliReza"
    Then the response status code is OK
    And the response UpdateProfileResponse user name is "AliReza"
    And the response UpdateProfileResponse user email is "ali@example.com"
    And the response UpdateProfileResponse user updated_at is a valid google.protobuf.Timestamp

  Scenario: UpdateProfile returns NotFound for non-existent user
    When an UpdateProfile request is sent with user_id "00000000-0000-0000-0000-000000000000" and name "Ghost"
    Then the response status code is NotFound
    And the error message is "user not found"

  Scenario: UpdateProfile returns InvalidArgument for empty name
    Given a registered user with id "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    When an UpdateProfile request is sent with user_id "f47ac10b-58cc-4372-a567-0e02b2c3d479" and name ""
    Then the response status code is InvalidArgument
    And the error message contains "name"

  # ---------------------------------------------------------------------------
  # ChangePassword
  # ---------------------------------------------------------------------------

  Scenario: ChangePassword updates password successfully
    Given a registered user with id "f47ac10b-58cc-4372-a567-0e02b2c3d479" and password "oldPass1!"
    When a ChangePassword request is sent with user_id "f47ac10b-58cc-4372-a567-0e02b2c3d479" and old_password "oldPass1!" and new_password "newPass2@"
    Then the response status code is OK
    And the response body is an Empty message

  Scenario: ChangePassword returns PermissionDenied for wrong old password
    Given a registered user with id "f47ac10b-58cc-4372-a567-0e02b2c3d479" and password "actualPass1!"
    When a ChangePassword request is sent with user_id "f47ac10b-58cc-4372-a567-0e02b2c3d479" and old_password "wrongOld!" and new_password "newPass2@"
    Then the response status code is PermissionDenied
    And the error message is "permission denied"

  Scenario: ChangePassword returns InvalidArgument for weak new password
    Given a registered user with id "f47ac10b-58cc-4372-a567-0e02b2c3d479" and password "actualPass1!"
    When a ChangePassword request is sent with user_id "f47ac10b-58cc-4372-a567-0e02b2c3d479" and old_password "actualPass1!" and new_password "abc"
    Then the response status code is InvalidArgument
    And the error message contains "password"
