import gleam/io
import gleam/list
import gleam/dynamic.{type Dynamic, field, optional_field}
import gleam/option.{type Option}
import gleam/json
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import lustre/element
import lustre/app.{type Flag, type Init, type Update, type View}
import lustre/live/runtime.{type ClientEmitter,
  type ClientPatcher, type Runtime}
import lustre/live/internal/patch.{type Patch}
import lustre/live/internal/util/logger
import lustre/live/internal/constants.{call_timeout}
import lustre/live/internal/util/unique.{type Unique}

pub type CSRFValidator =
  fn(String) -> Result(Nil, Nil)

pub type LiveService(model, msg) =
  Subject(Message(model, msg))

pub type State(model, msg) {
  State(
    flags: List(Flag),
    init: Init(model, msg),
    update: Update(model, msg),
    view: View(model, msg),
    runtimes: List(Runtime(model, msg)),
    debug: Bool,
    csrf_validator: CSRFValidator,
  )
}

pub type Message(model, msg) {
  Shutdown
  GetState(reply_with: Subject(State(model, msg)))
  PushRuntime(view: Runtime(model, msg))
  GetRuntime(reply_with: Subject(Result(Runtime(model, msg), Nil)), id: Unique)
  PopRuntime(reply_with: Subject(Result(Runtime(model, msg), Nil)), id: Unique)
}

fn handle_message(
  message: Message(model, msg),
  state: State(model, msg),
) -> actor.Next(Message(model, msg), State(model, msg)) {
  case message {
    Shutdown -> {
      actor.Stop(process.Normal)
    }

    GetState(reply_with) -> {
      process.send(reply_with, state)
      actor.continue(state)
    }

    PushRuntime(r) -> {
      let updated_runtimes = list.reverse([r, ..list.reverse(state.runtimes)])

      actor.continue(State(..state, runtimes: updated_runtimes))
    }

    GetRuntime(reply_with, id) -> {
      let spkt =
        list.find(
          state.runtimes,
          fn(s) {
            case runtime.get_id(s) {
              Ok(spkt_id) -> unique.equals(spkt_id, id)
              Error(_) -> False
            }
          },
        )

      process.send(reply_with, spkt)

      actor.continue(state)
    }

    PopRuntime(reply_with, id) -> {
      let r =
        list.find(
          state.runtimes,
          fn(s) {
            case runtime.get_id(s) {
              Ok(spkt_id) -> unique.equals(spkt_id, id)
              Error(_) -> False
            }
          },
        )

      process.send(reply_with, r)

      case r {
        Ok(r) -> {
          runtime.stop(r)

          let updated_runtimes = list.filter(state.runtimes, fn(s) { r != s })

          let new_state = State(..state, runtimes: updated_runtimes)

          actor.continue(new_state)
        }

        Error(_) -> actor.continue(state)
      }
    }
  }
}

pub type LiveServiceOpts {
  LiveServiceOpts(debug: Bool)
}

/// Start the live service. This is intended to only be called once during web server
/// initiliazation.
/// 
/// The live service is a long running process that manages the state of all server components.
pub fn start(
  flags: List(Flag),
  init: Init(model, msg),
  update: Update(model, msg),
  view: View(model, msg),
  csrf_validator: CSRFValidator,
  opts: Option(LiveServiceOpts),
) -> LiveService(model, msg) {
  let assert Ok(ca) =
    actor.start(
      State(
        flags: flags,
        init: init,
        update: update,
        view: view,
        runtimes: [],
        debug: option.map(opts, fn(opts) { opts.debug })
        |> option.unwrap(False),
        csrf_validator: csrf_validator,
      ),
      handle_message,
    )

  ca
}

/// Stop the live service
pub fn stop(lsvc: LiveService(model, msg)) {
  process.send(lsvc, Shutdown)
}

/// Get the current state of the live service. Mostly intended for unit tests and debugging.
pub fn get_state(lsvc: LiveService(model, msg)) {
  process.call(lsvc, GetState(_), call_timeout)
}

/// Pushes a runtime instance to the live service.
pub fn push_runtime(lsvc: LiveService(model, msg), view: Runtime(model, msg)) {
  process.send(lsvc, PushRuntime(view))
}

/// Gets a runtime instance from the live service.
pub fn get_runtime(lsvc: LiveService(model, msg), ws: Unique) {
  process.call(lsvc, GetRuntime(_, ws), call_timeout)
}

/// Pops a runtime instance from the live service.
pub fn pop_runtime(lsvc: LiveService(model, msg), ws: Unique) {
  process.call(lsvc, PopRuntime(_, ws), call_timeout)
}

fn validate_csrf(lsvc: LiveService(model, msg), csrf: String) {
  case get_state(lsvc) {
    State(csrf_validator: csrf_validator, ..) -> csrf_validator(csrf)
  }
}

type Payload {
  JoinPayload(csrf_token: String)
  EventPayload(name: String, data: Option(Dynamic))
  EmptyPayload(nothing: Option(String))
}

/// Handles client websocket messages.
/// 
/// This function is intended to be called from the web server's websocket handler. It
/// handles the initial connection handshake and all subsequent messages. It is responsible
/// for dispatching events to the appropriate live view and sending updates back to the
/// client.
pub fn handle_live_message(
  lsvc: LiveService(model, msg),
  id: String,
  msg: String,
  ws_send: fn(String) -> Result(Nil, Nil),
) -> Result(Nil, Nil) {
  case
    json.decode(msg, dynamic.any([decode_join, decode_event, decode_empty]))
  {
    Ok(#("join", JoinPayload(csrf))) -> {
      logger.info("New client joined")

      case validate_csrf(lsvc, csrf) {
        Ok(_) -> {
          connect(lsvc, id, ws_send)

          Ok(Nil)
        }
        Error(_) -> {
          logger.error("Invalid CSRF token")

          let assert Ok(_) = ws_send(error_to_json(InvalidCSRFToken))

          Ok(Nil)
        }
      }
    }
    Ok(#("event", EventPayload(name, _data))) -> {
      logger.info("Event: " <> name)

      // TODO: Implement event handling
      // case get_runtime(ca, id) {
      //   Ok(runtime) -> {
      //     runtime.emit(name, data)
      //     Ok(Nil)
      //   }
      //   _ -> Error(Nil)
      // }

      Ok(Nil)
    }
    Error(e) -> {
      logger.error("Error decoding message")
      io.debug(e)

      Error(Nil)
    }
  }
}

/// Handles client websocket connection initialization.
fn connect(
  lsvc: LiveService(model, msg),
  id: String,
  ws_send: fn(String) -> Result(Nil, Nil),
) {
  let State(
    flags: flags,
    init: init,
    update: update,
    view: view,
    debug: debug,
    ..,
  ) = get_state(lsvc)

  let patcher = fn(patch) {
    let _ = ws_send(patch_to_json(patch, debug))
    Ok(Nil)
  }

  let emitter = fn(name: String, data: Dynamic) {
    let _ = ws_send(event_to_json(name, data))
    Ok(Nil)
  }

  let runtime =
    runtime.start(
      unique.from_string(id),
      flags,
      init,
      update,
      view,
      patcher,
      emitter,
    )

  push_runtime(lsvc, runtime)

  logger.info("Runtime connected! " <> id)
}

fn decode_join(data: Dynamic) {
  data
  |> dynamic.tuple2(
    dynamic.string,
    dynamic.decode1(JoinPayload, field("csrf", dynamic.string)),
  )
}

fn decode_event(data: Dynamic) {
  data
  |> dynamic.tuple2(
    dynamic.string,
    dynamic.decode2(
      EventPayload,
      field("name", dynamic.string),
      optional_field("data", dynamic.dynamic),
    ),
  )
}

fn decode_empty(data: Dynamic) {
  data
  |> dynamic.tuple2(
    dynamic.string,
    dynamic.decode1(EmptyPayload, optional_field("nothing", dynamic.string)),
  )
}

fn patch_to_json(patch: Patch, debug: Bool) -> String {
  json.preprocessed_array([
    json.string("patch"),
    patch.patch_to_json(patch, debug),
    json.object([#("debug", json.bool(debug))]),
  ])
  |> json.to_string()
}

fn event_to_json(name: String, _data: Dynamic) -> String {
  json.preprocessed_array([json.string("event")])
  // TODO: Figure out how to handle serializing dynamic data values, perhaps using ffi
  // json.object([#("name", json.string(name)), #("data", json.dynamic(data))]),
  json.object([#("name", json.string(name))])
  |> json.to_string()
}

type ConnectError {
  ConnectError
  InvalidCSRFToken
}

fn error_to_json(error: ConnectError) {
  json.preprocessed_array([
    json.string("error"),
    case error {
      ConnectError ->
        json.object([
          #("code", json.string("connect_error")),
          #("msg", json.string("Unable to connect to session")),
        ])
      InvalidCSRFToken ->
        json.object([
          #("code", json.string("invalid_csrf_token")),
          #("msg", json.string("Invalid CSRF token")),
        ])
    },
  ])
  |> json.to_string()
}
