%%% Copyright (C) 2010  Tomas Abrahamsson
%%%
%%% Author: Tomas Abrahamsson <tab@lysator.liu.se>
%%%
%%% This library is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU Library General Public
%%% License as published by the Free Software Foundation; either
%%% version 2 of the License, or (at your option) any later version.
%%%
%%% This library is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% Library General Public License for more details.
%%%
%%% You should have received a copy of the GNU Library General Public
%%% License along with this library; if not, write to the Free
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

-module(gpb_compile).
%-compile(export_all).
-export([file/1]).
-include_lib("eunit/include/eunit.hrl").
-include("gpb.hrl").

file(File) ->
    Defs = parse_file(File),
    Mod = list_to_atom(filename:basename(File, filename:extension(File))),
    Erl = change_ext(File, ".erl"),
    Hrl = change_ext(File, ".hrl"),
    file:write_file(Erl, format_erl(Mod, Defs)),
    file:write_file(Hrl, format_hrl(Mod, Defs)).

change_ext(File, NewExt) ->
    filename:join(filename:dirname(File),
                  filename:basename(File, filename:extension(File)) ++ NewExt).

parse_file(FName) ->
    case parse_file_and_imports(FName) of
        {ok, {Defs1, _AllImported}} ->
            %% io:format("processed these imports:~n  ~p~n", [_AllImported]),
            %% io:format("Defs1=~n  ~p~n", [Defs1]),
            Defs2 = gpb_parse:reformat_names(
                      gpb_parse:flatten_defs(
                        gpb_parse:absolutify_names(Defs1))),
            case gpb_parse:verify_refs(Defs2) of
                ok ->
                    gpb_parse:normalize_msg_field_options( %% Sort it?
                      gpb_parse:enumerate_msg_fields(
                        gpb_parse:extend_msgs(
                          gpb_parse:resolve_refs(Defs2))))
            end;
        {error, Reason} ->
            {error, Reason}
    end.

parse_file_and_imports(FName) ->
    parse_file_and_imports(FName, [FName]).

parse_file_and_imports(FName, AlreadyImported) ->
    FName2 = locate_import(FName),
    {ok,B} = file:read_file(FName2),
    %% Add to AlreadyImported to prevent trying to import it again: in
    %% case we get an error we don't want to try to reprocess it later
    %% (in case it is multiply imported) and get the error again.
    AlreadyImported2 = [FName | AlreadyImported],
    case scan_and_parse_string(binary_to_list(B)) of
        {ok, Defs} ->
            Imports = gpb_parse:fetch_imports(Defs),
            {ok, lists:foldl(
                   fun(Import, {Ds,Is}) ->
                           case lists:member(Import, Is) of
                               true  -> {Ds,Is};
                               false -> import_it(Import, Ds, Is)
                           end
                   end,
                   {Defs, AlreadyImported2},
                   Imports)};
        {error, Reason} ->
            io:format("Error for ~s (ignoring):~n  ~p~n",
                      [FName, Reason]),
            {error, Reason}
    end.

scan_and_parse_string(S) ->
    case gpb_scan:string(S) of
        {ok, Tokens, _} ->
            case gpb_parse:parse(Tokens++[{'$end', 999}]) of
                {ok, Result} ->
                    {ok, Result};
                {error, {LNum,_Module,EMsg}=Reason} ->
                    io:format(user, "Parse error on line ~w:~n  ~p~n",
                              [LNum, {Tokens,EMsg}]),
                    erlang:error({parse_error,S,Reason})
            end;
        {error,Reason} ->
            io:format(user, "Scan error:~n  ~p~n", [Reason]),
            erlang:error({scan_error,S,Reason})
    end.


import_it(Import, Defs, AlreadyImported) ->
    %% FIXME: how do we handle scope of declarations,
    %%        e.g. options/package for imported files?
    case parse_file_and_imports(Import, AlreadyImported) of
        {ok, {MoreDefs, MoreImported}} ->
            Defs2 = Defs++MoreDefs,
            Imported2 = lists:usort(AlreadyImported++MoreImported),
            {Defs2, Imported2};
        {error, Reason} ->
            io:format("Error for ~s (ignoring):~n  ~p~n", [Import, Reason]),
            {Defs, AlreadyImported}
    end.

locate_import(Import) -> "/tmp/u/"++Import. %% FIXME: include path...

format_erl(Mod, Defs) ->
    iolist_to_binary(
      [f("%% Automatically generated, do not edit~n"
         "%% Generated by ~p on ~p~n", [?MODULE, calendar:local_time()]),
       f("-module(~w).~n", [Mod]),
       "\n",
       f("-export([encode_msg/1]).~n"),
       f("-export([decode_msg/2]).~n"),
       f("-export([get_msg_defs/0]).~n"),
       "\n",
       f("-include(\"gpb.hrl\").~n"),
       "\n",
       f("encode_msg(Msg) ->~n"
         "    gpb:encode_msg(Msg, get_msg_defs()).~n"),
       "\n",
       f("decode_msg(Bin, MsgName) ->~n"
         "    gpb:encode_msg(Bin, MsgName, get_msg_defs()).~n"),
       "\n",
       f("get_msg_defs() ->~n"
         "    [~n~s].~n", [format_msgs_and_enums(5, Defs)])]).

format_msgs_and_enums(Indent, Defs) ->
    Enums = [Item || {{enum, _}, _}=Item <- Defs],
    Msgs  = [Item || {{msg, _}, _}=Item <- Defs],
    [format_enums(Indent, Enums),
     if Enums /= [], Msgs /= [] -> ",\n";
        true                    -> ""
     end,
     format_msgs(Indent, Msgs)].

format_enums(Indent, Enums) ->
    string:join([f("~s~p", [indent(Indent,""), Enum]) || Enum <- Enums],
                ",\n").

format_msgs(Indent, Msgs) ->
    string:join([indent(Indent,
                        f("{~w, [~n~s]}",
                          [{msg,Msg}, format_efields(Indent+2, Fields)]))
                 || {{msg,Msg},Fields} <- Msgs],
                ",\n").

format_efields(Indent, Fields) ->
    string:join([format_efield(Indent, Field) || Field <- Fields],
                ",\n").

format_efield(I, #field{name=N,fnum=F,rnum=R,type=T,occurrence=O,opts=Opts}) ->
    [indent(I, f("#field{name=~w, fnum=~w, rnum=~w, type=~w,~n", [N,F,R,T])),
     indent(I, f("       occurrence=~w, opts=~p}", [O, Opts]))].


format_hrl(Mod, Defs) ->
    iolist_to_binary(
      [f("-ifndef(~p).~n", [Mod]),
       f("-define(~p, true).~n", [Mod]),
       "\n",
       string:join([format_msg_record(Msg,Fs) || {{msg,Msg},Fs} <- Defs],
                   "\n"),
       "\n",
       f("-endif.~n")]).

format_msg_record(Msg, Fields) ->
    [f("-record(~p,~n", [Msg]),
     f("        {~n"),
     format_hfields(8+1, Fields),
     f("        }).~n")].

format_hfields(Indent, Fields) ->
    lists:map(fun({I, #field{name=Name, fnum=FNum, type=Type, opts=Opts}}) ->
                      DefaultStr =
                          case proplists:get_value(default, Opts, '$nodflt') of
                              '$nodflt' -> "";
                              Default   -> f(" = ~p", [Default])
                          end,
                      CommaSep = if I < length(Fields) -> ",";
                                    true               -> "" %% last entry
                                 end,
                      FieldTxt = indent(Indent,
                                        f("~w~s~s",
                                          [Name, DefaultStr, CommaSep])),
                      LineUpStr = lineup(lists:flatlength(FieldTxt), 32),
                      f("~s~s% = ~w, ~w~n",
                        [FieldTxt, LineUpStr, FNum, Type])
              end,
              index_seq(Fields)).

lineup(CurrentCol, TargetCol) when CurrentCol < TargetCol ->
    lists:duplicate(TargetCol - CurrentCol, $\s);
lineup(_, _) ->
    " ".

indent(Indent, Str) ->
    lists:duplicate(Indent, $\s) ++ Str.

index_seq([]) -> [];
index_seq(L)  -> lists:zip(lists:seq(1,length(L)), L).

f(F)   -> f(F,[]).
f(F,A) -> io_lib:format(F,A).
