#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RawConversationPageSource {
    RuntimePage,
    RuntimeTranscript,
    DatabasePage,
    RestoredTranscript,
    RestoredMessages,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BootstrapSeedSource {
    RuntimeBootstrap,
    RuntimeTranscript,
    DatabasePage,
    RawConversationPage,
    RestoredTranscript,
    RestoredMessages,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FullSessionHistorySource {
    ExistingMessages,
    Transcript,
    DatabaseMessages,
}

pub(crate) fn select_runtime_raw_conversation_page_source(
    runtime_page_has_data: bool,
    transcript_path_present: bool,
) -> RawConversationPageSource {
    if runtime_page_has_data {
        RawConversationPageSource::RuntimePage
    } else if transcript_path_present {
        RawConversationPageSource::RuntimeTranscript
    } else {
        RawConversationPageSource::DatabasePage
    }
}

pub(crate) fn select_persisted_raw_conversation_page_source(
    db_page_has_data: bool,
    restored_messages_present: bool,
    transcript_path_present: bool,
) -> RawConversationPageSource {
    if db_page_has_data {
        RawConversationPageSource::DatabasePage
    } else if !restored_messages_present && transcript_path_present {
        RawConversationPageSource::RestoredTranscript
    } else {
        RawConversationPageSource::RestoredMessages
    }
}

pub(crate) fn select_runtime_bootstrap_seed_source(
    runtime_bootstrap_has_data: bool,
    transcript_path_present: bool,
) -> BootstrapSeedSource {
    if runtime_bootstrap_has_data {
        BootstrapSeedSource::RuntimeBootstrap
    } else if transcript_path_present {
        BootstrapSeedSource::RuntimeTranscript
    } else {
        BootstrapSeedSource::DatabasePage
    }
}

pub(crate) fn select_persisted_bootstrap_seed_source(
    raw_page_has_data: bool,
    restored_messages_present: bool,
    transcript_path_present: bool,
) -> BootstrapSeedSource {
    if raw_page_has_data {
        BootstrapSeedSource::RawConversationPage
    } else if !restored_messages_present && transcript_path_present {
        BootstrapSeedSource::RestoredTranscript
    } else {
        BootstrapSeedSource::RestoredMessages
    }
}

pub(crate) fn select_runtime_full_session_history_source(
    messages_present: bool,
    transcript_path_present: bool,
) -> FullSessionHistorySource {
    if messages_present {
        FullSessionHistorySource::ExistingMessages
    } else if transcript_path_present {
        FullSessionHistorySource::Transcript
    } else {
        FullSessionHistorySource::DatabaseMessages
    }
}

pub(crate) fn select_restored_full_session_history_source(
    messages_present: bool,
    transcript_path_present: bool,
) -> FullSessionHistorySource {
    if messages_present {
        FullSessionHistorySource::ExistingMessages
    } else if transcript_path_present {
        FullSessionHistorySource::Transcript
    } else {
        FullSessionHistorySource::ExistingMessages
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_raw_page_prefers_runtime_when_it_has_data() {
        assert_eq!(
            select_runtime_raw_conversation_page_source(true, true),
            RawConversationPageSource::RuntimePage
        );
    }

    #[test]
    fn runtime_raw_page_prefers_transcript_before_database_when_runtime_is_empty() {
        assert_eq!(
            select_runtime_raw_conversation_page_source(false, true),
            RawConversationPageSource::RuntimeTranscript
        );
    }

    #[test]
    fn persisted_raw_page_prefers_database_rows_over_transcript_backfill() {
        assert_eq!(
            select_persisted_raw_conversation_page_source(true, false, true),
            RawConversationPageSource::DatabasePage
        );
    }

    #[test]
    fn persisted_raw_page_uses_transcript_only_when_restored_messages_are_missing() {
        assert_eq!(
            select_persisted_raw_conversation_page_source(false, false, true),
            RawConversationPageSource::RestoredTranscript
        );
        assert_eq!(
            select_persisted_raw_conversation_page_source(false, true, true),
            RawConversationPageSource::RestoredMessages
        );
    }

    #[test]
    fn runtime_bootstrap_prefers_transcript_before_database_when_empty() {
        assert_eq!(
            select_runtime_bootstrap_seed_source(false, true),
            BootstrapSeedSource::RuntimeTranscript
        );
        assert_eq!(
            select_runtime_bootstrap_seed_source(false, false),
            BootstrapSeedSource::DatabasePage
        );
    }

    #[test]
    fn persisted_bootstrap_uses_raw_page_when_any_history_was_loaded() {
        assert_eq!(
            select_persisted_bootstrap_seed_source(true, false, true),
            BootstrapSeedSource::RawConversationPage
        );
    }

    #[test]
    fn full_session_history_prefers_existing_messages_then_transcript_then_db() {
        assert_eq!(
            select_runtime_full_session_history_source(true, true),
            FullSessionHistorySource::ExistingMessages
        );
        assert_eq!(
            select_runtime_full_session_history_source(false, true),
            FullSessionHistorySource::Transcript
        );
        assert_eq!(
            select_runtime_full_session_history_source(false, false),
            FullSessionHistorySource::DatabaseMessages
        );
    }

    #[test]
    fn restored_full_session_history_never_chooses_database_messages() {
        assert_eq!(
            select_restored_full_session_history_source(false, false),
            FullSessionHistorySource::ExistingMessages
        );
    }
}
