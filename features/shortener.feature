# SPEC: Link Shortener Service gRPC Contracts
# BUDGET: small (<5K)
# SCOPE: proto/shortener/v1/shortener.proto
# STATUS: draft

Feature: Link Shortener Service — gRPC contract validation
  The Shortener service exposes four internal gRPC RPCs: CreateLink, GetLink, DeleteLink,
  and ListLinks. Public redirects (GET /s/{slug}) are HTTP-only and out of scope.

  Background:
    Given the Shortener gRPC server is running on port 9091
    And a registered user with id "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    And a file with id "a47ac10b-58cc-4372-a567-0e02b2c3d490" is owned by user "f47ac10b-58cc-4372-a567-0e02b2c3d479"

  # ---------------------------------------------------------------------------
  # CreateLink
  # ---------------------------------------------------------------------------

  Scenario: CreateLink returns a short link with a unique slug
    When a CreateLink request is sent with:
      | Field      | Value                                |
      | user_id    | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | file_id    | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | target_url | https://s3.example.com/photo.jpg     |
    Then the response status code is OK
    And the response ShortLinkResponse has:
      | Field      | Value                                |
      | user_id    | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | file_id    | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | target_url | https://s3.example.com/photo.jpg     |
    And the response ShortLinkResponse slug matches the pattern [a-zA-Z0-9]{6}
    And the response ShortLinkResponse id is a valid UUID
    And the response ShortLinkResponse hit_count is 0
    And the response ShortLinkResponse created_at is a valid google.protobuf.Timestamp

  Scenario: CreateLink with expires_at sets an expiration on the link
    When a CreateLink request is sent with:
      | Field      | Value                                |
      | user_id    | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | file_id    | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | target_url | https://s3.example.com/photo.jpg     |
      | expires_at | 2027-01-01T00:00:00Z                 |
    Then the response status code is OK
    And the response ShortLinkResponse expires_at is set
    And the response ShortLinkResponse expires_at is a valid google.protobuf.Timestamp

  Scenario: CreateLink without expires_at returns a link that never expires
    When a CreateLink request is sent with:
      | Field      | Value                                |
      | user_id    | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | file_id    | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | target_url | https://s3.example.com/photo.jpg     |
    Then the response status code is OK
    And the response ShortLinkResponse expires_at is null

  Scenario: CreateLink returns InvalidArgument when target_url is empty
    When a CreateLink request is sent with:
      | Field      | Value                                |
      | user_id    | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | file_id    | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | target_url |                                      |
    Then the response status code is InvalidArgument
    And the error message contains "invalid target_url"

  Scenario: CreateLink returns InvalidArgument when user_id is malformed
    When a CreateLink request is sent with:
      | Field      | Value                                |
      | user_id    | bad-uuid                             |
      | file_id    | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | target_url | https://s3.example.com/photo.jpg     |
    Then the response status code is InvalidArgument
    And the error message contains "invalid user_id"

  Scenario: CreateLink returns AlreadyExists on persistent slug collision
    Given slug generation has failed 5 consecutive collision retries for user "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    When a CreateLink request is sent with:
      | Field      | Value                                |
      | user_id    | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | file_id    | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | target_url | https://s3.example.com/photo.jpg     |
    Then the response status code is AlreadyExists
    And the error message contains "slug collision"

  # ---------------------------------------------------------------------------
  # GetLink
  # ---------------------------------------------------------------------------

  Scenario: GetLink returns the link for a valid slug
    Given a short link with slug "aB3kR9" exists for file "a47ac10b-58cc-4372-a567-0e02b2c3d490"
    When a GetLink request is sent with slug "aB3kR9"
    Then the response status code is OK
    And the response ShortLinkResponse has:
      | Field      | Value                                |
      | slug       | aB3kR9                               |
      | file_id    | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
    And the response ShortLinkResponse target_url is not empty

  Scenario: GetLink returns NotFound for non-existent slug
    Given no short link exists with slug "XxXxXx"
    When a GetLink request is sent with slug "XxXxXx"
    Then the response status code is NotFound
    And the error message is "link not found"

  Scenario: GetLink returns InvalidArgument for empty slug
    When a GetLink request is sent with slug ""
    Then the response status code is InvalidArgument
    And the error message contains "invalid slug"

  Scenario: GetLink returns InvalidArgument for slug that is not 6 characters
    When a GetLink request is sent with slug "abc"
    Then the response status code is InvalidArgument
    And the error message contains "invalid slug"

  # ---------------------------------------------------------------------------
  # DeleteLink
  # ---------------------------------------------------------------------------

  Scenario: DeleteLink deletes an existing link
    Given a short link with id "b47ac10b-58cc-4372-a567-0e02b2c3d491" exists for user "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    When a DeleteLink request is sent with:
      | Field   | Value                                |
      | link_id | b47ac10b-58cc-4372-a567-0e02b2c3d491 |
      | user_id | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
    Then the response status code is OK
    And the response is a google.protobuf.Empty

  Scenario: DeleteLink returns NotFound for non-existent link_id
    When a DeleteLink request is sent with:
      | Field   | Value                                |
      | link_id | 00000000-0000-0000-0000-000000000000 |
      | user_id | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
    Then the response status code is NotFound
    And the error message is "link not found"

  Scenario: DeleteLink returns InvalidArgument for empty link_id
    When a DeleteLink request is sent with:
      | Field   | Value                                |
      | link_id |                                      |
      | user_id | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
    Then the response status code is InvalidArgument
    And the error message contains "invalid link_id"

  Scenario: DeleteLink returns PermissionDenied for non-owner
    Given a short link with id "b47ac10b-58cc-4372-a567-0e02b2c3d491" is owned by user "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    When a DeleteLink request is sent with:
      | Field   | Value                                |
      | link_id | b47ac10b-58cc-4372-a567-0e02b2c3d491 |
      | user_id | 99999999-9999-9999-9999-999999999999 |
    Then the response status code is PermissionDenied
    And the error message is "permission denied"

  # ---------------------------------------------------------------------------
  # ListLinks
  # ---------------------------------------------------------------------------

  Scenario: ListLinks returns all links for a user
    Given user "f47ac10b-58cc-4372-a567-0e02b2c3d479" has 2 short links
    When a ListLinks request is sent with:
      | Field     | Value                                |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | page_size | 50                                   |
    Then the response status code is OK
    And the response ListLinksResponse links count is 2
    And the response ListLinksResponse next_page_token is empty

  Scenario: ListLinks returns empty list when user has no links
    Given user "f47ac10b-58cc-4372-a567-0e02b2c3d479" has 0 short links
    When a ListLinks request is sent with:
      | Field     | Value                                |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
    Then the response status code is OK
    And the response ListLinksResponse links is empty
    And the response ListLinksResponse next_page_token is empty

  Scenario: ListLinks paginates through multiple pages
    Given user "f47ac10b-58cc-4372-a567-0e02b2c3d479" has 5 short links
    When a ListLinks request is sent with:
      | Field     | Value                                |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | page_size | 2                                    |
    Then the response status code is OK
    And the response ListLinksResponse links count is 2
    And the response ListLinksResponse next_page_token is not empty

  Scenario: ListLinks returns InvalidArgument for empty user_id
    When a ListLinks request is sent with:
      | Field   | Value |
      | user_id |       |
    Then the response status code is InvalidArgument
    And the error message contains "invalid user_id"
