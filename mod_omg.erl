%%%----------------------------------------------------------------------
%%%  mod_omg.erl - a bot provides omegle like service
%%%  Copyright (C) 2010  bhuztez <bhuztez@gmail.com>
%%%
%%% This program is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program.  If not, see <http://www.gnu.org/licenses/>.
%%%
%%%----------------------------------------------------------------------


-module(mod_omg).
-author('bhuztez@gmail.com').

-behaviour(gen_server).
-behaviour(gen_mod).

-export([start_link/2, start/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
        terminate/2, code_change/3]).


-include("ejabberd.hrl").
-include("jlib.hrl").

-record(state, {host, participants, waiting}).

-define(PROCNAME, ejabberd_mod_omg).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Host, Opts) ->
   Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
   gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

start(Host, Opts) ->
   Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
   ChildSpec =
       {Proc,
        {?MODULE, start_link, [Host, Opts]},
        temporary,
        1000,
        worker,
        [?MODULE]},
   supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
   Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
   gen_server:call(Proc, stop),
   supervisor:terminate_child(ejabberd_sup, Proc),
   supervisor:delete_child(ejabberd_sup, Proc).



%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Host, Opts]) ->
   MyHost = gen_mod:get_opt_host(Host, Opts, "omg.@HOST@"),
   ejabberd_router:register_route(MyHost),
   Participants = dict:new(),
   Waiting = none,
   {ok,
    #state{host = MyHost,
           participants = Participants,
           waiting = Waiting}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(stop, _From, State) ->
   {stop, normal, ok, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
   {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
   ejabberd_router:unregister_route(State#state.host),
   ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
   {ok, State}.


handle_info({route, From, To, Packet}, State) ->
   case From#jid.user of
       "" ->
             Packet2 = jlib:make_error_reply(Packet, ?ERR_BAD_REQUEST),
             ejabberd_router:route(To, From, Packet2),
             {noreply, State};
       _ ->
            NextState = do_route(From, To, Packet, State),
            {noreply, NextState}
   end;
handle_info(_Info, State) ->
   {noreply, State}.


do_route(From, To, {xmlelement, "iq", _Attrs, _Els} = Packet, State) ->
case jlib:iq_query_info(Packet) of

   #iq{type = get,
       xmlns = ?NS_DISCO_INFO = XMLNS,
       sub_el = _SubEl,
       lang = _Lang} = IQ ->

       Res = IQ#iq{type = result,
                   sub_el = [{xmlelement, "query",
                   [{"xmlns", XMLNS}], iq_disco_info()}]},
       ejabberd_router:route(To, From, jlib:iq_to_xml(Res));

   #iq{type = get,
       xmlns = ?NS_DISCO_ITEMS = XMLNS,
       sub_el = _SubEl} = IQ ->

       Res = IQ#iq{type = result,
                   sub_el = [{xmlelement, "query",
                   [{"xmlns", XMLNS}], iq_disco_items()}]},

       ejabberd_router:route(To, From, jlib:iq_to_xml(Res));

   _ ->
       ?DEBUG("unhandled iq packet: ~p~n~p~n~p", [From, To, Packet])
end,
State;

do_route(From, To, {xmlelement, "presence", _Attrs, _Els} = Packet, State) ->
    case xml:get_tag_attr_s("type", Packet) of
       "subscribe" ->
           send_presence(To, From, "subscribe"),
           State;

       "subscribed" ->
           send_presence(To, From, "subscribed"),
           send_presence(To, From, ""),
           State;

       "unsubscribe" ->
           send_presence(To, From, "unsubscribed"),
           send_presence(To, From, "unsubscribe"),
           State;

       "unsubscribed" ->
           send_presence(To, From, "unsubscribed"),
           State;

       "" ->
           send_presence(To, From, ""),
           State;

       "unavailable" ->
           send_presence(To, From, "unavailable"),
           case get_partner(From, State) of
               error -> State;
               Partner -> quit_chat(From, Partner, To, State)
           end;

       "probe" ->
           send_presence(To, From, ""),
           State;

       _ ->
           ?DEBUG("unhandled presence packet ~p~n~p~n~p", [From, To, Packet]),
           State
    end;

do_route(From, To, {xmlelement, "message", _Attrs, Els} = Packet, State) ->
   Partner = get_partner(From, State),
   case xml:get_subtag_cdata(Packet, "body") of
       "^JOIN" ->
           join_chat(From, Partner, To, State);
       "^QUIT" ->
           quit_chat(From, Partner, To, State);
       [ 94 | _ ] ->
           send_message(To, From, "^SYSTEM: Oops! Invalid command :-("),
           State;
       _ ->
           redirect_message(To, Partner, xml:get_tag_attr_s("type", Packet), Els),
           State
   end;

do_route(From, To, Packet, State) ->
   ?DEBUG("unhandled packet: ~p~n~p~n~p", [From, To, Packet]),
   State.


%% route iq packet
iq_disco_info() ->
   [{xmlelement,"identity",
        [{"category", "client"},
         {"type", "bot"},
         {"name", "stranger"}], []},
    {xmlelement, "feature",
        [{"var", ?NS_DISCO_INFO}], []}].

iq_disco_items() ->
   [].


%% route precense packet
send_presence(From, To, "") ->
   ejabberd_router:route(From, To, {xmlelement, "presence", [], []});
send_presence(From, To, TypeStr) ->
   ejabberd_router:route(From, To, {xmlelement, "presence", [{"type", TypeStr}], []}).


%% send message
send_message(From, To, Body) ->
   XmlBody = {xmlelement, "message",
              [{"type", "chat"},
               {"to", jlib:jid_to_string(To)}],
              [{xmlelement, "body", [],
               [{xmlcdata, Body}]}]},
   ejabberd_router:route(From, To, XmlBody).

%% redirect message to your partner
redirect_message(From, To, Type, Msg) when (To /= error) ->
   XmlBody = {xmlelement, "message",
              [{"type", Type},
               {"to", jlib:jid_to_string(To)}],
              Msg},
   ejabberd_router:route(From, To, XmlBody);
redirect_message(_From, _Partner, _To, _Msg) ->
   ok.

get_partner(Jid,
           #state{host = _Host,
                  participants = Participants,
                  waiting = _Waiting} = _State) ->
   case dict:find(Jid, Participants) of
       {ok, [Partner]} ->
           Partner;
       _ ->
           error
   end.


join_chat(From, Partner, To, State) when (Partner /= error) ->
   send_message(To, From, "^SYSTEM: already chatting with a stranger."),
   State;

join_chat(From, _Partner, To,
         #state{host = Host,
                participants = Participants,
                waiting = Waiting} = _State)
        when (Waiting == none) ->
   send_message(To, From, "^SYSTEM: waiting for a stranger ..."),
   #state{host = Host,
          participants = Participants,
          waiting = From};

join_chat(From, _Partner, To,
         #state{host = _Host,
                participants = _Participants,
                waiting = Waiting} = State)
        when (Waiting == From) ->
   send_message(To, From, "^SYSTEM: please wait for a stranger ..."),
   State;

join_chat(From, _Partner, To,
         #state{host = Host,
                participants = Participants,
                waiting = Waiting} = _State) ->
   Participants_ = dict:append(Waiting, From, Participants),
   NewParticipants = dict:append(From, Waiting, Participants_),
   send_message(To, Waiting, "^SYSTEM: a stranger come in :-)"),
   send_message(To, From, "^SYSTEM: join :-)"),
   #state{host = Host,
          participants = NewParticipants,
          waiting = none}.


quit_chat(From, Partner, To,
         #state{host = Host,
                participants = Participants,
                waiting = Waiting} = _State)
        when (Partner /= error)->
   Participants_ = dict:erase(From, Participants),
   NewParticipants = dict:erase(Partner, Participants_),
   send_message(To, From, "^SYSTEM: chat quit."),
   send_message(To, Partner, "^SYSTEM: the stranger left."),
   #state{host = Host,
          participants = NewParticipants,
          waiting = Waiting};

quit_chat(From, _Partner, To,
         #state{host = Host,
                participants = Participants,
                waiting = Waiting} = _State)
        when (Waiting == From)->
   send_message(To, From, "^SYSTEM: bye :-D"),
   #state{host = Host,
          participants = Participants,
          waiting = none};

quit_chat(From, _Partner, To, State) ->
   send_message(To, From, "^SYSTEM: how hell you ^QUIT before you ^JOIN :-P"),
   State.


