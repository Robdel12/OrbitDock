use super::super::commands::PersistCommand;
use super::SyncCommand;

enum RowSyncKind {
    Append,
    Upsert,
}

struct RowSyncPlan {
    kind: RowSyncKind,
    row_id: String,
    session_id: String,
    entry: orbitdock_protocol::conversation_contracts::ConversationRowEntry,
    viewer_present: bool,
}

enum SyncPlanKind {
    None,
    Ready(SyncCommand),
    Row(RowSyncPlan),
}

pub(crate) struct SyncPlan(SyncPlanKind);

impl SyncPlan {
    pub(crate) fn from_command(command: &PersistCommand) -> Self {
        match command {
            PersistCommand::RowAppend {
                session_id,
                entry,
                viewer_present,
                ..
            } => Self(SyncPlanKind::Row(RowSyncPlan {
                kind: RowSyncKind::Append,
                row_id: entry.id().to_string(),
                session_id: session_id.clone(),
                entry: entry.clone(),
                viewer_present: *viewer_present,
            })),
            PersistCommand::RowUpsert {
                session_id,
                entry,
                viewer_present,
                ..
            } => Self(SyncPlanKind::Row(RowSyncPlan {
                kind: RowSyncKind::Upsert,
                row_id: entry.id().to_string(),
                session_id: session_id.clone(),
                entry: entry.clone(),
                viewer_present: *viewer_present,
            })),
            _ => match Option::<SyncCommand>::from(command) {
                Some(command) => Self(SyncPlanKind::Ready(command)),
                None => Self(SyncPlanKind::None),
            },
        }
    }

    pub(crate) fn into_sync_command_with_sequence(
        self,
        assigned_sequence: u64,
    ) -> Option<SyncCommand> {
        match self.0 {
            SyncPlanKind::None => None,
            SyncPlanKind::Ready(command) => Some(command),
            SyncPlanKind::Row(plan) => Some(plan.into_sync_command(assigned_sequence)),
        }
    }

    pub(crate) fn row_id(&self) -> Option<&str> {
        match &self.0 {
            SyncPlanKind::Row(plan) => Some(plan.row_id.as_str()),
            SyncPlanKind::None | SyncPlanKind::Ready(_) => None,
        }
    }
}

impl RowSyncPlan {
    fn into_sync_command(mut self, assigned_sequence: u64) -> SyncCommand {
        self.entry.sequence = assigned_sequence;
        match self.kind {
            RowSyncKind::Append => SyncCommand::RowAppend {
                session_id: self.session_id,
                entry: self.entry,
                viewer_present: self.viewer_present,
                sequence: assigned_sequence,
            },
            RowSyncKind::Upsert => SyncCommand::RowUpsert {
                session_id: self.session_id,
                entry: self.entry,
                viewer_present: self.viewer_present,
                sequence: assigned_sequence,
            },
        }
    }
}
