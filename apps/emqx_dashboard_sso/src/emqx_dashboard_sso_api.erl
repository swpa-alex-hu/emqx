%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_dashboard_sso_api).

-behaviour(minirest_api).

-include_lib("hocon/include/hoconsc.hrl").
-include_lib("emqx/include/logger.hrl").

-import(hoconsc, [
    mk/2,
    array/1,
    enum/1,
    ref/1
]).

-import(emqx_dashboard_sso, [provider/1]).

-export([
    api_spec/0,
    fields/1,
    paths/0,
    schema/1,
    namespace/0
]).

-export([
    running/2,
    login/2,
    sso/2,
    backend/2
]).

-export([sso_parameters/1, login_meta/3]).

-define(REDIRECT, 'REDIRECT').
-define(BAD_USERNAME_OR_PWD, 'BAD_USERNAME_OR_PWD').
-define(BAD_REQUEST, 'BAD_REQUEST').
-define(BACKEND_NOT_FOUND, 'BACKEND_NOT_FOUND').
-define(TAGS, <<"Dashboard Single Sign-On">>).

namespace() -> "dashboard_sso".

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => true, translate_body => true}).

paths() ->
    [
        "/sso",
        "/sso/:backend",
        "/sso/running",
        "/sso/login/:backend"
    ].

schema("/sso/running") ->
    #{
        'operationId' => running,
        get => #{
            tags => [?TAGS],
            desc => ?DESC(list_running),
            responses => #{
                200 => array(enum(emqx_dashboard_sso:types()))
            },
            security => []
        }
    };
schema("/sso") ->
    #{
        'operationId' => sso,
        get => #{
            tags => [?TAGS],
            desc => ?DESC(get_sso),
            responses => #{
                200 => array(ref(backend_status))
            }
        }
    };
%% Visit "/sso/login/saml" to start the saml authentication process -- first check to see if
%% we are already logged in, otherwise we will make an AuthnRequest and send it to
%% our IDP
schema("/sso/login/:backend") ->
    #{
        'operationId' => login,
        post => #{
            tags => [?TAGS],
            desc => ?DESC(login),
            parameters => backend_name_in_path(),
            'requestBody' => login_union(),
            responses => #{
                200 => emqx_dashboard_api:fields([role, token, version, license]),
                %% Redirect to IDP for saml
                302 => response_schema(302),
                401 => response_schema(401),
                404 => response_schema(404)
            },
            security => []
        }
    };
schema("/sso/:backend") ->
    #{
        'operationId' => backend,
        get => #{
            tags => [?TAGS],
            desc => ?DESC(get_backend),
            parameters => backend_name_in_path(),
            responses => #{
                200 => backend_union(),
                404 => response_schema(404)
            }
        },
        put => #{
            tags => [?TAGS],
            desc => ?DESC(update_backend),
            parameters => backend_name_in_path(),
            'requestBody' => backend_union(),
            responses => #{
                200 => backend_union(),
                404 => response_schema(404)
            }
        },
        delete => #{
            tags => [?TAGS],
            desc => ?DESC(delete_backend),
            parameters => backend_name_in_path(),
            responses => #{
                204 => <<"Delete successfully">>,
                404 => response_schema(404)
            }
        }
    }.

fields(backend_status) ->
    emqx_dashboard_sso_schema:common_backend_schema(emqx_dashboard_sso:types()).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

running(get, _Request) ->
    SSO = emqx:get_config([dashboard_sso], #{}),
    {200,
        lists:filtermap(
            fun
                (#{backend := Backend, enable := true}) ->
                    {true, Backend};
                (_) ->
                    false
            end,
            maps:values(SSO)
        )}.

login(post, #{bindings := #{backend := Backend}, body := Body} = Request) ->
    case emqx_dashboard_sso_manager:lookup_state(Backend) of
        undefined ->
            {404, #{code => ?BACKEND_NOT_FOUND, message => <<"Backend not found">>}};
        State ->
            case emqx_dashboard_sso:login(provider(Backend), Request, State) of
                {ok, Role, Token} ->
                    ?SLOG(info, #{msg => "dashboard_sso_login_successful", request => Request}),
                    Username = maps:get(<<"username">>, Body),
                    {200, login_meta(Username, Role, Token)};
                {redirect, Redirect} ->
                    ?SLOG(info, #{msg => "dashboard_sso_login_redirect", request => Request}),
                    Redirect;
                {error, Reason} ->
                    ?SLOG(info, #{
                        msg => "dashboard_sso_login_failed",
                        request => Request,
                        reason => Reason
                    }),
                    {401, #{code => ?BAD_USERNAME_OR_PWD, message => <<"Auth failed">>}}
            end
    end.

sso(get, _Request) ->
    SSO = emqx:get_config([dashboard_sso], #{}),
    {200,
        lists:map(
            fun(Backend) ->
                maps:with([backend, enable], Backend)
            end,
            maps:values(SSO)
        )}.

backend(get, #{bindings := #{backend := Type}}) ->
    case emqx:get_config([dashboard_sso, Type], undefined) of
        undefined ->
            {404, #{code => ?BACKEND_NOT_FOUND, message => <<"Backend not found">>}};
        Backend ->
            {200, to_json(Backend)}
    end;
backend(put, #{bindings := #{backend := Backend}, body := Config}) ->
    ?SLOG(info, #{msg => "Update SSO backend", backend => Backend, config => Config}),
    on_backend_update(Backend, Config, fun emqx_dashboard_sso_manager:update/2);
backend(delete, #{bindings := #{backend := Backend}}) ->
    ?SLOG(info, #{msg => "Delete SSO backend", backend => Backend}),
    handle_backend_update_result(emqx_dashboard_sso_manager:delete(Backend), undefined).

sso_parameters(Params) ->
    backend_name_as_arg(query, [local], <<"local">>) ++ Params.

%%--------------------------------------------------------------------
%% internal
%%--------------------------------------------------------------------

response_schema(302) ->
    emqx_dashboard_swagger:error_codes([?REDIRECT], ?DESC(redirect));
response_schema(401) ->
    emqx_dashboard_swagger:error_codes([?BAD_USERNAME_OR_PWD], ?DESC(login_failed401));
response_schema(404) ->
    emqx_dashboard_swagger:error_codes([?BACKEND_NOT_FOUND], ?DESC(backend_not_found)).

backend_union() ->
    hoconsc:union([emqx_dashboard_sso:hocon_ref(Mod) || Mod <- emqx_dashboard_sso:modules()]).

login_union() ->
    hoconsc:union([emqx_dashboard_sso:login_ref(Mod) || Mod <- emqx_dashboard_sso:modules()]).

backend_name_in_path() ->
    backend_name_as_arg(path, [], <<"ldap">>).

backend_name_as_arg(In, Extra, Default) ->
    [
        {backend,
            mk(
                enum(Extra ++ emqx_dashboard_sso:types()),
                #{
                    in => In,
                    desc => ?DESC(backend_name_in_qs),
                    required => false,
                    example => Default
                }
            )}
    ].

on_backend_update(Backend, Config, Fun) ->
    Result = valid_config(Backend, Config, Fun),
    handle_backend_update_result(Result, Config).

valid_config(Backend, #{<<"backend">> := Backend} = Config, Fun) ->
    Fun(Backend, Config);
valid_config(_, _, _) ->
    {error, invalid_config}.

handle_backend_update_result({ok, #{backend := saml} = State}, _Config) ->
    {200, to_json(maps:without([idp_meta, sp], State))};
handle_backend_update_result({ok, _State}, Config) ->
    {200, to_json(Config)};
handle_backend_update_result(ok, _) ->
    204;
handle_backend_update_result({error, not_exists}, _) ->
    {404, #{code => ?BACKEND_NOT_FOUND, message => <<"Backend not found">>}};
handle_backend_update_result({error, already_exists}, _) ->
    {400, #{code => ?BAD_REQUEST, message => <<"Backend already exists">>}};
handle_backend_update_result({error, failed_to_load_metadata}, _) ->
    {400, #{code => ?BAD_REQUEST, message => <<"Failed to load metadata">>}};
handle_backend_update_result({error, Reason}, _) ->
    {400, #{code => ?BAD_REQUEST, message => Reason}}.

to_json(Data) ->
    emqx_utils_maps:jsonable_map(
        Data,
        fun(K, V) ->
            {K, emqx_utils_maps:binary_string(V)}
        end
    ).

login_meta(Username, Role, Token) ->
    #{
        username => Username,
        role => Role,
        token => Token,
        version => iolist_to_binary(proplists:get_value(version, emqx_sys:info())),
        license => #{edition => emqx_release:edition()}
    }.
