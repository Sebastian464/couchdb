% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(aegis_server).

-behaviour(gen_server).

-vsn(1).


-include("aegis.hrl").
-include_lib("kernel/include/logger.hrl").


%% aegis_server API
-export([
    start_link/0,
    init_db/2,
    open_db/1,
    encrypt/3,
    decrypt/3
]).

%% gen_server callbacks
-export([
    init/1,
    terminate/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3
]).


-define(CACHE, aegis_cache).
-define(BY_ACCESS, aegis_by_access).
-define(KEY_CHECK, aegis_key_check).
-define(INIT_TIMEOUT, 60000).
-define(TIMEOUT, 10000).
-define(CACHE_LIMIT, 100000).
-define(CACHE_MAX_AGE_SEC, 1800).
-define(CACHE_EXPIRATION_CHECK_SEC, 10).
-define(LAST_ACCESSED_INACTIVITY_SEC, 10).


-record(entry, {uuid, encryption_key, counter, last_accessed, expires_at}).


start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


-spec init_db(Db :: #{}, Options :: list()) -> boolean().
init_db(#{uuid := UUID} = Db, Options) ->
    case ?AEGIS_KEY_MANAGER:init_db(Db, Options) of
	{ok, DbKey} ->
	    gen_server:call(?MODULE, {insert_key, UUID, DbKey}),
	    true;
	false ->
	    false
    end.


-spec open_db(Db :: #{}) -> boolean().
open_db(#{} = Db) ->
    case do_open_db(Db) of
	{ok, _DbKey} ->
	    true;
	false ->
	    false
    end.


-spec encrypt(Db :: #{}, Key :: binary(), Value :: binary()) -> binary().
encrypt(#{} = Db, Key, Value) when is_binary(Key), is_binary(Value) ->
    #{
        uuid := UUID
    } = Db,

    {ok, DbKey} = case is_key_fresh(UUID) of
        true ->
	    lookup(UUID);
        false ->
	    do_open_db(Db)
    end,
    do_encrypt(DbKey, Db, Key, Value).


-spec decrypt(Db :: #{}, Key :: binary(), Value :: binary()) -> binary().
decrypt(#{} = Db, Key, Value) when is_binary(Key), is_binary(Value) ->
    #{
        uuid := UUID
    } = Db,

    {ok, DbKey} = case is_key_fresh(UUID) of
        true ->
            lookup(UUID);
        false ->
	    do_open_db(Db)
    end,
    do_decrypt(DbKey, Db, Key, Value).


%% gen_server functions

init([]) ->
    ets:new(?CACHE, [named_table, set, {keypos, #entry.uuid}]),
    ets:new(?BY_ACCESS,
        [named_table, ordered_set, {keypos, #entry.counter}]),
    ets:new(?KEY_CHECK, [named_table, protected, {read_concurrency, true}]),

    erlang:send_after(0, self(), maybe_remove_expired),

    St = #{
        counter => 0
    },
    {ok, St, ?INIT_TIMEOUT}.


terminate(_Reason, _St) ->
    ok.


handle_call({insert_key, UUID, DbKey}, _From, #{} = St) ->
    case ets:lookup(?CACHE, UUID) of
        [#entry{uuid = UUID} = Entry] ->
            delete(Entry);
        [] ->
            ok
    end,
    NewSt = insert(St, UUID, DbKey),
    {reply, ok, NewSt, ?TIMEOUT};

handle_call(_Msg, _From, St) ->
    {noreply, St}.


handle_cast({accessed, UUID}, St) ->
    NewSt = bump_last_accessed(St, UUID),
    {noreply, NewSt};


handle_cast(_Msg, St) ->
    {noreply, St}.


handle_info(maybe_remove_expired, St) ->
    remove_expired_entries(),
    CheckInterval = erlang:convert_time_unit(
        expiration_check_interval(), second, millisecond),
    erlang:send_after(CheckInterval, self(), maybe_remove_expired),
    {noreply, St};

handle_info(_Msg, St) ->
    {noreply, St}.


code_change(_OldVsn, St, _Extra) ->
    {ok, St}.


%% private functions

do_open_db(#{uuid := UUID} = Db) ->
    case ?AEGIS_KEY_MANAGER:open_db(Db) of
        {ok, DbKey} ->
            gen_server:call(?MODULE, {insert_key, UUID, DbKey}),
            {ok, DbKey};
        false ->
            false
    end.


do_encrypt(DbKey, #{uuid := UUID}, Key, Value) ->
    EncryptionKey = crypto:strong_rand_bytes(32),
    <<WrappedKey:320>> = aegis_keywrap:key_wrap(DbKey, EncryptionKey),

    {CipherText, <<CipherTag:128>>} =
        ?aes_gcm_encrypt(
           EncryptionKey,
           <<0:96>>,
           <<UUID/binary, 0:8, Key/binary>>,
           Value),
    <<1:8, WrappedKey:320, CipherTag:128, CipherText/binary>>.


do_decrypt(DbKey, #{uuid := UUID}, Key, Value) ->
    case Value of
        <<1:8, WrappedKey:320, CipherTag:128, CipherText/binary>> ->
            case aegis_keywrap:key_unwrap(DbKey, <<WrappedKey:320>>) of
                fail ->
                    erlang:error(decryption_failed);
                DecryptionKey ->
                    Decrypted =
                    ?aes_gcm_decrypt(
                        DecryptionKey,
                        <<0:96>>,
                        <<UUID/binary, 0:8, Key/binary>>,
                        CipherText,
                        <<CipherTag:128>>),
                    if Decrypted /= error -> Decrypted; true ->
                        erlang:error(decryption_failed)
                    end
            end;
        _ ->
            erlang:error(not_ciphertext)
    end.


is_key_fresh(UUID) ->
    Now = fabric2_util:now(sec),

    case ets:lookup(?KEY_CHECK, UUID) of
        [{UUID, ExpiresAt}] when ExpiresAt >= Now -> true;
        _ -> false
    end.


%% cache functions

insert(St, UUID, DbKey) ->
    #{
        counter := Counter
    } = St,

    Now = fabric2_util:now(sec),
    ExpiresAt = Now + max_age(),

    Entry = #entry{
        uuid = UUID,
        encryption_key = DbKey,
        counter = Counter,
        last_accessed = Now,
        expires_at = ExpiresAt
    },

    true = ets:insert(?CACHE, Entry),
    true = ets:insert_new(?BY_ACCESS, Entry),
    true = ets:insert(?KEY_CHECK, {UUID, ExpiresAt}),

    CacheLimit = cache_limit(),
    CacheSize = ets:info(?CACHE, size),

    case CacheSize > CacheLimit of
        true ->
            LRUKey = ets:first(?BY_ACCESS),
            [LRUEntry] = ets:lookup(?BY_ACCESS, LRUKey),
            delete(LRUEntry);
        false ->
            ok
    end,

    St#{counter := Counter + 1}.


lookup(UUID) ->
    case ets:lookup(?CACHE, UUID) of
        [#entry{uuid = UUID, encryption_key = DbKey} = Entry] ->
            maybe_bump_last_accessed(Entry),
            {ok, DbKey};
        [] ->
            {error, not_found}
    end.


delete(#entry{uuid = UUID} = Entry) ->
    true = ets:delete(?KEY_CHECK, UUID),
    true = ets:delete_object(?CACHE, Entry),
    true = ets:delete_object(?BY_ACCESS, Entry).


maybe_bump_last_accessed(#entry{last_accessed = LastAccessed} = Entry) ->
    case fabric2_util:now(sec) > LastAccessed + ?LAST_ACCESSED_INACTIVITY_SEC of
        true ->
            gen_server:cast(?MODULE, {accessed, Entry#entry.uuid});
        false ->
            ok
    end.


bump_last_accessed(St, UUID) ->
    #{
        counter := Counter
    } = St,


    [#entry{counter = OldCounter} = Entry0] = ets:lookup(?CACHE, UUID),

    Entry = Entry0#entry{
        last_accessed = fabric2_util:now(sec),
        counter = Counter
    },

    true = ets:insert(?CACHE, Entry),
    true = ets:insert_new(?BY_ACCESS, Entry),

    ets:delete(?BY_ACCESS, OldCounter),

    St#{counter := Counter + 1}.


remove_expired_entries() ->
    MatchConditions = [{'=<', '$1', fabric2_util:now(sec)}],

    KeyCheckMatchHead = {'_', '$1'},
    KeyCheckExpired = [{KeyCheckMatchHead, MatchConditions, [true]}],
    Count = ets:select_delete(?KEY_CHECK, KeyCheckExpired),

    CacheMatchHead = #entry{expires_at = '$1', _ = '_'},
    CacheExpired = [{CacheMatchHead, MatchConditions, [true]}],
    Count = ets:select_delete(?CACHE, CacheExpired),
    Count = ets:select_delete(?BY_ACCESS, CacheExpired).



max_age() ->
    config:get_integer("aegis", "cache_max_age_sec", ?CACHE_MAX_AGE_SEC).


expiration_check_interval() ->
    config:get_integer(
        "aegis", "cache_expiration_check_sec", ?CACHE_EXPIRATION_CHECK_SEC).


cache_limit() ->
    config:get_integer("aegis", "cache_limit", ?CACHE_LIMIT).
