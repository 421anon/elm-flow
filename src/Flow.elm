module Flow exposing
    ( Flow
    , pure, map, andThen, join, ap, flap, compose, seq, return, traverse, mapM
    , if_, when, unless, bracket_
    , none, assertJust, assertOk, assertCondition, fromMaybe
    , get, set, modify
    , try, forAll, getAll, over, setAll, ifHas, whenHas, unlessHas, setting, locking
    , viaLens, viaPrism, replace
    , lift, liftUpdate, performTask, attemptTask, attemptTaskWith
    , batch, batchM, async, gather, gather_, Codec(..)
    , yield, forceRendering
    , ChannelSpec, Channel, ChannelKey
    , connect, listen, filterChannel
    , await, subscribe, subscribeWhile
    , openChannel, nextOnChannel
    , ffi
    , Program, element, document, application
    )

{-| Write effectful Elm logic as composable steps - no `Msg` type, no `update` function.

Event handlers and subscriptions produce `Flow` values directly:

    -- a button click
    Html.button
        [ Html.Events.onClick (Flow.modify (\m -> { m | count = m.count + 1 })) ]
        [ Html.text "+" ]

    -- an HTTP response
    Flow.lift (Http.get { url = "/api/data", expect = Http.expectJson handleResult decoder })

@docs Flow


# Composing flows

@docs pure, map, andThen, join, ap, flap, compose, seq, return, traverse, mapM


# Control flow

@docs if_, when, unless, bracket_


# Terminating a fiber

@docs none, assertJust, assertOk, assertCondition, fromMaybe


# Reading and writing the model

@docs get, set, modify


# Optics

@docs try, forAll, getAll, over, setAll, ifHas, whenHas, unlessHas, setting, locking


# Zooming into sub-models

@docs viaLens, viaPrism, replace


# Commands and tasks

@docs lift, liftUpdate, performTask, attemptTask, attemptTaskWith


# Concurrency

@docs batch, batchM, async, gather, gather_, Codec


# Rendering

@docs yield, forceRendering


# Channels

Describe an event source with a `ChannelSpec`: use `connect` when you have both
a subscription source and a command to kick it off, or `listen` when
subscriptions alone are enough. Then consume events with `await`, `subscribe`,
or `subscribeWhile`, each of which opens a live `Channel` from the spec.

@docs ChannelSpec, Channel, ChannelKey
@docs connect, listen, filterChannel
@docs await, subscribe, subscribeWhile
@docs openChannel, nextOnChannel
@docs ffi


# Running a program

@docs Program, element, document, application

-}

import Accessors exposing (A_Lens, A_Prism, An_Optic)
import Browser exposing (Document, UrlRequest)
import Browser.Navigation exposing (Key)
import Dict exposing (Dict)
import Html exposing (Html)
import Json.Decode
import Json.Encode
import Process
import Task exposing (Task)
import Url exposing (Url)


{-| A description of a computation that can read and write state `s` and
eventually produces a value of type `a`.
-}
type Flow s a
    = Pure a
    | Get (s -> Flow s a)
    | Set s (Flow s a)
    | Batch (List (Flow s a))
    | Command (Cmd (Flow s a))
    | Await ChannelRequest (ChannelKey -> Sub (Maybe (Flow s a)))
    | Gather (List Json.Encode.Value -> Flow s a) (Flow s a)
    | Deliver Json.Encode.Value


type ChannelRequest
    = Open (ChannelKey -> Cmd Never)
    | Resume ChannelKey


{-| A description of how to connect an external event source to a `Flow`
pipeline. A spec does nothing by itself and can be opened any number of times,
including concurrently; each opening is a separate `Channel`.
-}
type ChannelSpec a
    = ChannelSpec
        { open : ChannelKey -> Cmd Never
        , values : ChannelKey -> Sub (Maybe a)
        }


{-| One live opening of a `ChannelSpec`. Receive further values from it with
`nextOnChannel`.
-}
type Channel a
    = Channel ChannelKey (ChannelSpec a)


{-| Key identifying a `Channel`.

Opening a spec creates a fresh key and passes it to the spec's command. The
channel keeps that key for its whole lifetime, so the external source can tag
its values with it and `filterChannel` can match them.

-}
type alias ChannelKey =
    String


{-| Build a spec from a subscription port and a command that opens or
attaches it. The command fires each time the spec is opened, receiving the key
of the new channel; `nextOnChannel` does not fire it again.

    -- Port declarations:
    --   port onMessage : (String -> msg) -> Sub msg
    --   port subscribe : String -> Cmd msg
    myChannel : ChannelSpec String
    myChannel =
        Flow.connect Ports.onMessage (\_ -> Ports.subscribe "myTopic")

To drop or transform values before they reach the channel, wrap the port:

    -- port onJson : (Json.Decode.Value -> msg) -> Sub msg
    userChannel : ChannelSpec User
    userChannel =
        Flow.listen
            (\toMsg -> Ports.onJson (Json.Decode.decodeValue userDecoder >> Result.toMaybe >> Maybe.andThen toMsg))

-}
connect : ((a -> Maybe a) -> Sub (Maybe a)) -> (ChannelKey -> Cmd Never) -> ChannelSpec a
connect subPort cmdPort =
    ChannelSpec
        { open = cmdPort
        , values = \_ -> subPort Just
        }


{-| Build a spec from a subscription port when no startup command is needed.

    -- Port declaration:
    --   port onKeyDown : (String -> msg) -> Sub msg
    keyChannel : ChannelSpec String
    keyChannel =
        Flow.listen Ports.onKeyDown

-}
listen : ((a -> Maybe a) -> Sub (Maybe a)) -> ChannelSpec a
listen subPort =
    connect subPort (\_ -> Cmd.none)


{-| Filter events for a spec. Only events for which the predicate returns
`True` are forwarded; others are silently dropped.

The predicate receives the `ChannelKey` of the channel and the event payload.
Match on the key when the source tags values with it; otherwise you only need
the payload:

    Flow.filterChannel (\_ msg -> msg /= "") myChannel

-}
filterChannel : (ChannelKey -> a -> Bool) -> ChannelSpec a -> ChannelSpec a
filterChannel predicate (ChannelSpec spec) =
    ChannelSpec
        { spec
            | values =
                \key ->
                    Sub.map
                        (Maybe.andThen
                            (\a ->
                                if predicate key a then
                                    Just a

                                else
                                    Nothing
                            )
                        )
                        (spec.values key)
        }


{-| Suspend this Flow pipeline, open a channel from the spec, and resume when a value arrives.

    type alias Model =
        { latestMessage : String }

    listenOnce : Flow Model ()
    listenOnce =
        Flow.await myChannel
            |> Flow.andThen (\msg -> Flow.modify (\m -> { m | latestMessage = msg }))

-}
await : ChannelSpec a -> Flow s a
await ch =
    openChannel ch (\_ -> Just << Pure)


{-| Open a channel and run the given handler for every value it produces,
indefinitely.

    listenForever : Flow Model ()
    listenForever =
        Flow.subscribe
            (\msg -> Flow.modify (\m -> { m | latestMessage = msg }))
            myChannel

-}
subscribe : (a -> Flow s ()) -> ChannelSpec a -> Flow s a
subscribe handler ch =
    let
        continuation channel a =
            Just (andThen (\() -> nextOnChannel channel (continuation channel)) (async (handler a)))
    in
    openChannel ch continuation


{-| Like `subscribe`, but stops when the predicate returns `False`.
The predicate receives both the current model and the incoming value, so
cancellation can be based on model state, the value itself, or both.
Cancellation is lazy: the check runs on each incoming message, not
immediately when the model changes.

    -- stop based on model state alone
    Flow.subscribeWhile (\model _ -> model.listening) handleMessage myChannel

    -- stop on a specific sentinel value
    Flow.subscribeWhile (\_ msg -> msg /= "disconnect") handleMessage myChannel

-}
subscribeWhile : (s -> a -> Bool) -> (a -> Flow s ()) -> ChannelSpec a -> Flow s a
subscribeWhile isActive handler ch =
    let
        continuation channel a =
            Just
                (Get
                    (\model ->
                        if isActive model a then
                            andThen (\() -> nextOnChannel channel (continuation channel)) (async (handler a))

                        else
                            none
                    )
                )
    in
    openChannel ch continuation


{-| Open a channel from a spec, firing the spec's command, and suspend until the
first value arrives. The callback receives the opened `Channel` and each value:
`Just flow` resumes with `flow`, `Nothing` ignores the value and keeps waiting.

This is the low-level primitive that `await` and `subscribe` are built on.
Prefer those unless you need custom continuation logic.

-}
openChannel : ChannelSpec a -> (Channel a -> a -> Maybe (Flow s b)) -> Flow s b
openChannel ((ChannelSpec spec) as channelSpec) callback =
    Await
        (Open spec.open)
        (\key -> Sub.map (Maybe.andThen (callback (Channel key channelSpec))) (spec.values key))


{-| Wait for the next value on an already opened channel, without firing the
spec's command again.
-}
nextOnChannel : Channel a -> (a -> Maybe (Flow s b)) -> Flow s b
nextOnChannel (Channel key (ChannelSpec spec)) callback =
    Await
        (Resume key)
        (\resumed -> Sub.map (Maybe.andThen callback) (spec.values resumed))


{-| Lift a plain value into Flow without performing any effects.

    Flow.pure 42
        |> Flow.map (\n -> n + 1)
    -- produces 43, state unchanged

-}
pure : a -> Flow s a
pure a =
    Pure a


{-| Run several independent Flow branches concurrently, one per list element.
Each branch shares the same initial state snapshot; state writes from earlier
branches are visible to later ones (left-to-right evaluation order).

    Flow.batch [ 1, 2, 3 ]
        |> Flow.map (\n -> n * 2)
    -- forks into three branches producing 2, 4, 6

-}
batch : List a -> Flow s a
batch l =
    Batch (List.map Pure l)


{-| Lift an Elm `Cmd` into Flow. The command is executed and its result
becomes the value produced by this Flow step.

    Flow.lift (Http.get { url = "/ping", expect = Http.expectString identity })
        |> Flow.andThen handleResponse

-}
lift : Cmd a -> Flow s a
lift cmd =
    Command (Cmd.map Pure cmd)


{-| Read the current model.

    Flow.get
        |> Flow.andThen (\model -> Flow.pure model.count)

-}
get : Flow s s
get =
    Get Pure


{-| Replace the model entirely.

    Flow.set { count = 0 }

-}
set : s -> Flow s ()
set s =
    Set s (Pure ())


{-| Apply a function to transform the model.

    Flow.modify (\m -> { m | count = m.count + 1 })

-}
modify : (s -> s) -> Flow s ()
modify f =
    Get (\m -> Set (f m) (Pure ()))


{-| Transform the value produced by a Flow without changing state.

    Flow.pure 3
        |> Flow.map (\n -> n * 2)
    -- produces 6

-}
map : (a -> b) -> Flow s a -> Flow s b
map f =
    andThen (Pure << f)


{-| Chain two Flow computations. The second receives the value produced by the
first.

    Flow.get
        |> Flow.andThen (\m -> Flow.pure m.count)

-}
andThen : (a -> Flow s b) -> Flow s a -> Flow s b
andThen f flow =
    case flow of
        Pure a ->
            f a

        Get k ->
            Get (\s -> andThen f (k s))

        Set s next ->
            Set s (andThen f next)

        Batch l ->
            Batch (List.map (andThen f) l)

        Command cmd ->
            Command (Cmd.map (andThen f) cmd)

        Await req sub ->
            Await req (\key -> Sub.map (Maybe.map (andThen f)) (sub key))

        Gather continue branches ->
            Gather (continue >> andThen f) (andThen f branches)

        Deliver value ->
            Deliver value


{-| Flatten a nested `Flow s (Flow s a)` into `Flow s a`.

    Flow.pure (Flow.pure 42)
        |> Flow.join
    -- same as Flow.pure 42

-}
join : Flow s (Flow s a) -> Flow s a
join =
    andThen identity


{-| Apply a function wrapped in Flow to a value wrapped in Flow.

    Flow.pure (\n -> n + 1)
        |> Flow.ap (Flow.pure 41)
    -- produces 42

-}
ap : Flow s (a -> b) -> Flow s a -> Flow s b
ap mf ma =
    andThen (\y -> map y ma) mf


{-| Flipped `ap`. Apply a value to a function, both wrapped in Flow.

    Flow.pure 41
        |> Flow.flap (Flow.pure (\n -> n + 1))
    -- produces 42

-}
flap : Flow s a -> Flow s (a -> b) -> Flow s b
flap ma mf =
    ap mf ma


{-| Compose two Kleisli arrows (functions returning Flow).

    handleResponse : Response -> Flow Model ()
    handleResponse =
        Flow.compose persistToDisk fetchData

-}
compose : (b -> Flow m c) -> (a -> Flow m b) -> a -> Flow m c
compose g f a =
    f a |> andThen g


{-| Run the piped Flow for its effects, discard its result, then run the
argument Flow and return its result.

    saveRecord
        |> Flow.seq (Flow.pure "saved!")
    -- runs saveRecord, then produces "saved!"

-}
seq : Flow s b -> Flow s a -> Flow s b
seq second first =
    first |> andThen (\_ -> second)


{-| The empty computation. Terminates the current branch without producing a
value or changing state.

**WARNING:** `none` is a 0-fiber program - it has no active fiber to carry
a continuation forward. Chaining it with `andThen`, `seq`, etc. produces
another 0-fiber program, so those continuations will never run.

    Flow.get
        |> Flow.andThen
            (\m ->
                if m.ready then
                    doWork

                else
                    Flow.none
            )

-}
none : Flow s a
none =
    Batch []


{-| Run a list of Flow computations as concurrent branches. Each branch runs
independently; the continuation (via `andThen`) is invoked once per branch
with that branch's individual result.

**WARNING:** `batchM` multiplies the number of fibers by the number of continuations.
If you wish to extend a multi-fiber Flow on a single branch, consider [`async`](#async).

Use [`mapM`](#mapM) instead if you want the results collected into a `List`.

    -- fire three notifications in parallel
    Flow.batchM [ notifyAlice, notifyBob, notifyCarol ]

    -- continuation runs once per branch, not once with a List
    Flow.batchM [ fetchUserA, fetchUserB ]
        |> Flow.andThen (\user -> renderUser user)

-}
batchM : List (Flow s a) -> Flow s a
batchM l =
    join (batch l)


{-| Join the branches of a batched Flow: wait until every branch has finished,
then continue once with all of their results.

Results come in branch order (the order of the `batch` / `batchM` lists),
not in completion order. Branches that terminate with `none` contribute
nothing.

Results are stored outside the Flow while the other branches are still
running, so they travel as JSON: provide a [`Codec`](#Codec) for the result
type. If its decoder rejects an encoded result, the joined Flow terminates.

**WARNING:** the join waits for every branch forked inside it, including
background branches started with [`async`](#async) or [`subscribe`](#subscribe).
A branch that never finishes keeps the join waiting forever.

    -- fetch all users concurrently, then store them in input order
    Flow.batch userIds
        |> Flow.andThen fetchUser
        |> Flow.gather (Flow.Codec encodeUser userDecoder)
        |> Flow.andThen (\users -> Flow.modify (\m -> { m | users = users }))

-}
gather : Codec a -> Flow s a -> Flow s (List a)
gather (Codec encoder decoder) flow =
    Gather
        (\values ->
            case Json.Decode.decodeValue (Json.Decode.list decoder) (Json.Encode.list identity values) of
                Ok results ->
                    Pure results

                Err _ ->
                    none
        )
        (andThen (encoder >> Deliver) flow)


{-| Like [`gather`](#gather), but discards the results: wait until every
branch has finished, then continue once with `()`. Needs no `Codec`.

**WARNING:** like `gather`, it waits for every branch forked inside it,
including background branches.

    -- save every draft concurrently, then report once
    Flow.batch drafts
        |> Flow.andThen saveDraft
        |> Flow.gather_
        |> Flow.seq (Flow.modify (\m -> { m | status = AllSaved }))

-}
gather_ : Flow s a -> Flow s ()
gather_ flow =
    Gather (\_ -> Pure ()) (andThen (\_ -> none) flow)


{-| How to turn a value into JSON and back: an encoder and a decoder that
accepts whatever the encoder produces.

    userCodec : Flow.Codec User
    userCodec =
        Flow.Codec encodeUser userDecoder

-}
type Codec a
    = Codec (a -> Json.Encode.Value) (Json.Decode.Decoder a)


{-| Lift a classic TEA `update`-style function into Flow. Reads the current
model, applies the function, writes the new model, and emits any commands.

    Flow.liftUpdate (MyOldModule.update msg)

-}
liftUpdate : (s -> ( s, Cmd a )) -> Flow s a
liftUpdate f =
    Get
        (\m0 ->
            let
                ( m2, cmd ) =
                    f m0
            in
            Set m2 (Command (Cmd.map Pure cmd))
        )


{-| Re-interpret a `Flow a x` inside a larger context `Flow b x` by providing
a getter (`Flow b a`) and a setter (`a -> Flow b ()`).

This is the primitive that `viaLens` is built on. Use `viaLens` in normal code;
reach for `replace` only when you need a custom traversal that optics cannot
express.

-}
replace : Flow b a -> (a -> Flow b ()) -> Flow a x -> Flow b x
replace rget rset =
    let
        aux : Flow a x -> Flow b x
        aux ioa =
            case ioa of
                Pure x ->
                    Pure x

                Get k ->
                    rget |> andThen (k >> aux)

                Set a next ->
                    rset a |> andThen (\_ -> aux next)

                Batch l ->
                    Batch (List.map aux l)

                Command c ->
                    Command (Cmd.map aux c)

                Await req sub ->
                    Await req (\key -> Sub.map (Maybe.map aux) (sub key))

                Gather continue branches ->
                    Gather (continue >> aux) (aux branches)

                Deliver value ->
                    Deliver value
    in
    aux


{-| Map over a list with a function that returns Flow, collecting the results
in order.

    Flow.traverse fetchUser userIds
        |> Flow.andThen renderAll

-}
traverse : (a -> Flow s b) -> List a -> Flow s (List b)
traverse f =
    let
        aux l =
            case l of
                [] ->
                    pure []

                hd :: tl ->
                    ap (ap (pure (::)) (f hd)) (aux tl)
    in
    aux


{-| Sequence a list of Flow computations, collecting all results.

Equivalent to `traverse identity`.

    Flow.mapM [ step1, step2, step3 ]
        |> Flow.andThen finalize

-}
mapM : List (Flow s a) -> Flow s (List a)
mapM =
    traverse identity


{-| Yield a value back to the Elm runtime, allowing the browser to repaint,
then continue with the value. Equivalent to `Process.sleep 0`.

    -- ensure the UI reflects intermediate state before a heavy computation
    Flow.set loadingModel
        |> Flow.seq (Flow.yield ())
        |> Flow.seq heavyComputation

-}
yield : a -> Flow s a
yield a =
    lift (Task.perform (\_ -> a) (Process.sleep 0))


{-| Wrap a Flow so that every state write inside it is followed by a render
cycle, giving the browser a chance to repaint between steps.

Useful when you need the UI to visually reflect intermediate states during a
multi-step computation rather than only showing the final result.

    -- the UI repaints after each step, not just at the end
    Flow.forceRendering <|
        Flow.mapM [ setStepOne, setStepTwo, setStepThree ]

-}
forceRendering : Flow a b -> Flow a b
forceRendering =
    replace get (set |> compose yield)


{-| The concrete Elm `Platform.Program` type produced by `Flow.element`,
`Flow.document`, and `Flow.application`.
-}
type alias Program flags s a =
    Platform.Program flags ( s, Runtime s a ) (RuntimeMsg s a)


{-| Build a standard `Browser.element` program whose messages are `Flow`
computations.
-}
element :
    { init : flags -> ( s, Flow s a )
    , view : s -> Html (Flow s a)
    , subscriptions : s -> Sub (Flow s a)
    }
    -> Program flags s a
element args =
    Browser.element
        { update = runtimeUpdate
        , init = args.init >> runtimeInit
        , view = \( model, _ ) -> Html.map UserFlow (args.view model)
        , subscriptions = runtimeSubscriptions args.subscriptions
        }


{-| Like `element` but the view function returns a full `Document`, allowing
you to control the page `<title>`.

    main =
        Flow.document
            { init = \_ -> ( initialModel, loadData )
            , view = view -- returns { title = "…", body = […] }
            , subscriptions = \_ -> Sub.none
            }

-}
document :
    { init : flags -> ( s, Flow s a )
    , view : s -> Document (Flow s a)
    , subscriptions : s -> Sub (Flow s a)
    }
    -> Program flags s a
document args =
    Browser.document
        { update = runtimeUpdate
        , init = args.init >> runtimeInit
        , view =
            \( model, _ ) ->
                let
                    doc =
                        args.view model
                in
                { title = doc.title, body = List.map (Html.map UserFlow) doc.body }
        , subscriptions = runtimeSubscriptions args.subscriptions
        }


{-| Like `document` but also handles URL changes, for single-page applications.

    main =
        Flow.application
            { init = \_ url key -> ( initialModel key, loadPage url )
            , view = view
            , subscriptions = \_ -> Sub.none
            , onUrlRequest = handleUrlRequest
            , onUrlChange = handleUrlChange
            }

-}
application :
    { init : flags -> Url -> Key -> ( s, Flow s a )
    , view : s -> Document (Flow s a)
    , subscriptions : s -> Sub (Flow s a)
    , onUrlRequest : UrlRequest -> Flow s a
    , onUrlChange : Url -> Flow s a
    }
    -> Program flags s a
application args =
    Browser.application
        { update = runtimeUpdate
        , init = \f u k -> runtimeInit (args.init f u k)
        , view =
            \( model, _ ) ->
                let
                    doc =
                        args.view model
                in
                { title = doc.title, body = List.map (Html.map UserFlow) doc.body }
        , subscriptions = runtimeSubscriptions args.subscriptions
        , onUrlRequest = \req -> UserFlow (args.onUrlRequest req)
        , onUrlChange = \url -> UserFlow (args.onUrlChange url)
        }


type alias Runtime s a =
    { nextId : Int
    , channels : Dict Int (Sub (RuntimeMsg s a))
    , joins : Dict Int (JoinPoint s a)
    }


type alias JoinPoint s a =
    { pending : Int
    , results : List ( List Int, Json.Encode.Value )
    , continue : List Json.Encode.Value -> Flow s a
    , parent : Fiber
    }


type Fiber
    = Root
    | Branch Int (List Int)


type RuntimeMsg s a
    = UserFlow (Flow s a)
    | Continue Fiber (Flow s a)
    | Unsubscribe Int Fiber (Flow s a)


type alias RuntimeStep s a =
    ( s, Runtime s a, Cmd (RuntimeMsg s a) )


runtimeInit : ( s, Flow s a ) -> ( ( s, Runtime s a ), Cmd (RuntimeMsg s a) )
runtimeInit ( model, flow ) =
    runtimeUpdate (UserFlow flow) ( model, { nextId = 0, channels = Dict.empty, joins = Dict.empty } )


runtimeUpdate : RuntimeMsg s a -> ( s, Runtime s a ) -> ( ( s, Runtime s a ), Cmd (RuntimeMsg s a) )
runtimeUpdate msg ( model, runtime ) =
    case msg of
        UserFlow flow ->
            commit (run Root flow model runtime)

        Continue fiber flow ->
            commit (run fiber flow model runtime)

        Unsubscribe channelId fiber flow ->
            if Dict.member channelId runtime.channels then
                commit (run fiber flow model { runtime | channels = Dict.remove channelId runtime.channels })

            else
                ( ( model, runtime ), Cmd.none )


commit : RuntimeStep s a -> ( ( s, Runtime s a ), Cmd (RuntimeMsg s a) )
commit ( model, runtime, cmd ) =
    ( ( model, runtime ), cmd )


runtimeSubscriptions : (s -> Sub (Flow s a)) -> ( s, Runtime s a ) -> Sub (RuntimeMsg s a)
runtimeSubscriptions userSubs ( model, runtime ) =
    Sub.batch
        [ Sub.map UserFlow (userSubs model)
        , Sub.batch (Dict.values runtime.channels)
        ]


run : Fiber -> Flow s a -> s -> Runtime s a -> RuntimeStep s a
run fiber flow model runtime =
    case flow of
        Pure _ ->
            finishFiber fiber Nothing model runtime

        Deliver value ->
            finishFiber fiber (Just value) model runtime

        Get k ->
            run fiber (k model) model runtime

        Set newModel next ->
            run fiber next newModel runtime

        Batch [] ->
            finishFiber fiber Nothing model runtime

        Batch branches ->
            let
                ( finalModel, finalRuntime, cmds ) =
                    List.foldl
                        (\( index, branch ) ( currentModel, currentRuntime, accCmds ) ->
                            let
                                ( nextModel, nextRuntime, cmd ) =
                                    run (forkFiber index fiber) branch currentModel currentRuntime
                            in
                            ( nextModel, nextRuntime, cmd :: accCmds )
                        )
                        ( model, spawnFibers (List.length branches - 1) fiber runtime, [] )
                        (List.indexedMap Tuple.pair branches)
            in
            ( finalModel, finalRuntime, Cmd.batch cmds )

        Command cmd ->
            ( model, runtime, Cmd.map (Continue fiber) cmd )

        Await request sub ->
            let
                channelId =
                    runtime.nextId

                ( key, cmd ) =
                    case request of
                        Open open ->
                            let
                                fresh =
                                    "Channel-" ++ String.fromInt channelId
                            in
                            ( fresh, open fresh )

                        Resume existing ->
                            ( existing, Cmd.none )

                wrapMsg fired =
                    case fired of
                        Nothing ->
                            UserFlow none

                        Just next ->
                            Unsubscribe channelId fiber next
            in
            ( model
            , { runtime
                | nextId = runtime.nextId + 1
                , channels = Dict.insert channelId (Sub.map wrapMsg (sub key)) runtime.channels
              }
            , Cmd.map never cmd
            )

        Gather continue branches ->
            let
                joinId =
                    runtime.nextId
            in
            run (Branch joinId [])
                branches
                model
                { runtime
                    | nextId = runtime.nextId + 1
                    , joins = Dict.insert joinId { pending = 1, results = [], continue = continue, parent = fiber } runtime.joins
                }


finishFiber : Fiber -> Maybe Json.Encode.Value -> s -> Runtime s a -> RuntimeStep s a
finishFiber fiber delivered model runtime =
    case fiber of
        Root ->
            ( model, runtime, Cmd.none )

        Branch joinId path ->
            case Dict.get joinId runtime.joins of
                Nothing ->
                    ( model, runtime, Cmd.none )

                Just joinPoint ->
                    let
                        results =
                            delivered
                                |> Maybe.map (\value -> ( path, value ) :: joinPoint.results)
                                |> Maybe.withDefault joinPoint.results
                    in
                    if joinPoint.pending == 1 then
                        run joinPoint.parent
                            (joinPoint.continue (List.map Tuple.second (List.sortBy Tuple.first results)))
                            model
                            { runtime | joins = Dict.remove joinId runtime.joins }

                    else
                        ( model
                        , { runtime | joins = Dict.insert joinId { joinPoint | pending = joinPoint.pending - 1, results = results } runtime.joins }
                        , Cmd.none
                        )


spawnFibers : Int -> Fiber -> Runtime s a -> Runtime s a
spawnFibers count fiber runtime =
    case fiber of
        Root ->
            runtime

        Branch joinId _ ->
            { runtime | joins = Dict.update joinId (Maybe.map (\joinPoint -> { joinPoint | pending = joinPoint.pending + count })) runtime.joins }


forkFiber : Int -> Fiber -> Fiber
forkFiber index fiber =
    case fiber of
        Root ->
            Root

        Branch joinId path ->
            Branch joinId (path ++ [ index ])


{-| Continue only if the value is `Just`, terminate with `none` otherwise.

    fetchUser userId
        |> Flow.assertJust
        |> Flow.andThen renderUser

-}
assertJust : Flow s (Maybe a) -> Flow s a
assertJust =
    andThen
        (\maybeValue ->
            case maybeValue of
                Just value ->
                    pure value

                Nothing ->
                    none
        )


{-| Continue only if the result is `Ok`, silently terminate on `Err`.

    decodeResponse body
        |> Flow.assertOk
        |> Flow.andThen handleData

-}
assertOk : Flow s (Result e a) -> Flow s a
assertOk =
    andThen
        (\result ->
            case result of
                Ok value ->
                    pure value

                Err _ ->
                    none
        )


{-| Continue only if the predicate holds for the produced value, terminate
with `none` otherwise.

    Flow.get
        |> Flow.assertCondition (\m -> m.count > 0)
        |> Flow.andThen doSomethingWithPositiveCount

-}
assertCondition : (a -> Bool) -> Flow s a -> Flow s a
assertCondition pred =
    andThen
        (\value ->
            if pred value then
                pure value

            else
                none
        )


{-| Unwrap a `Maybe` and feed the inner value into a continuation, or
terminate with `none` if the `Maybe` is `Nothing`.

    Flow.fromMaybe model.selectedId
        (\id -> fetchItem id |> Flow.andThen renderItem)

-}
fromMaybe : Maybe a -> (a -> Flow s b) -> Flow s b
fromMaybe m f =
    pure m |> assertJust |> andThen f


{-| Run an infallible `Task` and produce its result.

    Flow.performTask (Task.succeed 42)
        |> Flow.andThen (\n -> Flow.modify (\m -> { m | count = n }))

-}
performTask : Task Never a -> Flow s a
performTask t =
    lift (Task.perform identity t)


{-| Fire a `Task` for its side-effects and ignore the result (both `Ok` and
`Err` are discarded). Useful for fire-and-forget operations such as writing
to `localStorage` via a port task.

    Flow.attemptTask (Ports.saveToLocalStorage key value)

-}
attemptTask : Task e a -> Flow s ()
attemptTask t =
    lift (Task.attempt (always ()) t)


{-| Run a `Task` and feed its `Result` into a continuation.

    Flow.attemptTaskWith
        (\result ->
            case result of
                Ok data ->
                    Flow.modify (\m -> { m | data = data })

                Err err ->
                    Flow.modify (\m -> { m | error = Just err })
        )
        (Http.task { ... })

-}
attemptTaskWith : (Result e a -> Flow s b) -> Task e a -> Flow s b
attemptTaskWith handler t =
    lift (Task.attempt identity t) |> andThen handler


{-| Read a value through an optic. Produces `Just a` if the optic matches,
`Nothing` if it does not (e.g. a `Prism` pointing at the wrong variant).

    Flow.try MyLenses.selectedItem
        (\maybeItem ->
            case maybeItem of
                Just item ->
                    renderItem item

                Nothing ->
                    showPlaceholder
        )

-}
try : An_Optic pr ls s a -> (Maybe a -> Flow s b) -> Flow s b
try optic f =
    get |> map (Accessors.try optic) |> andThen f


{-| Fork into n concurrent fibers for each matching value through an optic.

    -- Only runs if a user is logged in
    Flow.forAll MyLenses.currentUser
        (\user -> showWelcomeBanner user.name)

-}
forAll : An_Optic pr ls s a -> (a -> Flow s b) -> Flow s b
forAll optic f =
    get |> andThen (Accessors.all optic >> List.map f >> batchM)


{-| Read all values targeted by an optic (useful for traversals).

    Flow.getAll MyLenses.allItems
        (\items -> Flow.pure (List.length items))

-}
getAll : An_Optic pr ls s a -> (List a -> Flow s b) -> Flow s b
getAll optic f =
    get |> map (Accessors.all optic) |> andThen f


{-| Modify the value(s) targeted by an optic.

    Flow.over MyLenses.count (\n -> n + 1)

-}
over : An_Optic pr ls s a -> (a -> a) -> Flow s ()
over =
    (<<) modify << Accessors.over


{-| Set the value(s) targeted by an optic.

    Flow.setAll MyLenses.status Loading

-}
setAll : An_Optic pr ls s a -> a -> Flow s ()
setAll =
    (>>) always << over


{-| Embed a `Flow inner a` into a larger model `outer` through a lens. All state
reads and writes inside the sub-flow are transparently routed through the lens.

This is the primary tool for reusable components: write a self-contained `Flow`
against a sub-model type, then embed it anywhere that sub-model appears by
passing in the appropriate lens.

    -- SelectState is a reusable component with its own Flow logic
    handleArrowDown : Flow SelectState ()
    handleArrowDown =
        Flow.get
            |> Flow.map (get activeIndex)
            |> Flow.andThen (\i -> Flow.modify (set activeIndex (i + 1)))

    -- Embed it into the parent model through a lens
    Flow.viaLens MyLenses.selectState handleArrowDown

-}
viaLens : A_Lens pr outer inner -> Flow inner a -> Flow outer a
viaLens optic =
    replace
        (get |> map (Accessors.get optic))
        (modify << Accessors.set optic)


{-| Embed a `Flow inner a` into a larger model `outer` through a prism.

When the prism matches, the sub-flow runs with its state routed through the
prism and its result is returned as `Just`. When the prism does not match, the
sub-flow is skipped and the result is `Nothing`. If the prism stops matching
while the sub-flow is suspended (for example across `await`), the sub-flow
stops there and produces `Nothing`.

    -- Run a component only while the model holds its active variant
    Flow.viaPrism MyLenses.activePage handlePageEvent

-}
viaPrism : A_Prism ls outer inner -> Flow inner a -> Flow outer (Maybe a)
viaPrism optic innerFlow =
    let
        resume : Flow inner x -> Flow outer (Maybe x)
        resume flow =
            get
                |> andThen
                    (\outer ->
                        case Accessors.try optic outer of
                            Just _ ->
                                step flow

                            Nothing ->
                                pure Nothing
                    )

        step : Flow inner x -> Flow outer (Maybe x)
        step flow =
            case flow of
                Pure x ->
                    pure (Just x)

                Get k ->
                    get
                        |> andThen
                            (\outer ->
                                case Accessors.try optic outer of
                                    Just inner ->
                                        step (k inner)

                                    Nothing ->
                                        pure Nothing
                            )

                Set inner next ->
                    get
                        |> andThen
                            (\outer ->
                                case Accessors.try optic outer of
                                    Just _ ->
                                        set (Accessors.set optic inner outer)
                                            |> andThen (\_ -> step next)

                                    Nothing ->
                                        pure Nothing
                            )

                Batch flows ->
                    Batch (List.map step flows)

                Command cmd ->
                    Command (Cmd.map resume cmd)

                Await req sub ->
                    Await req (\key -> Sub.map (Maybe.map resume) (sub key))

                Gather continue branches ->
                    Gather (continue >> resume) (andThen (\_ -> none) (step branches))

                Deliver value ->
                    Deliver value
    in
    resume innerFlow


{-| Branch on whether an optic matches: run `onPresent` with the matched value
when the optic succeeds, `onAbsent` otherwise. Exactly one branch runs.

    Flow.ifHas
        (currentProject << success)
        openStream
        closeStream

-}
ifHas : An_Optic pr ls s a -> (a -> Flow s b) -> Flow s b -> Flow s b
ifHas optic onPresent onAbsent =
    try optic
        (\maybeA ->
            case maybeA of
                Just a ->
                    onPresent a

                Nothing ->
                    onAbsent
        )


{-| Run a Flow only when an optic matches. No match produces `Flow.pure ()`.

    Flow.whenHas (currentProject << success) openStream

-}
whenHas : An_Optic pr ls s a -> (a -> Flow s ()) -> Flow s ()
whenHas optic onPresent =
    ifHas optic onPresent (pure ())


{-| Run a Flow only when an optic does NOT match. A match produces `Flow.pure ()`.

    Flow.unlessHas (currentProject << success) handleMissingProject

-}
unlessHas : An_Optic pr ls s a -> Flow s () -> Flow s ()
unlessHas optic onAbsent =
    ifHas optic (\_ -> pure ()) onAbsent


{-| Branch on a `Bool`: run `onTrue` when the condition holds, `onFalse` otherwise.

Exactly one branch runs.

    Flow.if_ model.isLoggedIn
        loadDashboard
        redirectToLogin

-}
if_ : Bool -> Flow s a -> Flow s a -> Flow s a
if_ cond onTrue onFalse =
    if cond then
        onTrue

    else
        onFalse


{-| Run a Flow only when the condition is `True`, otherwise produce `()`.

    Flow.when model.isLoggedIn savePreferences

-}
when : Bool -> Flow s () -> Flow s ()
when pred io =
    if pred then
        io

    else
        pure ()


{-| Run a Flow only when the condition is `False`, otherwise produce `()`.

    Flow.unless model.isCached fetchFromServer

-}
unless : Bool -> Flow s () -> Flow s ()
unless cond io =
    if cond then
        pure ()

    else
        io


{-| Shorthand for \`Flow.seq (Flow.pure a).

    saveRecord
        |> Flow.return "saved"

-}
return : a -> Flow s b -> Flow s a
return =
    seq << pure


{-| Fire a Flow as a background branch and immediately continue with `()`.
The background branch runs concurrently; its state writes are interleaved
with the rest of the batch.

    Flow.async (longRunningSync model)
        |> Flow.seq nextStep

-}
async : Flow s a -> Flow s ()
async io =
    Batch [ andThen (\_ -> none) io, Pure () ]


{-| Acquire a resource, run a computation, then release the resource.

**WARNING:** If the computation forks into multiple fibers, the
release step will run once per fiber. This also means that if the
computation is terminating (which is equivalent to forking into 0 fibers),
then the release step will NOT run.

    Flow.bracket_
        (Flow.modify (\m -> { m | loading = True }))
        (Flow.modify (\m -> { m | loading = False }))
        fetchData

-}
bracket_ : Flow s a -> Flow s b -> Flow s c -> Flow s c
bracket_ before after thing =
    before |> seq thing |> andThen (\b -> after |> return b)


{-| Set a `Bool` field to `True` for the duration of a computation, then
restore it to `False`. Useful for loading/busy flags.

    Flow.setting MyLenses.isLoading fetchData

-}
setting : An_Optic pr ls s Bool -> Flow s a -> Flow s a
setting lns =
    bracket_ (setAll lns True) (setAll lns False)


{-| Run a computation only if a `Bool` lens is currently `False`, and hold
it at `True` for the duration. Subsequent calls while the lock is held are
silently dropped.

    Flow.locking MyLenses.isSaving saveRecord

-}
locking : A_Lens pr s Bool -> Flow s () -> Flow s ()
locking lns io =
    forAll lns (\locked -> when (not locked) (setting lns io))


{-| Instead of creating a new port for every JavaScript interaction, you can use `Flow.ffi`
to call many JS functions by name using a single pair of ports.

You provide the JS function name, an encoder for the outgoing data, and a decoder for
the return value. Under the hood, this helper uses a unique string key to automatically
match JavaScript responses back to the correct `Flow` request.

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

    -- On the JavaScript side:
    -- app.ports.ffiOut.subscribe(async (req) => {
    --     if (req.fn === "fetchData") {
    --         const data = await fetch("/api/data/" + req.value).then(r => r.json());
    --         app.ports.ffiIn.send({ key: req.key, value: data });
    --     }
    -- });

-}
ffi :
    ({ key : String, fn : String, value : Json.Encode.Value } -> Cmd Never)
    -> (({ key : String, value : Json.Decode.Value } -> Maybe { key : String, value : Json.Decode.Value }) -> Sub (Maybe { key : String, value : Json.Decode.Value }))
    -> String
    -> (a -> Json.Encode.Value)
    -> Json.Decode.Decoder b
    -> a
    -> Flow s b
ffi outPort inPort fnName encode decoder payload =
    await
        (ChannelSpec
            { open = \key -> outPort { key = key, fn = fnName, value = encode payload }
            , values =
                \key ->
                    Sub.map
                        (Maybe.andThen
                            (\msg ->
                                if msg.key == key then
                                    Result.toMaybe (Json.Decode.decodeValue decoder msg.value)

                                else
                                    Nothing
                            )
                        )
                        (inPort Just)
            }
        )
