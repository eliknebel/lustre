import gleam/dynamic.{type Dynamic}
import gleam/otp/actor
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None}
import lustre/element
import lustre/app.{type App, type Flag, type Init, type Update, type View}
import lustre/live/internal/patch.{type Patch}
import lustre/live/internal/constants.{call_timeout}
import lustre/live/internal/util/unique.{type Unique}

pub type ClientPatcher(patch) =
  fn(patch) -> Result(Nil, Nil)

pub type ClientEmitter =
  fn(String, Dynamic) -> Result(Nil, Nil)

pub type Runtime(model, msg) =
  Subject(Message(model, msg))

type State(model, msg) {
  Starting
  State(
    id: Unique,
    self: Runtime(model, msg),
    cancel_shutdown: Option(fn() -> Nil),
    app: App(model, msg),
    dispatch: fn(msg) -> Nil,
  )
}

pub type Message(model, msg) {
  Shutdown
  Start(
    self: Runtime(model, msg),
    id: Unique,
    flags: List(Flag),
    init: Init(model, msg),
    update: Update(model, msg),
    view: View(model, msg),
    patcher: ClientPatcher(Patch),
    emitter: ClientEmitter,
  )
  Dispatch(msg)
  GetId(reply_with: Subject(Unique))
}

fn handle_message(
  message: Message(model, msg),
  state: State(model, msg),
) -> actor.Next(Message(model, msg), State(model, msg)) {
  case message {
    Shutdown -> {
      actor.Stop(process.Normal)
    }

    Start(self, id, flags, init, update, view, patcher, emitter) -> {
      let #(app, dispatch) =
        app.start(
          flags,
          init,
          update,
          view,
          fn(el) {
            let assert Ok(_) =
              el
              |> element.to_string()
              |> patcher()

            Nil
          },
          fn(event, data) {
            let assert Ok(_) = emitter(event, data)

            Nil
          },
        )

      actor.continue(State(
        id: id,
        self: self,
        cancel_shutdown: None,
        app: app,
        dispatch: dispatch,
      ))
    }

    Dispatch(msg) -> {
      case state {
        State(_, _, _, _, dispatch) -> {
          dispatch(msg)
        }
        _ -> Nil
      }

      actor.continue(state)
    }

    GetId(reply_with) -> {
      case state {
        State(id, _, _, _, _) -> {
          actor.send(reply_with, id)
        }
        _ -> Nil
      }

      actor.continue(state)
    }
  }
}

/// Start a new runtime actor
pub fn start(
  id: Unique,
  flags: List(Flag),
  init: Init(model, msg),
  update: Update(model, msg),
  view: View(model, msg),
  patcher: ClientPatcher(Patch),
  emitter: ClientEmitter,
) {
  let assert Ok(actor) = actor.start(Starting, handle_message)

  actor.send(
    actor,
    Start(actor, id, flags, init, update, view, patcher, emitter),
  )

  actor
}

/// Stop a runtime actor
pub fn stop(actor) {
  actor.send(actor, Shutdown)
}

/// Returns the id of a runtime actor
pub fn get_id(actor) -> Result(Unique, Nil) {
  case process.try_call(actor, GetId(_), call_timeout) {
    Ok(id) -> Ok(id)
    Error(_) -> Error(Nil)
  }
}

pub fn dispatch(actor, msg) {
  actor.send(actor, Dispatch(msg))
}
