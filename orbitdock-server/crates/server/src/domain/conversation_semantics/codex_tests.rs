use super::handled_wrappers;

#[test]
fn reports_handled_wrapper_inventory() {
  assert!(handled_wrappers().contains(&"subagent_notification"));
  assert!(handled_wrappers().contains(&"proposed_plan"));
}
