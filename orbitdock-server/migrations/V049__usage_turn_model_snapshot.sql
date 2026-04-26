ALTER TABLE usage_turns
    ADD COLUMN provider TEXT NOT NULL DEFAULT 'claude';

ALTER TABLE usage_turns
    ADD COLUMN model TEXT;

UPDATE usage_turns
   SET provider = COALESCE(NULLIF((
         SELECT s.provider
           FROM sessions s
          WHERE s.id = usage_turns.session_id
       ), ''), 'claude'),
       model = (
         SELECT s.model
           FROM sessions s
          WHERE s.id = usage_turns.session_id
       )
 WHERE provider IS NULL
    OR trim(provider) = ''
    OR model IS NULL;
