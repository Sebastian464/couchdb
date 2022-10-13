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

-module(couch_prometheus_e2e_tests).

-include_lib("couch/include/couch_eunit.hrl").
-include_lib("couch/include/couch_db.hrl").

-define(USER, "prometheus_test_admin").
-define(PASS, "pass").
-define(AUTH, {basic_auth, {?USER, ?PASS}}).
-define(PROM_PORT, "17986").
-define(CONTENT_JSON, {"Content-Type", "application/json"}).

e2e_test_() ->
    {
        "With dedicated port",
        {
            setup,
            fun() ->
                setup_prometheus(true)
            end,
            fun(Ctx) ->
                test_util:stop_couch(Ctx)
            end,
            {
                foreach,
                fun() ->
                    mochiweb_socket_server:get(chttpd, port)
                end,
                [
                    ?TDEF_FE(chttpd_port),
                    ?TDEF_FE(prometheus_port),
                    ?TDEF_FE(metrics_updated)
                ]
            }
        }
    }.

reject_test_() ->
    {
        "Without dedicated port",
        {
            setup,
            fun() ->
                setup_prometheus(false)
            end,
            fun(Ctx) ->
                test_util:stop_couch(Ctx)
            end,
            {
                foreach,
                fun() ->
                    ?PROM_PORT
                end,
                [
                    ?TDEF_FE(reject_prometheus_port)
                ]
            }
        }
    }.

setup_prometheus(WithAdditionalPort) ->
    Ctx = test_util:start_couch([chttpd]),
    Persist = false,
    Hashed = couch_passwords:hash_admin_password(?PASS),
    ok = config:set("admins", ?USER, ?b2l(Hashed), Persist),
    ok = config:set_integer("stats", "interval", 2, Persist),
    ok = config:set_integer("prometheus", "interval", 1, Persist),
    ok = config:set_boolean(
        "prometheus",
        "additional_port",
        WithAdditionalPort,
        Persist
    ),
    % it's started by default, so restart to pick up config
    ok = application:stop(couch_prometheus),
    ok = application:start(couch_prometheus),
    Ctx.

chttpd_port(ChttpdPort) ->
    {ok, RC1, _, _} = test_request:get(
        node_local_url(ChttpdPort),
        [?CONTENT_JSON, ?AUTH],
        []
    ),
    ?assertEqual(200, RC1).

prometheus_port(_) ->
    Url = node_local_url(?PROM_PORT),
    {ok, RC1, _, _} = test_request:get(
        Url,
        [?CONTENT_JSON, ?AUTH]
    ),
    ?assertEqual(200, RC1),
    % since this port doesn't require auth, this should work
    {ok, RC2, _, _} = test_request:get(
        Url,
        [?CONTENT_JSON]
    ),
    ?assertEqual(200, RC2).

metrics_updated(ChttpdPort) ->
    Url = node_local_url(ChttpdPort),
    InitMetrics = wait_for_metrics(Url, "couchdb_httpd_requests_total 0", 5000),
    TmpDb = ?tempdb(),
    Addr = config:get("chttpd", "bind_address", "127.0.0.1"),
    Port = mochiweb_socket_server:get(chttpd, port),
    DbUrl = lists:concat(["http://", Addr, ":", Port, "/", ?b2l(TmpDb)]),
    create_db(DbUrl),
    lists:foreach(
        fun(I) ->
            create_doc(DbUrl, "testdoc" ++ integer_to_list(I))
        end,
        lists:seq(1, 100)
    ),
    %% [create_doc(DbUrl, "testdoc" ++ integer_to_list(I)) || I <- lists:seq(1, 100)],
    delete_db(DbUrl),
    UpdatedMetrics = wait_for_metrics(Url, "couchdb_httpd_requests_total", 10000),
    % since the puts happen so fast, we can't have an exact
    % total requests given the scraping interval. so we just want to acknowledge
    % a change as occurred
    ?assertNotEqual(InitMetrics, UpdatedMetrics).

% we don't start the http server
reject_prometheus_port(PrometheusPort) ->
    Response = test_request:get(
        node_local_url(PrometheusPort),
        [?CONTENT_JSON, ?AUTH],
        []
    ),
    ?assertEqual({error, {conn_failed, {error, econnrefused}}}, Response).

node_local_url(Port) ->
    Addr = config:get("chttpd", "bind_address", "127.0.0.1"),
    lists:concat(["http://", Addr, ":", Port, "/_node/_local/_prometheus"]).

create_db(Url) ->
    {ok, Status, _, _} = test_request:put(Url, [?CONTENT_JSON, ?AUTH], "{}"),
    ?assert(Status =:= 201 orelse Status =:= 202).

delete_db(Url) ->
    {ok, 200, _, _} = test_request:delete(Url, [?AUTH]).

create_doc(Url, Id) ->
    test_request:put(
        Url ++ "/" ++ Id,
        [?CONTENT_JSON, ?AUTH],
        "{\"mr\": \"rockoartischocko\"}"
    ).

wait_for_metrics(Url, Value, Timeout) ->
    test_util:wait(
        fun() ->
            {ok, _, _, Body} = test_request:get(
                Url,
                [?CONTENT_JSON, ?AUTH],
                []
            ),
            ?debugVal({Body, Value}, 100),
            case string:find(Body, Value) of
                nomatch -> wait;
                M -> M
            end
        end,
        Timeout
    ).
