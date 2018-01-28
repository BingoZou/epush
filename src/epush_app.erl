%%%-------------------------------------------------------------------
%% @doc epush public API
%% @end
%%%-------------------------------------------------------------------

-module(epush_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).
-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("eutil/include/eutil.hrl").

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    case epush_sup:start_link() of
        {error, _} = E ->
            E;
        R ->
            init(),
            R
    end.

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================
init() ->
    ets:new(epush_confs, [named_table, public, set, {read_concurrency,true}]),
    epush_statistics:start_link(),
    start_workers(),
    start_websvr(),
    ?INFO_MSG("epush app start's init done"),
    ok.

start_websvr() ->
    {ok, HttpPort} = application:get_env(epush, http_port),
    Dispatch = cowboy_router:compile([
                                      {'_', [{"/push", epush_websvr, []}]}
                                     ]),
    %{ok, _} = cowboy:start_http(http, 100, [{port, HttpPort}],
    %                            [{env, [{dispatch, Dispatch}]},
    %                             {timeout, 30000}
    %                            ]
    %                           ),
	{ok, _} = cowboy:start_clear(http, [{port, HttpPort}, {num_acceptors, 60}], #{
		env => #{dispatch => Dispatch}
	}),
    ok.

start_workers() ->
    ?INFO_MSG("start_workers..."),
    {ok, PushConfs} = application:get_env(epush, push_confs),
    [start_worker(Conf) || Conf <- PushConfs],
    ?INFO_MSG("done_workers.."),
    ok.

%start_worker(#{id:=Id, type:=apns, pool_size:=PoolSize, cert_file:=CertFile,
%               is_sandbox_env:=IsSandbox}=Conf) ->
%    {AppleHost, FeedbackHost} = case IsSandbox of
%                                    true -> {"gateway.sandbox.push.apple.com", "feedback.sandbox.push.apple.com"};
%                                    false -> {"gateway.push.apple.com", "feedback.push.apple.com"}
%                                end,
%    DefConn = apns:default_connection(),
%    ApnsConn = DefConn#apns_connection{cert_file = CertFile, apple_host = AppleHost,
%                                       feedback_host = FeedbackHost,
%                                       error_fun = fun epush_apns:handle_apns_error/2,
%                                       feedback_fun = fun epush_apns:handle_apns_delete_subscription/1
%                                      },
%    apns:connect(eutil:to_atom(Id), ApnsConn),
%    gen_subscriber(apns, eutil:to_binary(Id), PoolSize, #{type=>apns, apns_name=>Id}),
%    epush_util:put_push_conf(Id, Conf);
start_worker(#{id := Id, type := apns, pool_size := PoolSize, certfile := CertFile,
               keyfile := KeyFile, is_dev_env := IsDev, headers := Headers,
               timeout := Timeout} = Conf) ->
    AppleHost = case IsDev of
                    false -> "api.push.apple.com";
                    true -> "api.development.push.apple.com"
                end,
    Apns = #{name => undefined, apple_host => AppleHost, apple_port => 443, certfile => CertFile,
             keyfile => KeyFile, type => cert, timeout => Timeout, id=>Id},
    PoolName = list_to_atom(lists:concat([Id, "_pool"])),
    epush_pool:add_pool(PoolName, Apns),
    ok = gen_subscriber(apns, eutil:to_binary(Id), PoolSize, #{type => apns, apns_name => Id, headers => Headers, pool_name => PoolName, timeout => Timeout}),
    epush_util:put_push_conf(Id, Conf);

start_worker(#{id:=Id, type:=xiaomi, pkg_name:=PkgName, app_secret:=AppSecret,
               pool_size:=PoolSize}=Conf) ->
    State = #{type=>xiaomi, pkg_name=>PkgName, app_secret=>AppSecret},
    ok = gen_subscriber(xiaomi, eutil:to_binary(Id), PoolSize, State),
    epush_util:put_push_conf(Id, Conf);
%start_worker(#{id:=Id, type:=huawei, app_id:=AppId, app_secret:=AppSecret,
%               pool_size:=PoolSize}=Conf) ->
%    State = #{type=>huawei, app_id=>AppId, app_secret=>AppSecret},
%    ok = gen_subscriber(huawei, eutil:to_binary(Id), PoolSize, State),
%    %Pid = gproc:where({n,l,{turtle,service,huawei_subscriber}}),
%    %ChildSpecs = supervisor:which_children(Pid),
%    %PoolSpec = lists:keyfind(pool, 1, ChildSpecs),
%    %{pool, PoolPid, supervisor, [turtle_subscriber_pool]} = PoolSpec,
%    %SubsriberSpecs = supervisor:which_children(PoolPid),
%    %Fun = fun({_, SubsriberPid, worker, [turtle_subscriber]}) ->
%    %              erlang:send_after(6000, SubsriberPid, refresh_access_token)
%    %      end,
%    %lists:foreach(Fun, SubsriberSpecs),
%    epush_util:put_push_conf(Id, Conf);
start_worker(#{id:=Id, type:=hms, app_id:=AppId, app_secret:=AppSecret,
               pool_size:=PoolSize}=Conf) ->
    State = #{type=>huawei, app_id=>AppId, app_secret=>AppSecret},
    ok = gen_subscriber(hms, eutil:to_binary(Id), PoolSize, State),
    epush_util:put_push_conf(Id, Conf);
start_worker(#{id:=Id, type:=fcm, api_key:=ApiKey, proxy:=Proxy,
               pool_size:=PoolSize}=Conf) ->
    State = #{type=>fcm, api_key=>eutil:to_binary(ApiKey), proxy=>Proxy},
    ok = gen_subscriber(fcm, eutil:to_binary(Id), PoolSize, State),
    epush_util:put_push_conf(Id, Conf);
start_worker(#{id:=Id, type:=flyme, app_id:=AppId, app_secret:=AppSecret,
               pool_size:=PoolSize}=Conf) ->
    State = #{type=>flyme, app_id=>AppId, app_secret=>AppSecret},
    ok = gen_subscriber(flyme, eutil:to_binary(Id), PoolSize, State),
    epush_util:put_push_conf(Id, Conf);
start_worker(#{id:=Id, type:=yunpian, apikey:=Apikey, pool_size:=PoolSize}=Conf) ->
    State = #{type=>yunpian, apikey=>Apikey},
    ok = gen_subscriber(yunpian, eutil:to_binary(Id), PoolSize, State),
    epush_util:put_push_conf(Id, Conf),
    ok.

gen_subscriber(Type, Queue, PoolSize, State) ->
    Mod = erlang:list_to_atom(lists:concat(["epush_", Type])),
    Declarations = [#'queue.declare'{queue = Queue, durable = true}],
    Config = #{
      name => binary_to_atom(Queue, utf8),
      connection => amqp_server,
      function => fun Mod:loop/4,
      handle_info => fun Mod:handle_info/2,
      init_state => State,
      declarations => Declarations,
      subscriber_count => PoolSize,
      prefetch_count => PoolSize,
      consume_queue => Queue,
      passive => false
     },
    ServiceSpec = turtle_service:child_spec(Config),
    {ok, _}= supervisor:start_child(turtle_sup, ServiceSpec),
    ?INFO_MSG("done gen_subscriber, Type: ~p, Queue: ~p", [Type, Queue]),
    ok.
