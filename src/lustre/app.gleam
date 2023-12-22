import gleam/list
import gleam/dynamic.{type Dynamic}
import lustre/element.{type Element}
import lustre/effect
import lustre/live/internal/constants
import lustre/live/internal/util/logger

pub type Flag =
  Dynamic

pub type Init(model, msg) =
  fn(List(Flag)) -> #(model, effect.Effect(msg))

pub type Update(model, msg) =
  fn(msg, model) -> #(model, effect.Effect(msg))

pub type View(model, msg) =
  fn(model) -> Element(msg)

pub type Dispatcher(msg) =
  fn(msg) -> Nil

pub type Emitter =
  fn(String, Dynamic) -> Nil

pub type Renderer(msg) =
  fn(Element(msg)) -> Nil

type Effect(model, msg) =
  fn(Dispatcher(msg), Emitter) -> Nil

pub opaque type App(model, msg) {
  App(
    state: model,
    queue: List(msg),
    effects: List(Effect(model, msg)),
    did_update: Bool,
    update: Update(model, msg),
    view: View(model, msg),
    renderer: Renderer(msg),
    emitter: Emitter,
  )
}

pub fn start(
  flags: List(Flag),
  init: Init(model, msg),
  update: Update(model, msg),
  view: View(model, msg),
  renderer: Renderer(msg),
  emitter: Emitter,
) -> #(App(model, msg), Dispatcher(msg)) {
  let #(next, effects) = init(flags)

  let app =
    App(
      state: next,
      queue: [],
      effects: effect.to_list(effects),
      did_update: True,
      update: update,
      view: view,
      renderer: renderer,
      emitter: emitter,
    )

  let app = tick(app)

  #(
    app,
    fn(msg) {
      dispatch(app, msg)
      Nil
    },
  )
}

fn dispatch(app: App(model, msg), msg) -> App(model, msg) {
  let app = App(..app, queue: list.append(app.queue, [msg]))

  tick(app)
}

fn emit(app: App(model, msg), name, data) -> Nil {
  app.emitter(name, data)
}

fn tick(app: App(model, msg)) -> App(model, msg) {
  case flush(app, 0) {
    App(did_update: True, ..) -> render(app)
    app -> app
  }
}

fn flush(app: App(model, msg), flush_count) -> App(model, msg) {
  app
  |> update()
  |> run_effects(flush_count)
}

fn update(app: App(model, msg)) -> App(model, msg) {
  App(
    ..list.fold(
      app.queue,
      app,
      fn(app, msg) {
        let #(next, effects) = app.update(msg, app.state)

        App(
          ..app,
          state: next,
          effects: list.append(app.effects, effect.to_list(effects)),
          did_update: app.did_update || next != app.state,
        )
      },
    ),
    queue: [],
  )
}

fn run_effects(app: App(model, msg), flush_count) -> App(model, msg) {
  // TODO: This isn't quite right. We need to be able to run effects and
  // return the updated app state from disaptch. This is a bit tricky because effects
  // do not return the result of dispatch. This module might need to be converted to
  // a stateful actor that can keep track of the state and effects through messages.
  let app =
    App(
      ..list.fold(
        app.effects,
        app,
        fn(app, eff) {
          eff(
            fn(msg) {
              dispatch(app, msg)
              Nil
            },
            fn(name, data) { emit(app, name, data) },
          )

          // TODO: this needs to be the updated app state from dispatch calls
          app
        },
      ),
      effects: [],
    )

  // Synchronous effects will immediately queue a message to be processed. If
  // it is reasonable, we can process those updates too before proceeding to
  // the next render.
  case flush_count > constants.max_immediate_updates {
    True -> {
      logger.info(
        "Exceeded max immediate updates. Remaining updates will be processed in the next render.",
      )

      app
    }
    False ->
      case app.effects {
        [] -> app
        _ -> flush(app, flush_count + 1)
      }
  }
}

fn render(app: App(model, msg)) -> App(model, msg) {
  app.view(app.state)
  |> app.renderer()

  App(..app, did_update: False)
}
