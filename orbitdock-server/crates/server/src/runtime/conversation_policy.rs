use orbitdock_protocol::conversation_contracts::ConversationRowEntry;

use crate::domain::sessions::conversation::ConversationPage;

const COHERENT_HISTORY_MIN_TURNS: usize = 4;
pub(crate) const COHERENT_HISTORY_MAX_ROWS: usize = 200;

pub(crate) fn normalize_row_sequences(rows: &mut [ConversationRowEntry]) {
    let mut next_sequence = 0_u64;
    for entry in rows {
        if entry.sequence == 0 && next_sequence > 0 {
            entry.sequence = next_sequence;
        }
        next_sequence = entry.sequence + 1;
    }
}

pub(crate) fn conversation_page_from_rows(
    mut rows: Vec<ConversationRowEntry>,
    before_sequence: Option<u64>,
    limit: usize,
) -> ConversationPage {
    normalize_row_sequences(&mut rows);
    let total_row_count = rows.len() as u64;
    if rows.is_empty() || limit == 0 {
        return ConversationPage {
            rows: vec![],
            total_row_count,
            has_more_before: false,
            oldest_sequence: None,
            newest_sequence: None,
        };
    }

    let upper_bound = before_sequence.unwrap_or(u64::MAX);
    let mut page: Vec<ConversationRowEntry> = rows
        .into_iter()
        .filter(|entry| entry.sequence < upper_bound)
        .rev()
        .take(limit)
        .collect();
    page.reverse();

    conversation_page_with_total(page, total_row_count)
}

pub(crate) fn conversation_page_with_total(
    rows: Vec<ConversationRowEntry>,
    total_row_count: u64,
) -> ConversationPage {
    let oldest_sequence = rows.first().map(|entry| entry.sequence);
    let newest_sequence = rows.last().map(|entry| entry.sequence);
    let has_more_before = oldest_sequence.is_some_and(|sequence| sequence > 0);
    ConversationPage {
        rows,
        total_row_count,
        has_more_before,
        oldest_sequence,
        newest_sequence,
    }
}

pub(crate) fn requires_coherent_history_page(
    rows: &[ConversationRowEntry],
    has_more_before: bool,
) -> bool {
    if !has_more_before || rows.is_empty() {
        return false;
    }

    if !rows.first().is_some_and(row_starts_turn) {
        return true;
    }

    let turn_count = rows.iter().filter(|entry| row_starts_turn(entry)).count();
    turn_count < COHERENT_HISTORY_MIN_TURNS
}

pub(crate) fn prepend_conversation_page(
    current: ConversationPage,
    older: ConversationPage,
) -> ConversationPage {
    if older.rows.is_empty() {
        return current;
    }

    let mut rows = older.rows;
    rows.extend(current.rows);

    ConversationPage {
        total_row_count: current.total_row_count.max(older.total_row_count),
        has_more_before: older.has_more_before,
        oldest_sequence: rows.first().map(|entry| entry.sequence),
        newest_sequence: rows.last().map(|entry| entry.sequence),
        rows,
    }
}

pub(crate) fn expected_page_row_count(
    total_row_count: u64,
    before_sequence: Option<u64>,
    limit: usize,
) -> usize {
    let max_available = before_sequence
        .and_then(|sequence| usize::try_from(sequence).ok())
        .unwrap_or(usize::MAX);
    limit.min(max_available).min(total_row_count as usize)
}

fn row_starts_turn(entry: &ConversationRowEntry) -> bool {
    entry.row.starts_turn()
}
