# SPEC: File Upload Service gRPC Contracts
# BUDGET: medium (5-10K)
# SCOPE: proto/fileupload/v1/file.proto
# STATUS: draft

Feature: File Upload Service — gRPC contract validation
  The FileUpload service exposes six internal gRPC RPCs: InitiateUpload, ConfirmUpload,
  GetFile, ListFiles, DeleteFile, and GetDownloadURL. Files are uploaded by clients
  directly to S3/MinIO via presigned URLs.

  Background:
    Given the FileUpload gRPC server is running on port 9090
    And a registered user with id "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    And a pending file record with id "a47ac10b-58cc-4372-a567-0e02b2c3d490" exists for user "f47ac10b-58cc-4372-a567-0e02b2c3d479"

  # ---------------------------------------------------------------------------
  # InitiateUpload
  # ---------------------------------------------------------------------------

  Scenario: InitiateUpload creates a pending file and returns a presigned URL
    When an InitiateUpload request is sent with:
      | Field     | Value                                |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | name      | photo.jpg                            |
      | size      | 1048576                              |
      | mime_type | image/jpeg                           |
    Then the response status code is OK
    And the response InitiateUploadResponse file_id is a valid UUID
    And the response InitiateUploadResponse upload_url is a valid presigned S3 URL
    And the response InitiateUploadResponse upload_headers contains "Content-Type"
    And the file record with the returned file_id has status FILE_STATUS_PENDING

  Scenario: InitiateUpload returns InvalidArgument when name is empty
    When an InitiateUpload request is sent with:
      | Field     | Value                                |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | name      |                                      |
      | size      | 1048576                              |
      | mime_type | image/jpeg                           |
    Then the response status code is InvalidArgument
    And the error message contains "invalid name"

  Scenario: InitiateUpload returns InvalidArgument when size is zero
    When an InitiateUpload request is sent with:
      | Field     | Value                                |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | name      | photo.jpg                            |
      | size      | 0                                    |
      | mime_type | image/jpeg                           |
    Then the response status code is InvalidArgument
    And the error message contains "invalid size"

  Scenario: InitiateUpload returns InvalidArgument when user_id is malformed
    When an InitiateUpload request is sent with:
      | Field     | Value                                |
      | user_id   | bad-uuid                             |
      | name      | photo.jpg                            |
      | size      | 1048576                              |
      | mime_type | image/jpeg                           |
    Then the response status code is InvalidArgument
    And the error message contains "invalid user_id"

  Scenario: InitiateUpload returns InvalidArgument when mime_type is missing
    When an InitiateUpload request is sent with:
      | Field     | Value                                |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | name      | photo.jpg                            |
      | size      | 1048576                              |
      | mime_type |                                      |
    Then the response status code is InvalidArgument
    And the error message contains "invalid mime_type"

  # ---------------------------------------------------------------------------
  # ConfirmUpload
  # ---------------------------------------------------------------------------

  Scenario: ConfirmUpload marks a pending file as ready
    Given the file "a47ac10b-58cc-4372-a567-0e02b2c3d490" has status FILE_STATUS_PENDING
    And the client has uploaded bytes to S3 with storage_key "uploads/a47ac10b-58cc-4372-a567-0e02b2c3d490.jpg"
    When a ConfirmUpload request is sent with:
      | Field       | Value                                |
      | file_id     | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | user_id     | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | storage_key | uploads/a47ac10b-58cc-4372-a567-0e02b2c3d490.jpg |
      | size        | 1048576                              |
    Then the response status code is OK
    And the response FileResponse has:
      | Field     | Value                                |
      | id        | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | status    | FILE_STATUS_READY                    |
      | size      | 1048576                              |
    And the response FileResponse created_at is a valid google.protobuf.Timestamp
    And the response FileResponse updated_at is a valid google.protobuf.Timestamp

  Scenario: ConfirmUpload returns NotFound for non-existent file_id
    When a ConfirmUpload request is sent with:
      | Field       | Value                                |
      | file_id     | 00000000-0000-0000-0000-000000000000 |
      | user_id     | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | storage_key | uploads/nonexistent.jpg              |
      | size        | 1024                                 |
    Then the response status code is NotFound
    And the error message is "file not found"

  Scenario: ConfirmUpload returns PermissionDenied for wrong user
    When a ConfirmUpload request is sent with:
      | Field       | Value                                |
      | file_id     | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | user_id     | 99999999-9999-9999-9999-999999999999 |
      | storage_key | uploads/photo.jpg                    |
      | size        | 1024                                 |
    Then the response status code is PermissionDenied
    And the error message is "permission denied"

  Scenario: ConfirmUpload returns InvalidArgument for empty file_id
    When a ConfirmUpload request is sent with:
      | Field       | Value                                |
      | file_id     |                                      |
      | user_id     | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | storage_key | uploads/photo.jpg                    |
      | size        | 1024                                 |
    Then the response status code is InvalidArgument
    And the error message contains "invalid file_id"

  # ---------------------------------------------------------------------------
  # GetFile
  # ---------------------------------------------------------------------------

  Scenario: GetFile returns file metadata when the file exists
    When a GetFile request is sent with:
      | Field   | Value                                |
      | file_id | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | user_id | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
    Then the response status code is OK
    And the response FileResponse has:
      | Field     | Value                                |
      | id        | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | name      | photo.jpg                            |
    And the response FileResponse status is one of FILE_STATUS_PENDING or FILE_STATUS_READY

  Scenario: GetFile returns NotFound for non-existent file_id
    When a GetFile request is sent with:
      | Field   | Value                                |
      | file_id | 00000000-0000-0000-0000-000000000000 |
      | user_id | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
    Then the response status code is NotFound
    And the error message is "file not found"

  Scenario: GetFile returns InvalidArgument for empty file_id
    When a GetFile request is sent with:
      | Field   | Value                                |
      | file_id |                                      |
      | user_id | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
    Then the response status code is InvalidArgument
    And the error message contains "invalid file_id"

  Scenario: GetFile returns PermissionDenied when user does not own the file
    Given file "a47ac10b-58cc-4372-a567-0e02b2c3d490" is owned by user "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    When a GetFile request is sent with:
      | Field   | Value                                |
      | file_id | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | user_id | 99999999-9999-9999-9999-999999999999 |
    Then the response status code is PermissionDenied
    And the error message is "permission denied"

  # ---------------------------------------------------------------------------
  # ListFiles
  # ---------------------------------------------------------------------------

  Scenario: ListFiles returns all files for a user
    Given user "f47ac10b-58cc-4372-a567-0e02b2c3d479" has 3 file records
    When a ListFiles request is sent with:
      | Field     | Value                                |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | page_size | 50                                   |
      | page_token | ""                                  |
    Then the response status code is OK
    And the response ListFilesResponse files count is 3
    And the response ListFilesResponse next_page_token is empty

  Scenario: ListFiles returns empty list when user has no files
    Given user "f47ac10b-58cc-4372-a567-0e02b2c3d479" has 0 file records
    When a ListFiles request is sent with:
      | Field     | Value                                |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
    Then the response status code is OK
    And the response ListFilesResponse files is empty
    And the response ListFilesResponse next_page_token is empty

  Scenario: ListFiles paginates when page_size is smaller than total count
    Given user "f47ac10b-58cc-4372-a567-0e02b2c3d479" has 5 file records
    When a ListFiles request is sent with:
      | Field     | Value                                |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | page_size | 2                                    |
    Then the response status code is OK
    And the response ListFilesResponse files count is 2
    And the response ListFilesResponse next_page_token is not empty

  Scenario: ListFiles second page returns remaining items
    Given the first page token from a page_size=2 query for user "f47ac10b-58cc-4372-a567-0e02b2c3d479" is "eyJsYXN0X2lkIjoiYzQ3YWMxMGIifQ=="
    And user "f47ac10b-58cc-4372-a567-0e02b2c3d479" has 5 file records
    When a ListFiles request is sent with:
      | Field      | Value                                |
      | user_id    | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | page_size  | 2                                    |
      | page_token | eyJsYXN0X2lkIjoiYzQ3YWMxMGIifQ==    |
    Then the response status code is OK
    And the response ListFilesResponse files count is 2
    And the response ListFilesResponse next_page_token is not empty

  Scenario: ListFiles last page returns remaining items and empty next_page_token
    Given the last page token from a page_size=2 query for user "f47ac10b-58cc-4372-a567-0e02b2c3d479" is "eyJsYXN0X2lkIjoiZTQ3YWMxMGIifQ=="
    And user "f47ac10b-58cc-4372-a567-0e02b2c3d479" has 5 file records
    When a ListFiles request is sent with:
      | Field      | Value                                |
      | user_id    | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | page_size  | 2                                    |
      | page_token | eyJsYXN0X2lkIjoiZTQ3YWMxMGIifQ==    |
    Then the response status code is OK
    And the response ListFilesResponse files count is 1
    And the response ListFilesResponse next_page_token is empty

  Scenario: ListFiles returns InvalidArgument for empty user_id
    When a ListFiles request is sent with:
      | Field   | Value |
      | user_id |       |
    Then the response status code is InvalidArgument
    And the error message contains "invalid user_id"

  Scenario: ListFiles caps page_size at 200
    When a ListFiles request is sent with:
      | Field     | Value                                |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | page_size | 9999                                 |
    Then the response status code is OK
    And the response ListFilesResponse files count is at most 200

  Scenario: ListFiles returns InvalidArgument for malformed page_token
    When a ListFiles request is sent with:
      | Field      | Value                                |
      | user_id    | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | page_size  | 10                                   |
      | page_token | this-is-not-valid-base64             |
    Then the response status code is InvalidArgument
    And the error message contains "invalid page_token"

  # ---------------------------------------------------------------------------
  # DeleteFile
  # ---------------------------------------------------------------------------

  Scenario: DeleteFile deletes an existing file
    Given a ready file with id "a47ac10b-58cc-4372-a567-0e02b2c3d490" for user "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    When a DeleteFile request is sent with:
      | Field   | Value                                |
      | file_id | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | user_id | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
    Then the response status code is OK
    And the response is a google.protobuf.Empty

  Scenario: DeleteFile returns NotFound for non-existent file_id
    When a DeleteFile request is sent with:
      | Field   | Value                                |
      | file_id | 00000000-0000-0000-0000-000000000000 |
      | user_id | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
    Then the response status code is NotFound
    And the error message is "file not found"

  Scenario: DeleteFile returns InvalidArgument for empty file_id
    When a DeleteFile request is sent with:
      | Field   | Value                                |
      | file_id |                                      |
      | user_id | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
    Then the response status code is InvalidArgument
    And the error message contains "invalid file_id"

  Scenario: DeleteFile returns PermissionDenied for non-owner
    Given file "a47ac10b-58cc-4372-a567-0e02b2c3d490" is owned by user "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    When a DeleteFile request is sent with:
      | Field   | Value                                |
      | file_id | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | user_id | 99999999-9999-9999-9999-999999999999 |
    Then the response status code is PermissionDenied
    And the error message is "permission denied"

  # ---------------------------------------------------------------------------
  # GetDownloadURL
  # ---------------------------------------------------------------------------

  Scenario: GetDownloadURL returns a presigned URL for a ready file
    Given file "a47ac10b-58cc-4372-a567-0e02b2c3d490" has status FILE_STATUS_READY
    When a GetDownloadURL request is sent with:
      | Field        | Value                                |
      | file_id      | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | ttl_seconds  | 300                                  |
    Then the response status code is OK
    And the response DownloadURLResponse url is a valid presigned S3 URL
    And the response DownloadURLResponse expires_at is a valid google.protobuf.Timestamp

  Scenario: GetDownloadURL returns NotFound for non-existent file_id
    When a GetDownloadURL request is sent with:
      | Field        | Value                                |
      | file_id      | 00000000-0000-0000-0000-000000000000 |
      | ttl_seconds  | 300                                  |
    Then the response status code is NotFound
    And the error message is "file not found"

  Scenario: GetDownloadURL returns InvalidArgument for empty file_id
    When a GetDownloadURL request is sent with:
      | Field        | Value |
      | file_id      |       |
      | ttl_seconds  | 300   |
    Then the response status code is InvalidArgument
    And the error message contains "invalid file_id"

  Scenario: GetDownloadURL returns InvalidArgument when file status is PENDING
    Given file "a47ac10b-58cc-4372-a567-0e02b2c3d490" has status FILE_STATUS_PENDING
    When a GetDownloadURL request is sent with:
      | Field        | Value                                |
      | file_id      | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | ttl_seconds  | 300                                  |
    Then the response status code is InvalidArgument
    And the error message contains "file not ready"

  Scenario: GetDownloadURL caps ttl_seconds at 3600
    When a GetDownloadURL request is sent with:
      | Field        | Value                                |
      | file_id      | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | ttl_seconds  | 99999                                |
    Then the response status code is OK
    And the response DownloadURLResponse expires_at is within 3600 seconds from now
