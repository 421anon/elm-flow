module Flow.Program exposing
    ( Model
    , RuntimeMsg(..)
    , init
    , runtimeInit
    , runtimeUpdate
    , subscriptions
    )

import Dict exposing (Dict)
import Flow.Internal exposing (Flow(..), none)


type alias Model flow =
    { nextId : Int
    , channels : Dict Int (Sub (RuntimeMsg flow))
    }


type RuntimeMsg flow
    = UserFlow flow
    | Unsubscribe Int flow


init : Model flow
init =
    { nextId = 0
    , channels = Dict.empty
    }


runtimeInit : ( s, Flow s a ) -> ( ( s, Model (Flow s a) ), Cmd (RuntimeMsg (Flow s a)) )
runtimeInit ( m, fl ) =
    let
        ( newModel, newRegistry, cmd ) =
            runUserUpdate fl m init
    in
    ( ( newModel, newRegistry ), cmd )


runUserUpdate : Flow s a -> s -> Model (Flow s a) -> ( s, Model (Flow s a), Cmd (RuntimeMsg (Flow s a)) )
runUserUpdate flow state registry =
    let
        recur fl m reg =
            case fl of
                Pure _ ->
                    ( m, reg, Cmd.none )

                Get k ->
                    recur (k m) m reg

                Set m2 next ->
                    recur next m2 reg

                Batch l ->
                    let
                        ( finalM, finalReg, cmds ) =
                            List.foldl
                                (\fl_ ( currentM, currentReg, accCmds ) ->
                                    let
                                        ( nextM, nextReg, cmd ) =
                                            recur fl_ currentM currentReg
                                    in
                                    ( nextM, nextReg, cmd :: accCmds )
                                )
                                ( m, reg, [] )
                                l
                    in
                    ( finalM, finalReg, Cmd.batch cmds )

                Command cmd ->
                    ( m, reg, Cmd.map UserFlow cmd )

                Await req sub ->
                    let
                        channelId =
                            reg.nextId

                        key =
                            "Channel-" ++ String.fromInt channelId

                        wrapMsg mFired =
                            case mFired of
                                Nothing ->
                                    UserFlow none

                                Just fired ->
                                    Unsubscribe channelId fired

                        newRegistry =
                            { reg
                                | nextId = reg.nextId + 1
                                , channels = Dict.insert channelId (Sub.map wrapMsg (sub key)) reg.channels
                            }
                    in
                    ( m, newRegistry, Cmd.map never (req key) )
    in
    recur flow state registry


runtimeUpdate : RuntimeMsg (Flow s a) -> ( s, Model (Flow s a) ) -> ( ( s, Model (Flow s a) ), Cmd (RuntimeMsg (Flow s a)) )
runtimeUpdate runtimeMsg ( userModel, registry ) =
    case runtimeMsg of
        UserFlow flow ->
            let
                ( newModel, newRegistry, cmd ) =
                    runUserUpdate flow userModel registry
            in
            ( ( newModel, newRegistry ), cmd )

        Unsubscribe channelId flow ->
            let
                newRegistry =
                    { registry | channels = Dict.remove channelId registry.channels }

                ( newModel, finalRegistry, cmd ) =
                    runUserUpdate flow userModel newRegistry
            in
            ( ( newModel, finalRegistry ), cmd )


subscriptions : (model -> Sub (Flow s a)) -> ( model, Model (Flow s a) ) -> Sub (RuntimeMsg (Flow s a))
subscriptions userSubs ( userModel, registry ) =
    Sub.batch
        [ Sub.map UserFlow (userSubs userModel)
        , Sub.batch (Dict.values registry.channels)
        ]
