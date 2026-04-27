use super::*;

#[test]
fn mission_tools_expose_expected_catalog() {
  let tools = mission_tool_definitions();
  let names: Vec<&str> = tools.iter().map(|tool| tool.name.as_str()).collect();
  assert_eq!(names.len(), 8);
  assert_eq!(
    names,
    vec![
      "mission_get_issue",
      "mission_post_update",
      "mission_update_comment",
      "mission_get_comments",
      "mission_set_status",
      "mission_link_pr",
      "mission_create_followup",
      "mission_report_blocked",
    ]
  );
  for tool in tools {
    assert!(
      tool.name.starts_with("mission_"),
      "Tool '{}' should start with 'mission_'",
      tool.name
    );
  }
}

#[test]
fn mission_tool_schemas_stay_self_consistent() {
  let tools = mission_tool_definitions();
  let mut names: Vec<&str> = tools.iter().map(|tool| tool.name.as_str()).collect();
  names.sort();
  names.dedup();
  assert_eq!(names.len(), 8, "Duplicate tool names detected");

  for tool in tools {
    assert_eq!(
      tool.input_schema.get("type").and_then(|v| v.as_str()),
      Some("object"),
      "Tool '{}' schema must have type: object",
      tool.name
    );
    let required = tool
      .input_schema
      .get("required")
      .and_then(|v| v.as_array())
      .cloned()
      .unwrap_or_default();
    let properties = tool
      .input_schema
      .get("properties")
      .and_then(|v| v.as_object());

    for req in &required {
      let name = req.as_str().unwrap_or("");
      assert!(
        properties.map(|p| p.contains_key(name)).unwrap_or(false),
        "Tool '{}' lists required field '{}' that doesn't exist in properties",
        tool.name,
        name
      );
    }
  }
}
