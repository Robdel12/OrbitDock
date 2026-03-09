use orbitdock_protocol::UsageErrorInfo;

pub(crate) fn not_control_plane_endpoint_error() -> UsageErrorInfo {
    UsageErrorInfo {
        code: "not_control_plane_endpoint".to_string(),
        message: "This endpoint is not primary for control-plane usage reads.".to_string(),
    }
}
