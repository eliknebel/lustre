//// To read the full documentation for this module, please visit
//// [https://lustre.build/api/lustre](https://lustre.build/api/lustre)

// IMPORTS ---------------------------------------------------------------------

import gleam/dynamic.{type Decoder}
import gleam/option.{type Option}
import gleam/map.{type Map}
import lustre/app.{type Flag, type Init, type Update, type View}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/live/live_service.{type LiveService, type LiveServiceOpts}
import lustre/live/runtime
import lustre/live/internal/util/unique

// TYPES -----------------------------------------------------------------------

@target(javascript)
///
pub type App(flags, model, msg)

@target(erlang)
///
pub opaque type App(flags, model, msg) {
  App
}

pub type Error {
  AppAlreadyStarted
  AppNotYetStarted
  BadComponentName
  ComponentAlreadyRegistered
  ElementNotFound
  NotABrowser
}

// CONSTRUCTORS ----------------------------------------------------------------

///
pub fn element(element: Element(msg)) -> App(Nil, Nil, msg) {
  let init = fn(_) { #(Nil, effect.none()) }
  let update = fn(_, _) { #(Nil, effect.none()) }
  let view = fn(_) { element }

  application(init, update, view)
}

///
pub fn simple(
  init: fn(flags) -> model,
  update: fn(model, msg) -> model,
  view: fn(model) -> Element(msg),
) -> App(flags, model, msg) {
  let init = fn(flags) { #(init(flags), effect.none()) }
  let update = fn(model, msg) { #(update(model, msg), effect.none()) }

  application(init, update, view)
}

///
@external(javascript, "./lustre.ffi.mjs", "setup")
pub fn application(
  _init: fn(flags) -> #(model, Effect(msg)),
  _update: fn(model, msg) -> #(model, Effect(msg)),
  _view: fn(model) -> Element(msg),
) -> App(flags, model, msg) {
  // Applications are not usable on the erlang target. For those users, `App`
  // is an opaque type (aka they can't see its structure) and functions like
  // `start` and `destroy` are no-ops.
  //
  // Because the constructor is marked as `@target(erlang)` for some reason we
  // can't simply refer to it here even though the compiler should know that the
  // body of this function can only be entered from erlang (because we have an
  // external def for javascript) but alas, it does not.
  //
  // So instead, we must do this awful hack and cast a `Nil` to the `App` type
  // to make everything happy. Theoeretically this is not going to be a problem
  // unless someone starts poking around with their own ffi and at that point
  // they deserve it.
  dynamic.unsafe_coerce(dynamic.from(Nil))
}

@external(javascript, "./lustre.ffi.mjs", "setup_component")
pub fn component(
  _name: String,
  _init: fn() -> #(model, Effect(msg)),
  _update: fn(model, msg) -> #(model, Effect(msg)),
  _view: fn(model) -> Element(msg),
  _on_attribute_change: Map(String, Decoder(msg)),
) -> Result(Nil, Error) {
  Ok(Nil)
}

// LIVE SERVICE ----------------------------------------------------------------

/// Start a live service.
/// 
/// This function creates a long running live service and should be called when the server starts
/// once for every route that has a live view.
/// 
/// This is a low-level function that is typically not called directly. Instead, you should use the
/// live service bridge for your web server. For example, if you are using the `mist` web server,
/// you would use the `mist_lustre` package which provides a `mist_lustre.live_service` function.
pub fn start_live_service(
  flags: List(Flag),
  init: Init(model, msg),
  update: Update(model, msg),
  view: View(model, msg),
  validate_csrf: fn(String) -> Result(Nil, Nil),
  opts: Option(LiveServiceOpts),
) -> LiveService(model, msg) {
  live_service.start(flags, init, update, view, validate_csrf, opts)
}

/// Handle a message from the websocket.
/// 
/// This function should be called when a message is received from the websocket. It will identify
/// and relay the message to the live view that is associated with the websocket. The live
/// view will handle the message and send a response back to the websocket via ws_send.
/// 
/// This is a low-level function that is typically not called directly. Instead, you should use the
/// live service bridge for your web server. For example, if you are using the `mist` web server,
/// you would use the `mist_lustre` package which provides a `mist_lustre.live_service` function.
pub fn handle_live_message(
  id: String,
  lsvc: LiveService(model, msg),
  msg: String,
  ws_send: fn(String) -> Result(Nil, Nil),
) -> Result(Nil, Nil) {
  live_service.handle_live_message(lsvc, id, msg, ws_send)
}

/// Cleanup a live runtime.
/// 
/// This function is called when a websocket is closed. It will find the runtime that is associated
/// with the websocket and stop it. It's important to call this function when the websocket
/// connection is terminated.
pub fn cleanup_live_runtime(lsvc: LiveService(model, msg), id: String) {
  let r = live_service.pop_runtime(lsvc, unique.from_string(id))

  case r {
    Ok(r) -> {
      runtime.stop(r)
    }
    Error(_) -> {
      Nil
    }
  }
}

// EFFECTS ---------------------------------------------------------------------

///
@external(javascript, "./lustre.ffi.mjs", "start")
pub fn start(
  _app: App(flags, model, msg),
  _selector: String,
  _flags: flags,
) -> Result(fn(msg) -> Nil, Error) {
  Error(NotABrowser)
}

///
@external(javascript, "./lustre.ffi.mjs", "destroy")
pub fn destroy(_app: App(flags, model, msg)) -> Result(Nil, Error) {
  Ok(Nil)
}

// UTILS -----------------------------------------------------------------------

///
@external(javascript, "./lustre.ffi.mjs", "is_browser")
pub fn is_browser() -> Bool {
  False
}

///
@external(javascript, "./lustre.ffi.mjs", "is_registered")
pub fn is_registered(_name: String) -> Bool {
  False
}
