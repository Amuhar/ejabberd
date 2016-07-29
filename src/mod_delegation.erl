-module(mod_delegation).

-author('amuhar3@gmail.com').

-behaviour(gen_mod).

-protocol({xep, 0355, '0.2.1'}).

-export([start/2, stop/1, depends/2, mod_opt_type/1]).

-export([advertise_delegations/1, process_packet/3,
         disco_local_features/5, disco_sm_features/5,
         disco_local_identity/5, disco_sm_identity/5, disco_info/5]).

-include("ejabberd_service.hrl").

%%%--------------------------------------------------------------------------------------
%%%  API
%%%--------------------------------------------------------------------------------------

start(Host, _Opts) ->
    mod_disco:register_feature(Host, ?NS_DELEGATION),
    ejabberd_hooks:add(disco_local_features, Host, ?MODULE,
                       disco_local_features, 500), %% This hook should be the last
    ejabberd_hooks:add(disco_local_identity, Host, ?MODULE,
                       disco_local_identity, 500),
    ejabberd_hooks:add(disco_sm_identity, Host, ?MODULE,
                       disco_sm_identity, 500),
    ejabberd_hooks:add(disco_sm_features, Host, ?MODULE, 
                       disco_sm_features, 500),
    ejabberd_hooks:add(disco_info, Host, ?MODULE,
                       disco_info, 500).


stop(Host) ->
    mod_disco:unregister_feature(Host, ?NS_DELEGATION),
    ejabberd_hooks:delete(disco_local_features, Host, ?MODULE,
                          disco_local_features, 500), 
    ejabberd_hooks:delete(disco_local_identity, Host, ?MODULE,
                          disco_local_identity, 500),
    ejabberd_hooks:delete(disco_sm_identity, Host, ?MODULE,
                          disco_sm_identity, 500),
    ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE, 
                          disco_sm_features, 500),
    ejabberd_hooks:delete(disco_info, Host, ?MODULE,
                          disco_info, 500).

depends(_Host, _Opts) -> [].

mod_opt_type(_Opt) -> [].

%%%--------------------------------------------------------------------------------------
%%%  server advertises delegated namespaces 4.2
%%%--------------------------------------------------------------------------------------
attribute_tag([]) -> [];
attribute_tag(Attrs) ->
    lists:map(fun(Attr) ->
                  #xmlel{name = <<"attribute">>, 
                         attrs = [{<<"name">> , Attr}]}
              end, Attrs).

delegations(Id, Delegations, From, To) ->
    Elem0 = lists:map(fun({Ns, FilterAttr}) ->
                          #xmlel{name = <<"delegated">>, 
                                 attrs = [{<<"namespace">>, Ns}],
                                 children = attribute_tag(FilterAttr)}
                      end, Delegations),
    Elem1 = #xmlel{name = <<"delegation">>, 
                   attrs = [{<<"xmlns">>, ?NS_DELEGATION}],
                   children = Elem0},
    #xmlel{name = <<"message">>, 
           attrs = [{<<"id">>, Id}, {<<"from">>, From}, {<<"to">>, To}],
           children = [Elem1]}.

delegation_ns_debug(Host, Delegations) ->
    lists:foreach(fun({Ns, []}) ->
    	                ?DEBUG("namespace ~s is delegated to ~s with"
    	                       " no filtering attributes ~n",[Ns, Host]);
    	               ({Ns, Attr}) ->
                      ?DEBUG("namespace ~s is delegated to ~s with"
    	                       " ~p filtering attributes ~n",[Ns, Host, Attr])
    	            end, Delegations).

add_iq_handlers(Ns) ->
    lists:foreach(fun(Host) -> 
                    gen_iq_handler:add_iq_handler(ejabberd_sm, Host,
                                                  Ns, ?MODULE, 
                                                  process_packet, one_queue),
                    gen_iq_handler:add_iq_handler(ejabberd_local, Host,
                                                  Ns, ?MODULE,
                                                  process_packet, one_queue)
                  end, ?MYHOSTS).

advertise_delegations(#state{delegations = []}) -> ok;
advertise_delegations(StateData) ->
    Delegated = delegations(StateData#state.streamid, StateData#state.delegations,
                            ?MYNAME, StateData#state.host),
    ejabberd_service:send_element(StateData, Delegated),
    % server asks available features for delegated namespaces 
    disco_info(StateData),
    
    lists:foreach(fun({Ns, _}) ->
                      add_iq_handlers(Ns)
                  end, StateData#state.delegations),

    delegation_ns_debug(StateData#state.host, StateData#state.delegations).

%%%--------------------------------------------------------------------------------------
%%%  Delegated namespaces hook
%%%--------------------------------------------------------------------------------------

check_filter_attr([], _Children) -> true;
check_filter_attr(_FilterAttr, []) -> false;
check_filter_attr(FilterAttr, [#xmlel{} = Stanza|_]) ->
    Attrs = proplists:get_keys(Stanza#xmlel.attrs),
    lists:all(fun(Attr) ->
                  lists:member(Attr, Attrs)
              end, FilterAttr);
check_filter_attr(_FilterAttr, _Children) -> false.

check_delegation([], _Ns, _Children) -> false;
check_delegation(Delegations, Ns, Children) ->
    case lists:keysearch(Ns, 1, Delegations) of
        {value, {Ns, FilterAttr}} ->
            check_filter_attr(FilterAttr, Children);
    	  false-> false
    end.

-spec check_tab(atom()) -> boolean().

check_tab(Name) ->
    case ets:info(Name) of
      undefined ->
          false;
      _ ->
          true
    end.

-spec get_client_server([attr()]) -> {jid(), jid()}. 

get_client_server(Attrs) ->
    Client = fxml:get_attr_s(<<"from">>, Attrs),
    ClientJID = jid:from_string(Client),
    ServerJID = jid:from_string(ClientJID#jid.lserver),
    {ClientJID, ServerJID}.

-spec hook_name(binary(), binary()) -> atom().

hook_name(Name, Id) ->
    Hook = << Name/binary, Id/binary >>,
    binary_to_atom(Hook, 'latin1').

decapsulate_result(#xmlel{children = []}) -> ok;
decapsulate_result(#xmlel{children = Children}) ->
    decapsulate_result0(Children).

decapsulate_result0([]) -> ok;
decapsulate_result0([#xmlel{name = <<"delegation">>, 
                          attrs = [{<<"xmlns">>, ?NS_DELEGATION}]} = Packet]) ->
    decapsulate_result1(Packet#xmlel.children);
decapsulate_result0(_Children) -> ok.

decapsulate_result1([]) -> ok;
decapsulate_result1([#xmlel{name = <<"forwarded">>,
                            attrs = [{<<"xmlns">>, ?NS_FORWARD}]} = Packet]) ->
    decapsulate_result2(Packet#xmlel.children);
decapsulate_result1(_Children) -> ok.

decapsulate_result2([]) -> ok;
decapsulate_result2([#xmlel{name = <<"iq">>, attrs = Attrs} = Packet]) ->
    Ns = fxml:get_attr_s(<<"xmlns">>, Attrs),
    if
      Ns /= <<"jabber:client">> ->
        ok;
      true -> Packet
    end;
decapsulate_result2(_Children) -> ok.

-spec check_iq(xmlel(), xmlel()) -> xmlel() | ignore.

check_iq(#xmlel{attrs = Attrs} = Packet,
         #xmlel{attrs = AttrsOrigin} = OriginPacket) ->
    % Id attribute of OriginPacket Must be equil to Packet Id attribute
    Id1 = fxml:get_attr_s(<<"id">>, Attrs),
    Id2 = fxml:get_attr_s(<<"id">>, AttrsOrigin),
    % From attribute of OriginPacket Must be equil to Packet To attribute
    From = fxml:get_attr_s(<<"from">>, AttrsOrigin),
    To = fxml:get_attr_s(<<"to">>, Attrs),
    % Type attribute Must be error or result
    Type = fxml:get_attr_s(<<"type">>, Attrs),
    if
      ((Type == <<"result">>) or (Type == <<"error">>)),
      Id1 == Id2,  
      To == From ->
        NewPacket = jlib:remove_attr(<<"xmlns">>, Packet),
        %% We can send the decapsulated stanza from Server to Client (To)
        NewPacket;
      true ->
        %% service-unavailable
        Err = jlib:make_error_reply(OriginPacket, ?ERR_SERVICE_UNAVAILABLE),
        Err
    end;
check_iq(_Packet, _OriginPacket) -> ignore.

-spec manage_service_result(atom(), atom(), binary(), xmlel()) -> ok.

manage_service_result(HookRes, HookErr, Service, OriginPacket) ->
    fun(Packet) ->
        {ClientJID, ServerJID} = get_client_server(OriginPacket#xmlel.attrs),
        Server = ClientJID#jid.lserver,
        ejabberd_hooks:delete(HookRes, Server, 
                              manage_service_result(HookRes, HookErr,
                                                    Service, OriginPacket), 10),
        ejabberd_hooks:delete(HookErr, Server, 
                              manage_service_error(HookRes, HookErr,
                                                   Service, OriginPacket), 10),
        % Check Packet "from" attribute
        % It Must be equil to current service host
        From = fxml:get_attr_s(<<"from">> , Packet#xmlel.attrs),
        if
          From == Service  ->
              % decapsulate iq result
              ResultIQ = decapsulate_result(Packet),
              ServResponse = check_iq(ResultIQ, OriginPacket),
              if
                ServResponse /= ignore ->
                  ejabberd_router:route(ServerJID, ClientJID, ServResponse);
                true -> ok
              end;
          true ->
              % service unavailable
              Err = jlib:make_error_reply(OriginPacket, ?ERR_SERVICE_UNAVAILABLE),
              ejabberd_router:route(ServerJID, ClientJID, Err) 
        end       
    end.

-spec manage_service_error(atom(), atom(), binary(), xmlel()) -> ok.

manage_service_error(HookRes, HookErr, Service, OriginPacket) ->
    fun(_Packet) ->
        {ClientJID, ServerJID} = get_client_server(OriginPacket#xmlel.attrs),
        Server = ClientJID#jid.lserver,
        ejabberd_hooks:delete(HookRes, Server, 
                              manage_service_result(HookRes, HookErr,
                                                    Service, OriginPacket), 10),
        ejabberd_hooks:delete(HookErr, Server, 
                              manage_service_error(HookRes, HookErr,
                                                   Service, OriginPacket), 10),
        Err = jlib:make_error_reply(OriginPacket, ?ERR_SERVICE_UNAVAILABLE),
        ejabberd_router:route(ServerJID, ClientJID, Err)        
    end.


-spec forward_iq(binary(), binary(), xmlel()) -> ok.

forward_iq(Server, Service, Packet) ->
    Elem0 = #xmlel{name = <<"forwarded">>,
                   attrs = [{<<"xmlns">>, ?NS_FORWARD}], children = [Packet]},
    Elem1 = #xmlel{name = <<"delegation">>, 
                   attrs = [{<<"xmlns">>, ?NS_DELEGATION}], children = [Elem0]},
    Id = randoms:get_string(),
    Elem2 = #xmlel{name = <<"iq">>,
                   attrs = [{<<"from">>, Server}, {<<"to">>, Service},
                            {<<"type">>, <<"set">>}, {<<"id">>, Id}],
                   children = [Elem1]},

    HookRes = hook_name(<<"iq_result">>, Id),
    HookErr = hook_name(<<"iq_error">>, Id),

    FunRes = manage_service_result(HookRes, HookErr, Service, Packet),
    FunErr = manage_service_error(HookRes, HookErr, Service, Packet),

    ejabberd_hooks:add(HookRes, Server, FunRes, 10),
    ejabberd_hooks:add(HookErr, Server, FunErr, 10),

    From = jid:make(<<"">>, Server, <<"">>),
    To = jid:make(<<"">>, Service, <<"">>),
    ejabberd_router:route(From, To, Elem2).

process_packet(From, To, #iq{type = Type, xmlns = XMLNS} = IQ) ->
    %% check if stanza directed to server
    %% or directed to the bare JID of the sender
    case %((From#jid.user == To#jid.user) and
       	 % (From#jid.lserver == To#jid.lserver) or
        % (To#jid.luser == <<"">>)) and
         ((Type == get) or (Type == set)) and
         check_tab(delegated_namespaces) of
        true ->
            Packet = jlib:iq_to_xml(IQ),
            #xmlel{name = <<"iq">>, attrs = Attrs, children = Children} = Packet,

            AttrsNew = [{<<"xmlns">>, <<"jabber:client">>} | Attrs],

            AttrsNew2 = jlib:replace_from_to_attrs(jid:to_string(From),
                                                   jid:to_string(To), AttrsNew),

            case ets:lookup(delegated_namespaces, XMLNS) of
              [{XMLNS, Pid, _, _}] ->
                {ServiceHost, Delegations} = ejabberd_service:get_delegated_ns(Pid),
                case check_delegation(Delegations, XMLNS, Children) of
                    true ->
                        forward_iq(From#jid.server, ServiceHost,
                                   Packet#xmlel{attrs = AttrsNew2});
                    _ -> ok
                end;
              [] -> ok
            end, 
            ignore;
        _ -> 
            ignore
    end.

%%%--------------------------------------------------------------------------------------
%%%  7. Discovering Support
%%%--------------------------------------------------------------------------------------

decapsulate_features(#xmlel{attrs = Attrs} = Packet, Node) ->
  case fxml:get_attr_s(<<"node">>, Attrs) of 
      Node ->
          PREFIX = << ?NS_DELEGATION/binary, <<"::">>/binary >>,
          Size = byte_size(PREFIX),
          BARE_PREFIX = << ?NS_DELEGATION/binary, <<":bare:">>/binary >>,
          SizeBare = byte_size(BARE_PREFIX),

          Features = [Feat || #xmlel{attrs = [{<<"var">>, Feat}]} <-
                              fxml:get_subtags(Packet, <<"feature">>)],
                       
          Identity = [I || I <- fxml:get_subtags(Packet, <<"identity">>)],

          Exten = [I || I <- fxml:get_subtags_with_xmlns(Packet, <<"x">>, ?NS_XDATA)],

          case Node of
            << PREFIX:Size/binary, NS/binary >> ->
              ets:update_element(delegated_namespaces, NS,
                                 {3, {Features, Identity, Exten}});
            << BARE_PREFIX:SizeBare/binary, NS/binary >> ->
              ets:update_element(delegated_namespaces, NS,
                                 {4, {Features, Identity}});
               _ -> ok
          end;
      _ -> ok %% error ?
  end;
decapsulate_features(_Packet, _Node) -> ok. %% send error ? from = ?MYHOSTS, to = ?
    
-spec disco_result(atom(), atom(), binary()) -> ok.

disco_result(HookRes, HookErr, Node) ->
    fun(Packet) ->
        Server = fxml:get_attr_s(<<"to">>, Packet#xmlel.attrs),
        Tag = fxml:get_subtag_with_xmlns(Packet, <<"query">>, ?NS_DISCO_INFO),
        decapsulate_features(Tag, Node),
        ejabberd_hooks:delete(HookRes, Server, 
                              disco_result(HookRes, HookErr, Node), 10),
        ejabberd_hooks:delete(HookErr, Server, 
                              disco_error(HookRes, HookErr, Node), 10)
    end.

-spec disco_error(atom(), atom(), binary()) -> ok.

disco_error(HookRes, HookErr, Node) ->
    fun(Packet) ->
        Server = fxml:get_attr_s(<<"to">>, Packet#xmlel.attrs),
        ejabberd_hooks:delete(HookRes, Server, 
                              disco_result(HookRes, HookErr, Node), 10),
        ejabberd_hooks:delete(HookErr, Server, 
                              disco_error(HookRes, HookErr, Node), 10)
    end.

-spec disco_info(state()) -> ok.

disco_info(StateData) -> 
    disco_info(StateData, <<"::">>),
    disco_info(StateData, <<":bare:">>).

-spec disco_info(state(), binary()) -> ok.

disco_info(StateData, Sep) ->
    lists:foreach(fun({Ns, _FilterAttr}) ->
                    Id = randoms:get_string(),
                    Node = << ?NS_DELEGATION/binary, Sep/binary, Ns/binary >>,

                    HookRes = hook_name(<<"iq_result">>, Id),
                    HookErr = hook_name(<<"iq_error">>, Id),
                
                    FunRes = disco_result(HookRes, HookErr, Node),
                    FunErr = disco_error(HookRes, HookErr, Node),

                    ejabberd_hooks:add(HookRes, ?MYNAME, FunRes, 10),
                    ejabberd_hooks:add(HookErr, ?MYNAME, FunErr, 10),

                    Tag = #xmlel{name = <<"query">>,
                                 attrs = [{<<"xmlns">>, ?NS_DISCO_INFO}, 
                                          {<<"node">>, Node}],
                                 children = []},
                    DiscoReq = #xmlel{name = <<"iq">>,
                                      attrs = [{<<"type">>, <<"get">>}, {<<"id">>, Id},
                                               {<<"from">>, ?MYNAME},
                                               {<<"to">>, StateData#state.host }],
                                      children = [Tag]},
                    ejabberd_service:send_element(StateData, DiscoReq)

              end, StateData#state.delegations).


disco_features(Acc, Bare) ->
    case check_tab(delegated_namespaces) of
        true ->
            Fun = fun(Feat) ->
                      ets:foldl(fun({Ns, _Pid, _, _}, A) ->  
                                    (A or str:prefix(Ns, Feat))
                                end, false, delegated_namespaces)
                  end,
            % delete feature namespace which is delegated to service
            Features =
              lists:filter(fun ({{Feature, _Host}}) ->
                                 not Fun(Feature);
                               (Feature) when is_binary(Feature) ->
                                 not Fun(Feature)
                           end, Acc),
            % add service features
            FeaturesList =
              ets:foldl(fun({_Ns, _Pid, {Feats, _, _}, {FeatsBare, _}}, A) ->
                          if
                            Bare -> A ++ FeatsBare;
                            true -> A ++ Feats
                          end
                        end, Features, delegated_namespaces),
            {result, FeaturesList};
        _ ->
            {result, Acc}
    end.

disco_identity(Acc, Bare) ->
    case check_tab(delegated_namespaces) of
      true ->
        % filter delegated identites
        Fun = fun(Ident) ->
                ets:foldl(fun({_, _, {_ , I, _}, {_ , IBare}}, A) ->
                            Identity = 
                              if
                                Bare -> IBare;
                                true -> I
                              end,
                            (fxml:get_attr_s(<<"category">> , Ident) ==
                             fxml:get_attr_s(<<"category">>, Identity)) and
                            (fxml:get_attr_s(<<"type">> , Ident) ==
                             fxml:get_attr_s(<<"type">>, Identity)) or A
                          end, false, delegated_namespaces)
              end,

        Identities =
          lists:filter(fun (#xmlel{attrs = Attrs}) ->
                          not Fun(Attrs)
                       end, Acc),
        % add service features
        ets:foldl(fun({_, _, {_, I, _}, {_, IBare}}, A) ->
                        if
                          Bare -> A ++ IBare;
                          true -> A ++ I
                        end
                  end, Identities, delegated_namespaces);
      _ ->
        Acc
    end.
%% return xmlns from value element

-spec get_field_value([xmlel()]) -> binary().

get_field_value([]) -> <<"">>;
get_field_value([Elem| Elems]) ->
    Ns = fxml:get_subtag_cdata(Elem, <<"value">>),
    case (fxml:get_attr_s(<<"var">>, Elem#xmlel.attrs) == <<"FORM_TYPE">>) and
         (fxml:get_attr_s(<<"type">>, Elem#xmlel.attrs) == <<"hidden">>) and 
         (Ns /= <<"">>) of
      true -> Ns;
      _ -> get_field_value(Elems)
end.

get_info(Acc) ->
    Fun = fun(Feat) ->
            ets:foldl(fun({Ns, _, _, _}, A) ->  
                        (A or str:prefix(Ns, Feat))
                      end, false, delegated_namespaces)
          end, 
    Exten =
      lists:filter(fun(Xmlel) ->
                     Tags = fxml:get_subtags(Xmlel, <<"field">>),
                     Value = get_field_value(Tags),
                     case Value of
                       <<"">> -> true;
                       _ -> not Fun(Value)
                     end
                   end, Acc),

    ets:foldl(fun({_, _, {_, _, Ext}, _}, A) ->
                A ++ Ext
              end, Exten, delegated_namespaces).

%% 7.2.1 General Case

disco_local_features({error, _Error} = Acc, _From, _To, _Node, _Lang) ->
    Acc;
disco_local_features(Acc, _From, _To, <<>>, _Lang) ->
    FeatsOld = case Acc of
                 {result, I} -> I;
                 _ -> []
               end,
    disco_features(FeatsOld, false);
disco_local_features(Acc, _From, _To, _Node, _Lang) ->
    Acc.

disco_local_identity(Acc, _From, _To, <<>>, _Lang) ->
    disco_identity(Acc, false);
disco_local_identity(Acc, _From, _To, _Node, _Lang) ->
    Acc.

%% 7.2.2 Rediction Of Bare JID Disco Info

disco_sm_features({error, _Error} = Acc, _From, _To, _Node, _Lang) ->
    Acc;
disco_sm_features(Acc, _From, #jid{lresource = <<"">>}, _Node, _Lang) ->
    FeatsOld = case Acc of
                 {result, I} -> I;
                 _ -> []
               end,
    disco_features(FeatsOld, true);
disco_sm_features(Acc, _From, _To, _Node, _Lang) ->
    Acc.

disco_sm_identity(Acc, _From, #jid{lresource = <<"">>}, _Node, _Lang) ->
    disco_identity(Acc, true);
disco_sm_identity(Acc, _From, _To, _Node, _Lang) ->
    Acc.

disco_info(Acc, _Host, _Mod, _Node, _Lang) ->
    get_info(Acc).

%%%--------------------------------------------------------------------------------------
%%%  7. Client mode
%%%--------------------------------------------------------------------------------------