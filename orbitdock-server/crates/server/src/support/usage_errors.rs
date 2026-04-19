use orbitdock_protocol::UsageErrorInfo;

pub(crate) fn not_primary_usage_endpoint_error() -> UsageErrorInfo {
  UsageErrorInfo {
    code: "not_primary_usage_endpoint".to_string(),
    message: "Usage reads must run through the primary endpoint.".to_string(),
  }
}
