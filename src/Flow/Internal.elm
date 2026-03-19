module Flow.Internal exposing (ChannelKey, Flow(..), andThen, async, none)


type Flow s a
    = Pure a
    | Get (s -> Flow s a)
    | Set s (Flow s a)
    | Batch (List (Flow s a))
    | Command (Cmd (Flow s a))
    | Await (ChannelKey -> Cmd (Flow s a)) (ChannelKey -> Sub (Maybe (Flow s a)))


type alias ChannelKey =
    String


none : Flow model a
none =
    Batch []


async : Flow s a -> Flow s ()
async io =
    Batch [ andThen (\_ -> none) io, Pure () ]


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
            Await
                (\key -> Cmd.map (andThen f) (req key))
                (\key -> Sub.map (Maybe.map (andThen f)) (sub key))
