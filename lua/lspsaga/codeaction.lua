local api, util, fn, lsp = vim.api, vim.lsp.util, vim.fn, vim.lsp
local config = require('lspsaga').config
local window = require('lspsaga.window')
local nvim_buf_set_keymap = api.nvim_buf_set_keymap
local act = {}
local ctx = {}

act.__index = act
function act.__newindex(t, k, v)
  rawset(t, k, v)
end

local function clean_ctx()
  for k, _ in pairs(ctx) do
    ctx[k] = nil
  end
end

local function clean_msg(msg)
  if msg:find('%(.+%)%S$') then
    return msg:gsub('%(.+%)%S$', '')
  end
  return msg
end

function act:action_callback()
  local contents = {}

  for index, client_with_actions in pairs(self.action_tuples) do
    local action_title = ''
    if #client_with_actions ~= 2 then
      vim.notify('There is something wrong in aciton_tuples')
      return
    end
    if client_with_actions[2].title then
      action_title = '[' .. index .. '] ' .. clean_msg(client_with_actions[2].title)
    end
    if config.code_action.show_server_name == true then
      if type(client_with_actions[1]) == 'string' then
        action_title = action_title .. '  (' .. client_with_actions[1] .. ')'
      else
        action_title = action_title
          .. '  ('
          .. lsp.get_client_by_id(client_with_actions[1]).name
          .. ')'
      end
    end
    contents[#contents + 1] = action_title
  end

  local content_opts = {
    contents = contents,
    filetype = 'sagacodeaction',
    buftype = 'nofile',
    enter = true,
    highlight = {
      normal = 'CodeActionNormal',
      border = 'CodeActionBorder',
    },
  }

  local opt = {}
  local max_height = math.floor(vim.o.lines * 0.5)
  opt.height = max_height < #contents and max_height or #contents
  local max_width = math.floor(vim.o.columns * 0.7)
  local max_len = window.get_max_content_length(contents)
  opt.width = max_len + 10 < max_width and max_len + 5 or max_width
  opt.no_size_override = true

  if fn.has('nvim-0.9') == 1 and config.ui.title then
    opt.title = {
      { config.ui.code_action .. ' CodeActions', 'TitleString' },
    }
  end

  self.action_bufnr, self.action_winid = window.create_win_with_border(content_opts, opt)
  vim.wo[self.action_winid].conceallevel = 2
  vim.wo[self.action_winid].concealcursor = 'niv'
  -- initial position in code action window
  api.nvim_win_set_cursor(self.action_winid, { 1, 1 })

  api.nvim_create_autocmd('CursorMoved', {
    buffer = self.action_bufnr,
    callback = function()
      self:set_cursor()
    end,
  })

  for i = 1, #contents, 1 do
    local row = i - 1
    local col = contents[i]:find('%]')
    api.nvim_buf_add_highlight(self.action_bufnr, -1, 'CodeActionText', row, 0, -1)
    api.nvim_buf_add_highlight(self.action_bufnr, 0, 'CodeActionNumber', row, 0, col)
  end

  self:apply_action_keys()
  if config.code_action.num_shortcut then
    self:num_shortcut(self.action_bufnr)
  end
end

local function map_keys(mode, keys, action, options)
  if type(keys) == 'string' then
    keys = { keys }
  end
  for _, key in ipairs(keys) do
    vim.keymap.set(mode, key, action, options)
  end
end

---@private
---@param bufnr integer
---@param mode "v"|"V"
---@return table {start={row, col}, end={row, col}} using (1, 0) indexing
local function range_from_selection(bufnr, mode)
  -- TODO: Use `vim.region()` instead https://github.com/neovim/neovim/pull/13896
  -- [bufnum, lnum, col, off]; both row and column 1-indexed
  local start = vim.fn.getpos('v')
  local end_ = vim.fn.getpos('.')
  local start_row = start[2]
  local start_col = start[3]
  local end_row = end_[2]
  local end_col = end_[3]

  -- A user can start visual selection at the end and move backwards
  -- Normalize the range to start < end
  if start_row == end_row and end_col < start_col then
    end_col, start_col = start_col, end_col
  elseif end_row < start_row then
    start_row, end_row = end_row, start_row
    start_col, end_col = end_col, start_col
  end
  if mode == 'V' then
    start_col = 1
    local lines = api.nvim_buf_get_lines(bufnr, end_row - 1, end_row, true)
    end_col = #lines[1]
  end
  return {
    ['start'] = { start_row, start_col - 1 },
    ['end'] = { end_row, end_col - 1 },
  }
end

function act:apply_action_keys()
  map_keys('n', config.code_action.keys.exec, function()
    self:do_code_action()
  end, { buffer = self.action_bufnr })

  map_keys('n', config.code_action.keys.quit, function()
    self:close_action_window()
    clean_ctx()
  end, { buffer = self.action_bufnr })
end

function act:send_code_action_request(main_buf, options, cb)
  local diagnostics = lsp.diagnostic.get_line_diagnostics(main_buf)
  self.bufnr = main_buf
  local ctx_diags = { diagnostics = diagnostics }
  local params
  local mode = api.nvim_get_mode().mode
  options = options or {}
  if options.range then
    assert(type(options.range) == 'table', 'code_action range must be a table')
    local start = assert(options.range.start, 'range must have a `start` property')
    local end_ = assert(options.range['end'], 'range must have an `end` property')
    params = util.make_given_range_params(start, end_)
  elseif mode == 'v' or mode == 'V' then
    local range = range_from_selection(0, mode)
    params = util.make_given_range_params(range.start, range['end'])
  else
    params = util.make_range_params()
  end
  params.context = ctx_diags
  if not self.enriched_ctx then
    self.enriched_ctx = { bufnr = main_buf, method = 'textDocument/codeAction', params = params }
  end

  lsp.buf_request_all(main_buf, 'textDocument/codeAction', params, function(results)
    self.pending_request = false
    self.action_tuples = {}

    for client_id, result in pairs(results) do
      for _, action in pairs(result.result or {}) do
        self.action_tuples[#self.action_tuples + 1] = { client_id, action }
      end
    end

    if config.code_action.extend_gitsigns then
      local res = self:extend_gitsing(params)
      if res then
        for _, action in pairs(res) do
          self.action_tuples[#self.action_tuples + 1] = { 'gitsigns', action }
        end
      end
    end

    if #self.action_tuples == 0 and not options.silent then
      vim.notify('No code actions available', vim.log.levels.INFO)
      return
    end

    if cb then
      cb(vim.deepcopy(self.action_tuples), vim.deepcopy(self.enriched_ctx))
    end
  end)
end

function act:set_cursor()
  local col = 1
  local current_line = api.nvim_win_get_cursor(self.action_winid)[1]

  if current_line == #self.action_tuples + 1 then
    api.nvim_win_set_cursor(self.action_winid, { 1, col })
  else
    api.nvim_win_set_cursor(self.action_winid, { current_line, col })
  end
  self:action_preview(self.action_winid, self.bufnr)
end

function act:num_shortcut(bufnr)
  for num, _ in pairs(self.action_tuples or {}) do
    nvim_buf_set_keymap(bufnr, 'n', tostring(num), '', {
      noremap = true,
      nowait = true,
      callback = function()
        self:do_code_action(num)
      end,
    })
  end
end

function act:code_action(options)
  if self.pending_request then
    vim.notify(
      '[lspsaga.nvim] there is already a code action request please wait',
      vim.log.levels.WARN
    )
    return
  end
  self.pending_request = true
  options = options or {}

  self:send_code_action_request(api.nvim_get_current_buf(), options, function()
    self:action_callback()
  end)
end

function act:apply_action(action, client, enriched_ctx)
  if action.edit then
    util.apply_workspace_edit(action.edit, client.offset_encoding)
  end
  if action.command then
    local command = type(action.command) == 'table' and action.command or action
    local func = client.commands[command.command] or lsp.commands[command.command]
    if func then
      enriched_ctx.client_id = client.id
      func(command, enriched_ctx)
    else
      local params = {
        command = command.command,
        arguments = command.arguments,
        workDoneToken = command.workDoneToken,
      }
      client.request('workspace/executeCommand', params, nil, enriched_ctx.bufnr)
    end
  end
  clean_ctx()
end

function act:do_code_action(num, tuple, enriched_ctx)
  local number
  if num then
    number = tonumber(num)
  else
    local cur_text = api.nvim_get_current_line()
    number = cur_text:match('%[(%d+)%]%s+%S')
    number = tonumber(number)
  end

  if not number and not tuple then
    vim.notify('[Lspsaga] no action number choice', vim.log.levels.WARN)
    return
  end

  local action = tuple and tuple[2] or vim.deepcopy(self.action_tuples[number][2])
  local id = tuple and tuple[1] or self.action_tuples[number][1]
  local client = lsp.get_client_by_id(id)

  local curbuf = api.nvim_get_current_buf()
  self:close_action_window(curbuf)
  enriched_ctx = enriched_ctx or vim.deepcopy(self.enriched_ctx)
  if
    not action.edit
    and client
    and vim.tbl_get(client.server_capabilities, 'codeActionProvider', 'resolveProvider')
  then
    client.request('codeAction/resolve', action, function(err, resolved_action)
      if err then
        vim.notify(err.code .. ': ' .. err.message, vim.log.levels.ERROR)
        return
      end
      self:apply_action(resolved_action, client, enriched_ctx)
    end)
  elseif action.action and type(action.action) == 'function' then
    action.action()
  else
    self:apply_action(action, client, enriched_ctx)
  end
end

function act:get_action_diff(num, main_buf, tuple)
  local action = tuple and tuple[2] or self.action_tuples[tonumber(num)][2]
  if not action then
    return
  end

  local id = tuple and tuple[1] or self.action_tuples[tonumber(num)][1]
  local client = lsp.get_client_by_id(id)
  if
    not action.edit
    and client
    and vim.tbl_get(client.server_capabilities, 'codeActionProvider', 'resolveProvider')
  then
    local results = lsp.buf_request_sync(main_buf, 'codeAction/resolve', action, 1000)
    ---@diagnostic disable-next-line: need-check-nil
    action = results[client.id].result
    if not action then
      return
    end
    if tuple then
      tuple[tonumber(num)][2] = action
    elseif self.action_tuples then
      self.action_tuples[tonumber(num)][2] = action
    end
  end

  if not action.edit then
    return
  end

  local all_changes = {}
  if action.edit.documentChanges then
    for _, item in pairs(action.edit.documentChanges) do
      if item.textDocument then
        if not all_changes[item.textDocument.uri] then
          all_changes[item.textDocument.uri] = {}
        end
        for _, edit in pairs(item.edits) do
          table.insert(all_changes[item.textDocument.uri], edit)
        end
      end
    end
  elseif action.edit.changes then
    all_changes = action.edit.changes
  end

  if not (all_changes and not vim.tbl_isempty(all_changes)) then
    return
  end

  local tmp_buf = api.nvim_create_buf(false, false)
  vim.bo[tmp_buf].bufhidden = 'wipe'
  local lines = api.nvim_buf_get_lines(main_buf, 0, -1, false)
  api.nvim_buf_set_lines(tmp_buf, 0, -1, false, lines)

  for _, changes in pairs(all_changes) do
    util.apply_text_edits(changes, tmp_buf, client.offset_encoding)
  end
  local data = api.nvim_buf_get_lines(tmp_buf, 0, -1, false)
  api.nvim_buf_delete(tmp_buf, { force = true })
  local diff = vim.diff(table.concat(lines, '\n') .. '\n', table.concat(data, '\n') .. '\n')
  return diff
end

function act:action_preview(main_winid, main_buf, border_hi, tuple)
  if self.preview_winid and api.nvim_win_is_valid(self.preview_winid) then
    api.nvim_win_close(self.preview_winid, true)
    self.preview_winid = nil
  end
  local line = api.nvim_get_current_line()
  local num = line:match('%[(%d+)%]')
  if not num then
    return
  end

  local tbl = self:get_action_diff(num, main_buf, tuple)
  if not tbl or #tbl == 0 then
    return
  end

  tbl = vim.split(tbl, '\n')
  table.remove(tbl, 1)

  local win_conf = api.nvim_win_get_config(main_winid)
  local max_height
  local opt = {
    relative = win_conf.relative,
    win = win_conf.win,
    width = win_conf.width,
    no_size_override = true,
    col = win_conf.col[false],
    anchor = win_conf.anchor,
    focusable = false,
  }
  local winheight = api.nvim_win_get_height(win_conf.win)

  if win_conf.anchor:find('^S') then
    opt.row = win_conf.row[false] - win_conf.height - 2
    max_height = win_conf.row[false] - win_conf.height
  elseif win_conf.anchor:find('^N') then
    opt.row = win_conf.row[false] + win_conf.height + 2
    max_height = winheight - opt.row
  end
  opt.height = #tbl > max_height and max_height or #tbl

  if fn.has('nvim-0.9') == 1 and config.ui.title then
    opt.title = { { 'Action Preview', 'ActionPreviewTitle' } }
  end

  local content_opts = {
    contents = tbl,
    filetype = 'diff',
    bufhidden = 'wipe',
    highlight = {
      normal = 'ActionPreviewNormal',
      border = border_hi or 'ActionPreviewBorder',
    },
  }

  local preview_buf
  preview_buf, self.preview_winid = window.create_win_with_border(content_opts, opt)
  vim.bo[preview_buf].syntax = 'on'
  return self.preview_winid
end

function act:close_action_window(bufnr)
  if self.action_winid and api.nvim_win_is_valid(self.action_winid) then
    api.nvim_win_close(self.action_winid, true)
  end
  if self.preview_winid and api.nvim_win_is_valid(self.preview_winid) then
    api.nvim_win_close(self.preview_winid, true)
  end

  if config.code_action.num_shortcut and self.action_tuples and #self.action_tuples > 1 then
    for i = 1, #self.action_tuples do
      pcall(api.nvim_buf_del_keymap, bufnr, 'n', tostring(i))
    end
  end
end

function act:clean_context()
  clean_ctx()
end

function act:extend_gitsing(params)
  local ok, gitsigns = pcall(require, 'gitsigns')
  if not ok then
    return
  end

  local gitsigns_actions = gitsigns.get_actions()
  if not gitsigns_actions or vim.tbl_isempty(gitsigns_actions) then
    return
  end

  local name_to_title = function(name)
    return name:sub(1, 1):upper() .. name:gsub('_', ' '):sub(2)
  end

  local actions = {}
  local range_actions = { ['reset_hunk'] = true, ['stage_hunk'] = true }
  local mode = vim.api.nvim_get_mode().mode
  for name, action in pairs(gitsigns_actions) do
    local title = name_to_title(name)
    local cb = action
    if (mode == 'v' or mode == 'V') and range_actions[name] then
      title = title:gsub('hunk', 'selection')
      cb = function()
        action({ params.range.start.line, params.range['end'].line })
      end
    end
    actions[#actions + 1] = {
      title = title,
      action = function()
        local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
        vim.api.nvim_buf_call(bufnr, cb)
      end,
    }
  end
  return actions
end

return setmetatable(ctx, act)
