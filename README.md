# elm-flow

A monadic interface for _The Elm Architecture_, bridging synchronous state modifications with asynchronous subscriptions via Channels.

This library merges concepts from two community packages:

- [`chrilves/elm-io`](https://package.elm-lang.org/packages/chrilves/elm-io/latest/) — the free monad interface for TEA
- [`brian-watkins/elm-procedure`](https://github.com/brian-watkins/elm-procedure) — continuation-passing channels and subscriptions

## Overview

`Flow s a` is a free monad that describes a computation which can:

- Read and write application state `s`
- Fire Elm `Cmd`s and receive their results
- Subscribe to channels (ports, WebSockets, timers, …) and resume when a value arrives
- Run multiple branches concurrently via `Batch`

The runtime interpreter (`Flow.Program`) drives these computations inside a standard TEA `update` loop, so the rest of your Elm app stays unchanged.

## Quick start

```elm
import Flow exposing (Flow)
import Flow.Channel exposing (Channel)

type alias Model =
    { count : Int, loading : Bool }

type Msg
    = Increment
    | Decrement

update : Msg -> Flow Model Msg
update msg =
    case msg of
        Increment ->
            Flow.modify (\m -> { m | count = m.count + 1 })

        Decrement ->
            Flow.modify (\m -> { m | count = m.count - 1 })

main : Flow.Program () Model Msg
main =
    Flow.sandbox
        { init = \_ -> ( { count = 0, loading = False }, Flow.none )
        , view = view
        , subscriptions = \_ -> Sub.none
        }
```

## Channels

Channels connect external event sources (ports, WebSockets, timers) to a `Flow` pipeline. Use `Flow.Channel.connect` to build a channel from an Elm subscription port and an optional command port, then pass it to `Flow.await` (receive one value) or `Flow.subscribe` (handle values indefinitely).

```elm
-- In Ports.elm
port onMessage : (String -> msg) -> Sub msg
port send : String -> Cmd msg

myChannel : Channel Model String
myChannel =
    Flow.Channel.connect
        (\callback -> Ports.onMessage (\s -> callback s))
        (\_ -> Ports.send "subscribe")

listenLoop : Flow Model ()
listenLoop =
    Flow.subscribe
        (\msg -> Flow.modify (\m -> { m | lastMessage = msg }))
        myChannel
```

## Optics helpers

When you have nested state, the optics helpers (`try`, `forAll`, `over`, `setAll`, `via`) work with [`erlandsona/elm-accessors`](https://package.elm-lang.org/packages/erlandsona/elm-accessors/latest/) lenses to target sub-fields without manual getter/setter boilerplate.

## API reference

See the generated documentation for the full API.

### Core

| Function | Description |
|---|---|
| `pure` | Lift a plain value into Flow |
| `lift` | Lift a `Cmd` into Flow |
| `get` / `set` / `modify` | Read and write the model |
| `andThen` / `map` | Sequence and transform computations |
| `batch` / `batchM` | Run multiple branches |
| `none` | Terminate / no-op |

### Async

| Function | Description |
|---|---|
| `await` | Suspend until a Channel delivers one value |
| `subscribe` | Handle every value from a Channel indefinitely |
| `yield` | Force a render cycle before continuing |
| `async` | Fire-and-forget a sub-computation |

### Control flow

| Function | Description |
|---|---|
| `when` | Conditional execution |
| `bracket_` | Acquire/release resources around a computation |
| `setting` | Temporarily set a Bool lens to `True` |
| `locking` | Skip execution if a Bool lens is already `True` |

## License

BSD-3-Clause
