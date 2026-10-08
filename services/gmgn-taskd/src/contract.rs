//! The **read-only capability contract** the MCP face publishes.
//!
//! Why this lives in the authority and not in `gmgn-mcpd`: the answer to "how big
//! may a thing be, which axes exist, what does a world commit accept" is a fact
//! about the authority. If the MCP server answered it from its own copy of the
//! numbers, there would be two sources for one fact and they would eventually
//! disagree — and the agent would then be reading a contract that the validator
//! does not enforce.
//!
//! So every number and every word here is **read from the same constant the
//! validating code uses**, and the error-code list is compared against the
//! authority's own sources by test. This method is purely additive: no state is
//! read, written, or advanced, and it takes no parameters.

use crate::{model, world};
use serde_json::{json, Value};

/// Every error code this authority can put on the wire.
///
/// **Not written by hand.** `the_published_codes_are_exactly_the_authoritys_own`
/// re-derives this set from the sources themselves — legacy shaped literals on a
/// line that raises an error (`Err(`, `.ok_or`, `map_err`, `failure(`, `code:`,
/// and the helpers that take the code as an argument: `bounded(`, `identity(`,
/// `glb_container(`, `object_text(`, `fail(`, `error(`) — in non-test code, and
/// fails in both directions. A code the code returns but this list omits is a
/// contract that lies by omission; a code this list publishes but the code no
/// longer returns is a contract that lies outright. The first live end-to-end run
/// against a real daemon is what found the omission this test now prevents
/// (`world_id_mismatch`, reachable through `world_commit`).
///
/// New host services use balanced error-constructor arguments; runtime RPC
/// errors use their actual public_error_code projection. Internal executor or
/// background CLI failures are not advertised as direct RPC errors. Listing an
/// authenticated host error never registers its RPC as a model capability.
///
/// Known limit, stated rather than hidden: the legacy rule is line-based, so a code that
/// reached the wire without ever appearing on an error-site line would not be
/// found by it. Explicit runtime projections supplement that rule;
/// `every_published_code_appears_in_the_sources` additionally refuses a code that
/// appears nowhere at all, which is the "invented field" direction.
///
/// The MCP face must surface these **verbatim**. It is a translator; a friendlier
/// name here would create a second vocabulary for one fact.
const ERROR_CODES: &[&str] = &[
    "absolute_path_required",
    "activity_action_mismatch",
    "activity_approach_binding_missing",
    "activity_approach_input_limit",
    "activity_approach_invalid_binding",
    "activity_approach_invalid_geometry",
    "activity_approach_invalid_input",
    "activity_approach_invalid_physics",
    "activity_approach_object_unavailable",
    "activity_approach_stale_geometry",
    "activity_approach_stale_layout",
    "activity_approach_world_missing",
    "activity_duplicate_id",
    "activity_duplicate_phase",
    "activity_function_point_requires_definition",
    "activity_invalid_input",
    "activity_missing_definition",
    "activity_missing_phase",
    "activity_orphan_definition",
    "activity_unsupported_action",
    "agent_chat_capacity",
    "agent_chat_invalid_backend",
    "agent_chat_invalid_configuration",
    "agent_chat_invalid_history",
    "agent_chat_invalid_image",
    "agent_chat_invalid_input",
    "agent_chat_invalid_request",
    "agent_chat_invalid_session",
    "agent_chat_not_found",
    "agent_chat_request_conflict",
    "agent_chat_stale_session",
    "agent_chat_unknown",
    "agent_chat_unsafe_configuration",
    "agent_claude_clock_unavailable",
    "agent_claude_duplicate_call",
    "agent_claude_grant_revoked",
    "agent_claude_host_unauthorized",
    "agent_claude_image_limit",
    "agent_claude_input_limit",
    "agent_claude_invalid_authorization",
    "agent_claude_invalid_configuration",
    "agent_claude_invalid_image",
    "agent_claude_invalid_input",
    "agent_claude_invalid_receipt",
    "agent_claude_invalid_request",
    "agent_claude_invalid_tools",
    "agent_claude_missing_credential",
    "agent_claude_not_pending",
    "agent_claude_not_started",
    "agent_claude_queue_limit",
    "agent_claude_receipt_conflict",
    "agent_claude_run_not_claimed",
    "agent_claude_session_busy",
    "agent_claude_stale_session",
    "agent_claude_tool_not_authorized",
    "agent_claude_unresolved_tools",
    "agent_claude_unsafe_configuration",
    "agent_claude_unsafe_result",
    "agent_claude_unsupported_input",
    "agent_cli_host_resume_forbidden",
    "agent_cli_image_limit",
    "agent_cli_input_limit",
    "agent_cli_invalid_authorization",
    "agent_cli_invalid_configuration",
    "agent_cli_invalid_image",
    "agent_cli_invalid_input",
    "agent_cli_invalid_receipt",
    "agent_cli_invalid_request",
    "agent_cli_invalid_tools",
    "agent_cli_not_pending",
    "agent_cli_not_started",
    "agent_cli_receipt_conflict",
    "agent_cli_registry_changed",
    "agent_cli_run_not_claimed",
    "agent_cli_session_busy",
    "agent_cli_stale_session",
    "agent_cli_unsafe_arguments",
    "agent_cli_unsafe_directory",
    "agent_dsh_duplicate_call",
    "agent_dsh_host_result_unknown",
    "agent_dsh_host_unauthorized",
    "agent_dsh_image_limit",
    "agent_dsh_invalid_authorization",
    "agent_dsh_invalid_configuration",
    "agent_dsh_invalid_environment",
    "agent_dsh_invalid_image",
    "agent_dsh_invalid_input",
    "agent_dsh_invalid_receipt",
    "agent_dsh_invalid_request",
    "agent_dsh_invalid_tools",
    "agent_dsh_not_pending",
    "agent_dsh_not_started",
    "agent_dsh_queue_limit",
    "agent_dsh_receipt_conflict",
    "agent_dsh_run_not_claimed",
    "agent_dsh_session_busy",
    "agent_dsh_stale_session",
    "agent_dsh_tool_not_authorized",
    "agent_dsh_unresolved_tools",
    "agent_dsh_unsafe_arguments",
    "agent_dsh_unsafe_configuration",
    "agent_dsh_unsupported_mcp_configuration",
    "agent_loop_event_conflict",
    "agent_loop_event_missing",
    "agent_loop_input_conflict",
    "agent_loop_invalid_clock",
    "agent_loop_invalid_interval",
    "agent_loop_invalid_limit",
    "agent_loop_invalid_receipt",
    "agent_loop_invalid_request",
    "agent_loop_message_conflict",
    "agent_loop_message_missing",
    "agent_loop_not_configured",
    "agent_loop_parent_inactive",
    "agent_loop_receipt_conflict",
    "agent_loop_receipt_mismatch",
    "agent_loop_run_conflict",
    "agent_loop_stale_session",
    "agent_runtime_already_started",
    "agent_runtime_authorization_conflict",
    "agent_runtime_authorization_not_pending",
    "agent_runtime_duplicate_tool",
    "agent_runtime_failed",
    "agent_runtime_input_limit",
    "agent_runtime_invalid_authorization",
    "agent_runtime_invalid_input",
    "agent_runtime_invalid_operations",
    "agent_runtime_invalid_provider",
    "agent_runtime_invalid_receipt",
    "agent_runtime_invalid_request",
    "agent_runtime_invalid_steering",
    "agent_runtime_invalid_tools",
    "agent_runtime_invalid_verification",
    "agent_runtime_not_configured",
    "agent_runtime_receipt_expired",
    "agent_runtime_receipt_limit",
    "agent_runtime_receipt_mismatch",
    "agent_runtime_receipt_not_pending",
    "agent_runtime_reconciliation_mismatch",
    "agent_runtime_run_not_claimed",
    "agent_runtime_session_exists",
    "agent_runtime_session_limit",
    "agent_runtime_stale_session",
    "agent_runtime_steering_conflict",
    "agent_runtime_steering_not_admitted",
    "agent_runtime_unsupported_input",
    "agent_tool_authority_conflict",
    "agent_tool_budget_exhausted",
    "agent_tool_call_conflict",
    "agent_tool_call_not_found",
    "agent_tool_invalid_arguments",
    "agent_tool_invalid_authority",
    "agent_tool_invalid_payload",
    "agent_tool_invalid_request",
    "agent_tool_not_authorized",
    "agent_tool_not_unknown",
    "agent_tool_operation_blocked",
    "agent_tool_operation_conflict",
    "agent_tool_operation_not_authorized",
    "agent_tool_receipt_conflict",
    "agent_tool_requires_reconciliation",
    "agent_tool_run_not_claimed",
    "already_running",
    "artifact_already_ready",
    "authoritative_size_conflicts_with_intent",
    "blob_hash_mismatch",
    "blob_outside_private_root",
    "chat_attachments_clock",
    "chat_attachments_closed",
    "chat_attachments_file_mismatch",
    "chat_attachments_id_conflict",
    "chat_attachments_invalid_directory",
    "chat_attachments_invalid_file",
    "chat_attachments_invalid_id",
    "chat_attachments_invalid_input",
    "chat_attachments_invalid_path",
    "chat_attachments_invalid_selection",
    "chat_attachments_invalid_state",
    "chat_attachments_limit",
    "chat_attachments_not_in_draft",
    "chat_attachments_not_issued",
    "chat_attachments_not_restorable",
    "chat_attachments_path_conflict",
    "chat_attachments_revision_exhausted",
    "chat_attachments_session_conflict",
    "chat_attachments_stale_frame",
    "chat_attachments_stale_revision",
    "chat_attachments_stale_session",
    "chat_attachments_submission_conflict",
    "chat_attachments_submission_unknown",
    "chat_attachments_terminal_conflict",
    "chat_images_unsupported",
    "chat_speech_invalid_input",
    "chat_speech_source_already_selected",
    "chat_speech_source_conflict",
    "chat_speech_source_missing",
    "chat_speech_source_not_completed",
    "chat_speech_stale_request",
    "client_disconnected",
    "client_timeout",
    "collision_integrity_failed",
    "collision_not_supported",
    "compaction_rejected",
    "duplicate_active_source_wish",
    "duplicate_music_id",
    "embedding_dimension_mismatch",
    "endpoint_outside_private_root",
    "endpoint_unavailable",
    "fact_payload_too_large",
    "fallback_profile_mismatch_would_change_collision_box",
    "frame_too_large",
    "generation_configuration_invalid_request",
    "generation_configuration_legacy_unreadable",
    "generation_configuration_secret_unavailable",
    "generation_endpoint_requires_token",
    "generation_not_ready",
    "held_prop_conflict",
    "history_record_too_large",
    "history_unavailable",
    "host_operation_rejected",
    "host_tool_unavailable",
    "http_content_type_required",
    "http_events_route_required",
    "http_method_not_allowed",
    "http_origin_forbidden",
    "http_route_not_found",
    "http_stream_method_required",
    "http_unauthorized",
    "http_unavailable",
    "idempotency_conflict",
    "image_byte_limit",
    "image_count_limit",
    "image_format_invalid",
    "image_integrity_failed",
    "import_conflict",
    "import_hash_mismatch",
    "inbox_clock_unavailable",
    "inbox_invalid_input",
    "inbox_invalid_state",
    "inbox_too_large",
    "invalid_arguments",
    "invalid_authoritative_size",
    "invalid_blob",
    "invalid_blob_hash",
    "invalid_blob_mime",
    "invalid_blob_path",
    "invalid_client_id",
    "invalid_collision_descriptor",
    "invalid_concurrency",
    "invalid_consumer",
    "invalid_context",
    "invalid_cursor",
    "invalid_domain",
    "invalid_drop_held",
    "invalid_endpoint",
    "invalid_event_id",
    "invalid_event_kind",
    "invalid_event_payload",
    "invalid_event_read",
    "invalid_file",
    "invalid_generated_prop",
    "invalid_generation_profile",
    "invalid_glb",
    "invalid_id",
    "invalid_import_hash",
    "invalid_input",
    "invalid_input_px",
    "invalid_legacy_identity",
    "invalid_limit",
    "invalid_media_helper_config",
    "invalid_media_input",
    "invalid_media_revision",
    "invalid_memory_query",
    "invalid_memory_read",
    "invalid_memory_recall",
    "invalid_memory_status",
    "invalid_message",
    "invalid_message_ack",
    "invalid_message_cursor",
    "invalid_message_id",
    "invalid_message_kind",
    "invalid_message_payload",
    "invalid_message_read",
    "invalid_message_scope",
    "invalid_music_count",
    "invalid_music_date",
    "invalid_music_input",
    "invalid_music_revision",
    "invalid_music_slot",
    "invalid_object_id",
    "invalid_op",
    "invalid_op_count",
    "invalid_package_id",
    "invalid_package_version",
    "invalid_placement_request",
    "invalid_placement_result",
    "invalid_png",
    "invalid_producer",
    "invalid_provider_api_key",
    "invalid_provider_capabilities",
    "invalid_provider_endpoint",
    "invalid_provider_model",
    "invalid_query",
    "invalid_request",
    "invalid_request_id",
    "invalid_response",
    "invalid_revision",
    "invalid_scope",
    "invalid_size_intent",
    "invalid_source_wish_id",
    "invalid_state_commit",
    "invalid_state_key",
    "invalid_state_read",
    "invalid_state_value",
    "invalid_task_id",
    "invalid_token",
    "invalid_topk",
    "invalid_vector",
    "invalid_voice_input",
    "invalid_workflow_profile",
    "invalid_world_blob_get",
    "invalid_world_blob_put",
    "invalid_world_commit",
    "invalid_world_cursors",
    "invalid_world_facts",
    "invalid_world_facts_read",
    "invalid_world_id",
    "invalid_world_import",
    "invalid_world_records",
    "invalid_world_snapshot",
    "invalid_world_state",
    "jukebox_busy",
    "jukebox_cancelled",
    "jukebox_claim_unknown",
    "jukebox_execution_failed",
    "jukebox_identity_mismatch",
    "jukebox_invalid_facts",
    "jukebox_invalid_input",
    "jukebox_invalid_state",
    "jukebox_playback_not_observed",
    "jukebox_stale_action",
    "jukebox_stale_render",
    "jukebox_stale_run",
    "jukebox_stale_world",
    "jukebox_stop_not_observed",
    "jukebox_timeout",
    "legacy_integrity_failed",
    "legacy_unavailable",
    "limit_exceeded",
    "marble_control_assets_missing",
    "marble_control_busy",
    "marble_control_capacity",
    "marble_control_clock_unavailable",
    "marble_control_comparison_unavailable",
    "marble_control_corrupt",
    "marble_control_identity_mismatch",
    "marble_control_identity_missing",
    "marble_control_invalid_input",
    "marble_control_invalid_package",
    "marble_control_invalid_response",
    "marble_control_legacy_invalid",
    "marble_control_legacy_unconfirmed",
    "marble_control_package_conflict",
    "marble_control_provider_rejected",
    "marble_control_receipt_conflict",
    "marble_control_registration_failed",
    "marble_control_revision_conflict",
    "marble_control_stale_session",
    "marble_control_transport_failed",
    "marble_control_unknown_action",
    "marble_control_unknown_preset",
    "marble_control_unknown_result",
    "marble_control_unknown_task",
    "marble_control_unknown_world",
    "marble_geometry_incomplete_proof",
    "marble_geometry_invalid_input",
    "marble_geometry_invalid_proof",
    "marble_geometry_no_spawn",
    "marble_geometry_plan_mismatch",
    "marble_geometry_unavailable",
    "media_cache_corrupt",
    "media_cache_limit",
    "media_cache_missing",
    "media_cancelled",
    "media_disk_full",
    "media_download_failed",
    "media_download_timeout",
    "media_helper_integrity_failed",
    "media_helper_unavailable",
    "media_interrupted",
    "media_invalid_content",
    "media_invalid_range",
    "media_live_unsupported",
    "media_playlist_empty",
    "media_playlist_start_outside_limit",
    "media_playlist_unavailable",
    "media_queue_full",
    "media_resolve_failed",
    "media_resolve_timeout",
    "media_restricted",
    "media_revision_conflict",
    "media_storage_corrupt",
    "media_unsupported_format",
    "media_unsupported_site",
    "memory_conflict",
    "memory_history_unavailable",
    "memory_original_text_layer_removed",
    "memory_request_conflict",
    "memory_snapshot_too_large",
    "memory_storage_failed",
    "message_id_conflict",
    "message_not_found",
    "message_payload_too_large",
    "message_scope_mismatch",
    "message_storage_failed",
    "method_not_found",
    "missing_collision_descriptor",
    "missing_receipt",
    "missing_root",
    "missing_task",
    "missing_workflow_profile",
    "model_image_input_unsupported",
    "model_integrity_failed",
    "model_too_large",
    "music_account_account_cannot_play",
    "music_account_attempt_identity",
    "music_account_attempt_not_replayable",
    "music_account_capacity",
    "music_account_encoding_failed",
    "music_account_invalid_authorization",
    "music_account_invalid_clock",
    "music_account_invalid_cookie",
    "music_account_invalid_input",
    "music_account_invalid_response",
    "music_account_invalid_secret_identity",
    "music_account_invalid_stored_session",
    "music_account_missing_required_cookie",
    "music_account_receipt_conflict",
    "music_account_request_conflict",
    "music_account_response_capacity",
    "music_account_response_identity",
    "music_account_revision_conflict",
    "music_account_transport_failed",
    "music_account_unknown_attempt",
    "music_account_unsupported_provider",
    "music_cache_claim_unknown",
    "music_cache_identity_mismatch",
    "music_cache_invalid_audio",
    "music_cache_invalid_input",
    "music_cache_receipt_mismatch",
    "music_cache_unsafe_path",
    "music_capacity_exceeded",
    "music_knowledge_capacity",
    "music_knowledge_corrupt",
    "music_knowledge_invalid_input",
    "music_knowledge_normalization_unavailable",
    "music_knowledge_request_conflict",
    "music_library_batch_conflict",
    "music_library_batch_unknown",
    "music_library_capacity",
    "music_library_corrupt",
    "music_library_duplicate_id",
    "music_library_identity_conflict",
    "music_library_invalid_count",
    "music_library_invalid_edit",
    "music_library_invalid_input",
    "music_library_invalid_page",
    "music_library_invalid_provider",
    "music_library_invalid_source",
    "music_library_invalid_track",
    "music_library_page_boundary",
    "music_library_page_busy",
    "music_library_page_duplicate",
    "music_library_page_identity",
    "music_library_page_no_progress",
    "music_library_page_stale",
    "music_library_playlist_missing",
    "music_library_request_conflict",
    "music_library_revision_exhausted",
    "music_library_sort_unavailable",
    "music_playback_ambiguous_track",
    "music_playback_empty",
    "music_playback_invalid_input",
    "music_playback_invalid_queue",
    "music_playback_invalid_state",
    "music_playback_program_revision_mismatch",
    "music_playback_request_conflict",
    "music_playback_revision_overflow",
    "music_playback_selection_pending",
    "music_playback_stale_selection",
    "music_playback_stale_session",
    "music_playback_stale_track",
    "music_playback_track_not_found",
    "music_playlist_not_found",
    "music_program_clock_unavailable",
    "music_program_insufficient_playable_candidates",
    "music_program_invalid_archive",
    "music_program_invalid_clock",
    "music_program_invalid_edit_mode",
    "music_program_invalid_input",
    "music_program_invalid_operation",
    "music_program_invalid_playlist",
    "music_program_invalid_proposal",
    "music_program_invalid_response",
    "music_program_invalid_revision",
    "music_program_invalid_time",
    "music_program_model_failed",
    "music_program_not_active",
    "music_program_not_prepared",
    "music_program_revision_conflict",
    "music_program_revision_exhausted",
    "music_program_text_unavailable",
    "music_program_unsafe_runner",
    "music_revision_conflict",
    "music_revision_exhausted",
    "music_storage_corrupt",
    "network_unavailable",
    "notification_changed",
    "notification_missing",
    "object_not_found",
    "object_record_too_large",
    "object_revision_conflict",
    "presence_avatar_unavailable",
    "presence_catalog_identity_mismatch",
    "presence_catalog_unbound",
    "presence_invalid_catalog",
    "presence_invalid_catalog_scope",
    "presence_invalid_event",
    "presence_invalid_input",
    "presence_invalid_state",
    "presence_motion_incompatible",
    "presence_motion_receipt_stale",
    "presence_removal_identity_mismatch",
    "presence_removal_not_dispatchable",
    "presence_removal_pending",
    "presence_removal_receipt_stale",
    "presence_removal_verification_failed",
    "presence_remove_builtin",
    "presence_renderer_pending",
    "presence_renderer_receipt_stale",
    "presence_request_conflict",
    "presence_resource_missing",
    "presence_resource_outside_root",
    "presence_revision_conflict",
    "product_settings_invalid_backend",
    "product_settings_invalid_catalog",
    "product_settings_invalid_locale",
    "product_settings_invalid_model",
    "product_settings_invalid_state",
    "product_settings_invalid_value",
    "product_settings_invalid_voice",
    "product_settings_request_conflict",
    "product_settings_revision_conflict",
    "product_settings_unknown_field",
    "product_settings_unknown_world",
    "prop_capability_capacity",
    "prop_capability_invalid_geometry",
    "prop_capability_invalid_input",
    "prop_capability_invalid_object",
    "prop_capability_invalid_physics",
    "prop_capability_object_unavailable",
    "prop_capability_stale_geometry",
    "prop_capability_stale_layout",
    "prop_capability_unsupported_template",
    "prop_capability_world_missing",
    "prop_grip_insufficient_clearance",
    "prop_grip_invalid",
    "prop_grip_invalid_orientation",
    "prop_grip_invalid_size",
    "prop_grip_unknown_handle",
    "prop_out_of_reach",
    "provider_not_ready",
    "reference_call_conflict",
    "reference_invalid_arguments",
    "reference_registration_unauthorized",
    "reference_registration_unverified",
    "reference_search_timeout",
    "reference_search_unavailable",
    "reference_search_unparseable",
    "remote_id_mismatch",
    "report_unserializable",
    "request_conflict",
    "request_id_conflict",
    "request_rejected",
    "resident_history_unavailable",
    "resident_intent_inactive_run",
    "resident_intent_input_limit",
    "resident_intent_invalid_clock",
    "resident_intent_invalid_events",
    "resident_intent_invalid_input",
    "resident_intent_invalid_scope",
    "resident_intent_invalid_state",
    "resident_intent_invalid_summary",
    "resident_intent_invalid_wake",
    "resident_intent_missing_human_guidance",
    "resident_intent_paused",
    "resident_storage_failed",
    "response_too_large_or_unsafe",
    "retry_unavailable",
    "revision_conflict",
    "runtime_unavailable",
    "screen_playback_invalid_eof",
    "screen_playback_invalid_input",
    "screen_playback_invalid_state",
    "screen_playback_receipt_conflict",
    "screen_playback_stale_item",
    "screen_playback_stale_session",
    "screen_playback_unresolved_begin",
    "screen_state_import_conflict",
    "screen_state_invalid_content",
    "screen_state_invalid_definition",
    "screen_state_invalid_input",
    "screen_state_invalid_record",
    "screen_state_legacy_invalid",
    "screen_state_legacy_unreadable",
    "screen_state_limit",
    "screen_state_receipt_conflict",
    "screen_state_revision_conflict",
    "screen_state_unsafe_legacy_path",
    "secret_in_input",
    "signal_unavailable",
    "size_intent_conflict",
    "size_intent_echo_conflict",
    "size_intent_shape_conflict",
    "socket_unavailable",
    "source_task_still_active",
    "speech_delivery_empty_output",
    "speech_delivery_invalid_input",
    "speech_delivery_invalid_state",
    "speech_delivery_queue_full",
    "speech_delivery_receipt_conflict",
    "speech_delivery_stale_session",
    "speech_delivery_start_rejected",
    "speech_delivery_unavailable",
    "speech_delivery_window_full",
    "stage_video_invalid_input",
    "stage_video_invalid_state",
    "stage_video_pending_action",
    "stage_video_stale_receipt",
    "stage_video_unknown_asset",
    "stale_wish_reference_session",
    "state_value_too_large",
    "storage_unavailable",
    "stream_limit_exceeded",
    "subject_revision_regression",
    "task_not_found",
    "terminal_remote_task",
    "too_many_facts",
    "unknown_method",
    "unsafe_download",
    "unsafe_endpoint_path",
    "unsafe_legacy_path",
    "unsafe_path",
    "unsupported_method",
    "unsupported_provider_backend",
    "unsupported_voice_provider",
    "voice_backpressure",
    "voice_client_busy",
    "voice_not_ready",
    "voice_protocol_error",
    "voice_provider_error",
    "voice_session_not_found",
    "voice_timeout",
    "voice_transport_error",
    "wish_control_conflicting_call",
    "wish_control_consumed_authorization",
    "wish_control_image_limit",
    "wish_control_import_conflict",
    "wish_control_invalid_request",
    "wish_control_not_at_machine",
    "wish_control_not_published",
    "wish_control_not_ready",
    "wish_control_placement_revoked",
    "wish_control_resume_unauthorized",
    "wish_control_retry_unavailable",
    "wish_control_revision_conflict",
    "wish_control_stale_session",
    "wish_control_transition_rejected",
    "wish_control_unauthorized",
    "wish_control_unknown_attachment",
    "wish_control_wrong_scope",
    "worker_failed",
    "world_activity_clock_unavailable",
    "world_activity_cooldown_active",
    "world_activity_deadline_not_due",
    "world_activity_graph_too_large",
    "world_activity_host_plan_rejected",
    "world_activity_infinite_loop",
    "world_activity_invalid_definition",
    "world_activity_invalid_destination",
    "world_activity_invalid_facts",
    "world_activity_invalid_graph",
    "world_activity_invalid_input",
    "world_activity_invalid_path",
    "world_activity_invalid_physics",
    "world_activity_invalid_position",
    "world_activity_invalid_priority",
    "world_activity_invalid_receipt",
    "world_activity_invalid_state",
    "world_activity_lower_priority",
    "world_activity_not_arrived",
    "world_activity_not_interruptible",
    "world_activity_owned_projection",
    "world_activity_plan_binding_conflict",
    "world_activity_plan_binding_missing",
    "world_activity_plan_changed",
    "world_activity_plan_expired",
    "world_activity_plan_not_ready",
    "world_activity_plan_unreachable",
    "world_activity_renderer_receipt_required",
    "world_activity_request_conflict",
    "world_activity_revision_overflow",
    "world_activity_stale_receipt",
    "world_activity_stale_session",
    "world_activity_unknown_definition",
    "world_activity_unknown_destination",
    "world_activity_unreachable",
    "world_control_catalog_missing",
    "world_control_clock_unavailable",
    "world_control_goal_already_completed",
    "world_control_input_limit",
    "world_control_invalid_goal",
    "world_control_invalid_input",
    "world_control_invalid_state",
    "world_control_invalid_weather",
    "world_control_owned_projection",
    "world_control_unauthorized",
    "world_control_unknown_camera",
    "world_coordinate_blocked",
    "world_coordinate_missing_ground",
    "world_coordinate_occupied",
    "world_coordinate_off_ground",
    "world_device_basic_object",
    "world_device_cannot_place",
    "world_device_catalog_changed",
    "world_device_clock_unavailable",
    "world_device_invalid_catalog",
    "world_device_invalid_command",
    "world_device_invalid_input",
    "world_device_invalid_native_facts",
    "world_device_invalid_state",
    "world_device_template_unavailable",
    "world_device_unauthorized",
    "world_fact_unreadable",
    "world_id_mismatch",
    "world_prop_activity_conflict",
    "world_prop_activity_not_ready",
    "world_prop_asset_unverified",
    "world_prop_avatar_changed",
    "world_prop_basic_object",
    "world_prop_clock_unavailable",
    "world_prop_dimensions_unrealizable",
    "world_prop_invalid_input",
    "world_prop_invalid_measurement",
    "world_prop_invalid_native_facts",
    "world_prop_invalid_orientation",
    "world_prop_invalid_size",
    "world_prop_invalid_state",
    "world_prop_native_not_ready",
    "world_prop_no_nearby_drop",
    "world_prop_not_held",
    "world_prop_object_deleted",
    "world_prop_object_held",
    "world_prop_object_not_found",
    "world_prop_owned_projection",
    "world_prop_placement_blocked",
    "world_prop_request_conflict",
    "world_prop_resident_blocked",
    "world_prop_route_blocked",
    "world_prop_slot_unavailable",
    "world_prop_stale_native_facts",
    "world_prop_system_binding_changed",
    "world_prop_system_event_stale",
    "world_prop_too_large",
    "world_prop_unauthorized",
    "world_record_too_large",
    "world_record_unreadable",
    "world_request_unreadable",
];

/// What a code means, for the codes reachable through the MCP face's tools.
///
/// The rest are published with a `null` reason rather than an invented one: the
/// vocabulary is the authority's, and inventing a meaning for a code this face
/// never surfaces would be exactly the kind of second-hand truth the contract
/// exists to remove.
const ERROR_REASONS: &[(&str, &str)] = &[
    ("invalid_size_intent", "尺寸意图的形状/轴/出处/米数/三轴毫米数不合法"),
    ("size_intent_conflict", "sizeIntent 的 height 轴（或三轴的 y）与 heightMeters 说的不是同一个数"),
    ("size_intent_echo_conflict", "回执里的尺寸意图与已落盘的意图不是同一份"),
    ("size_intent_shape_conflict", "sizeIntent 同时给了 axis/meters 与 mode=dimensions 两种形状，说不清是哪一种"),
    ("invalid_input", "提交字段本身不合法（名字、出处、heightMeters 范围、PNG 大小等）"),
    ("invalid_png", "参考图不是合法 PNG，或边长超出 1—2048"),
    ("invalid_endpoint", "生成服务 origin 不合法（必须 https，或 loopback 上的 http，且无路径/查询/凭据）"),
    ("invalid_id", "任务编号不是合法 UUID"),
    ("invalid_response", "远端或自身的响应形状不符合契约"),
    ("invalid_generation_profile", "生成档位不合法"),
    ("invalid_workflow_profile", "生成档位指纹不合法"),
    ("invalid_provider_capabilities", "生成服务自报的能力声明整块不可信"),
    ("invalid_source_wish_id", "sourceWishID 不合法"),
    ("invalid_context", "提交里的 context 不合法"),
    ("duplicate_active_source_wish", "同一个 sourceWishID 已经有一笔活跃任务"),
    ("source_task_still_active", "换后端时原任务仍未结束"),
    ("artifact_already_ready", "该产物已就绪，无需重开"),
    ("fallback_profile_mismatch_would_change_collision_box", "回退重试沿用了不同的生成档位指纹"),
    ("missing_workflow_profile", "两端都没有生成档位指纹"),
    ("terminal_remote_task", "远端任务已终结，不能重试"),
    ("retry_unavailable", "该任务当前不可重试"),
    ("missing_task", "任务不存在"),
    ("missing_receipt", "缺少远端回执，结果不明"),
    ("invalid_cursor", "游标不合法（负数或无法解析）"),
    ("invalid_limit", "读取条数为 0 或超过上限"),
    ("invalid_world_id", "世界编号不合法"),
    ("invalid_domain", "记录域不合法"),
    ("invalid_request_id", "幂等编号不合法"),
    ("invalid_revision", "expectedRevision 为负"),
    ("invalid_op_count", "ops 为空或超过上限"),
    ("invalid_op", "ops 里出现未知操作，或该操作缺少必需字段"),
    ("request_id_conflict", "同一 requestID 被用于不同内容"),
    ("revision_conflict", "expectedRevision 与当前世界修订不一致"),
    ("world_id_mismatch", "变更里的 worldID 与世界状态文档里的不是同一个"),
    ("subject_revision_regression", "提交的状态修订低于已存的那份"),
    ("invalid_object_id", "物件编号不合法"),
    ("object_not_found", "要改的物件不存在"),
    ("object_revision_conflict", "物件的 expectedObjectRevision 与当前不一致"),
    ("invalid_world_state", "世界状态文档不合法"),
    ("invalid_world_facts", "世界事实负载不合法"),
    ("invalid_generated_prop", "物件的生成信息保留键不合法"),
    ("invalid_consumer", "消费者名不在允许名单里"),
    ("too_many_facts", "一次提交产生的事实数超过上限"),
    ("fact_payload_too_large", "单条事实负载超过上限"),
    ("world_record_too_large", "世界记录超过上限"),
    ("object_record_too_large", "物件记录超过上限"),
    ("world_record_unreadable", "世界记录无法读回"),
    ("world_fact_unreadable", "世界事实无法读回"),
    ("world_request_unreadable", "世界请求记录无法读回"),
    ("invalid_world_snapshot", "world_snapshot 的请求形状不合法"),
    ("invalid_world_records", "world_records 的请求形状不合法"),
    ("invalid_world_facts_read", "world_facts_read 的请求形状不合法"),
    ("invalid_world_cursors", "world_cursors 的请求形状不合法"),
    ("invalid_world_commit", "world_commit 的请求形状不合法，或参数里出现了已配置的凭据"),
    ("invalid_world_import", "world_import 的请求形状不合法，或参数里出现了已配置的凭据"),
    ("invalid_arguments", "参数不符合方法本身的要求"),
    ("storage_unavailable", "存储层不可用"),
    ("frame_too_large", "帧超过上限"),
    ("client_timeout", "写回超时"),
    ("client_disconnected", "客户端在写回前断开"),
    ("unknown_method", "请求的方法名不存在"),
    ("invalid_request", "请求不是一个合法的 JSON 对象"),
];

/// Keys of the generated-prop metadata block. They are *data shape* owned by the
/// world document, and the authority reserves the names; the MCP face must not
/// invent new ones.
const WORLD_KEYS: &[(&str, &str)] = &[
    (
        world::GENERATED_PROP_KEY,
        "物件记录 metadata 里承载生成信息（含 size）的保留键",
    ),
    (
        world::SUPPORT_SURFACE_KEY,
        "物件记录 metadata 里承载承托面信息的保留键",
    ),
];

pub fn describe() -> Value {
    let reasons = |code: &str| -> Value {
        match ERROR_REASONS.iter().find(|(name, _)| *name == code) {
            Some((_, reason)) => Value::String((*reason).to_owned()),
            None => Value::Null,
        }
    };
    json!({
        "authority": "gmgn-taskd",
        "note": "本契约由权威进程按自己的常量生成，MCP 面原样转述；这里没有任何一处是转述者写死的。错误码表是权威**全部**的错误词汇，reason 只给 MCP 面可能触及的那些，其余为 null（不替权威编一个含义）。",
        "http_transport": {
            "transport": "http",
            "endpoint_version": 2,
            "framing": "POST /rpc JSON; POST /events server-sent events",
            "authentication": "Authorization: Bearer",
            "frame_limit_bytes": model::FRAME_LIMIT,
            "id_limit_bytes": world::TOKEN_LIMIT,
            "request_id_is_a_string": true,
        },
        "read_limits": {
            "default": world::DEFAULT_READ_LIMIT,
            "max": world::MAX_READ_LIMIT,
        },
        "size_intent": {
            "axes": ["longest", "height"],
            "sources": ["user", "suggested", "default"],
            "min_meters": model::SIZE_INTENT_MIN_METERS,
            "max_meters": model::SIZE_INTENT_MAX_METERS,
            "height_meters_same_range": true,
            "height_axis_equals_height_meters": true,
            "applies": ["normalize", "echo"],
            "note": "axis=height 时 meters 必须与 heightMeters 逐值相同；axis=longest 时 heightMeters 仍必须给出（权威的提交形状如此），它只是另一根轴上的既有事实。",
        },
        "world": {
            "domains": [world::WORLD_DOMAIN, world::OBJECT_DOMAIN],
            "world_key": world::WORLD_KEY,
            "consumers": world::CONSUMERS,
            "ops": world::OPS.iter().map(|op| json!({
                "op": op,
                "requires": match *op {
                    "replaceState" => vec!["state"],
                    "upsertObject" => vec!["objectID 或 object", "expectedObjectRevision（可选）"],
                    "deleteObject" => vec!["objectID"],
                    "setWorldFacts" => vec!["facts"],
                    "advanceCursor" => vec!["consumer", "seq"],
                    _ => vec![],
                },
            })).collect::<Vec<Value>>(),
            "max_operations": world::MAX_OPERATIONS,
            "max_facts": world::MAX_FACTS,
            "fact_payload_limit": world::FACT_PAYLOAD_LIMIT,
            "world_record_limit": world::WORLD_RECORD_LIMIT,
            "object_record_limit": world::OBJECT_RECORD_LIMIT,
            "reserved_metadata_keys": WORLD_KEYS.iter().map(|(key, why)| json!({
                "key": key, "why": why,
            })).collect::<Vec<Value>>(),
            "idempotency": {
                "key": "requestID",
                "replay": "同 requestID 同内容重放返回同一结果并带 replayed=true；内容不同返回 request_id_conflict",
                "cas": "expectedRevision 必须等于当前 world revision，否则 revision_conflict",
            },
        },
        "error_codes": ERROR_CODES.iter().map(|code| json!({
            "code": code, "reason": reasons(code),
        })).collect::<Vec<Value>>(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    /// The authority's own sources, compiled into this test. `contract.rs` is
    /// excluded on purpose: a contract that quoted itself as evidence would
    /// always agree with itself.
    const AUTHORITY_SOURCES: &[(&str, &str)] = &[
        ("activity.rs", include_str!("activity.rs")),
        ("agent_cli.rs", include_str!("agent_cli.rs")),
        ("agent_claude.rs", include_str!("agent_claude.rs")),
        ("agent_chat.rs", include_str!("agent_chat.rs")),
        ("agent_dsh.rs", include_str!("agent_dsh.rs")),
        ("agent_runtime.rs", include_str!("agent_runtime.rs")),
        ("agent_runtime_tools.rs", include_str!("agent_runtime_tools.rs")),
        ("agent_scheduler.rs", include_str!("agent_scheduler.rs")),
        ("agent_tools.rs", include_str!("agent_tools.rs")),
        ("artifact.rs", include_str!("artifact.rs")),
        ("chat_attachments.rs", include_str!("chat_attachments.rs")),
        ("chat_speech.rs", include_str!("chat_speech.rs")),
        ("cli.rs", include_str!("cli.rs")),
        ("daemon.rs", include_str!("daemon.rs")),
        ("files.rs", include_str!("files.rs")),
        ("generation_configuration.rs", include_str!("generation_configuration.rs")),
        ("http.rs", include_str!("http.rs")),
        ("inbox_control.rs", include_str!("inbox_control.rs")),
        ("jukebox.rs", include_str!("jukebox.rs")),
        ("main.rs", include_str!("main.rs")),
        ("marble_control.rs", include_str!("marble_control.rs")),
        ("marble_geometry.rs", include_str!("marble_geometry.rs")),
        ("stage_video.rs", include_str!("stage_video.rs")),
        ("music_cache.rs", include_str!("music_cache.rs")),
        ("music_account.rs", include_str!("music_account.rs")),
        ("music_account_http.rs", include_str!("music_account_http.rs")),
        ("media.rs", include_str!("media.rs")),
        ("memory.rs", include_str!("memory.rs")),
        ("messages.rs", include_str!("messages.rs")),
        ("model.rs", include_str!("model.rs")),
        ("music.rs", include_str!("music.rs")),
        ("music_library.rs", include_str!("music_library.rs")),
        ("music_knowledge.rs", include_str!("music_knowledge.rs")),
        ("music_playback.rs", include_str!("music_playback.rs")),
        ("music_program.rs", include_str!("music_program.rs")),
        ("music_program_rules.rs", include_str!("music_program_rules.rs")),
        ("presence_selection.rs", include_str!("presence_selection.rs")),
        ("product_settings.rs", include_str!("product_settings.rs")),
        ("provider.rs", include_str!("provider.rs")),
        ("resident.rs", include_str!("resident.rs")),
        ("resident_intent.rs", include_str!("resident_intent.rs")),
        ("screen_playback.rs", include_str!("screen_playback.rs")),
        ("screen_state.rs", include_str!("screen_state.rs")),
        ("speech_delivery.rs", include_str!("speech_delivery.rs")),
        ("store.rs", include_str!("store.rs")),
        ("world.rs", include_str!("world.rs")),
        ("world_activity.rs", include_str!("world_activity.rs")),
        ("world_activity_approach.rs", include_str!("world_activity_approach.rs")),
        ("world_control.rs", include_str!("world_control.rs")),
        ("world_device.rs", include_str!("world_device.rs")),
        ("world_prop.rs", include_str!("world_prop.rs")),
        ("world_prop_capability.rs", include_str!("world_prop_capability.rs")),
        ("world_prop_grip.rs", include_str!("world_prop_grip.rs")),
        ("world_prop_measurement.rs", include_str!("world_prop_measurement.rs")),
        ("voice.rs", include_str!("voice.rs")),
        ("wish_control.rs", include_str!("wish_control.rs")),
        ("wish_reference.rs", include_str!("wish_reference.rs")),
    ];

    /// Tokens that mark a line as an error site.
    ///
    /// A word is a code when it appears on a line that returns or raises an
    /// error; the same word used as a field name, a method name or a status is
    /// not a code. `bounded(`, `identity(`, `glb_container(`, `object_text(`,
    /// `fail(` and `error(` are here because those helpers take the code as an
    /// argument (`bounded(raw, "invalid_world_id")`), which is how a third of
    /// this vocabulary reaches the wire.
    const ERROR_SITES: &[&str] = &[
        "Err(",
        "ok_or",
        "map_err",
        "bounded(",
        "identity(",
        "fail(",
        "error(",
        "glb_container(",
        "object_text(",
        "failure(",
        "reject(",
        "code:",
        "code =",
        "set_state(",
    ];

    /// Every `"…"` on this line that looks like a code: lowercase snake_case,
    /// containing an underscore, at least six characters long.
    fn shaped_literals(line: &str) -> Vec<String> {
        let mut out = Vec::new();
        let mut index = 0usize;
        while index < line.len() {
            let Some(open) = line[index..].find('"').map(|at| index + at) else {
                break;
            };
            let start = open + 1;
            let Some(end) = line[start..].find('"').map(|at| start + at) else {
                break;
            };
            let candidate = &line[start..end];
            let shaped = candidate.len() >= 6
                && candidate.contains('_')
                && candidate.starts_with(|c: char| c.is_ascii_lowercase())
                && candidate
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
            if shaped {
                out.push(candidate.to_owned());
            }
            index = end + 1;
        }
        out
    }

    /// Every code the non-test code of this authority can return.
    fn codes_the_authority_returns() -> BTreeSet<String> {
        let mut codes = BTreeSet::new();
        for (name, text) in AUTHORITY_SOURCES {
            if *name == "agent_runtime_tools.rs" {
                // Internal executor failures are observations, not direct RPC errors.
                // daemon.rs projects runtime errors through public_error_code.
                continue;
            }
            if *name == "agent_runtime.rs" {
                let start = text.find("pub fn public_error_code(").expect("runtime wire projection");
                let end = text[start..].find("\n}").expect("projection closing brace") + start;
                codes.extend(shaped_literals(&text[start..end]));
                continue;
            }
            if *name == "music_cache.rs" {
                let production = without_test_modules(text);
                for token in ["Err(", "ok_or(", "ok_or_else(", "map_err("] {
                    for (start, _) in production.match_indices(token) {
                        let arguments = start + token.len();
                        if let Some(end) = balanced_end(&production, arguments, b'(', b')') {
                            codes.extend(shaped_literals(&production[arguments..end]));
                        }
                    }
                }
                continue;
            }
            if *name == "stage_video.rs" || matches!(*name, "activity.rs" | "agent_cli.rs" | "agent_claude.rs" | "agent_chat.rs" | "agent_dsh.rs" | "agent_scheduler.rs" | "agent_tools.rs" | "chat_attachments.rs" | "generation_configuration.rs" | "inbox_control.rs" | "marble_control.rs" | "marble_geometry.rs" | "music_account.rs" | "music_account_http.rs" | "music_library.rs" | "music_playback.rs" | "music_program.rs" | "music_program_rules.rs" | "presence_selection.rs" | "product_settings.rs" | "resident_intent.rs" | "screen_playback.rs" | "screen_state.rs" | "speech_delivery.rs" | "wish_control.rs" | "world_activity.rs" | "world_activity_approach.rs" | "world_control.rs" | "world_device.rs" | "world_prop_capability.rs") {
                let production = without_test_modules(text);
                let production = if *name == "agent_cli.rs" {
                    // CLI drive/probe and executor queue failures settle state;
                    // they are not errors returned by CliService::request.
                    let config_end = production.find("async fn config_probe(").expect("CLI config boundary");
                    let service_start = production.find("impl CliService {").expect("CLI RPC service");
                    let service_end = production.find("async fn run(").expect("CLI background run");
                    format!("{}\n{}", &production[..config_end], &production[service_start..service_end])
                } else if *name == "agent_claude.rs" {
                    // Native Claude executor failures settle the run; only
                    // configuration and authenticated RPC errors are public.
                    let config_end = production.find("struct PendingApproval {").expect("Claude config boundary");
                    let service_start = production.find("impl ClaudeService {").expect("Claude RPC service");
                    let service_end = production.find("async fn run(").expect("Claude background run");
                    format!("{}\n{}", &production[..config_end], &production[service_start..service_end])
                } else if *name == "agent_dsh.rs" {
                    // DSH configuration and authenticated control/flat-plugin
                    // RPCs return errors. Background drive only settles state.
                    let config_end = production.find("struct Approval {").expect("DSH config boundary");
                    let service_start = production.find("impl DshService {").expect("DSH RPC service");
                    let service_end = production.find("async fn run(").expect("DSH background run");
                    format!("{}\n{}", &production[..config_end], &production[service_start..service_end])
                } else { production };
                // Unlike line-wide scanning, constructor argument scanning does
                // not publish adjacent RPC method names or ledger state values.
                for token in ["Err(", "ok_or(", "ok_or_else(", "map_err("] {
                    for (start, _) in production.match_indices(token) {
                        let arguments = start + token.len();
                        if let Some(end) = balanced_end(&production, arguments, b'(', b')') {
                            codes.extend(shaped_literals(&production[arguments..end]));
                        }
                    }
                }
                if matches!(*name, "agent_dsh.rs" | "agent_claude.rs" | "music_account.rs") {
                    // Flat-plugin failures are structured result observations,
                    // still real wire error codes, with no control capability grant.
                    // `music_account_begin` reports an account that cannot play in
                    // the same shape: a receipt body with a `code` field.
                    for line in production.lines().filter(|line| line.contains("\"code\":")) {
                        codes.extend(shaped_literals(line));
                    }
                }
                continue;
            }
            // Inline cfg(test) fields may precede production methods. Only the
            // actual test module marks the end of the production vocabulary.
            let text = match text.find("#[cfg(test)]\nmod tests") {
                Some(at) => &text[..at],
                None => text,
            };
            for line in text.lines() {
                if !ERROR_SITES.iter().any(|token| line.contains(token)) {
                    continue;
                }
                for literal in shaped_literals(line) {
                    codes.insert(literal);
                }
            }
            // HTTP status + error-code helpers are formatted across lines.
            // Extract only the balanced reject(...) arguments (not surrounding
            // branches), so rustfmt cannot hide a published HTTP error code.
            for (start, _) in text.match_indices("reject(") {
                let mut depth = 1usize;
                let mut quoted = false;
                let mut escaped = false;
                let arguments = start + "reject(".len();
                for (offset, byte) in text.as_bytes()[arguments..].iter().enumerate() {
                    if quoted {
                        if escaped { escaped = false; }
                        else if *byte == b'\\' { escaped = true; }
                        else if *byte == b'"' { quoted = false; }
                        continue;
                    }
                    match byte {
                        b'"' => quoted = true,
                        b'(' => depth += 1,
                        b')' => {
                            depth -= 1;
                            if depth == 0 {
                                codes.extend(shaped_literals(&text[arguments..arguments + offset]));
                                break;
                            }
                        }
                        _ => {}
                    }
                }
            }
            // ASR maps typed core errors through a single static match helper;
            // its returned literals are wire errors even without an inline Err.
            if let Some(start) = text.find("fn asr_error(") {
                let helper = &text[start..];
                let end = helper.find("\n}").expect("ASR error mapper has a closing brace");
                codes.extend(shaped_literals(&helper[..end]));
            }
        }
        codes
    }

    // Skip quoted strings/comments while balancing source delimiters. This is
    // source evidence extraction, not a Rust compiler or runtime authorization.
    fn balanced_end(text: &str, start: usize, open: u8, close: u8) -> Option<usize> {
        let bytes = text.as_bytes();
        let (mut depth, mut quoted, mut escaped, mut line_comment) = (1usize, false, false, false);
        let mut index = start;
        while index < bytes.len() {
            let byte = bytes[index];
            if line_comment { if byte == b'\n' { line_comment = false; } index += 1; continue; }
            if quoted {
                if escaped { escaped = false; }
                else if byte == b'\\' { escaped = true; }
                else if byte == b'"' { quoted = false; }
            } else if byte == b'/' && bytes.get(index + 1) == Some(&b'/') { line_comment = true; }
            else if byte == b'"' { quoted = true; }
            else if byte == open { depth += 1; }
            else if byte == close { depth -= 1; if depth == 0 { return Some(index); } }
            index += 1;
        }
        None
    }
    fn without_test_modules(text: &str) -> String {
        let mut result = text.to_owned();
        while let Some(start) = result.find("#[cfg(test)]\nmod tests") {
            let body = result[start..].find('{').expect("test module opening") + start + 1;
            let end = balanced_end(&result, body, b'{', b'}').expect("test module closing");
            result.replace_range(start..=end, "");
        }
        result
    }

    #[test]
    fn host_source_extraction_keeps_production_after_tests_and_wire_projection() {
        let source = "fn before() {}\n#[cfg(test)]\nmod tests {\n fn fixture() { let _ = \"}\"; }\n}\nfn after() { Err(\"production_after_tests\") }";
        let production = without_test_modules(source);
        assert!(production.contains("production_after_tests"));
        assert!(!production.contains("fixture"));
        let actual = codes_the_authority_returns();
        assert!(actual.contains("agent_runtime_failed"));
        assert!(actual.contains("agent_cli_invalid_receipt"));
        assert!(actual.contains("agent_dsh_unresolved_tools"));
        assert!(actual.contains("host_tool_unavailable"));
        assert!(actual.contains("world_coordinate_missing_ground"));
        assert!(!actual.contains("host_tool_result_unknown"));
        assert!(!actual.contains("agent_cli_launch_failed"));
        assert!(!actual.contains("agent_dsh_launch_failed"));
        assert!(!actual.contains("agent_dsh_protocol_failed"));
        assert!(!actual.contains("agent_runtime_authorize_operation"));
        assert!(!actual.contains("agent_loop_configure"));
    }

    /// The whole point of this method: it is generated, not transcribed.
    #[test]
    fn capability_contract_matches_the_authority() {
        let contract = describe();
        assert_eq!(
            contract["size_intent"]["min_meters"].as_f64(),
            Some(model::SIZE_INTENT_MIN_METERS)
        );
        assert_eq!(
            contract["size_intent"]["max_meters"].as_f64(),
            Some(model::SIZE_INTENT_MAX_METERS)
        );
        assert_eq!(
            contract["http_transport"]["frame_limit_bytes"].as_u64(),
            Some(model::FRAME_LIMIT as u64)
        );
        assert_eq!(
            contract["read_limits"]["max"].as_u64(),
            Some(world::MAX_READ_LIMIT as u64)
        );
        let consumers: Vec<&str> = contract["world"]["consumers"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_str().unwrap())
            .collect();
        assert_eq!(consumers, world::CONSUMERS.to_vec());
        let ops: Vec<&str> = contract["world"]["ops"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| entry["op"].as_str().unwrap())
            .collect();
        assert_eq!(ops, world::OPS.to_vec());
    }

    /// The published vocabulary is exactly the authority's — no more, no less.
    ///
    /// Adding a code to the contract without the code returning it fails; so does
    /// removing one from the contract while the code still returns it. That is
    /// what "the read-only contract agrees with the authority" means when the
    /// thing being read is a vocabulary rather than a document.
    #[test]
    fn the_published_codes_are_exactly_the_authoritys_own() {
        let published: BTreeSet<String> = ERROR_CODES.iter().map(|c| (*c).to_owned()).collect();
        let actual = codes_the_authority_returns();
        let missing: Vec<&String> = actual.difference(&published).collect();
        let invented: Vec<&String> = published.difference(&actual).collect();
        assert!(
            missing.is_empty(),
            "权威会返回这些码，契约却没有发布：{missing:?}"
        );
        assert!(
            invented.is_empty(),
            "契约发布了这些码，权威已经不再返回：{invented:?}"
        );
    }

    /// The other direction of "no invented fields": every published code must
    /// exist as a shaped literal somewhere in the authority's own sources, so a
    /// hand-typed code with no implementation behind it cannot stay.
    #[test]
    fn every_published_code_appears_in_the_sources() {
        let all: String = AUTHORITY_SOURCES
            .iter()
            .map(|(_, text)| *text)
            .collect::<Vec<&str>>()
            .join("\n");
        let literals: std::collections::BTreeSet<String> =
            shaped_literals(&all).into_iter().collect();
        for code in ERROR_CODES {
            assert!(
                literals.contains(*code),
                "契约发布了 `{code}`，但权威源码里根本没有这个字面量"
            );
        }
    }

    #[test]
    fn the_published_list_is_sorted_unique_and_snake_case() {
        let mut previous: Option<&str> = None;
        for code in ERROR_CODES {
            if let Some(previous) = previous {
                assert!(previous < *code, "错误码表必须有序且不重复：{previous} / {code}");
            }
            previous = Some(code);
            assert!(
                code.chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_'),
                "错误码不是 snake_case：{code}"
            );
        }
        for (code, _) in ERROR_REASONS {
            assert!(
                ERROR_CODES.contains(code),
                "给一个不存在的错误码写了含义：{code}"
            );
        }
    }

    /// "不许改名": the two codes the size contract is written in terms of are the
    /// ones the validator actually returns.
    #[test]
    fn the_pinned_size_codes_exist_and_are_the_validators_own() {
        assert!(ERROR_CODES.contains(&"invalid_size_intent"));
        assert!(ERROR_CODES.contains(&"size_intent_conflict"));

        let mut submit = crate::model::Submit {
            id: "0b54a1d2-6f3c-4a1e-9d77-2c9f5b8e4a01".to_owned(),
            endpoint: "https://example.test".to_owned(),
            name: "剑".to_owned(),
            png_base64: String::new(),
            source: crate::model::Source {
                author: "a".to_owned(),
                license: "l".to_owned(),
            },
            height_meters: 1.1,
            size_intent: Some(serde_json::json!({"axis": "width", "meters": 1.1, "source": "user"})),
            context: None,
            source_wish_id: None,
            generation_profile: None,
        };
        assert_eq!(submit.validate(), Err("invalid_size_intent"));
        submit.size_intent = Some(serde_json::json!({
            "axis": "height", "meters": 0.5, "source": "user"
        }));
        assert_eq!(submit.validate(), Err("size_intent_conflict"));
    }

    #[test]
    fn the_published_op_vocabulary_matches_the_match() {
        // Every op the contract advertises must still be an arm in `apply`.
        // A removed arm leaves the contract lying; this fails first.
        let source = include_str!("world.rs");
        for op in world::OPS {
            let arm = format!("\"{op}\" => {{");
            assert!(
                source.contains(&arm),
                "契约发布了 `{op}`，但 world.rs 里已经没有 `{arm}` 这个分支"
            );
        }
    }

    #[test]
    fn the_contract_has_no_parameters_and_no_side_effects() {
        // `describe` takes nothing and only reads constants: calling it twice
        // must produce identical bytes.
        assert_eq!(describe(), describe());
    }
}
