use dashmap::DashMap;
use orbitdock_protocol::ClientPrimaryClaim;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Instant;

#[derive(Clone)]
struct ClientPrimaryClaimState {
    client_id: String,
    device_name: String,
    is_primary: bool,
}

pub(crate) struct ConnectionState {
    is_primary: AtomicBool,
    client_primary_claims: DashMap<u64, ClientPrimaryClaimState>,
    ws_connections: AtomicU64,
    started_at: Instant,
    orchestrator_running: AtomicBool,
}

impl ConnectionState {
    pub(crate) fn new(is_primary: bool) -> Self {
        Self {
            is_primary: AtomicBool::new(is_primary),
            client_primary_claims: DashMap::new(),
            ws_connections: AtomicU64::new(0),
            started_at: Instant::now(),
            orchestrator_running: AtomicBool::new(false),
        }
    }

    pub(crate) fn is_primary(&self) -> bool {
        self.is_primary.load(Ordering::Relaxed)
    }

    pub(crate) fn set_primary(&self, is_primary: bool) -> bool {
        let previous = self.is_primary.swap(is_primary, Ordering::SeqCst);
        previous != is_primary
    }

    pub(crate) fn ws_connect(&self) -> u64 {
        self.ws_connections.fetch_add(1, Ordering::Relaxed) + 1
    }

    pub(crate) fn ws_disconnect(&self) -> u64 {
        self.ws_connections.fetch_sub(1, Ordering::Relaxed) - 1
    }

    pub(crate) fn ws_connection_count(&self) -> u64 {
        self.ws_connections.load(Ordering::Relaxed)
    }

    pub(crate) fn uptime_seconds(&self) -> u64 {
        self.started_at.elapsed().as_secs()
    }

    /// Atomically claim orchestrator ownership. Returns `true` if this call
    /// transitioned from stopped → running (caller should spawn the loop).
    /// Returns `false` if an orchestrator is already running.
    pub(crate) fn try_start_orchestrator(&self) -> bool {
        self.orchestrator_running
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::Relaxed)
            .is_ok()
    }

    pub(crate) fn stop_orchestrator(&self) {
        self.orchestrator_running.store(false, Ordering::SeqCst);
    }

    pub(crate) fn is_orchestrator_running(&self) -> bool {
        self.orchestrator_running.load(Ordering::Relaxed)
    }

    pub(crate) fn set_client_primary_claim(
        &self,
        conn_id: u64,
        client_id: String,
        device_name: String,
        is_primary: bool,
    ) {
        self.client_primary_claims.insert(
            conn_id,
            ClientPrimaryClaimState {
                client_id,
                device_name,
                is_primary,
            },
        );
    }

    pub(crate) fn clear_client_primary_claim(&self, conn_id: u64) -> bool {
        self.client_primary_claims.remove(&conn_id).is_some()
    }

    pub(crate) fn active_client_primary_claims(&self) -> Vec<ClientPrimaryClaim> {
        collect_active_primary_claims(self.client_primary_claims.iter().map(|claim| {
            (
                *claim.key(),
                claim.value().client_id.clone(),
                claim.value().device_name.clone(),
                claim.value().is_primary,
            )
        }))
    }
}

fn collect_active_primary_claims<I>(claims: I) -> Vec<ClientPrimaryClaim>
where
    I: IntoIterator<Item = (u64, String, String, bool)>,
{
    let mut by_client: BTreeMap<String, (u64, String)> = BTreeMap::new();
    for (conn_id, client_id, device_name, is_primary) in claims {
        if !is_primary {
            continue;
        }

        by_client
            .entry(client_id)
            .and_modify(|existing| {
                if conn_id < existing.0 {
                    *existing = (conn_id, device_name.clone());
                }
            })
            .or_insert((conn_id, device_name));
    }

    by_client
        .into_iter()
        .map(|(client_id, (_, device_name))| ClientPrimaryClaim {
            client_id,
            device_name,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{collect_active_primary_claims, ConnectionState};

    #[test]
    fn orchestrator_first_start_succeeds() {
        let state = ConnectionState::new(true);
        assert!(!state.is_orchestrator_running());
        assert!(state.try_start_orchestrator());
        assert!(state.is_orchestrator_running());
    }

    #[test]
    fn orchestrator_second_start_rejected() {
        let state = ConnectionState::new(true);
        assert!(state.try_start_orchestrator());
        assert!(!state.try_start_orchestrator());
    }

    #[test]
    fn orchestrator_can_restart_after_stop() {
        let state = ConnectionState::new(true);
        assert!(state.try_start_orchestrator());
        state.stop_orchestrator();
        assert!(!state.is_orchestrator_running());
        assert!(state.try_start_orchestrator());
    }

    #[test]
    fn collect_active_primary_claims_dedup_by_client_and_ignore_non_primary() {
        let claims = collect_active_primary_claims([
            (
                1,
                String::from("client-a"),
                String::from("MacBook Pro"),
                true,
            ),
            (2, String::from("client-a"), String::from("iPhone"), true),
            (3, String::from("client-b"), String::from("Studio"), false),
        ]);

        assert_eq!(claims.len(), 1);
        assert_eq!(claims[0].client_id, "client-a");
        assert_eq!(claims[0].device_name, "MacBook Pro");
    }
}
