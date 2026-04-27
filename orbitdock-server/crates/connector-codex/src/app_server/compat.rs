use std::path::PathBuf;

pub(crate) fn strings_to_path_bufs(paths: Vec<String>) -> Vec<PathBuf> {
  paths.into_iter().map(PathBuf::from).collect()
}
