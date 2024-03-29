%%%----------------------------------------------------------------------
%%% File    : ejabberd_s2s_out.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Manage outgoing server-to-server connections
%%% Created :  6 Dec 2002 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2010   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(ejabberd_s2s_out).
-author('alexey@process-one.net').

-behaviour(p1_fsm).

%% External exports
-export([start/3,
	 start_link/3,
	 start_connection/1,
	 terminate_if_waiting_delay/2,
	 stop_connection/1,
	 stop_connection/2]).

%% p1_fsm callbacks (same as gen_fsm)
-export([init/1,
	 open_socket/2,
	 wait_for_stream/2,
	 wait_for_validation/2,
	 wait_for_features/2,
	 wait_for_auth_result/2,
	 wait_for_starttls_proceed/2,
	 reopen_socket/2,
	 wait_before_retry/2,
	 stream_established/2,
	 handle_event/3,
	 handle_sync_event/4,
	 handle_info/3,
	 terminate/3,
	 code_change/4,
	 print_state/1,
	 test_get_addr_port/1,
	 get_addr_port/1]).

-include_lib("exmpp/include/exmpp.hrl").

-include("ejabberd.hrl").

-record(state, {socket,
		streamid,
		use_v10,
		tls = false,
		tls_required = false,
		tls_enabled = false,
		tls_options = [],
		authenticated = false,
		db_enabled = true,
		try_auth = true,
		myname, server, queue,
		delay_to_retry = undefined_delay,
		new = false, verify = false,
		timer}).

%-define(DBGFSM, true).

-ifdef(DBGFSM).
-define(FSMOPTS, [{debug, [trace]}]).
-else.
-define(FSMOPTS, []).
-endif.

%% Module start with or without supervisor:
-ifdef(NO_TRANSIENT_SUPERVISORS).
-define(SUPERVISOR_START, rpc:call(Node, p1_fsm, start,
				   [ejabberd_s2s_out, [From, Host, Type],
				    fsm_limit_opts() ++ ?FSMOPTS])).
-else.
-define(SUPERVISOR_START, supervisor:start_child({ejabberd_s2s_out_sup, Node},
						 [From, Host, Type])).
-endif.

-define(FSMTIMEOUT, 30000).

%% We do not block on send anymore.
-define(TCP_SEND_TIMEOUT, 15000).

%% Maximum delay to wait before retrying to connect after a failed attempt.
%% Specified in miliseconds. Default value is 5 minutes.
-define(MAX_RETRY_DELAY, 300000).

% These are the namespace already declared by the stream opening. This is
% used at serialization time.
-define(DEFAULT_NS, ?NS_JABBER_SERVER).
-define(PREFIXED_NS,
        [{?NS_XMPP, ?NS_XMPP_pfx}, {?NS_DIALBACK, ?NS_DIALBACK_pfx}]).


-define(SOCKET_DEFAULT_RESULT, {error, badarg}).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(From, Host, Type) ->
    Node = ejabberd_cluster:get_node({From, Host}),
    ?SUPERVISOR_START.

start_link(From, Host, Type) ->
    p1_fsm:start_link(ejabberd_s2s_out, [From, Host, Type],
		      fsm_limit_opts() ++ ?FSMOPTS).

start_connection(Pid) ->
    p1_fsm:send_event(Pid, init).

stop_connection(Pid) ->
    p1_fsm:send_event(Pid, closed).

stop_connection(Pid, Timeout) ->
    p1_fsm:send_all_state_event(Pid, {closed, Timeout}).

%%%----------------------------------------------------------------------
%%% Callback functions from p1_fsm
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}          |
%%          {ok, StateName, StateData, Timeout} |
%%          ignore                              |
%%          {stop, StopReason}
%%----------------------------------------------------------------------
init([From, Server, Type]) ->
    process_flag(trap_exit, true),
    ?DEBUG("started: ~p", [{From, Server, Type}]),
    TLS = case ejabberd_config:get_local_option(s2s_use_starttls) of
	      undefined ->
		  false;
	      UseStartTLS ->
		  UseStartTLS
	  end,
    UseV10 = TLS,
    TLSOpts = case ejabberd_config:get_local_option(s2s_certfile) of
		  undefined ->
		      [];
		  CertFile ->
		      [{certfile, CertFile}, connect]
	      end,
    {New, Verify} = case Type of
			{new, Key} ->
			    {Key, false};
			{verify, Pid, Key, SID} ->
			    start_connection(self()),
			    {false, {Pid, Key, SID}}
		    end,
    Timer = erlang:start_timer(?S2STIMEOUT, self(), []),
    {ok, open_socket, #state{use_v10 = UseV10,
			     tls = TLS,
			     tls_options = TLSOpts,
			     queue = queue:new(),
			     myname = From,
			     server = Server,
			     new = New,
			     verify = Verify,
			     timer = Timer}}.

%%----------------------------------------------------------------------
%% Func: StateName/2
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------
open_socket(init, StateData) ->
    log_s2s_out(StateData#state.new,
		StateData#state.myname,
		StateData#state.server,
		StateData#state.tls),
    ?DEBUG("open_socket: ~p", [{StateData#state.myname,
				StateData#state.server,
				StateData#state.new,
				StateData#state.verify}]),
    AddrList = case idna:domain_utf8_to_ascii(StateData#state.server) of
		   false -> [];
		   ASCIIAddr ->
		       get_addr_port(ASCIIAddr)
	       end,
    case lists:foldl(fun({Addr, Port}, Acc) ->
			     case Acc of
				 {ok, Socket} ->
				     {ok, Socket};
				 _ ->
				     open_socket1(Addr, Port)
			     end
		     end, ?SOCKET_DEFAULT_RESULT, AddrList) of
	{ok, Socket} ->
	    Version = if
			  StateData#state.use_v10 ->
			      "1.0";
			  true ->
			      ""
		      end,
	    NewStateData = StateData#state{socket = Socket,
					   tls_enabled = false,
					   streamid = new_id()},
	    Opening = exmpp_stream:opening(
	      StateData#state.server,
	      ?NS_JABBER_SERVER,
	      Version),
	    send_element(NewStateData,
	      exmpp_stream:set_dialback_support(Opening)),
	    {next_state, wait_for_stream, NewStateData, ?FSMTIMEOUT};
	{error, _Reason} ->
	    ?INFO_MSG("s2s connection: ~s -> ~s (remote server not found)",
		      [StateData#state.myname, StateData#state.server]),
	    wait_before_reconnect(StateData)
	    %%{stop, normal, StateData}
    end;
open_socket(stop, StateData) ->
    ?INFO_MSG("s2s connection: ~s -> ~s (stopped in open socket)",
	      [StateData#state.myname, StateData#state.server]),
    {stop, normal, StateData};
open_socket(timeout, StateData) ->
    ?INFO_MSG("s2s connection: ~s -> ~s (timeout in open socket)",
	      [StateData#state.myname, StateData#state.server]),
    {stop, normal, StateData};
open_socket(_, StateData) ->
    {next_state, open_socket, StateData}.

%%----------------------------------------------------------------------
%% IPv4
open_socket1({_,_,_,_} = Addr, Port) ->
    open_socket2(inet, Addr, Port);

%% IPv6
open_socket1({_,_,_,_,_,_,_,_} = Addr, Port) ->
    open_socket2(inet6, Addr, Port);

%% Hostname
open_socket1(Host, Port) ->
    lists:foldl(fun(_Family, {ok, _Socket} = R) ->
			R;
		   (Family, _) ->
			Addrs = get_addrs(Host, Family),
			lists:foldl(fun(_Addr, {ok, _Socket} = R) ->
					    R;
				       (Addr, _) ->
					    open_socket1(Addr, Port)
				    end, ?SOCKET_DEFAULT_RESULT, Addrs)
		end, ?SOCKET_DEFAULT_RESULT, outgoing_s2s_families()).

open_socket2(Type, Addr, Port) ->
    ?DEBUG("s2s_out: connecting to ~p:~p~n", [Addr, Port]),
    Timeout = outgoing_s2s_timeout(),
    SockOpts = case erlang:system_info(otp_release) >= "R13B" of
	true -> [{send_timeout_close, true}];
	false -> []
    end,
    IpOpts = get_outgoing_local_address_opts(Type),
    case (catch ejabberd_socket:connect(Addr, Port,
					[binary, {packet, 0},
					 {send_timeout, ?TCP_SEND_TIMEOUT},
					 {active, false}, Type | SockOpts]++IpOpts,
					Timeout)) of
	{ok, _Socket} = R -> R;
	{error, Reason} = R ->
	    ?DEBUG("s2s_out: connect return ~p~n", [Reason]),
	    R;
	{'EXIT', Reason} ->
	    ?DEBUG("s2s_out: connect crashed ~p~n", [Reason]),
	    {error, Reason}
    end.

get_outgoing_local_address_opts(DestType) ->
    ListenerIp = get_incoming_local_address(),
    OutLocalIp = case ejabberd_config:get_local_option(
			outgoing_s2s_local_address) of
		     undefined -> undefined;
		     T when is_tuple(T) ->
			 T;
		     S when is_list(S) ->
			 [S2 | _] = string:tokens(S, "/"),
			 {ok, T} = inet_parse:address(S2),
			 T
		 end,
    case {OutLocalIp, ListenerIp, DestType} of
	{{_, _, _, _}, _, inet} ->
	    [{ip, OutLocalIp}];
	{{_, _, _, _, _, _, _, _}, _, inet6} ->
	    [{ip, OutLocalIp}];
	{undefined, any, _} ->
	    [];
	{undefined, _, _} ->
	    [{ip, ListenerIp}];
	_ ->
	    []
    end.

get_incoming_local_address() ->
    Ports = ejabberd_config:get_local_option(listen),
    case [IP || {{_Port, IP, _Prot}, ejabberd_s2s_in, _Opts} <- Ports] of
	[{0, 0, 0, 0}] -> any;
	[{0, 0, 0, 0, 0, 0, 0, 0}] -> any;
	[IP] -> IP;
	_ -> any
    end.

%%----------------------------------------------------------------------


wait_for_stream({xmlstreamstart, Opening}, StateData) ->
    case {exmpp_stream:get_default_ns(Opening),
	  exmpp_xml:is_ns_declared_here(Opening, ?NS_DIALBACK),
	  exmpp_stream:get_version(Opening) == {1, 0}} of
	{?NS_JABBER_SERVER, true, false} ->
	    send_db_request(StateData);
	{?NS_JABBER_SERVER, true, true} when
	StateData#state.use_v10 ->
	    {next_state, wait_for_features, StateData, ?FSMTIMEOUT};
	{?NS_JABBER_SERVER, false, true} when StateData#state.use_v10 ->
	    {next_state, wait_for_features, StateData#state{db_enabled = false}, ?FSMTIMEOUT};
	{NSProvided, DB, _} ->
	    send_element(StateData, exmpp_stream:error('invalid-namespace')),
	    ?INFO_MSG("Closing s2s connection: ~s -> ~s (invalid namespace).~n"
		      "Namespace provided: ~p~nNamespace expected: \"jabber:server\"~n"
		      "xmlns:db provided: ~p~nFull packet: ~p",
		      [StateData#state.myname, StateData#state.server, NSProvided, DB, Opening]),
	    {stop, normal, StateData}
    end;

wait_for_stream({xmlstreamerror, _}, StateData) ->
    send_element(StateData, exmpp_stream:error('xml-not-well-formed')),
    send_element(StateData, exmpp_stream:closing()),
    ?INFO_MSG("Closing s2s connection: ~s -> ~s (invalid xml)",
	      [StateData#state.myname, StateData#state.server]),
    {stop, normal, StateData};

wait_for_stream({xmlstreamend,_Name}, StateData) ->
    ?INFO_MSG("Closing s2s connection: ~s -> ~s (xmlstreamend)",
	      [StateData#state.myname, StateData#state.server]),
    {stop, normal, StateData};

wait_for_stream(timeout, StateData) ->
    ?INFO_MSG("Closing s2s connection: ~s -> ~s (timeout in wait_for_stream)",
	      [StateData#state.myname, StateData#state.server]),
    {stop, normal, StateData};

wait_for_stream(closed, StateData) ->
    ?INFO_MSG("Closing s2s connection: ~s -> ~s (close in wait_for_stream)",
	      [StateData#state.myname, StateData#state.server]),
    {stop, normal, StateData}.



wait_for_validation({xmlstreamelement, El}, StateData) ->
    case is_verify_res(El) of
	{result, To, From, Id, Type} ->
	    ?DEBUG("recv result: ~p", [{From, To, Id, Type}]),
	    case Type of
		"valid" ->
		    send_queue(StateData, StateData#state.queue),
		    ?INFO_MSG("Connection established: ~s -> ~s with TLS=~p",
			      [StateData#state.myname, StateData#state.server, StateData#state.tls_enabled]),
		    ejabberd_hooks:run(s2s_connect_hook,
				       [StateData#state.myname,
					StateData#state.server]),
		    {next_state, stream_established,
		     StateData#state{queue = queue:new()}};
		_ ->
		    %% TODO: bounce packets
		    ?INFO_MSG("Closing s2s connection: ~s -> ~s (invalid dialback key)",
			      [StateData#state.myname, StateData#state.server]),
		    {stop, normal, StateData}
	    end;
	{verify, To, From, Id, Type} ->
	    ?DEBUG("recv verify: ~p", [{From, To, Id, Type}]),
	    case StateData#state.verify of
		false ->
		    NextState = wait_for_validation,
		    %% TODO: Should'nt we close the connection here ?
		    {next_state, NextState, StateData,
		     get_timeout_interval(NextState)};
		{Pid, _Key, _SID} ->
		    case Type of
			"valid" ->
			    p1_fsm:send_event(
			      Pid, {valid,
				    StateData#state.server,
				    StateData#state.myname});
			_ ->
			    p1_fsm:send_event(
			      Pid, {invalid,
				    StateData#state.server,
				    StateData#state.myname})
		    end,
		    if
			StateData#state.verify == false ->
			    {stop, normal, StateData};
			true ->
			    NextState = wait_for_validation,
			    {next_state, NextState, StateData,
			     get_timeout_interval(NextState)}
		    end
	    end;
	_ ->
	    {next_state, wait_for_validation, StateData, ?FSMTIMEOUT*3}
    end;

wait_for_validation({xmlstreamend, _Name}, StateData) ->
    ?INFO_MSG("wait for validation: ~s -> ~s (xmlstreamend)",
	      [StateData#state.myname, StateData#state.server]),
    {stop, normal, StateData};

wait_for_validation({xmlstreamerror, _}, StateData) ->
    ?INFO_MSG("wait for validation: ~s -> ~s (xmlstreamerror)",
	      [StateData#state.myname, StateData#state.server]),
    send_element(StateData, exmpp_stream:error('xml-not-well-formed')),
    send_element(StateData, exmpp_stream:closing()),
    {stop, normal, StateData};

wait_for_validation(timeout, #state{verify = {VPid, VKey, SID}} = StateData)
  when is_pid(VPid) and is_list(VKey) and is_list(SID) ->
    %% This is an auxiliary s2s connection for dialback.
    %% This timeout is normal and doesn't represent a problem.
    ?DEBUG("wait_for_validation: ~s -> ~s (timeout in verify connection)",
	   [StateData#state.myname, StateData#state.server]),
    {stop, normal, StateData};

wait_for_validation(timeout, StateData) ->
    ?INFO_MSG("wait_for_validation: ~s -> ~s (connect timeout)",
	      [StateData#state.myname, StateData#state.server]),
    {stop, normal, StateData};

wait_for_validation(closed, StateData) ->
    ?INFO_MSG("wait for validation: ~s -> ~s (closed)",
	      [StateData#state.myname, StateData#state.server]),
    {stop, normal, StateData}.


wait_for_features({xmlstreamelement, El}, StateData) ->
    case El of
	#xmlel{ns = ?NS_XMPP, name = 'features'} = Features ->
	    {SASLEXT, StartTLS, StartTLSRequired} =
		lists:foldl(
		  fun(#xmlel{ns = ?NS_SASL, name = 'mechanisms'},
		      {_SEXT, STLS, STLSReq} = Acc) ->
			  try
			      Mechs = exmpp_client_sasl:announced_mechanisms(
				El),
			      NewSEXT = lists:member("EXTERNAL", Mechs),
			      {NewSEXT, STLS, STLSReq}
			  catch
			      _Exception ->
				  Acc
			  end;
		     (#xmlel{ns = ?NS_TLS, name ='starttls'},
		      {SEXT, _STLS, _STLSReq} = Acc) ->
			  try
			      Support = exmpp_client_tls:announced_support(
				El),
			      case Support of
				  none     -> Acc;
				  optional -> {SEXT, true, false};
				  required -> {SEXT, true, true}
			      end
			  catch
			      _Exception ->
				  Acc
			  end;
		     (_, Acc) ->
			  Acc
		  end, {false, false, false}, Features#xmlel.children),
	    if
		(not SASLEXT) and (not StartTLS) and
		StateData#state.authenticated ->
		    send_queue(StateData, StateData#state.queue),
		    ?INFO_MSG("Connection established: ~s -> ~s",
			      [StateData#state.myname, StateData#state.server]),
		    ejabberd_hooks:run(s2s_connect_hook,
				       [StateData#state.myname,
					StateData#state.server]),
		    {next_state, stream_established,
		     StateData#state{queue = queue:new()}};
		SASLEXT and StateData#state.try_auth and
		(StateData#state.new /= false) ->
		    send_element(StateData,
		      exmpp_client_sasl:selected_mechanism("EXTERNAL",
		      StateData#state.myname)),
		    {next_state, wait_for_auth_result,
		     StateData#state{try_auth = false}, ?FSMTIMEOUT};
		StartTLS and StateData#state.tls and
		(not StateData#state.tls_enabled) ->
		    send_element(StateData,
		      exmpp_client_tls:starttls()),
		    {next_state, wait_for_starttls_proceed, StateData,
		     ?FSMTIMEOUT};
		StartTLSRequired and (not StateData#state.tls) ->
		    ?DEBUG("restarted: ~p", [{StateData#state.myname,
					      StateData#state.server}]),
		    ejabberd_socket:close(StateData#state.socket),
		    {next_state, reopen_socket,
		     StateData#state{socket = undefined,
				     use_v10 = false}, ?FSMTIMEOUT};
		StateData#state.db_enabled ->
		    send_db_request(StateData);
		true ->
		    ?DEBUG("restarted: ~p", [{StateData#state.myname,
					      StateData#state.server}]),
						% TODO: clear message queue
		    ejabberd_socket:close(StateData#state.socket),
		    {next_state, reopen_socket, StateData#state{socket = undefined,
								use_v10 = false}, ?FSMTIMEOUT}
	    end;
	_ ->
	    send_element(StateData, exmpp_stream:error('bad-format')),
	    send_element(StateData, exmpp_stream:closing()),
	    ?INFO_MSG("Closing s2s connection: ~s -> ~s (bad format)",
		      [StateData#state.myname, StateData#state.server]),
	    {stop, normal, StateData}
    end;

wait_for_features({xmlstreamend, _Name}, StateData) ->
    ?INFO_MSG("wait_for_features: xmlstreamend", []),
    {stop, normal, StateData};

wait_for_features({xmlstreamerror, _}, StateData) ->
    send_element(StateData, exmpp_stream:error('xml-not-well-formed')),
    send_element(StateData, exmpp_stream:closing()),
    ?INFO_MSG("wait for features: xmlstreamerror", []),
    {stop, normal, StateData};

wait_for_features(timeout, StateData) ->
    ?INFO_MSG("wait for features: timeout", []),
    {stop, normal, StateData};

wait_for_features(closed, StateData) ->
    ?INFO_MSG("wait for features: closed", []),
    {stop, normal, StateData}.


wait_for_auth_result({xmlstreamelement, El}, StateData) ->
    case El of
	#xmlel{ns = ?NS_SASL, name = 'success'} ->
	    ?DEBUG("auth: ~p", [{StateData#state.myname,
				 StateData#state.server}]),
	    ejabberd_socket:reset_stream(StateData#state.socket),
	    Opening = exmpp_stream:opening(
	      StateData#state.server,
	      ?NS_JABBER_SERVER,
	      "1.0"),
	    send_element(StateData,
	      exmpp_stream:set_dialback_support(Opening)),
	    {next_state, wait_for_stream,
	     StateData#state{streamid = new_id(),
			     authenticated = true
			    }, ?FSMTIMEOUT};
	#xmlel{ns = ?NS_SASL, name = 'failure'} ->
	    ?DEBUG("restarted: ~p", [{StateData#state.myname,
				      StateData#state.server}]),
	    ejabberd_socket:close(StateData#state.socket),
	    {next_state, reopen_socket,
	     StateData#state{socket = undefined}, ?FSMTIMEOUT};
	_ ->
	    send_element(StateData, exmpp_stream:error('bad-format')),
	    send_element(StateData, exmpp_stream:closing()),
	    ?INFO_MSG("Closing s2s connection: ~s -> ~s (bad format)",
		      [StateData#state.myname, StateData#state.server]),
	    {stop, normal, StateData}
    end;

wait_for_auth_result({xmlstreamend, _Name}, StateData) ->
    ?INFO_MSG("wait for auth result: xmlstreamend", []),
    {stop, normal, StateData};

wait_for_auth_result({xmlstreamerror, _}, StateData) ->
    send_element(StateData, exmpp_stream:error('xml-not-well-formed')),
    send_element(StateData, exmpp_stream:closing()),
    ?INFO_MSG("wait for auth result: xmlstreamerror", []),
    {stop, normal, StateData};

wait_for_auth_result(timeout, StateData) ->
    ?INFO_MSG("wait for auth result: timeout", []),
    {stop, normal, StateData};

wait_for_auth_result(closed, StateData) ->
    ?INFO_MSG("wait for auth result: closed", []),
    {stop, normal, StateData}.


wait_for_starttls_proceed({xmlstreamelement, El}, StateData) ->
    case El of
	#xmlel{ns = ?NS_TLS, name = 'proceed'} ->
	    ?DEBUG("starttls: ~p", [{StateData#state.myname,
				     StateData#state.server}]),
	    Socket = StateData#state.socket,
	    TLSOpts = case ejabberd_config:get_local_option
                          ({domain_certfile, StateData#state.server}) of
			  undefined ->
			      StateData#state.tls_options;
			  CertFile ->
			      [{certfile, CertFile} |
			       lists:keydelete(
				 certfile, 1,
				 StateData#state.tls_options)]
		      end,
	    TLSSocket = ejabberd_socket:starttls(Socket, TLSOpts),
	    NewStateData = StateData#state{socket = TLSSocket,
					   streamid = new_id(),
					   tls_enabled = true
					  },
	    Opening = exmpp_stream:opening(
	      StateData#state.server,
	      ?NS_JABBER_SERVER,
	      "1.0"),
	    send_element(NewStateData,
	      exmpp_stream:set_dialback_support(Opening)),
	    {next_state, wait_for_stream, NewStateData, ?FSMTIMEOUT};
	_ ->
	    send_element(StateData, exmpp_stream:error('bad-format')),
	    send_element(StateData, exmpp_stream:closing()),
	    ?INFO_MSG("Closing s2s connection: ~s -> ~s (bad format)",
		      [StateData#state.myname, StateData#state.server]),
	    {stop, normal, StateData}
    end;

wait_for_starttls_proceed({xmlstreamend, _Name}, StateData) ->
    ?INFO_MSG("wait for starttls proceed: xmlstreamend", []),
    {stop, normal, StateData};

wait_for_starttls_proceed({xmlstreamerror, _}, StateData) ->
    send_element(StateData, exmpp_stream:error('xml-not-well-formed')),
    send_element(StateData, exmpp_stream:closing()),
    ?INFO_MSG("wait for starttls proceed: xmlstreamerror", []),
    {stop, normal, StateData};

wait_for_starttls_proceed(timeout, StateData) ->
    ?INFO_MSG("wait for starttls proceed: timeout", []),
    {stop, normal, StateData};

wait_for_starttls_proceed(closed, StateData) ->
    ?INFO_MSG("wait for starttls proceed: closed", []),
    {stop, normal, StateData}.


reopen_socket({xmlstreamelement, _El}, StateData) ->
    {next_state, reopen_socket, StateData, ?FSMTIMEOUT};
reopen_socket({xmlstreamend, _Name}, StateData) ->
    {next_state, reopen_socket, StateData, ?FSMTIMEOUT};
reopen_socket({xmlstreamerror, _}, StateData) ->
    {next_state, reopen_socket, StateData, ?FSMTIMEOUT};
reopen_socket(timeout, StateData) ->
    ?INFO_MSG("reopen socket: timeout", []),
    {stop, normal, StateData};
reopen_socket(closed, StateData) ->
    p1_fsm:send_event(self(), init),
    {next_state, open_socket, StateData, ?FSMTIMEOUT}.

%% This state is use to avoid reconnecting to often to bad sockets
wait_before_retry(_Event, StateData) ->
    {next_state, wait_before_retry, StateData, ?FSMTIMEOUT}.

stream_established({xmlstreamelement, El}, StateData) ->
    ?DEBUG("s2S stream established", []),
    case is_verify_res(El) of
	{verify, VTo, VFrom, VId, VType} ->
	    ?DEBUG("recv verify: ~p", [{VFrom, VTo, VId, VType}]),
	    case StateData#state.verify of
		{VPid, _VKey, _SID} ->
		    case VType of
			"valid" ->
			    p1_fsm:send_event(
			      VPid, {valid,
				     StateData#state.server,
				     StateData#state.myname});
			_ ->
			    p1_fsm:send_event(
			      VPid, {invalid,
				     StateData#state.server,
				     StateData#state.myname})
		    end;
		_ ->
		    ok
	    end;
	_ ->
	    ok
    end,
    {next_state, stream_established, StateData};

stream_established({xmlstreamend, _Name}, StateData) ->
    ?INFO_MSG("Connection closed in stream established: ~s -> ~s (xmlstreamend)",
	      [StateData#state.myname, StateData#state.server]),
    {stop, normal, StateData};

stream_established({xmlstreamerror, _}, StateData) ->
    send_element(StateData, exmpp_stream:error('xml-not-well-formed')),
    send_element(StateData, exmpp_stream:closing()),
    ?INFO_MSG("stream established: ~s -> ~s (xmlstreamerror)",
	      [StateData#state.myname, StateData#state.server]),
    {stop, normal, StateData};

stream_established(timeout, StateData) ->
    ?INFO_MSG("stream established: ~s -> ~s (timeout)",
	      [StateData#state.myname, StateData#state.server]),
    {stop, normal, StateData};

stream_established(closed, StateData) ->
    ?INFO_MSG("stream established: ~s -> ~s (closed)",
	      [StateData#state.myname, StateData#state.server]),
    {stop, normal, StateData}.



%%----------------------------------------------------------------------
%% Func: StateName/3
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}
%%----------------------------------------------------------------------
%%state_name(Event, From, StateData) ->
%%    Reply = ok,
%%    {reply, Reply, state_name, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_event/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------
handle_event({closed, Timeout}, StateName, StateData) ->
    p1_fsm:send_event_after(Timeout, closed),
    {next_state, StateName, StateData};
handle_event(_Event, StateName, StateData) ->
    {next_state, StateName, StateData, get_timeout_interval(StateName)}.

%%----------------------------------------------------------------------
%% Func: handle_sync_event/4
%% Returns: The associated StateData for this connection
%%   {reply, Reply, NextStateName, NextStateData}
%%   Reply = {state_infos, [{InfoName::atom(), InfoValue::any()]
%%----------------------------------------------------------------------
handle_sync_event(get_state_infos, _From, StateName, StateData) ->
    {Addr,Port} = try ejabberd_socket:peername(StateData#state.socket) of
		      {ok, {A,P}} ->  {A,P};
		      {error, _} -> {unknown,unknown}
		  catch
		      _:_ ->
			  {unknown,unknown}
		  end,
    Infos = [{direction, out},
	     {statename, StateName},
	     {addr, Addr},
	     {port, Port},
	     {streamid, StateData#state.streamid},
	     {use_v10, StateData#state.use_v10},
	     {tls, StateData#state.tls},
	     {tls_required, StateData#state.tls_required},
	     {tls_enabled, StateData#state.tls_enabled},
	     {tls_options, StateData#state.tls_options},
	     {authenticated, StateData#state.authenticated},
	     {db_enabled, StateData#state.db_enabled},
	     {try_auth, StateData#state.try_auth},
	     {myname, StateData#state.myname},
	     {server, StateData#state.server},
	     {delay_to_retry, StateData#state.delay_to_retry},
	     {verify, StateData#state.verify}
	    ],
    Reply = {state_infos, Infos},
    {reply,Reply,StateName,StateData};

%%----------------------------------------------------------------------
%% Func: handle_sync_event/4
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}
%%----------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, StateData) ->
    Reply = ok,
    {reply, Reply, StateName, StateData, get_timeout_interval(StateName)}.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_info/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------
handle_info({send_text, Text}, StateName, StateData) ->
    send_text(StateData, Text),
    cancel_timer(StateData#state.timer),
    Timer = erlang:start_timer(?S2STIMEOUT, self(), []),
    {next_state, StateName, StateData#state{timer = Timer},
     get_timeout_interval(StateName)};

handle_info({send_element, El}, StateName, StateData) ->
    case StateName of
	stream_established ->
	    cancel_timer(StateData#state.timer),
	    Timer = erlang:start_timer(?S2STIMEOUT, self(), []),
	    send_element(StateData, El),
	    {next_state, StateName, StateData#state{timer = Timer}};
	%% In this state we bounce all message: We are waiting before
	%% trying to reconnect
	wait_before_retry ->
	    bounce_element(El, 'remote-server-not-found'),
	    {next_state, StateName, StateData};
	_ ->
	    Q = queue:in(El, StateData#state.queue),
	    {next_state, StateName, StateData#state{queue = Q},
	     get_timeout_interval(StateName)}
    end;

handle_info({timeout, Timer, _}, wait_before_retry,
	    #state{timer = Timer} = StateData) ->
    ?INFO_MSG("Reconnect delay expired: Will now retry to connect to ~s when needed.", [StateData#state.server]),
    {stop, normal, StateData};

handle_info({timeout, Timer, _}, _StateName,
	    #state{timer = Timer} = StateData) ->
    ?INFO_MSG("Closing connection with ~s: timeout", [StateData#state.server]),
    {stop, normal, StateData};

handle_info(terminate_if_waiting_before_retry, wait_before_retry, StateData) ->
    {stop, normal, StateData};

handle_info(terminate_if_waiting_before_retry, StateName, StateData) ->
    {next_state, StateName, StateData, get_timeout_interval(StateName)};

handle_info(_, StateName, StateData) ->
    {next_state, StateName, StateData, get_timeout_interval(StateName)}.

%%----------------------------------------------------------------------
%% Func: terminate/3
%% Purpose: Shutdown the fsm
%% Returns: any
%%----------------------------------------------------------------------
terminate(Reason, StateName, StateData) ->
    ?DEBUG("terminated: ~p", [{Reason, StateName}]),
    case StateData#state.new of
	false ->
	    ok;
	Key ->
	    ejabberd_s2s:remove_connectio
              ({StateData#state.myname, StateData#state.server}, self(), Key)
    end,
    %% bounce queue manage by process and Erlang message queue
    bounce_queue(StateData#state.queue, 'remote-server-not-found'),
    bounce_messages('remote-server-not-found'),
    case StateData#state.socket of
	undefined ->
	    ok;
	_Socket ->
	    ejabberd_socket:close(StateData#state.socket)
    end,
    ok.

%%----------------------------------------------------------------------
%% Func: print_state/1
%% Purpose: Prepare the state to be printed on error log
%% Returns: State to print
%%----------------------------------------------------------------------
print_state(State) ->
   State.
%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

send_text(StateData, Text) ->
    ejabberd_socket:send(StateData#state.socket, Text).

send_element(StateData, #xmlel{ns = ?NS_XMPP, name = 'stream'} = El) ->
    send_text(StateData, exmpp_stream:to_iolist(El));
send_element(StateData, El) ->
    send_text(StateData, exmpp_stanza:to_iolist(El)).

send_queue(StateData, Q) ->
    case queue:out(Q) of
	{{value, El}, Q1} ->
	    send_element(StateData, El),
	    send_queue(StateData, Q1);
	{empty, _Q1} ->
	    ok
    end.

%% Bounce a single message (xmlel)
bounce_element(El, Condition) ->
    case exmpp_stanza:get_type(El) of
	<<"error">> -> ok;
	<<"result">> -> ok;
	_ ->
	    Err = exmpp_stanza:reply_with_error(El, Condition),
	    From = exmpp_jid:parse(exmpp_stanza:get_sender(El)),
	    To = exmpp_jid:parse(exmpp_stanza:get_recipient(El)),
	    % No namespace conversion (:server <-> :client) is done.
	    % This is handled by C2S and S2S send_element functions.
	    ejabberd_router:route(To, From, Err)
    end.

bounce_queue(Q, Condition) ->
    case queue:out(Q) of
	{{value, El}, Q1} ->
	    bounce_element(El, Condition),
	    bounce_queue(Q1, Condition);
	{empty, _} ->
	    ok
    end.

new_id() ->
    randoms:get_string().

cancel_timer(Timer) ->
    erlang:cancel_timer(Timer),
    receive
	{timeout, Timer, _} ->
	    ok
    after 0 ->
	    ok
    end.

bounce_messages(Condition) ->
    receive
	{send_element, El} ->
	    bounce_element(El, Condition),
	    bounce_messages(Condition)
    after 0 ->
	    ok
    end.


send_db_request(StateData) ->
    Server = StateData#state.server,
    New = case StateData#state.new of
	      false ->
		  case ejabberd_s2s:try_register
                      ({StateData#state.myname, Server}) of
		      {key, Key} ->
			  Key;
		      false ->
			  false
		  end;
	      Key ->
		  Key
	  end,
    NewStateData = StateData#state{new = New},
    try
	case New of
	    false ->
		ok;
	    Key1 ->
		send_element(StateData, exmpp_dialback:key(
					  StateData#state.myname, Server, Key1))
	end,
	case StateData#state.verify of
	    false ->
		ok;
	    {_Pid, Key2, SID} ->
		send_element(StateData, exmpp_dialback:verify_request(
					  StateData#state.myname,
					  StateData#state.server, SID, Key2))
	end,
	{next_state, wait_for_validation, NewStateData, ?FSMTIMEOUT*6}
    catch
	_:_ ->
	    {stop, normal, NewStateData}
    end.


is_verify_res(#xmlel{ns = ?NS_DIALBACK, name = 'result',
  attrs = Attrs}) ->
    {result,
     exmpp_stanza:get_recipient_from_attrs(Attrs),
     exmpp_stanza:get_sender_from_attrs(Attrs),
     exmpp_stanza:get_id_from_attrs(Attrs),
     binary_to_list(exmpp_stanza:get_type_from_attrs(Attrs))};
is_verify_res(#xmlel{ns = ?NS_DIALBACK, name = 'verify',
  attrs = Attrs}) ->
    {verify,
     exmpp_stanza:get_recipient_from_attrs(Attrs),
     exmpp_stanza:get_sender_from_attrs(Attrs),
     exmpp_stanza:get_id_from_attrs(Attrs),
     binary_to_list(exmpp_stanza:get_type_from_attrs(Attrs))};
is_verify_res(_) ->
    false.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% SRV support

-include_lib("kernel/include/inet.hrl").

get_addr_port(Server) ->
    Res = srv_lookup(Server),
    case Res of
	{error, Reason} ->
	    ?DEBUG("srv lookup of '~s' failed: ~p~n", [Server, Reason]),
	    [{Server, outgoing_s2s_port()}];
	{ok, HEnt} ->
	    ?DEBUG("srv lookup of '~s': ~p~n",
		   [Server, HEnt#hostent.h_addr_list]),
	    AddrList = HEnt#hostent.h_addr_list,
		    %% Probabilities are not exactly proportional to weights
		    %% for simplicity (higher weigths are overvalued)
		    {A1, A2, A3} = now(),
		    random:seed(A1, A2, A3),
		    case (catch lists:map(
				  fun({Priority, Weight, Port, Host}) ->
					  N = case Weight of
						  0 -> 0;
						  _ -> (Weight + 1) * random:uniform()
					      end,
					  {Priority * 65536 - N, Host, Port}
				  end, AddrList)) of
			{'EXIT', _Reason} ->
			    [{Server, outgoing_s2s_port()}];
			SortedList ->
			    List = lists:map(
				     fun({_, Host, Port}) ->
					     {Host, Port}
				     end, lists:keysort(1, SortedList)),
			    ?DEBUG("srv lookup of '~s': ~p~n", [Server, List]),
			    List
	    end
    end.

srv_lookup(Server) ->
    Options = case ejabberd_config:get_local_option(s2s_dns_options) of
                  L when is_list(L) -> L;
                  _ -> []
              end,
    TimeoutMs = timer:seconds(proplists:get_value(timeout, Options, 10)),
    Retries = proplists:get_value(retries, Options, 2),
    srv_lookup(Server, TimeoutMs, Retries).

%% XXX - this behaviour is suboptimal in the case that the domain
%% has a "_xmpp-server._tcp." but not a "_jabber._tcp." record and
%% we don't get a DNS reply for the "_xmpp-server._tcp." lookup. In this
%% case we'll give up when we get the "_jabber._tcp." nxdomain reply.
srv_lookup(_Server, _Timeout, Retries) when Retries < 1 ->
    {error, timeout};
srv_lookup(Server, Timeout, Retries) ->
    case inet_res:getbyname("_xmpp-server._tcp." ++ Server, srv, Timeout) of
        {error, _Reason} ->
            case inet_res:getbyname("_jabber._tcp." ++ Server, srv, Timeout) of
                {error, timeout} ->
                    ?ERROR_MSG("The DNS servers~n  ~p~ntimed out on request"
			       " for ~p IN SRV."
			       " You should check your DNS configuration.",
                               [inet_db:res_option(nameserver), Server]),
                    srv_lookup(Server, Timeout, Retries - 1);
                R -> R
            end;
        {ok, _HEnt} = R -> R
    end.

test_get_addr_port(Server) ->
    lists:foldl(
      fun(_, Acc) ->
	      [HostPort | _] = get_addr_port(Server),
	      case lists:keysearch(HostPort, 1, Acc) of
		  false ->
		      [{HostPort, 1} | Acc];
		  {value, {_, Num}} ->
		      lists:keyreplace(HostPort, 1, Acc, {HostPort, Num + 1})
	      end
      end, [], lists:seq(1, 100000)).

get_addrs(Host, Family) ->
    Type = case Family of
	       inet4 -> inet;
	       ipv4 -> inet;
	       inet6 -> inet6;
	       ipv6 -> inet6
	   end,
    case inet:gethostbyname(Host, Type) of
	{ok, #hostent{h_addr_list = Addrs}} ->
	    ?DEBUG("~s of ~s resolved to: ~p~n", [Type, Host, Addrs]),
	    Addrs;
	{error, Reason} ->
	    ?DEBUG("~s lookup of '~s' failed: ~p~n", [Type, Host, Reason]),
	    []
    end.


outgoing_s2s_port() ->
    case ejabberd_config:get_local_option(outgoing_s2s_port) of
	Port when is_integer(Port) ->
	    Port;
	undefined ->
	    5269
    end.

outgoing_s2s_families() ->
    case ejabberd_config:get_local_option(outgoing_s2s_options) of
	{Families, _} when is_list(Families) ->
	    Families;
	undefined ->
	    %% DISCUSSION: Why prefer IPv4 first?
	    %%
	    %% IPv4 connectivity will be available for everyone for
	    %% many years to come. So, there's absolutely no benefit
	    %% in preferring IPv6 connections which are flaky at best
	    %% nowadays.
	    %%
	    %% On the other hand content providers hesitate putting up
	    %% AAAA records for their sites due to the mentioned
	    %% quality of current IPv6 connectivity. Making IPv6 the a
	    %% `fallback' may avoid these problems elegantly.
	    [ipv4, ipv6]
    end.

outgoing_s2s_timeout() ->
    case ejabberd_config:get_local_option(outgoing_s2s_options) of
	{_, Timeout} when is_integer(Timeout) ->
	    Timeout;
	{_, infinity} ->
	    infinity;
	undefined ->
	    %% 10 seconds
	    10000
    end.

%% Human readable S2S logging: Log only new outgoing connections as INFO
%% Do not log dialback
log_s2s_out(false, _, _, _) -> ok;
%% Log new outgoing connections:
log_s2s_out(_, Myname, Server, Tls) ->
    ?INFO_MSG("Trying to open s2s connection: ~s -> ~s with TLS=~p", [Myname, Server, Tls]).

%% Calculate timeout depending on which state we are in:
%% Can return integer > 0 | infinity
get_timeout_interval(StateName) ->
    case StateName of
	%% Validation implies dialback: Networking can take longer:
	wait_for_validation ->
	    ?FSMTIMEOUT*6;
	%% When stream is established, we only rely on S2S Timeout timer:
	stream_established ->
	    infinity;
	_ ->
	    ?FSMTIMEOUT
    end.

%% This function is intended to be called at the end of a state
%% function that want to wait for a reconnect delay before stopping.
wait_before_reconnect(StateData) ->
    %% bounce queue manage by process and Erlang message queue
    bounce_queue(StateData#state.queue, 'remote-server-not-found'),
    bounce_messages('remote-server-not-found'),
    cancel_timer(StateData#state.timer),
    Delay = case StateData#state.delay_to_retry of
		undefined_delay ->
		    %% The initial delay is random between 1 and 15 seconds
		    %% Return a random integer between 1000 and 15000
		    {_, _, MicroSecs} = now(),
		    (MicroSecs rem 14000) + 1000;
		D1 ->
		    %% Duplicate the delay with each successive failed
		    %% reconnection attempt, but don't exceed the max
		    lists:min([D1 * 2, get_max_retry_delay()])
	    end,
    Timer = erlang:start_timer(Delay, self(), []),
    {next_state, wait_before_retry, StateData#state{timer=Timer,
						    delay_to_retry = Delay,
						    queue = queue:new()}}.

%% @doc Get the maximum allowed delay for retry to reconnect (in miliseconds).
%% The default value is 5 minutes.
%% The option {s2s_max_retry_delay, Seconds} can be used (in seconds).
%% @spec () -> integer()
get_max_retry_delay() ->
    case ejabberd_config:get_local_option(s2s_max_retry_delay) of
	Seconds when is_integer(Seconds) ->
	    Seconds*1000;
	_ ->
	    ?MAX_RETRY_DELAY
    end.

%% Terminate s2s_out connections that are in state wait_before_retry
terminate_if_waiting_delay(From, To) ->
    FromTo = {From, To},
    Pids = ejabberd_s2s:get_connections_pids(FromTo),
    lists:foreach(
      fun(Pid) ->
	      Pid ! terminate_if_waiting_before_retry
      end,
      Pids).

fsm_limit_opts() ->
    case ejabberd_config:get_local_option(max_fsm_queue) of
	N when is_integer(N) ->
	    [{max_queue, N}];
	_ ->
	    []
    end.
