module Flow exposing
    ( Flow
    , Program, sandbox, element, document, application
    , await, subscribe
    , pure, lift, liftUpdate
    , get, set, modify
    , map, andThen, join, ap, flap, compose, seq, traverse, mapM
    , replace
    , none
    , yield, forceRendering
    , transform
    , batch, batchM
    , assertJust, assertOk, assertCondition, fromMaybe
    , attemptTask
    , try, forAll, getAll, over, setAll, via
    , when, return, async, bracket_, setting, locking
    )

{-| This module provides a monadic interface for _The Elm Architecture_, bridging synchronous state modifications with asynchronous subscriptions via Channels.

**Note:** This library merges concepts from two community packages:

  - `chrilves/elm-io` (The free monad interface for TEA)
  - `brian-watkins/elm-procedure` (Continuation-passing channels and subscriptions)

@docs Flow


# Running a web application with [Flow](#Flow)

@docs Program, sandbox, element, document, application


# Subscriptions and Procedures

@docs await, subscribe


# Lifting values and commands into [Flow](#Flow)

@docs pure, lift, liftUpdate


# The model as a state

@docs get, set, modify


# Classic monadic operations

@docs map, andThen, join, ap, flap, compose, seq, traverse, mapM


# Passing from a model to another via optics

@docs replace


# Terminating computation

@docs none


# Forces Elm rendering

@docs yield, forceRendering


# Transform Flow into regular Elm

@docs transform


# Batch operations

@docs batch, batchM


# Assertions and guards

@docs assertJust, assertOk, assertCondition, fromMaybe


# Task helpers

@docs attemptTask


# Optics helpers

@docs try, forAll, getAll, over, setAll, via


# Control flow utilities

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


type alias Flow s a =
    Flow.Internal.Flow s a


{-| Suspend this Flow pipeline, open a Channel, and resume when a value arrives.
-}
await : Channel s a -> Flow s a
await =
    Flow.Channel.acceptOne


{-| Open a channel and process each value indefinitely with the given handler.
-}
subscribe : (a -> Flow s ()) -> Channel s a -> Flow s a
subscribe =
    Flow.Channel.accept


pure : a -> Flow s a
pure a =
    Pure a


batch : List a -> Flow s a
batch l =
    Batch (List.map Pure l)


lift : Cmd a -> Flow s a
lift cmd =
    Command (Cmd.map Pure cmd)


get : Flow s s
get =
    Get Pure


set : s -> Flow s ()
set s =
    Set s (Pure ())


map : (a -> b) -> Flow s a -> Flow s b
map f =
    andThen (Pure << f)


andThen : (a -> Flow s b) -> Flow s a -> Flow s b
andThen =
    Flow.Internal.andThen


join : Flow s (Flow s a) -> Flow s a
join =
    andThen identity


ap : Flow s (a -> b) -> Flow s a -> Flow s b
ap mf ma =
    andThen (\y -> map y ma) mf


flap : Flow s a -> Flow s (a -> b) -> Flow s b
flap ma mf =
    ap mf ma


compose : (b -> Flow m c) -> (a -> Flow m b) -> a -> Flow m c
compose g f a =
    f a |> andThen g


seq : Flow s b -> Flow s a -> Flow s b
seq second first =
    first |> andThen (\_ -> second)


none : Flow s a
none =
    Flow.Internal.none


batchM : List (Flow s a) -> Flow s a
batchM l =
    join (batch l)


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


modify : (s -> s) -> Flow s ()
modify f =
    Get (\m -> Set (f m) (Pure ()))


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


mapM : List (Flow s a) -> Flow s (List a)
mapM =
    traverse identity


yield : a -> Flow s a
yield a =
    lift (Task.perform (\_ -> a) (Process.sleep 0))


forceRendering : Flow a b -> Flow a b
forceRendering =
    replace get (set |> compose yield)


type alias Program flags s a =
    Platform.Program flags ( s, Flow.Program.Model (Flow s a) ) (Flow.Program.RuntimeMsg (Flow s a))


transform :
    (a -> Flow s a)
    ->
        { update : Flow.Program.RuntimeMsg (Flow s a) -> ( s, Flow.Program.Model (Flow s a) ) -> ( ( s, Flow.Program.Model (Flow s a) ), Cmd (Flow.Program.RuntimeMsg (Flow s a)) )
        , initTransformer : ( s, Flow s a ) -> ( ( s, Flow.Program.Model (Flow s a) ), Cmd (Flow.Program.RuntimeMsg (Flow s a)) )
        }
transform update =
    { update = Flow.Program.update update
    , initTransformer =
        \( m, io ) ->
            let
                ( newModel, newRegistry, cmd ) =
                    Flow.Program.runUpdate update io m Flow.Program.init
            in
            ( ( newModel, newRegistry ), cmd )
    }


element :
    { init : flags -> ( s, Flow s a )
    , view : s -> Html (Flow s a)
    , update : a -> Flow s a
    , subscriptions : s -> Sub (Flow s a)
    }
    -> Program flags s a
element args =
    let
        new =
            transform args.update
    in
    Browser.element
        { update = new.update
        , init = args.init >> new.initTransformer
        , view = \( model, _ ) -> Html.map Flow.Program.UserFlow (args.view model)
        , subscriptions = Flow.Program.subscriptions args.subscriptions
        }


sandbox :
    { init : flags -> ( s, Flow s a )
    , view : s -> Html (Flow s a)
    , subscriptions : s -> Sub (Flow s a)
    }
    -> Program flags s a
sandbox args =
    element
        { init = args.init
        , view = args.view
        , update = always none
        , subscriptions = args.subscriptions
        }


document :
    { init : flags -> ( s, Flow s a )
    , view : s -> Document (Flow s a)
    , update : a -> Flow s a
    , subscriptions : s -> Sub (Flow s a)
    }
    -> Program flags s a
document args =
    let
        new =
            transform args.update
    in
    Browser.document
        { update = new.update
        , init = args.init >> new.initTransformer
        , view =
            \( model, _ ) ->
                let
                    doc =
                        args.view model
                in
                { title = doc.title, body = List.map (Html.map Flow.Program.UserFlow) doc.body }
        , subscriptions = Flow.Program.subscriptions args.subscriptions
        }


application :
    { init : flags -> Url -> Key -> ( s, Flow s a )
    , view : s -> Document (Flow s a)
    , update : a -> Flow s a
    , subscriptions : s -> Sub (Flow s a)
    , onUrlRequest : UrlRequest -> Flow s a
    , onUrlChange : Url -> Flow s a
    }
    -> Program flags s a
application args =
    let
        new =
            transform args.update
    in
    Browser.application
        { update = new.update
        , init = \f u k -> new.initTransformer (args.init f u k)
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


assertCondition : (a -> Bool) -> Flow s a -> Flow s a
assertCondition pred =
    andThen
        (\value ->
            if pred value then
                pure value

            else
                none
        )


fromMaybe : Maybe a -> (a -> Flow s b) -> Flow s b
fromMaybe m f =
    pure m |> assertJust |> andThen f


attemptTask : Task e a -> Flow s ()
attemptTask t =
    lift (Task.attempt (always ()) t)


try : An_Optic pr ls s a -> (Maybe a -> Flow s b) -> Flow s b
try optic f =
    get |> map (Accessors.try optic) |> andThen f


forAll : An_Optic pr ls s a -> (a -> Flow s b) -> Flow s b
forAll optic f =
    get |> map (Accessors.try optic) |> assertJust |> andThen f


getAll : An_Optic pr ls s a -> (List a -> Flow s b) -> Flow s b
getAll optic f =
    get |> map (Accessors.all optic) |> andThen f


over : An_Optic pr ls s a -> (a -> a) -> Flow s ()
over =
    (<<) modify << Accessors.over


setAll : An_Optic pr ls s a -> a -> Flow s ()
setAll =
    (>>) always << over


via : An_Optic pr ls s a -> Flow a x -> Flow s x
via optic =
    replace
        (get |> andThen (batchM << List.map pure << Accessors.all optic))
        (setAll optic)


when : Bool -> Flow s () -> Flow s ()
when pred io =
    if pred then
        io

    else
        pure ()


return : a -> Flow s b -> Flow s a
return =
    seq << pure


async : Flow s a -> Flow s ()
async =
    Flow.Internal.async


bracket_ : Flow s a -> Flow s b -> Flow s c -> Flow s c
bracket_ before after thing =
    before |> seq thing |> andThen (\b -> after |> return b)


setting : An_Optic pr ls s Bool -> Flow s a -> Flow s a
setting lns =
    bracket_ (setAll lns True) (setAll lns False)


locking : A_Lens pr s Bool -> Flow s () -> Flow s ()
locking lns io =
    forAll lns (\locked -> when (not locked) (setting lns io))
