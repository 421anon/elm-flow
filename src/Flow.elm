module Flow exposing
    ( Flow
    , Program, element, document, application
    , await, subscribe
    , pure, lift, liftUpdate
    , get, set, modify
    , map, andThen, join, ap, flap, compose, seq, traverse, mapM
    , replace
    , none
    , yield, forceRendering
    , batch, batchM
    , assertJust, assertOk, assertCondition, fromMaybe
    , attemptTask
    , try, forAll, getAll, over, setAll, via
    , when, return, async, bracket_, setting, locking
    )

{-| A monadic interface for _The Elm Architecture_, bridging synchronous state
modifications with asynchronous subscriptions via Channels.

**Note:** This library merges concepts from two community packages:

  - `chrilves/elm-io` (The free monad interface for TEA)
  - `brian-watkins/elm-procedure` (Continuation-passing channels and subscriptions)


## The Flow pattern

In a traditional TEA application you define a central `Msg` type and an
`update : Msg -> Model -> (Model, Cmd Msg)` function that dispatches on it.
With `Flow` there is no separate `Msg` type and no central dispatch table.

Your event handlers and subscriptions produce `Flow` values directly:

    -- a button click
    Html.button
        [ Html.Events.onClick (Flow.modify (\m -> { m | count = m.count + 1 })) ]
        [ Html.text "+" ]

    -- an HTTP response
    Flow.lift (Http.get { url = "/api/data", expect = Http.expectJson handleResult decoder })

The runtime executes each `Flow` immediately as it arrives, keeping behaviour
co-located with the event that triggers it.

@docs Flow


# Running a web application

@docs Program, element, document, application


# Subscriptions and channels

@docs await, subscribe


# Lifting values and commands into Flow

@docs pure, lift, liftUpdate


# Reading and writing the model

@docs get, set, modify


# Monadic operations

@docs map, andThen, join, ap, flap, compose, seq, traverse, mapM


# Zooming into sub-models via optics

@docs replace


# Terminating a computation

@docs none


# Forcing Elm to re-render

@docs yield, forceRendering


# Batching

@docs batch, batchM


# Assertions and guards

@docs assertJust, assertOk, assertCondition, fromMaybe


# Task helpers

@docs attemptTask


# Optics helpers

@docs try, forAll, getAll, over, setAll, via


# Control flow

@docs when, return, async, bracket_, setting, locking

-}

import Accessors exposing (A_Lens, An_Optic)
import Browser exposing (Document, UrlRequest)
import Browser.Navigation exposing (Key)
import Flow.Channel exposing (Channel)
import Flow.Internal exposing (..)
import Flow.Program
import Html exposing (Html)
import Process
import Task exposing (Task)
import Url exposing (Url)


{-| A description of a computation that can read and write state `s` and
eventually produces a value of type `a`.

`Flow` is a free monad: values of this type are data structures that the
runtime interprets, rather than functions that run immediately. This makes
it possible to batch, sequence, and transform computations before any
side-effects take place.

-}
type alias Flow s a =
    Flow.Internal.Flow s a


{-| Suspend this Flow pipeline, open a Channel, and resume when a value arrives.

    type alias Model =
        { latestMessage : String }

    listenOnce : Flow Model ()
    listenOnce =
        Flow.await myChannel
            |> Flow.andThen (\msg -> Flow.modify (\m -> { m | latestMessage = msg }))

-}
await : Channel s a -> Flow s a
await =
    Flow.Channel.acceptOne


{-| Open a channel and run the given handler for every value it produces,
indefinitely.

    listenForever : Flow Model ()
    listenForever =
        Flow.subscribe
            (\msg -> Flow.modify (\m -> { m | latestMessage = msg }))
            myChannel

-}
subscribe : (a -> Flow s ()) -> Channel s a -> Flow s a
subscribe =
    Flow.Channel.accept


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
andThen =
    Flow.Internal.andThen


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


{-| Flipped `ap` — apply a value to a function, both wrapped in Flow.

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


{-| Run the first Flow for its effects, discard its result, then run the
second and return its result.

    saveRecord
        |> Flow.seq (Flow.pure "saved!")

-}
seq : Flow s b -> Flow s a -> Flow s b
seq second first =
    first |> andThen (\_ -> second)


{-| The empty computation — terminates the current branch without producing a
value or changing state. Use this as the natural end-point of a pipeline.

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
    Flow.Internal.none


{-| Run a list of Flow computations concurrently and collect all their results.

    Flow.batchM [ fetchUser, fetchSettings, fetchPermissions ]
        |> Flow.andThen (\results -> ...)

-}
batchM : List (Flow s a) -> Flow s a
batchM l =
    join (batch l)


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

This is the primitive that `via` and the other optics helpers are built on.
Use `via` in normal code; reach for `replace` only when you need a custom
traversal that optics cannot express.

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
                    Await (\key -> Cmd.map aux (req key)) (\key -> Sub.map (Maybe.map aux) (sub key))
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


{-| Force a full render cycle before continuing by writing the current model
back to itself via `yield`. Use this when you need the DOM to update between
two state changes.
-}
forceRendering : Flow a b -> Flow a b
forceRendering =
    replace get (set |> compose yield)


{-| The concrete Elm `Platform.Program` type produced by `Flow.element`,
`Flow.document`, and `Flow.application`.
-}
type alias Program flags s a =
    Platform.Program flags ( s, Flow.Program.Model (Flow s a) ) (Flow.Program.RuntimeMsg (Flow s a))


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
        { update = Flow.Program.runtimeUpdate
        , init = args.init >> Flow.Program.runtimeInit
        , view = \( model, _ ) -> Html.map Flow.Program.UserFlow (args.view model)
        , subscriptions = Flow.Program.subscriptions args.subscriptions
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
        { update = Flow.Program.runtimeUpdate
        , init = args.init >> Flow.Program.runtimeInit
        , view =
            \( model, _ ) ->
                let
                    doc =
                        args.view model
                in
                { title = doc.title, body = List.map (Html.map Flow.Program.UserFlow) doc.body }
        , subscriptions = Flow.Program.subscriptions args.subscriptions
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
        { update = Flow.Program.runtimeUpdate
        , init = \f u k -> Flow.Program.runtimeInit (args.init f u k)
        , view =
            \( model, _ ) ->
                let
                    doc =
                        args.view model
                in
                { title = doc.title, body = List.map (Html.map Flow.Program.UserFlow) doc.body }
        , subscriptions = Flow.Program.subscriptions args.subscriptions
        , onUrlRequest = \req -> Flow.Program.UserFlow (args.onUrlRequest req)
        , onUrlChange = \url -> Flow.Program.UserFlow (args.onUrlChange url)
        }


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


{-| Fire a `Task` for its side-effects and ignore the result (both `Ok` and
`Err` are discarded). Useful for fire-and-forget operations such as writing
to `localStorage` via a port task.

    Flow.attemptTask (Ports.saveToLocalStorage key value)

-}
attemptTask : Task e a -> Flow s ()
attemptTask t =
    lift (Task.attempt (always ()) t)


{-| Read a value through an optic. Produces `Just a` if the optic matches,
`Nothing` if it does not (e.g. a `Prism` pointing at the wrong variant).

    Flow.try MyModel.selectedItem
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


{-| Read a value through an optic, terminating with `none` if the optic does
not match.

    Flow.forAll MyModel.selectedItem
        (\item -> renderItem item)

-}
forAll : An_Optic pr ls s a -> (a -> Flow s b) -> Flow s b
forAll optic f =
    get |> map (Accessors.try optic) |> assertJust |> andThen f


{-| Read all values targeted by an optic (useful for traversals).

    Flow.getAll MyModel.allItems
        (\items -> Flow.pure (List.length items))

-}
getAll : An_Optic pr ls s a -> (List a -> Flow s b) -> Flow s b
getAll optic f =
    get |> map (Accessors.all optic) |> andThen f


{-| Modify the value(s) targeted by an optic.

    Flow.over MyModel.count (\n -> n + 1)

-}
over : An_Optic pr ls s a -> (a -> a) -> Flow s ()
over =
    (<<) modify << Accessors.over


{-| Set the value(s) targeted by an optic.

    Flow.setAll MyModel.status Loading

-}
setAll : An_Optic pr ls s a -> a -> Flow s ()
setAll =
    (>>) always << over


{-| Run a `Flow a x` in the context of a larger model `s`, using an optic to
zoom in and out. State reads and writes inside the sub-flow are applied through
the optic.

    Flow.via MyModel.editingRecord
        (Flow.modify (\r -> { r | name = newName }))

-}
via : An_Optic pr ls s a -> Flow a x -> Flow s x
via optic =
    replace
        (get |> andThen (batchM << List.map pure << Accessors.all optic))
        (setAll optic)


{-| Run a Flow only when the condition is `True`, otherwise produce `()`.

    Flow.when model.isLoggedIn savePreferences

-}
when : Bool -> Flow s () -> Flow s ()
when pred io =
    if pred then
        io

    else
        pure ()


{-| Run a Flow for its effects, then produce a fixed value `a` regardless of
what the flow returned.

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
async =
    Flow.Internal.async


{-| Acquire a resource, run a computation, then release the resource —
even if the computation terminates early with `none`.

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

    Flow.setting MyModel.isLoading fetchData

-}
setting : An_Optic pr ls s Bool -> Flow s a -> Flow s a
setting lns =
    bracket_ (setAll lns True) (setAll lns False)


{-| Run a computation only if a `Bool` lens is currently `False`, and hold
it at `True` for the duration. Subsequent calls while the lock is held are
silently dropped.

    Flow.locking MyModel.isSaving saveRecord

-}
locking : A_Lens pr s Bool -> Flow s () -> Flow s ()
locking lns io =
    forAll lns (\locked -> when (not locked) (setting lns io))
