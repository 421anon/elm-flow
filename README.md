# elm-flow

A monadic interface for _The Elm Architecture_, bridging synchronous state modifications with asynchronous subscriptions via Channels.

This library merges concepts from two packages:

- [`chrilves/elm-io`](https://package.elm-lang.org/packages/chrilves/elm-io/latest/) — the free monad interface for TEA
- [`brian-watkins/elm-procedure`](https://github.com/brian-watkins/elm-procedure) — continuation-passing channels and subscriptions

We wish to express our deep respect and heartfelt thanks to the authors of these packages.
elm-flow is largely an amalgamation of the two enabled by the generosity of their authors,
publishing these under the permissive MIT and BSD-3 licenses, respectively. We hereby
republish our entire derivative work under BSD-3.

## Overview

`Flow s a` is a free monad that describes a computation which can:

- Read and write application state `s`
- Fire Elm `Cmd`s and receive their results
- Subscribe to channels (ports, WebSockets, timers, …) and resume when a value arrives
- Run multiple branches concurrently via `Batch`

The runtime interpreter (`Flow.Program`) drives these computations inside a standard TEA `update` loop, so the rest of your Elm app stays unchanged.

## Quick start

With `elm-flow`, you do **not** define a custom `Msg` type or an `update` function.
Instead, your `view` handlers and `subscriptions` emit `Flow` values directly,
and the library runtime interprets them.

```elm
import Flow exposing (Flow)
import Html
import Html.Events

type alias Model =
    { count : Int }

main : Flow.Program () Model Never
main =
    Flow.element
        { init = \_ -> ( { count = 0 }, Flow.none )
        , view = view
        , subscriptions = \_ -> Sub.none
        }

view : Model -> Html.Html (Flow Model ())
view model =
    Html.button
        [ Html.Events.onClick (Flow.modify (\m -> { m | count = m.count + 1 })) ]
        [ Html.text ("Count: " ++ String.fromInt model.count) ]
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

## More examples

### Async action with state preparation and error recovery

Read state, do preparatory work, fire a command, recover on failure — all in a
single linear pipeline with no `Msg` variants or pattern-match dispatch:

```elm
runJob : Int -> Flow Model ()
runJob id =
    Flow.get
        |> Flow.andThen
            (\model ->
                -- flush any pending edits before running
                Flow.when model.hasPendingEdits flushEdits
                    |> Flow.seq (setStatus id Loading)
                    |> Flow.seq (callApi (Api.start id model.config))
            )
        |> Flow.andThen
            (\result ->
                case result of
                    Ok _ ->
                        Flow.pure ()

                    Err _ ->
                        setStatus id Failed
            )
```

### Subscribing to a server-sent event stream

`subscribe` wires a channel to a handler function. When a single event carries
multiple updates, `batchM` fans them out into concurrent branches:

```elm
listenForUpdates : Int -> Flow Model ()
listenForUpdates roomId =
    Flow.subscribe handleEvent (Channels.connect roomId)


handleEvent : ServerMessage -> Flow Model ()
handleEvent msg =
    case msg of
        Snapshot items ->
            -- apply every item update as a concurrent branch
            Flow.batchM (List.map applyUpdate items)

        Heartbeat ->
            Flow.pure ()

        Error text ->
            showToast text
```

## Optics helpers

Lenses give you composable read/write paths into nested data. The state monad
gives you sequenced reads and writes. Put them together and you get something
that reads like imperative mutation — but the result is a pure value, a data
structure that can be passed around, combined, and transformed before a single
effect ever runs.

We recommend watching the recording of a talk by Edward Kmett titled "Lenses: A Functional Imperative"

The optics helpers (`try`, `forAll`, `over`, `setAll`, `via`) work with
[`erlandsona/elm-accessors`](https://package.elm-lang.org/packages/erlandsona/elm-accessors/latest/)
lenses to target sub-fields without manual getter/setter boilerplate.

```elm
type alias Model =
    { user : { name : String, email : String, loginCount : Int }
    }

-- Lenses: user, name, email, loginCount (defined once, composed with <<)
-- <...>
--

recordLogin : String -> String -> Flow Model ()
recordLogin newName newEmail =
    Flow.setAll (user << name) newName
        |> Flow.seq (Flow.setAll (user << email) (String.toLower newEmail))
        |> Flow.seq (Flow.over (user << loginCount) ((+) 1))
```

`via` zooms into a sub-model so you can write a self-contained `Flow` against it
and reuse it anywhere that sub-model appears:

```elm
-- operates only on User, with no knowledge of Model
normaliseUser : Flow User ()
normaliseUser =
    Flow.over name String.trim
        |> Flow.seq (Flow.over email String.toLower)

-- embed into the full model through the `user` lens
Flow.via user normaliseUser
```

## API quick reference

**Core** —
`pure` (lift a value),
`lift` (lift a `Cmd`),
`get` / `set` / `modify` (read and write the model),
`andThen` / `map` (sequence and transform),
`batch` / `batchM` (run multiple branches),
`none` (terminate / no-op).

**Async** —
`await` (suspend until a Channel delivers one value),
`subscribe` (handle every value indefinitely),
`yield` (force a render cycle before continuing),
`async` (fire-and-forget a sub-computation).

**Control flow** —
`when` (conditional execution),
`bracket_` (acquire/release resources),
`setting` (hold a `Bool` lens `True` for a computation),
`locking` (skip if a `Bool` lens is already `True`).

## License

BSD-3-Clause
