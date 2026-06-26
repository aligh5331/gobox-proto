# SPEC: Auth Service gRPC Contracts
# BUDGET: small (<5K)
# SCOPE: proto/auth/v1/auth.proto
# STATUS: draft

Feature: Auth Service — gRPC contract validation
  The Auth service exposes three internal gRPC RPCs: GetUser, ValidateSession, and GetPublicKey.
  These are consumed by the Core API. Register/Login/Logout are REST-only and out of scope.

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
