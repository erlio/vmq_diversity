-module(vmq_diversity_redis).

-behaviour(gen_server).
-behaviour(poolboy_worker).

%% API functions
-export([start_link/1,
         install/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-import(luerl_lib, [badarg_error/3]).

-record(state, {conn}).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).


install(St) ->
    luerl_emul:alloc_table(table(), St).

query(PoolName, Command) ->
    poolboy:transaction(PoolName, fun(Worker) ->
                                          gen_server:call(Worker, {q, Command})
                                  end).
%query_pipeline(PoolName, Pipeline) ->
%    poolboy:transaction(PoolName, fun(Worker) ->
%                                          gen_server:call(Worker, {qp, Pipeline})
%                                  end).
%                                  end).
%query_noreply(PoolName, Command) ->
%    poolboy:transaction(PoolName, fun(Worker) ->
%                                          gen_server:call(Worker, {q_noreply, Command})
%                                  end).
%
%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init(Args) ->
    {ok, Conn} = eredis:start_link(Args),
    {ok, #state{conn=Conn}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({q, Command}, _From, #state{conn=Conn}=State) ->
    {reply, eredis:q(Conn, Command), State};
handle_call({q_noreply, Command}, _From, #state{conn=Conn}=State) ->
    {reply, eredis:q_noreply(Conn, Command), State};
handle_call({qp, Pipeline}, _From, #state{conn=Conn}=State) ->
    {reply, eredis:qp(Conn, Pipeline), State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    _ = eredis:stop(State#state.conn),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
table() ->
    [
     {<<"cmd">>, {function, fun cmd/2}}
    ].

cmd(As, St) ->
    case As of
        [BPoolId, Command|Args] when is_binary(BPoolId)
                              and is_binary(Command) ->
            PoolId = pool_id(BPoolId, As, St),
            case query(PoolId, re:split(Command, " ") ++ parse_args(Args, [], St)) of
                {ok, <<"OK">>} ->
                    {[true], St};
                {ok, undefined} ->
                    {[nil], St};
                {ok, Ret0} when is_list(Ret0) ->
                    {Ret1, NewSt} = luerl:encode(Ret0, St),
                    {[Ret1], NewSt};
                {ok, Ret} ->
                    {[Ret], St};
                _ ->
                    {[false], St}
            end;
        _ ->
            badarg_error(execute_parse, As, St)
    end.

pool_id(BPoolId, As, St) ->
    try list_to_existing_atom(binary_to_list(BPoolId)) of
        APoolId -> APoolId
    catch
        _:_ ->
            lager:error("unknown pool ~p", [BPoolId]),
            badarg_error(unknown_pool, As, St)
    end.

parse_args([], Acc, _) -> lists:reverse(Acc);
parse_args([B|Rest], Acc, St) when is_binary(B) ->
    parse_args(Rest, [B|Acc], St);
parse_args([T|Rest], Acc, St) when is_tuple(T) ->
    case luerl:decode(T, St) of
        [{K, _}|_] = Array when is_integer(K) ->
            {_, Vals} = lists:unzip(Array),
            parse_args(Rest, [Vals|Acc], St);
        [{K, _}|_] = Table0 when is_binary(K) ->
            Table1 =
            lists:foldl(fun({Key, Val}, AccAcc) ->
                                [Key, Val|AccAcc]
                        end, [], Table0),
            parse_args(Rest, [Table1|Acc], St)
    end.

