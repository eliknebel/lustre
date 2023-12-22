import gleam/json.{type Json}

// TODO: Implement efficient diffing and patch creation
// For now, just send the entire rendered view as a string
pub type Patch =
  String

pub fn patch_to_json(patch: Patch, _debug: Bool) -> Json {
  json.string(patch)
}
