import gleam/erlang/process.{type Subject}
import ids/cuid.{type Message}
import ids/uuid

pub opaque type Unique {
  Unique(id: String)
}

pub type UniqueChannel =
  Subject(Message)

pub fn start_channel() -> UniqueChannel {
  // we don't expect this to fail, but if it does we cannot proceed so simply crash
  let assert Ok(cuid_channel) = cuid.start()

  cuid_channel
}

pub fn uuid() -> Unique {
  let assert Ok(id) = uuid.generate_v4()

  Unique(id: id)
}

pub fn cuid(channel: UniqueChannel) -> Unique {
  // requires a channel to be started in order to generate cuids
  let id = cuid.generate(channel)

  Unique(id: id)
}

pub fn slug(channel: UniqueChannel, label: String) -> Unique {
  // requires a channel to be started in order to generate slugs
  let id = label <> "-" <> cuid.slug(channel)

  Unique(id: id)
}

pub fn from_string(str: String) -> Unique {
  Unique(id: str)
}

pub fn to_string(unique: Unique) -> String {
  unique.id
}

pub fn equals(a: Unique, b: Unique) -> Bool {
  a.id == b.id
}
