module Flow.Channel exposing
    ( Channel
    , ChannelKey
    , accept
    , acceptOne
    , acceptUntil
    , connect
    , filter
    , join
    )

import Flow.Internal exposing (Flow(..), andThen, async)


type alias ChannelKey =
    String


type Channel s a
    = Channel
        { cmdPort : ChannelKey -> Cmd (Flow s a)
        , subPort : ChannelKey -> (a -> Maybe (Flow s a)) -> Sub (Maybe (Flow s a))
        }


connect : ((a -> Maybe (Flow s a)) -> Sub (Maybe (Flow s a))) -> (ChannelKey -> Cmd (Flow s a)) -> Channel s a
connect subPort cmdPort =
    Channel
        { cmdPort = cmdPort
        , subPort = \_ -> subPort
        }


join : ((a -> Maybe (Flow s a)) -> Sub (Maybe (Flow s a))) -> Channel s a
join subPort =
    Channel
        { cmdPort = \_ -> Cmd.none
        , subPort = \_ -> subPort
        }


filter : (ChannelKey -> a -> Bool) -> Channel s a -> Channel s a
filter predicate (Channel channel) =
    Channel
        { channel
            | subPort =
                \key callback ->
                    channel.subPort key
                        (\a ->
                            if predicate key a then
                                callback a

                            else
                                Nothing
                        )
        }


awaitWith : (ChannelKey -> Cmd (Flow s a)) -> Channel s a -> (a -> Maybe (Flow s a)) -> Flow s a
awaitWith cmd (Channel channel) callback =
    Await
        (\key -> Cmd.map (\_ -> Batch []) (cmd key))
        (\key -> channel.subPort key callback)


acceptOne : Channel s a -> Flow s a
acceptOne =
    acceptUntil (always True)


accept : (a -> Flow s ()) -> Channel s a -> Flow s a
accept handler ((Channel channel) as ch) =
    let
        continuation a =
            Just (andThen loop (async (handler a)))

        loop () =
            awaitWith (\_ -> Cmd.none) ch continuation
    in
    awaitWith channel.cmdPort ch continuation


acceptUntil : (a -> Bool) -> Channel s a -> Flow s a
acceptUntil shouldStop ((Channel channel) as ch) =
    awaitWith channel.cmdPort
        ch
        (\a ->
            if shouldStop a then
                Just (Pure a)

            else
                Just (acceptUntil shouldStop ch)
        )
