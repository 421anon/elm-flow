module Flow.Program exposing
    ( Model
    , RuntimeMsg(..)
    , init
    , runtimeInit
    , runtimeUpdate
    , subscriptions
    )

import Dict exposing (Dict)
import Flow.Internal exposing (ChannelRequest(..), Flow(..), none)
import Json.Encode exposing (Value)


type alias Model flow =
    { nextId : Int
    , channels : Dict Int (Sub (RuntimeMsg flow))
    , joins : Dict Int (JoinPoint flow)
    }


type alias JoinPoint flow =
    { pending : Int
    , results : List ( List Int, Value )
    , continue : List Value -> flow
    , parent : Thread
    }


type Thread
    = Root
    | Branch Int (List Int)


type RuntimeMsg flow
    = UserFlow flow
    | Continue Thread flow
    | Unsubscribe Int Thread flow


init : Model flow
init =
    { nextId = 0
    , channels = Dict.empty
    , joins = Dict.empty
    }


runtimeInit : ( s, Flow s a ) -> ( ( s, Model (Flow s a) ), Cmd (RuntimeMsg (Flow s a)) )
runtimeInit ( m, fl ) =
    let
        ( newModel, newRegistry, cmd ) =
            run Root fl m init
    in
    ( ( newModel, newRegistry ), cmd )


run : Thread -> Flow s a -> s -> Model (Flow s a) -> ( s, Model (Flow s a), Cmd (RuntimeMsg (Flow s a)) )
run thread fl m reg =
    case fl of
        Pure _ ->
            finish thread Nothing m reg

        Deliver value ->
            finish thread (Just value) m reg

        Get k ->
            run thread (k m) m reg

        Set m2 next ->
            run thread next m2 reg

        Batch [] ->
            finish thread Nothing m reg

        Batch l ->
            let
                ( finalM, finalReg, cmds ) =
                    List.foldl
                        (\( index, fl_ ) ( currentM, currentReg, accCmds ) ->
                            let
                                ( nextM, nextReg, cmd ) =
                                    run (fork index thread) fl_ currentM currentReg
                            in
                            ( nextM, nextReg, cmd :: accCmds )
                        )
                        ( m, spawn (List.length l - 1) thread reg, [] )
                        (List.indexedMap Tuple.pair l)
            in
            ( finalM, finalReg, Cmd.batch cmds )

        Command cmd ->
            ( m, reg, Cmd.map (Continue thread) cmd )

        Await request sub ->
            let
                channelId =
                    reg.nextId

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

                wrapMsg mFired =
                    case mFired of
                        Nothing ->
                            UserFlow none

                        Just fired ->
                            Unsubscribe channelId thread fired

                newRegistry =
                    { reg
                        | nextId = reg.nextId + 1
                        , channels = Dict.insert channelId (Sub.map wrapMsg (sub key)) reg.channels
                    }
            in
            ( m, newRegistry, Cmd.map never cmd )

        Gather continue branches ->
            let
                joinId =
                    reg.nextId
            in
            run (Branch joinId [])
                branches
                m
                { reg
                    | nextId = reg.nextId + 1
                    , joins = Dict.insert joinId { pending = 1, results = [], continue = continue, parent = thread } reg.joins
                }


finish : Thread -> Maybe Value -> s -> Model (Flow s a) -> ( s, Model (Flow s a), Cmd (RuntimeMsg (Flow s a)) )
finish thread delivered m reg =
    case thread of
        Root ->
            ( m, reg, Cmd.none )

        Branch joinId path ->
            case Dict.get joinId reg.joins of
                Nothing ->
                    ( m, reg, Cmd.none )

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
                            m
                            { reg | joins = Dict.remove joinId reg.joins }

                    else
                        ( m
                        , { reg | joins = Dict.insert joinId { joinPoint | pending = joinPoint.pending - 1, results = results } reg.joins }
                        , Cmd.none
                        )


spawn : Int -> Thread -> Model flow -> Model flow
spawn count thread reg =
    case thread of
        Root ->
            reg

        Branch joinId _ ->
            { reg | joins = Dict.update joinId (Maybe.map (\joinPoint -> { joinPoint | pending = joinPoint.pending + count })) reg.joins }


fork : Int -> Thread -> Thread
fork index thread =
    case thread of
        Root ->
            Root

        Branch joinId path ->
            Branch joinId (path ++ [ index ])


runtimeUpdate : RuntimeMsg (Flow s a) -> ( s, Model (Flow s a) ) -> ( ( s, Model (Flow s a) ), Cmd (RuntimeMsg (Flow s a)) )
runtimeUpdate runtimeMsg ( userModel, registry ) =
    case runtimeMsg of
        UserFlow flow ->
            let
                ( newModel, newRegistry, cmd ) =
                    run Root flow userModel registry
            in
            ( ( newModel, newRegistry ), cmd )

        Continue thread flow ->
            let
                ( newModel, newRegistry, cmd ) =
                    run thread flow userModel registry
            in
            ( ( newModel, newRegistry ), cmd )

        Unsubscribe channelId thread flow ->
            if Dict.member channelId registry.channels then
                let
                    ( newModel, finalRegistry, cmd ) =
                        run thread flow userModel { registry | channels = Dict.remove channelId registry.channels }
                in
                ( ( newModel, finalRegistry ), cmd )

            else
                ( ( userModel, registry ), Cmd.none )


subscriptions : (model -> Sub (Flow s a)) -> ( model, Model (Flow s a) ) -> Sub (RuntimeMsg (Flow s a))
subscriptions userSubs ( userModel, registry ) =
    Sub.batch
        [ Sub.map UserFlow (userSubs userModel)
        , Sub.batch (Dict.values registry.channels)
        ]
