-- Add URL column to mission_issues for linking back to the tracker
ALTER TABLE mission_issues ADD COLUMN url TEXT;
