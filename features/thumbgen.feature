# SPEC: Thumbnail Generator Service gRPC Contracts
# BUDGET: small (<5K)
# SCOPE: proto/thumbgen/v1/thumbgen.proto
# STATUS: draft

Feature: Thumbnail Generator Service — gRPC contract validation
  The ThumbGen service exposes three internal gRPC RPCs: EnqueueJob, GetJobStatus,
  and GetThumbnail. Processing happens asynchronously by a worker pool.

  Background:
    Given the ThumbGen gRPC server is running on port 9092
    And a source file with id "a47ac10b-58cc-4372-a567-0e02b2c3d490" and key "uploads/a47ac10b-58cc-4372-a567-0e02b2c3d490.jpg"
    And a user with id "f47ac10b-58cc-4372-a567-0e02b2c3d479"

  # ---------------------------------------------------------------------------
  # EnqueueJob
  # ---------------------------------------------------------------------------

  Scenario: EnqueueJob creates a job with status QUEUED
    When an EnqueueJob request is sent with:
      | Field     | Value                                |
      | file_id   | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | input_key | uploads/a47ac10b-58cc-4372-a567-0e02b2c3d490.jpg |
      | mime_type | image/jpeg                           |
    Then the response status code is OK
    And the response JobResponse has:
      | Field     | Value                                |
      | file_id   | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | status    | JOB_STATUS_QUEUED                    |
      | input_key | uploads/a47ac10b-58cc-4372-a567-0e02b2c3d490.jpg |
    And the response JobResponse output_key is empty
    And the response JobResponse error_msg is empty
    And the response JobResponse id is a valid UUID
    And the response JobResponse created_at is a valid google.protobuf.Timestamp

  Scenario: EnqueueJob returns InvalidArgument when file_id is missing
    When an EnqueueJob request is sent with:
      | Field     | Value                                |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | input_key | uploads/foo.jpg                      |
      | mime_type | image/jpeg                           |
    Then the response status code is InvalidArgument
    And the error message contains "invalid file_id"

  Scenario: EnqueueJob returns InvalidArgument when input_key is empty
    When an EnqueueJob request is sent with:
      | Field     | Value                                |
      | file_id   | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | input_key |                                      |
      | mime_type | image/jpeg                           |
    Then the response status code is InvalidArgument
    And the error message contains "invalid input_key"

  Scenario: EnqueueJob returns InvalidArgument for unsupported mime_type
    When an EnqueueJob request is sent with:
      | Field     | Value                                |
      | file_id   | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | user_id   | f47ac10b-58cc-4372-a567-0e02b2c3d479 |
      | input_key | uploads/foo.xml                      |
      | mime_type | application/xml                      |
    Then the response status code is InvalidArgument
    And the error message contains "unsupported mime_type"

  # ---------------------------------------------------------------------------
  # GetJobStatus
  # ---------------------------------------------------------------------------

  Scenario: GetJobStatus returns QUEUED for a newly enqueued job
    Given a job with id "b47ac10b-58cc-4372-a567-0e02b2c3d491" exists with status JOB_STATUS_QUEUED
    When a GetJobStatus request is sent with job_id "b47ac10b-58cc-4372-a567-0e02b2c3d491"
    Then the response status code is OK
    And the response JobResponse status is JOB_STATUS_QUEUED
    And the response JobResponse output_key is empty

  Scenario: GetJobStatus returns DONE for a completed job
    Given a job with id "c47ac10b-58cc-4372-a567-0e02b2c3d492" exists with status JOB_STATUS_DONE
    And the job has output_key "thumbs/c47ac10b-58cc-4372-a567-0e02b2c3d492.webp"
    When a GetJobStatus request is sent with job_id "c47ac10b-58cc-4372-a567-0e02b2c3d492"
    Then the response status code is OK
    And the response JobResponse status is JOB_STATUS_DONE
    And the response JobResponse output_key is "thumbs/c47ac10b-58cc-4372-a567-0e02b2c3d492.webp"
    And the response JobResponse error_msg is empty

  Scenario: GetJobStatus returns FAILED for a failed job
    Given a job with id "d47ac10b-58cc-4372-a567-0e02b2c3d493" exists with status JOB_STATUS_FAILED
    And the job has error_msg "processing timeout after 3 retries"
    When a GetJobStatus request is sent with job_id "d47ac10b-58cc-4372-a567-0e02b2c3d493"
    Then the response status code is OK
    And the response JobResponse status is JOB_STATUS_FAILED
    And the response JobResponse error_msg is "processing timeout after 3 retries"

  Scenario: GetJobStatus returns NotFound for non-existent job_id
    Given no job exists with id "00000000-0000-0000-0000-000000000000"
    When a GetJobStatus request is sent with job_id "00000000-0000-0000-0000-000000000000"
    Then the response status code is NotFound
    And the error message is "job not found"

  Scenario: GetJobStatus returns InvalidArgument for empty job_id
    When a GetJobStatus request is sent with job_id ""
    Then the response status code is InvalidArgument
    And the error message contains "invalid job_id"

  # ---------------------------------------------------------------------------
  # GetThumbnail
  # ---------------------------------------------------------------------------

  Scenario: GetThumbnail returns thumbnail metadata when ready
    Given a completed thumbnail for file "a47ac10b-58cc-4372-a567-0e02b2c3d490" exists
    When a GetThumbnail request is sent with file_id "a47ac10b-58cc-4372-a567-0e02b2c3d490"
    Then the response status code is OK
    And the response ThumbnailResponse has:
      | Field       | Value                                |
      | file_id     | a47ac10b-58cc-4372-a567-0e02b2c3d490 |
      | format      | webp                                 |
      | width       | 256                                  |
      | height      | 256                                  |
    And the response ThumbnailResponse download_url is a valid presigned URL
    And the response ThumbnailResponse storage_key is not empty

  Scenario: GetThumbnail returns NotFound when no thumbnail exists for file
    Given no thumbnail exists for file "00000000-0000-0000-0000-000000000000"
    When a GetThumbnail request is sent with file_id "00000000-0000-0000-0000-000000000000"
    Then the response status code is NotFound
    And the error message is "thumbnail not found"

  Scenario: GetThumbnail returns NotFound when job is still processing
    Given a job for file "e47ac10b-58cc-4372-a567-0e02b2c3d494" exists with status JOB_STATUS_PROCESSING
    And no thumbnail has been generated yet
    When a GetThumbnail request is sent with file_id "e47ac10b-58cc-4372-a567-0e02b2c3d494"
    Then the response status code is NotFound
    And the error message is "thumbnail not found"

  Scenario: GetThumbnail returns InvalidArgument for empty file_id
    When a GetThumbnail request is sent with file_id ""
    Then the response status code is InvalidArgument
    And the error message contains "invalid file_id"
