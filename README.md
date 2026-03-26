# elm-flow

Write effectful Elm logic as composable steps.

**Beginners:** `Flow` is a data type representing an Elm *imperative program* that can *do* things ("read/write the model", "call this API and take its return value", "wait for an incoming value on a port") and the library runs them. Your views emit `Flow` values as messages; nothing else to wire up. There is simply no `update` function.

**Experts:** `Flow s` is a **free monad over state, Elm commands, subscription continuations, and concurrent fan-out**. Its constructors - `Pure`, `Get (s -> Flow s a)`, `Set s`, `Command (Cmd (Flow s a))`, `Await` (channel-keyed subscription continuation), `Batch` - form a composable algebra over Elm's runtime effects. The `Msg`/`update` dispatch layer is eliminated; an interpreter takes its place.

What makes `Flow s` a monad? The fact that:

- there is a `Flow.pure` function that constructs a program with no effects, simply returning a value
- there is a `Flow.map` function that lifts a function into the program
- there is a `Flow.join` function that allows programs returning an inner program to run that program
- that the above three uphold trivial monad laws (such as mapping the identity function doesn't change the Flow)

This library merges concepts and code from two packages:

- [`chrilves/elm-io`](https://package.elm-lang.org/packages/chrilves/elm-io/latest/) - free monad interface for Elm
- [`brian-watkins/elm-procedure`](https://github.com/brian-watkins/elm-procedure) - continuation-passing channels and subscriptions

We wish to express our deep respect and heartfelt thanks to the authors of these packages.
elm-flow is largely an amalgamation of the two enabled by the generosity of their authors,
publishing these under the permissive MIT and BSD-3 licenses, respectively. We hereby
republish our entire derivative work under BSD-3.

## Quick start

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

Channels connect subscriptions to a `Flow` pipeline. Use `Flow.Channel.connect` to build a channel from an Elm subscription port and an optional command port, then pass it to `Flow.await` (receive one value) or `Flow.subscribe` (handle values indefinitely).

```elm
-- In Ports.elm
port wsMessages : (ServerMessage -> msg) -> Sub msg
port wsConnect  : String -> Cmd msg

type ServerMessage
    = ChatMessage String
    | RoomEvent String

-- Assumes a Model with:
--   messages  : List String   -- lens `messages`
--   events    : List String   -- lens `events`
--   listening : Bool          -- lens `listening`

roomChannel : String -> Channel Model ServerMessage
roomChannel roomId =
    Flow.Channel.connect
        Ports.wsMessages
        (\_ -> Ports.wsConnect roomId)

handleMessage : ServerMessage -> Flow Model ()
handleMessage msg =
    case msg of
        ChatMessage text -> Flow.over messages ((::) text)
        RoomEvent ev     -> Flow.over events   ((::) ev)

-- Runs until `model.listening` is set to False.
-- Cancellation is lazy: the subscription stops after the next incoming message.
listenRoom : String -> Flow Model ()
listenRoom roomId =
    Flow.subscribeWhile (\model _ -> model.listening) handleMessage (roomChannel roomId)

leaveRoom : Flow Model ()
leaveRoom =
    Flow.setAll listening False
```

### FFI with dynamic dispatch

Instead of creating a new port for every JavaScript interaction, you can use `Flow.ffi` to call many JS functions by name using a single pair of ports. 

You provide the JS function name, an encoder for the outgoing data, and a decoder for the return value.

```elm
-- 1. Define one pair of ports
port ffiOut : { key : String, fn : String, value : Json.Encode.Value } -> Cmd msg
port ffiIn : ({ key : String, value : Json.Decode.Value } -> msg) -> Sub msg

-- 2. Wire them into a helper
callJs : String -> (a -> Json.Encode.Value) -> Json.Decode.Decoder b -> a -> Flow s b
callJs =
    Flow.ffi Ports.ffiOut Ports.ffiIn

-- 3. Call any JS function by name
fetchData : String -> Flow Model ()
fetchData id =
    callJs "fetchData" Json.Encode.string decodeData id
        |> Flow.andThen handleData
```

```javascript
// On the JavaScript side:
app.ports.ffiOut.subscribe(async (req) => {
    if (req.fn === "fetchData") {
        const data = await fetch("/api/data/" + req.value).then(r => r.json());
        // Return the data using the exact same key
        app.ports.ffiIn.send({ key: req.key, value: data });
    }
});
```

## More examples

### Async action with state preparation and error recovery

Read state, do preparatory work, fire a command, recover on failure - all in a
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


## Optics helpers

Lenses give you composable read/write paths into nested data. The state monad
gives you sequenced reads and writes. Put them together and you get a Flow
that reads like imperative mutation.

We recommend watching the recording of a talk by Edward Kmett titled "Lenses: A Functional Imperative".

The optics helpers (`try`, `forAll`, `over`, `setAll`, `via`) work with
[`erlandsona/elm-accessors`](https://package.elm-lang.org/packages/erlandsona/elm-accessors/latest/)
lenses to target sub-fields without manual getter/setter boilerplate.

```elm
type alias Model =
    { user : { name : String, email : String, loginCount : Int }
    }

-- Lenses: user, name, email, loginCount (defined once, composed with <<)

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

**Core**
- [`pure`](./Flow#pure) (lift a value),
- [`lift`](./Flow#lift) (lift a `Cmd`),
- [`get`](./Flow#get) / [`set`](./Flow#set) / [`modify`](./Flow#modify) (read and write the model),
- [`andThen`](./Flow#andThen) / [`map`](./Flow#map) / [`seq`](./Flow#seq) (sequence and transform),
- [`batch`](./Flow#batch) / [`batchM`](./Flow#batchM) (run multiple branches),
- [`none`](./Flow#none) (terminate the current branch).

**Async**
- [`await`](./Flow#await) (suspend until a Channel delivers one value),
- [`subscribe`](./Flow#subscribe) (handle every value indefinitely),
- [`subscribeWhile`](./Flow#subscribeWhile) (handle values while a predicate holds),
- [`yield`](./Flow#yield) (force a render cycle before continuing),
- [`async`](./Flow#async) (fire-and-forget a sub-computation).

**Control flow**
- [`when`](./Flow#when) (conditional execution),
- [`return`](./Flow#return) (run a Flow for its effects, then produce a fixed value),
- [`bracket_`](./Flow#bracket_) (acquire/release resources),
- [`setting`](./Flow#setting) (hold a `Bool` lens `True` for a computation),
- [`locking`](./Flow#locking) (skip if a `Bool` lens is already `True`).

**Assertions**
- [`assertJust`](./Flow#assertJust) (terminate if `Nothing`),
- [`assertOk`](./Flow#assertOk) (terminate if `Err`),
- [`assertCondition`](./Flow#assertCondition) (terminate if predicate fails),
- [`fromMaybe`](./Flow#fromMaybe) (unwrap a `Maybe` or terminate).

**Tasks**
- [`performTask`](./Flow#performTask) (run an infallible `Task`),
- [`attemptTask`](./Flow#attemptTask) (fire-and-forget a fallible `Task`),
- [`attemptTaskWith`](./Flow#attemptTaskWith) (run a fallible `Task` and handle the `Result`).

**Optics**
- [`try`](./Flow#try) (read through an optic, producing `Just` or `Nothing`),
- [`forAll`](./Flow#forAll) (read through an optic, terminating if it does not match),
- [`getAll`](./Flow#getAll) (read all values targeted by a traversal),
- [`over`](./Flow#over) (modify value(s) through an optic),
- [`setAll`](./Flow#setAll) (set value(s) through an optic),
- [`via`](./Flow#via) (zoom a sub-`Flow` into a larger model through an optic).

**FFI**
- [`ffi`](./Flow#ffi) (call a JavaScript function by name through a single port pair).

## License

BSD-3-Clause
