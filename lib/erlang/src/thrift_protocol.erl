%%
%% Licensed to the Apache Software Foundation (ASF) under one
%% or more contributor license agreements. See the NOTICE file
%% distributed with this work for additional information
%% regarding copyright ownership. The ASF licenses this file
%% to you under the Apache License, Version 2.0 (the
%% "License"); you may not use this file except in compliance
%% with the License. You may obtain a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied. See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%

-module(thrift_protocol).

-export([new/2,
         write/2,
         read/2,
         read/3,
         skip/2,
         flush_transport/1,
         close_transport/1,
         typeid_to_atom/1
        ]).

-export([behaviour_info/1]).

-include("thrift_constants.hrl").
-include("thrift_protocol.hrl").

-record(protocol, {module, data}).

behaviour_info(callbacks) ->
    [
     {read, 2},
     {write, 2},
     {flush_transport, 1},
     {close_transport, 1}
    ];
behaviour_info(_Else) -> undefined.

new(Module, Data) when is_atom(Module) ->
    {ok, #protocol{module = Module,
                   data = Data}}.

-spec flush_transport(#protocol{}) -> {#protocol{}, ok}.
flush_transport(Proto = #protocol{module = Module,
                                  data = Data}) ->
    {NewData, Result} = Module:flush_transport(Data),
    {Proto#protocol{data = NewData}, Result}.

-spec close_transport(#protocol{}) -> ok.
close_transport(#protocol{module = Module,
                          data = Data}) ->
    Module:close_transport(Data).

typeid_to_atom(?tType_STOP) -> field_stop;
typeid_to_atom(?tType_VOID) -> void;
typeid_to_atom(?tType_BOOL) -> bool;
typeid_to_atom(?tType_DOUBLE) -> double;
typeid_to_atom(?tType_I8) -> byte;
typeid_to_atom(?tType_I16) -> i16;
typeid_to_atom(?tType_I32) -> i32;
typeid_to_atom(?tType_I64) -> i64;
typeid_to_atom(?tType_STRING) -> string;
typeid_to_atom(?tType_STRUCT) -> struct;
typeid_to_atom(?tType_MAP) -> map;
typeid_to_atom(?tType_SET) -> set;
typeid_to_atom(?tType_LIST) -> list.

term_to_typeid(void) -> ?tType_VOID;
term_to_typeid(bool) -> ?tType_BOOL;
term_to_typeid(byte) -> ?tType_I8;
term_to_typeid(double) -> ?tType_DOUBLE;
term_to_typeid(i8) -> ?tType_I8;
term_to_typeid(i16) -> ?tType_I16;
term_to_typeid(i32) -> ?tType_I32;
term_to_typeid(i64) -> ?tType_I64;
term_to_typeid(string) -> ?tType_STRING;
term_to_typeid({struct, _}) -> ?tType_STRUCT;
term_to_typeid({map, _, _}) -> ?tType_MAP;
term_to_typeid({set, _}) -> ?tType_SET;
term_to_typeid({list, _}) -> ?tType_LIST.

%% Structure is like:
%%    [{Fid, Type}, ...]
-spec read(#protocol{}, {struct, _StructDef}, atom()) -> {#protocol{}, {ok, tuple()}}.
read(IProto0, {struct, StructDef}, Tag)
  when is_list(StructDef), is_atom(Tag) ->

    % If we want a tagged tuple, we need to offset all the tuple indices
    % by 1 to avoid overwriting the tag.
    Offset = if Tag =/= undefined -> 2; true -> 1 end,

    {IProto1, ok} = read(IProto0, struct_begin),
    RTuple0 = erlang:make_tuple(length(StructDef) + Offset - 1, undefined),
    RTuple1 = if Tag =/= undefined -> setelement(1, RTuple0, Tag);
                 true              -> RTuple0
              end,

    {IProto2, RTuple2} = read_struct_loop(IProto1, enumerate(Offset, StructDef), RTuple1),
    {IProto2, {ok, RTuple2}}.

enumerate(N, [{Fid, _Req, Type, Name, _Default} | Rest]) ->
    [{N, Fid, Type, Name} | enumerate(N + 1, Rest)];
enumerate(_, []) ->
    [].

%% NOTE: Keep this in sync with thrift_protocol_behaviour:read
-spec read
        (#protocol{}, {struct, _Info}) ->    {#protocol{}, {ok, tuple()}      | {error, _Reason}};
        (#protocol{}, tprot_cont_tag()) ->   {#protocol{}, {ok, any()}        | {error, _Reason}};
        (#protocol{}, tprot_empty_tag()) ->  {#protocol{},  ok                | {error, _Reason}};
        (#protocol{}, tprot_header_tag()) -> {#protocol{}, tprot_header_val() | {error, _Reason}};
        (#protocol{}, tprot_data_tag()) ->   {#protocol{}, {ok, any()}        | {error, _Reason}}.

read(IProto, {struct, {Module, StructureName}}) when is_atom(Module),
                                                     is_atom(StructureName) ->
    read(IProto, Module:struct_info(StructureName), StructureName);

read(IProto, S={struct, Structure}) when is_list(Structure) ->
    read(IProto, S, undefined);

read(IProto, {enum, {Module, EnumName}}) when is_atom(Module) ->
    read(IProto, Module:enum_info(EnumName));

read(IProto, {enum, Fields}) when is_list(Fields) ->
    {IProto2, {ok, IVal}} = read(IProto, i32),
    {EnumVal, IVal} = lists:keyfind(IVal, 2, Fields),
    {IProto2, {ok, EnumVal}};

read(IProto0, {list, Type}) ->
    {IProto1, #protocol_list_begin{etype = EType, size = Size}} =
        read(IProto0, list_begin),
    {EType, EType} = {term_to_typeid(Type), EType},
    {IProto2, List} = read_list_loop(IProto1, Type, Size),
    {IProto3, ok} = read(IProto2, list_end),
    {IProto3, {ok, List}};

read(IProto0, {map, KeyType, ValType}) ->
    {IProto1, #protocol_map_begin{size = Size, ktype = KType, vtype = VType}} =
        read(IProto0, map_begin),
    _ = case Size of
      0 -> 0;
      _ ->
        {KType, KType} = {term_to_typeid(KeyType), KType},
        {VType, VType} = {term_to_typeid(ValType), VType}
    end,
    {IProto2, Map} = read_map_loop(IProto1, KeyType, ValType, Size),
    {IProto3, ok} = read(IProto2, map_end),
    {IProto3, {ok, Map}};

read(IProto0, {set, Type}) ->
    {IProto1, #protocol_set_begin{etype = EType, size = Size}} =
        read(IProto0, set_begin),
    {EType, EType} = {term_to_typeid(Type), EType},
    {IProto2, Set} = read_set_loop(IProto1, Type, Size),
    {IProto3, ok} = read(IProto2, set_end),
    {IProto3, {ok, Set}};

read(Protocol, ProtocolType) ->
    read_specific(Protocol, ProtocolType).

%% NOTE: Keep this in sync with thrift_protocol_behaviour:read
-spec read_specific
        (#protocol{}, tprot_empty_tag()) ->  {#protocol{},  ok                | {error, _Reason}};
        (#protocol{}, tprot_header_tag()) -> {#protocol{}, tprot_header_val() | {error, _Reason}};
        (#protocol{}, tprot_data_tag()) ->   {#protocol{}, {ok, any()}        | {error, _Reason}}.
read_specific(Proto = #protocol{module = Module,
                                data = ModuleData}, ProtocolType) ->
    {NewData, Result} = Module:read(ModuleData, ProtocolType),
    {Proto#protocol{data = NewData}, Result}.

-spec read_list_loop(#protocol{}, any(), non_neg_integer()) -> {#protocol{}, [any()]}.
read_list_loop(Proto0, ValType, Size) ->
    read_list_loop(Proto0, ValType, Size, []).

read_list_loop(Proto0, _ValType, 0, List) ->
    {Proto0, lists:reverse(List)};
read_list_loop(Proto0, ValType, Left, List) ->
    {Proto1, {ok, Val}} = read(Proto0, ValType),
    read_list_loop(Proto1, ValType, Left - 1, [Val | List]).

-spec read_map_loop(#protocol{}, any(), any(), non_neg_integer()) -> {#protocol{}, map()}.
read_map_loop(Proto0, KeyType, ValType, Size) ->
    read_map_loop(Proto0, KeyType, ValType, Size, #{}).

read_map_loop(Proto0, _KeyType, _ValType, 0, Map) ->
    {Proto0, Map};
read_map_loop(Proto0, KeyType, ValType, Left, Map) ->
    {Proto1, {ok, Key}} = read(Proto0, KeyType),
    {Proto2, {ok, Val}} = read(Proto1, ValType),
    read_map_loop(Proto2, KeyType, ValType, Left - 1, maps:put(Key, Val, Map)).

-spec read_set_loop(#protocol{}, any(), non_neg_integer()) -> {#protocol{}, ordsets:ordset(any())}.
read_set_loop(Proto0, ValType, Size) ->
    read_set_loop(Proto0, ValType, Size, ordsets:new()).

read_set_loop(Proto0, _ValType, 0, Set) ->
    {Proto0, Set};
read_set_loop(Proto0, ValType, Left, Set) ->
    {Proto1, {ok, Val}} = read(Proto0, ValType),
    read_set_loop(Proto1, ValType, Left - 1, ordsets:add_element(Val, Set)).

read_struct_loop(IProto0, StructIndex, RTuple) ->
    {IProto1, #protocol_field_begin{type = FType, id = Fid}} =
        thrift_protocol:read(IProto0, field_begin),
    case {FType, Fid} of
        {?tType_STOP, _} ->
            {IProto2, ok} = read(IProto1, struct_end),
            {IProto2, RTuple};
        _Else ->
            case lists:keyfind(Fid, 2, StructIndex) of
                {N, Fid, Type, Name} ->
                    case term_to_typeid(Type) of
                        FType ->
                            {IProto2, {ok, Val}} = read(IProto1, Type),
                            {IProto3, ok} = thrift_protocol:read(IProto2, field_end),
                            NewRTuple = setelement(N, RTuple, Val),
                            read_struct_loop(IProto3, StructIndex, NewRTuple);
                        _Expected ->
                            error_logger:info_msg(
                                "Skipping field ~p with wrong type: ~p~n",
                                [Name, typeid_to_atom(FType)]),
                            skip_field(FType, IProto1, StructIndex, RTuple)
                    end;
                false ->
                    error_logger:info_msg(
                        "Skipping unknown field [~p] with type: ~p~n",
                        [Fid, typeid_to_atom(FType)]),
                    skip_field(FType, IProto1, StructIndex, RTuple)
            end
    end.

skip_field(FType, IProto0, StructIndex, RTuple) ->
    FTypeAtom = typeid_to_atom(FType),
    {IProto1, ok} = skip(IProto0, FTypeAtom),
    {IProto2, ok} = read(IProto1, field_end),
    read_struct_loop(IProto2, StructIndex, RTuple).

-spec skip(#protocol{}, any()) -> {#protocol{}, ok}.

skip(Proto0, struct) ->
    {Proto1, ok} = read(Proto0, struct_begin),
    {Proto2, ok} = skip_struct_loop(Proto1),
    {Proto3, ok} = read(Proto2, struct_end),
    {Proto3, ok};

skip(Proto0, map) ->
    {Proto1, Map} = read(Proto0, map_begin),
    {Proto2, ok} = skip_map_loop(Proto1, Map),
    {Proto3, ok} = read(Proto2, map_end),
    {Proto3, ok};

skip(Proto0, set) ->
    {Proto1, Set} = read(Proto0, set_begin),
    {Proto2, ok} = skip_set_loop(Proto1, Set),
    {Proto3, ok} = read(Proto2, set_end),
    {Proto3, ok};

skip(Proto0, list) ->
    {Proto1, List} = read(Proto0, list_begin),
    {Proto2, ok} = skip_list_loop(Proto1, List),
    {Proto3, ok} = read(Proto2, list_end),
    {Proto3, ok};

skip(Proto0, Type) when is_atom(Type) ->
    {Proto1, _Ignore} = read(Proto0, Type),
    {Proto1, ok};

skip(Proto0, Type) when is_integer(Type) ->
    skip(Proto0, typeid_to_atom(Type)).

skip_struct_loop(Proto0) ->
    {Proto1, #protocol_field_begin{type = Type}} = read(Proto0, field_begin),
    case Type of
        ?tType_STOP ->
            {Proto1, ok};
        _Else ->
            {Proto2, ok} = skip(Proto1, Type),
            {Proto3, ok} = read(Proto2, field_end),
            skip_struct_loop(Proto3)
    end.

skip_map_loop(Proto0, #protocol_map_begin{size = 0}) ->
    {Proto0, ok};
skip_map_loop(Proto0, Map = #protocol_map_begin{ktype = Ktype, vtype = Vtype, size = Size}) ->
    {Proto1, ok} = skip(Proto0, Ktype),
    {Proto2, ok} = skip(Proto1, Vtype),
    skip_map_loop(Proto2, Map#protocol_map_begin{size = Size - 1}).

skip_set_loop(Proto0, #protocol_set_begin{size = 0}) ->
    {Proto0, ok};
skip_set_loop(Proto0, Map = #protocol_set_begin{etype = Etype, size = Size}) ->
    {Proto1, ok} = skip(Proto0, Etype),
    skip_set_loop(Proto1, Map#protocol_set_begin{size = Size - 1}).

skip_list_loop(Proto0, #protocol_list_begin{size = 0}) ->
    {Proto0, ok};
skip_list_loop(Proto0, Map = #protocol_list_begin{etype = Etype, size = Size}) ->
    {Proto1, ok} = skip(Proto0, Etype),
    skip_list_loop(Proto1, Map#protocol_list_begin{size = Size - 1}).


%%--------------------------------------------------------------------
%% Function: write(OProto, {Type, Data}) -> ok
%%
%% Type = {struct, StructDef} |
%%        {list, Type} |
%%        {map, KeyType, ValType} |
%%        {set, Type} |
%%        BaseType
%%
%% Data =
%%         tuple()  -- for struct
%%       | list()   -- for list
%%       | dictionary()   -- for map
%%       | set()    -- for set
%%       | any()    -- for base types
%%
%% Description:
%%--------------------------------------------------------------------
-spec write(#protocol{}, any()) -> {#protocol{}, ok | {error, _Reason}}.

write(Proto0, {{struct, StructDef}, Data})
  when is_list(StructDef), is_tuple(Data), length(StructDef) == size(Data) - 1 ->

    [StructName | Elems] = tuple_to_list(Data),
    {Proto1, ok} = write(Proto0, #protocol_struct_begin{name = StructName}),
    {Proto2, ok} = struct_write_loop(Proto1, StructDef, Elems),
    {Proto3, ok} = write(Proto2, struct_end),
    {Proto3, ok};

write(Proto, {{struct, {Module, StructureName}}, Data})
  when is_atom(Module),
       is_atom(StructureName),
       element(1, Data) =:= StructureName ->
    write(Proto, {Module:struct_info(StructureName), Data});

write(_, {{struct, {Module, StructureName}}, Data})
  when is_atom(Module),
       is_atom(StructureName) ->
    erlang:error(struct_unmatched, {{provided, element(1, Data)},
                             {expected, StructureName}});

write(Proto, {{enum, Fields}, Data}) when is_list(Fields), is_atom(Data) ->
    {Data, IVal} = lists:keyfind(Data, 1, Fields),
    write(Proto, {i32, IVal});

write(Proto, {{enum, {Module, EnumName}}, Data})
  when is_atom(Module),
       is_atom(EnumName) ->
    write(Proto, {Module:enum_info(EnumName), Data});

write(Proto0, {{list, Type}, Data})
  when is_list(Data) ->
    {Proto1, ok} = write(Proto0,
               #protocol_list_begin{
                 etype = term_to_typeid(Type),
                 size = length(Data)
                }),
    Proto2 = lists:foldl(fun(Elem, ProtoIn) ->
                                 {ProtoOut, ok} = write(ProtoIn, {Type, Elem}),
                                 ProtoOut
                         end,
                         Proto1,
                         Data),
    {Proto3, ok} = write(Proto2, list_end),
    {Proto3, ok};

write(Proto0, {{map, KeyType, ValType}, Data}) ->
    {Proto1, ok} = write(Proto0,
                         #protocol_map_begin{
                           ktype = term_to_typeid(KeyType),
                           vtype = term_to_typeid(ValType),
                           size  = map_size(Data)
                          }),
    Proto2 = maps:fold(fun(KeyData, ValData, ProtoS0) ->
                               {ProtoS1, ok} = write(ProtoS0, {KeyType, KeyData}),
                               {ProtoS2, ok} = write(ProtoS1, {ValType, ValData}),
                               ProtoS2
                       end,
                       Proto1,
                       Data),
    {Proto3, ok} = write(Proto2, map_end),
    {Proto3, ok};

write(Proto0, {{set, Type}, Data}) ->
    true = ordsets:is_set(Data),
    {Proto1, ok} = write(Proto0,
                         #protocol_set_begin{
                           etype = term_to_typeid(Type),
                           size  = ordsets:size(Data)
                          }),
    Proto2 = ordsets:fold(fun(Elem, ProtoIn) ->
                               {ProtoOut, ok} = write(ProtoIn, {Type, Elem}),
                               ProtoOut
                       end,
                       Proto1,
                       Data),
    {Proto3, ok} = write(Proto2, set_end),
    {Proto3, ok};

write(Proto = #protocol{module = Module,
                        data = ModuleData}, Data) ->
    {NewData, Result} = Module:write(ModuleData, Data),
    {Proto#protocol{data = NewData}, Result}.

struct_write_loop(Proto0, [{Fid, _Req, Type, _Name, _Default} | RestStructDef], [Data | RestData]) ->
    NewProto = case Data of
                   undefined ->
                       Proto0; % null fields are skipped in response
                   _ ->
                       {Proto1, ok} = write(Proto0,
                                           #protocol_field_begin{
                                             type = term_to_typeid(Type),
                                             id = Fid
                                            }),
                       {Proto2, ok} = write(Proto1, {Type, Data}),
                       {Proto3, ok} = write(Proto2, field_end),
                       Proto3
               end,
    struct_write_loop(NewProto, RestStructDef, RestData);
struct_write_loop(Proto, [], []) ->
    write(Proto, field_stop).