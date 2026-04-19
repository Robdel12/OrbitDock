UPDATE usage_events
   SET snapshot_kind = 'mixed'
 WHERE snapshot_kind = 'mixed_legacy';

UPDATE usage_session_state
   SET snapshot_kind = 'mixed'
 WHERE snapshot_kind = 'mixed_legacy';
