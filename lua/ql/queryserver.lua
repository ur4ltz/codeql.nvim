local util = require 'ql.util'
local job = require 'ql.job'
local rpc = require 'vim.lsp.rpc'
local protocol = require 'vim.lsp.protocol'
local vim = vim
local api = vim.api

local client_index = 0

-- local functions
local function next_client_id()
  client_index = client_index + 1
  return client_index
end

local function err_message(...)
  api.nvim_err_writeln(table.concat(vim.tbl_flatten{...}))
  api.nvim_command("redraw")
end

local function cmd_parts(input)
  local cmd, cmd_args
  if vim.tbl_islist(input) then
    cmd = input[1]
    cmd_args = {}
    -- Don't mutate our input.
    for i, v in ipairs(input) do
      assert(type(v) == 'string', "input arguments must be strings")
      if i > 1 then
        table.insert(cmd_args, v)
      end
    end
  else
    error("cmd type must be list.")
  end
  return cmd, cmd_args
end

-- exported functions
local M = {}

function M.start_client(config)
  local cmd, cmd_args = cmd_parts(config.cmd)

  local client_id = next_client_id()

  local callbacks = config.callbacks or {}
  local name = config.name or tostring(client_id)
  local log_prefix = string.format("LSP[%s]", name)
  local handlers = {}

  local function resolve_callback(method)
    return callbacks[method] -- or default_callbacks[method]
  end

  function handlers.notification(method, params)
    local callback = resolve_callback(method)
    if callback then
      -- Method name is provided here for convenience.
      callback(method, params, client_id)
    end
  end

  function handlers.server_request(method, params)
    local callback = resolve_callback(method)
    if callback then
      return callback(method, params, client_id)
    end
    return nil, rpc.rpc_response_error(protocol.ErrorCodes.MethodNotFound)
  end

  function handlers.on_error(code, err)
    err_message(log_prefix, ': Error ', rpc.client_errors[code], ': ', vim.inspect(err))
    if config.on_error then
      local status, usererr = pcall(config.on_error, code, err)
      if not status then
        err_message(log_prefix, ' user on_error failed: ', tostring(usererr))
      end
    end
  end

  function handlers.on_exit(code, signal)
    if config.on_exit then
      pcall(config.on_exit, code, signal)
    end
  end

  -- Start the RPC client.
  return rpc.start(cmd, cmd_args, handlers, {
    cwd = config.cmd_cwd;
    env = config.cmd_env;
  })
end

local clients = {}

function M.start_server(buf)
  if clients[buf] then
    print("Query Server already started for buffer "..buf)
    return clients[buf]
  end
  local config = {
      cmd             = {"codeql", "execute", "query-server", "--logdir", "/tmp/codeql"};
      offset_encoding = {"utf-8", "utf-16"};
      callbacks = {
        ['ql/progressUpdated'] = function(_, params, _)
          print(params.message)
        end;
        ['evaluation/queryCompleted'] = function(_, _, _)
          -- if ok, return {}, else return error (eg rpc.rpc_response_error(protocol.ErrorCodes.MethodNotFound))
          return {}
        end
      }
  }
  local client = M.start_client(config)
  clients[buf] = client
  return client
end

function M.run_query(config)
  local client = nil
  if clients[config.buf] then
    client = clients[config.buf]
  else
    client = M.start_server(config.buf)
    clients[config.buf] = client
  end
  local queryPath = config.query
  local dbPath = config.db
  local qloPath = vim.fn.tempname()
  local resultsPath = vim.fn.tempname()

  local json = util.run_cmd('codeql resolve library-path --format=json --query='..queryPath, true)
  local decoded, err = util.json_decode(json)
  if not decoded then
      print("Error resolving library path: "..err)
      return
  end
  local libraryPath = decoded.libraryPath

  local dbDir = dbPath
  for _, dir in ipairs(vim.fn.glob(vim.fn.fnameescape(dbPath)..'*', 1, 1)) do
    if vim.startswith(dir, dbPath..'db-') then
      dbDir = dir
      break
    end
  end
  local dbScheme = decoded.dbscheme

  -- https://github.com/github/vscode-codeql/blob/master/extensions/ql-vscode/src/messages.ts
  local compileQuery_params = {
    body = {
      compilationOptions = {
        computeNoLocationUrls = true;
        failOnWarnings = false;
        fastCompilation = false;
        includeDilInQlo = true;
        localChecking = false;
        noComputeGetUrl = false;
        noComputeToString = false;
      };
      extraOptions = {
        timeoutSecs = 0;
      };
      queryToCheck = {
        libraryPath = libraryPath;
        dbschemePath = dbScheme;
        queryPath = queryPath;
      };
      resultPath = qloPath;
      target = config.quick_eval and {
        quickEval = {
          quickEvalPos = {
            fileName = queryPath;
            line = config.startLine;
            column = config.startColumn;
            endLine = config.endLine;
            endColumn = config.endColumn;
          };
        };
      } or {
        query = {xx = ''}
      };
    };
    progressId = 1;
  }

  local runQueries_callback = function(err, _)
    if err then
      util.print_dump(err)
    else
      if vim.fn.glob(resultsPath) ~= '' then
        print("QLO: " .. qloPath)
        print("BQRS: " .. resultsPath)
        -- process results
        if config.quick_eval or config.metadata['kind'] ~= "path-problem" then
          local jsonPath = vim.fn.tempname()
          local cmds = {
            {'codeql', 'bqrs', 'decode', '-o='..jsonPath, '--format=json', '--entities=string,url', resultsPath},
            {'load_json', jsonPath, dbPath, config.metadata}
          }
          print("JSON: "..jsonPath)
          job.run_commands(cmds)
          print(' ')
        elseif config.metadata['kind'] == "path-problem" and config.metadata['id'] ~= nil then
          local sarifPath = vim.fn.tempname()
          local cmds = {
            {'codeql', 'bqrs', 'interpret', resultsPath, '-t=id='..config.metadata['id'], '-t=kind=path-problem', '-o='..sarifPath, '--format=sarif-latest'},
            {'load_sarif', sarifPath, dbPath, config.metadata}
          }
          print("SARIF: "..sarifPath)
          job.run_commands(cmds)
          print(' ')
        elseif config.metadata['kind'] == "path-problem" then
          print("Error: Insuficient Metadata for a Path Problem. Need at least @kind and @id elements")
        else
          print("Error: Could not interpret the results")
        end
      else
        print("Error: BQRS file was not created")
        return
      end
    end
  end

  local compileQuery_callback = function(err, _)
    if err then
      util.print_dump(err)
    else
      -- prepare `runQueries` params
      local runQueries_params = {
        body = {
          db = {
            dbDir = dbDir;
            workingSet = "default";
          };
          evaluateId = 0;
          queries = {
            {
              resultsPath = resultsPath;
              qlo = "file://"..qloPath;
              allowUnknownTemplates = true;
              id = 0;
              timeoutSecs = 0;
            }
          };
          stopOnError = false;
          useSequenceHint = false;
        };
        progressId = 2;
      }

      -- run query
      client.request("evaluation/runQueries", runQueries_params, runQueries_callback)
    end
  end

  -- compile query
  client.request("compilation/compileQuery", compileQuery_params, compileQuery_callback)
end

function M.shutdown_server(buf)
  if clients[buf] then
    local client = clients[buf]
    local handle = client.handle
    util.print_dump(handle)
    handle:kill()
    clients[buf] = nil
  end
end

return M
