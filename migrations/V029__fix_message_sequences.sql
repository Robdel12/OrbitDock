-- Fix broken sequences (many rows stuck at sequence=0) by reassigning
-- using rowid (insertion order) as ground truth.
UPDATE messages SET sequence = (
  SELECT sub.correct_seq FROM (
    SELECT id, (ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY rowid)) - 1 AS correct_seq
    FROM messages
  ) sub
  WHERE sub.id = messages.id
);
