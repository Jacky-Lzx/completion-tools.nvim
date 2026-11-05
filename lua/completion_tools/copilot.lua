-- Copilot's language server owns credentials and network access. This module
-- owns only the Neovim client; no copilot.lua modules or chat UI are involved.
local M = {}
local instance = 0

function M.params(ctx, root)
  local buf = ctx.bufnr
  local tabsize = vim.bo[buf].shiftwidth
  if tabsize == 0 then
    tabsize = vim.bo[buf].tabstop
  end
  local doc = {
    uri = vim.uri_from_bufnr(buf),
    version = vim.lsp.util.buf_versions[buf] or 0,
    relativePath = root
        and require("completion_tools.copilot_context").relative(vim.api.nvim_buf_get_name(buf), root)
      or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":."),
    position = { line = ctx.row, character = vim.str_utfindex(ctx.line, "utf-16", ctx.col, false) },
    tabSize = tabsize,
    indentSize = tabsize,
    insertSpaces = vim.bo[buf].expandtab,
  }
  return {
    doc = doc,
    textDocument = { uri = doc.uri, version = doc.version },
    position = doc.position,
    context = { triggerKind = 1 },
    formattingOptions = { tabSize = tabsize, insertSpaces = doc.insertSpaces },
  }
end

function M.new(opts)
  opts = opts or {}
  local manager = {}
  local client, disposed, disabled = nil, false, false
  local pending, sequence, last_error, status = {}, 0, nil, nil
  local documents, renaming = {}, {}
  local folders = {}
  local context = require("completion_tools.copilot_context")
  local command = "CompletionToolsCopilot"
  instance = instance + 1
  local group = vim.api.nvim_create_augroup("CompletionToolsCopilot" .. instance, { clear = true })
  local owns_command = not vim.api.nvim_get_commands({})[command]
  local command_definition

  local function changed()
    vim.schedule(function()
      vim.api.nvim_exec_autocmds("User", { pattern = "CompletionToolsCopilotStatus", modeline = false })
    end)
  end
  local function drain(value, err)
    local callbacks = pending
    pending = {}
    for _, cb in pairs(callbacks) do
      cb(value, err)
    end
  end
  local function warn(err)
    last_error = tostring(err)
    changed()
    vim.notify("completion-tools Copilot: " .. last_error, vim.log.levels.WARN)
  end
  function manager.eligible(buf)
    if disposed or disabled or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
      return false
    end
    if vim.bo[buf].buftype ~= "" or not vim.bo[buf].buflisted then
      return false
    end
    local filetypes = opts.filetypes or {}
    local allowed = filetypes[vim.bo[buf].filetype]
    if allowed == false or (allowed == nil and filetypes["*"] == false) then
      return false
    end
    return not opts.should_attach or opts.should_attach(buf) == true
  end
  local function invalidate(buf)
    local cmp = package.loaded.completion_tools
    if cmp and vim.api.nvim_get_current_buf() == buf then
      cmp.hide("copilot_document_changed")
    end
  end
  local function detach(buf, c)
    documents[buf] = nil
    if vim.lsp.buf_is_attached(buf, c.id) then
      vim.lsp.buf_detach_client(buf, c.id)
    end
  end
  local function add_folder(path, c)
    local uri = vim.uri_from_fname(context.directory(path))
    for _, folder in ipairs(folders) do
      if folder.uri == uri then
        return
      end
    end
    local folder = { uri = uri, name = context.directory(path) }
    folders[#folders + 1] = folder
    if c then
      c.workspace_folders = vim.deepcopy(folders)
      local workspace = c.server_capabilities.workspace or {}
      if workspace.workspaceFolders and workspace.workspaceFolders.supported then
        c:notify("workspace/didChangeWorkspaceFolders", { event = { added = { folder }, removed = {} } })
      end
    end
  end
  function manager.params(ctx)
    return M.params(ctx, context.root(ctx.bufnr, opts))
  end
  local function attach(buf, c)
    if manager.eligible(buf) then
      add_folder(context.root(buf, opts), c)
      local document = documents[buf]
      local uri, filetype = vim.uri_from_bufnr(buf), vim.bo[buf].filetype
      if document and (document.uri ~= uri or document.filetype ~= filetype) then
        invalidate(buf)
        detach(buf, c)
      end
      if not vim.lsp.buf_is_attached(buf, c.id) then
        vim.lsp.buf_attach_client(buf, c.id)
      end
      documents[buf] = { uri = uri, filetype = filetype }
      c:notify("textDocument/didFocus", { textDocument = { uri = vim.uri_from_bufnr(buf) } })
      return vim.lsp.buf_is_attached(buf, c.id)
    end
    detach(buf, c)
    return false
  end
  function manager.ensure(buf, callback, for_command)
    if disposed or (not for_command and not manager.eligible(buf)) then
      callback(nil)
      return function() end
    end
    local function ready(c, err)
      if not c or for_command or attach(buf, c) then
        callback(c, err)
      else
        callback(nil)
      end
    end
    if client and not client:is_stopped() and client.initialized then
      ready(client)
      return function() end
    end
    sequence = sequence + 1
    local token = sequence
    pending[token] = ready
    if not client or client:is_stopped() then
      local cmd = opts.command or { "copilot-language-server", "--stdio" }
      if vim.fn.executable(cmd[1]) ~= 1 then
        local err = "Server executable not found: "
          .. cmd[1]
          .. ". Install @github/copilot-language-server or set copilot.command."
        if last_error ~= err then
          warn(err)
        end
        drain(nil, err)
      else
        folders = {}
        local root = context.root(buf, opts)
        add_folder(root)
        for _, path in ipairs(opts.workspace_folders or {}) do
          add_folder(path)
        end
        local caps = vim.lsp.protocol.make_client_capabilities()
        caps.general = caps.general or {}
        caps.general.positionEncodings = { "utf-16" }
        caps.textDocument.inlineCompletion = { dynamicRegistration = false }
        caps.workspace.workspaceFolders = true
        local id = vim.lsp.start({
          name = "completion-tools-copilot",
          cmd = cmd,
          root_dir = root,
          workspace_folders = vim.deepcopy(folders),
          get_language_id = function(_, filetype)
            return context.language(filetype, opts.language_ids)
          end,
          offset_encoding = "utf-16",
          capabilities = caps,
          init_options = {
            editorInfo = { name = "Neovim", version = tostring(vim.version()) },
            editorPluginInfo = { name = "completion-tools.nvim", version = "1.0.0" },
          },
          settings = opts.settings or {},
          handlers = {
            didChangeStatus = function(_, result)
              status = result
              changed()
            end,
            ["textDocument/publishDiagnostics"] = function() end,
          },
          on_init = function(c)
            -- LSP invokes on_init before setting initialized=true.
            vim.schedule(function()
              if not disposed and client == c then
                last_error = nil
                c:notify("workspace/didChangeConfiguration", { settings = opts.settings or vim.empty_dict() })
                drain(c)
                changed()
              end
            end)
          end,
          on_exit = function(code, _, id)
            if not disposed and client and client.id == id then
              client = nil
              documents, renaming = {}, {}
              folders = {}
              last_error = "Server exited (" .. code .. ")"
              drain(nil, last_error)
              changed()
            end
          end,
        }, { attach = false })
        client = id and vim.lsp.get_client_by_id(id) or nil
        if not client then
          last_error = "Could not start Copilot Language Server"
          drain(nil, last_error)
        end
      end
    end
    return function()
      pending[token] = nil
    end
  end
  function manager.record_error(err)
    local message = err and (err.message or tostring(err)) or nil
    if last_error ~= message then
      last_error = message
      changed()
    end
  end
  function manager.get_status()
    return {
      enabled = not disabled,
      running = client ~= nil and not client:is_stopped(),
      initialized = client ~= nil and client.initialized or false,
      server = status and vim.deepcopy(status) or nil,
      attached_buffers = client and vim.deepcopy(client.attached_buffers) or {},
      workspace_folders = vim.deepcopy(folders),
      last_error = last_error,
    }
  end
  function manager.command(action)
    if action == "disable" then
      disabled = true
      changed()
      drain(nil)
      if client then
        for buf in pairs(client.attached_buffers) do
          detach(buf, client)
        end
      end
      require("completion_tools").hide()
      return
    elseif action == "enable" then
      disabled = false
      changed()
      return
    elseif action == "restart" then
      if client then
        client:stop(true)
        client = nil
      end
      status, last_error = nil, nil
      documents, renaming = {}, {}
      folders = {}
      changed()
      drain(nil)
      return
    elseif action == "status" then
      vim.notify(vim.inspect(manager.get_status()), vim.log.levels.INFO)
      return
    end
    manager.ensure(vim.api.nvim_get_current_buf(), function(c)
      if not c then
        return
      end
      local method = action == "auth" and "signIn" or "signOut"
      c:request(method, vim.empty_dict(), function(err, result)
        if disposed then
          return
        elseif err then
          warn(err.message)
          return
        end
        if action == "auth" and result and result ~= vim.NIL and result.userCode then
          vim.notify("GitHub Copilot sign-in code: " .. result.userCode, vim.log.levels.INFO)
          if result.command then
            c:exec_cmd(result.command, { bufnr = vim.api.nvim_get_current_buf() }, function(finish_err)
              if finish_err and not disposed then
                warn(finish_err.message)
              end
            end)
          end
        else
          vim.notify("Copilot: " .. vim.inspect(result), vim.log.levels.INFO)
        end
      end)
    end, true)
  end
  if owns_command then
    vim.api.nvim_create_user_command(command, function(args)
      local action = args.args == "" and "status" or args.args
      if not vim.list_contains({ "auth", "status", "enable", "disable", "restart", "signout" }, action) then
        error("Unknown Copilot action: " .. action)
      end
      manager.command(action)
    end, {
      nargs = "?",
      desc = "Copilot completion authentication and client control",
      complete = function()
        return { "auth", "status", "enable", "disable", "restart", "signout" }
      end,
    })
    command_definition = vim.api.nvim_get_commands({})[command].definition
  end
  vim.api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
    group = group,
    callback = function(args)
      if client and client.initialized and not client:is_stopped() then
        attach(args.buf, client)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufFilePre", "BufWipeout" }, {
    group = group,
    callback = function(args)
      local c = client
      if not c or not vim.lsp.buf_is_attached(args.buf, c.id) then
        return
      end
      -- Detach while Neovim still knows the old URI, flushing pending changes
      -- before didClose. First :write uses BufWipeout/BufNew instead of BufFile*.
      local token = {}
      renaming[args.buf] = token
      invalidate(args.buf)
      detach(args.buf, c)
      vim.schedule(function()
        if renaming[args.buf] ~= token then
          return
        end
        renaming[args.buf] = nil
        -- A failed :file may have no BufFilePost. Actual wipeouts stay detached.
        if not disposed and client == c and args.event == "BufFilePre" then
          attach(args.buf, c)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufFilePost", "BufNew" }, {
    group = group,
    callback = function(args)
      if renaming[args.buf] then
        renaming[args.buf] = nil
        if client and client.initialized and not client:is_stopped() then
          attach(args.buf, client)
        end
      end
    end,
  })
  function manager.dispose()
    if disposed then
      return
    end
    disposed = true
    changed()
    drain(nil)
    vim.api.nvim_del_augroup_by_id(group)
    local current = vim.api.nvim_get_commands({})[command]
    if owns_command and current and current.definition == command_definition then
      vim.api.nvim_del_user_command(command)
    end
    if client then
      client:stop()
      client = nil
    end
  end
  return manager
end

return M
