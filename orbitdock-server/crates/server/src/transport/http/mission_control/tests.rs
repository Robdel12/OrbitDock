use super::slugify_mission_name;

#[test]
fn slugify_mission_name_normalizes_user_visible_inputs() {
  let cases = [
    ("My Mission", "my-mission"),
    ("OrbitDock (v2)", "orbitdock-v2"),
    ("  test  ", "test"),
    ("a---b", "a-b"),
    ("café project", "café-project"),
    ("simple", "simple"),
    ("", ""),
    ("OrbitDock GitHub", "orbitdock-github"),
    ("hello@world.com #1", "hello-world-com-1"),
    ("---!!!---", ""),
  ];
  for (input, expected) in cases {
    assert_eq!(slugify_mission_name(input), expected, "input: {input:?}");
  }
}
