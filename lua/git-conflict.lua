local M = {}

local color = require('git-conflict.colors')
local utils = require('git-conflict.utils')

local fn = vim.fn
local api = vim.api
local map = vim.keymap.set
-----------------------------------------------------------------------------//
-- REFERENCES:
-----------------------------------------------------------------------------//
-- Advanced merging
-- https://git-scm.com/book/en/v2/Git-Tools-Advanced-Merging

-----------------------------------------------------------------------------//
-- Types
-----------------------------------------------------------------------------//

---@alias ConflictSide "'ours'"|"'theirs'"|"'both'"|"'base'"|"'none'"

--- @class ConflictHighlights
--- @field current string
--- @field incoming string
--- @field ancestor string?

--- @class ConflictLabel
--- @field lnum integer
--- @field hl string
--- @field text string

--- @class Range
--- @field range_start integer
--- @field range_end integer
--- @field content_start integer
--- @field content_end integer

--- @class ConflictPosition
--- @field incoming Range
--- @field middle Range
--- @field current Range
--- @field labels ConflictLabel[]

--- @class ConflictBufferCache
--- @field lines table<integer, boolean> map of conflicted line numbers
--- @field positions ConflictPosition[]
--- @field tick integer
--- @field bufnr integer

--- A keymap applied while a buffer has conflicts, written like a lazy.nvim `keys` entry.
--- Any field other than these is passed straight through to `vim.keymap.set`.
--- @class ConflictMapping
--- @field [1] string the keys to bind
--- @field [2] string|function what they run, e.g. '<cmd>GitConflictChooseOurs<cr>'
--- @field mode? string|string[] defaults to normal mode
--- @field desc? string label shown by which-key and :map

--- @class GitConflictConfig
--- @field mappings ConflictMapping[]
--- @field default_commands boolean
--- @field disable_diagnostics boolean
--- @field highlights ConflictHighlights
--- @field debug boolean

--- @class GitConflictUserConfig
--- @field mappings? ConflictMapping[]
--- @field default_commands? boolean
--- @field disable_diagnostics? boolean
--- @field highlights? ConflictHighlights
--- @field debug? boolean

-----------------------------------------------------------------------------//
-- Constants
-----------------------------------------------------------------------------//
local SIDES = {
  OURS = 'ours',
  THEIRS = 'theirs',
  BOTH = 'both',
  BASE = 'base',
  NONE = 'none',
}

-- A mapping between the internal names and the display names
local name_map = {
  ours = 'current',
  theirs = 'incoming',
  base = 'ancestor',
  both = 'both',
  none = 'none',
}

local CURRENT_HL = 'GitConflictCurrent'
local INCOMING_HL = 'GitConflictIncoming'
local ANCESTOR_HL = 'GitConflictAncestor'
local CURRENT_LABEL_HL = 'GitConflictCurrentLabel'
local INCOMING_LABEL_HL = 'GitConflictIncomingLabel'
local ANCESTOR_LABEL_HL = 'GitConflictAncestorLabel'
local PRIORITY = (vim.hl or vim.highlight).priorities.user
local NAMESPACE = api.nvim_create_namespace('git-conflict')
local AUGROUP_NAME = 'GitConflictCommands'

local conflict_start = '^<<<<<<<'
local conflict_middle = '^======='
local conflict_end = '^>>>>>>>'
local conflict_ancestor = '^|||||||'

local DEFAULT_CURRENT_BG_COLOR = 4218238  -- #405d7e
local DEFAULT_INCOMING_BG_COLOR = 3229523 -- #314753
local DEFAULT_ANCESTOR_BG_COLOR = 6824314 -- #68217A
-----------------------------------------------------------------------------//

--- @type GitConflictConfig
local config = {
  debug = false,
  --- Keymaps written like lazy.nvim's `keys`, applied buffer-locally while a buffer has
  --- conflicts and removed once it no longer does. Empty by default: this plugin claims no
  --- keys unless you ask for them.
  mappings = {},
  default_commands = true,
  disable_diagnostics = false,
  highlights = {
    current = 'DiffText',
    incoming = 'DiffAdd',
    ancestor = nil,
  },
}

--- @return table<string, ConflictBufferCache>
local function create_visited_buffers()
  return setmetatable({}, {
    __index = function(t, k)
      if type(k) == 'number' then return t[api.nvim_buf_get_name(k)] end
    end,
  })
end

--- Buffers that contain conflict markers, keyed by full path.
local visited_buffers = create_visited_buffers()

-----------------------------------------------------------------------------//

---Add the positions to the buffer in our in memory buffer list
---positions are keyed by a list of range start and end for each mark
---@param buf integer
---@param positions ConflictPosition[]
local function update_visited_buffers(buf, positions)
  if not buf or not api.nvim_buf_is_valid(buf) then return end
  local name = api.nvim_buf_get_name(buf)
  -- If this buffer is not in the list
  if not visited_buffers[name] then return end
  visited_buffers[name].bufnr = buf
  visited_buffers[name].tick = vim.b[buf].changedtick
  visited_buffers[name].positions = positions
end

---Set an extmark for each section of the git conflict
---@param bufnr integer
---@param hl string
---@param range_start integer
---@param range_end integer
local function hl_range(bufnr, hl, range_start, range_end)
  if not range_start or not range_end then return end
  api.nvim_buf_set_extmark(bufnr, NAMESPACE, range_start, 0, {
    hl_group = hl,
    hl_eol = true,
    hl_mode = 'combine',
    end_row = range_end,
    priority = PRIORITY,
  })
end

---Highlight each part of a git conflict i.e. the incoming changes vs the current/HEAD changes
---The section headings are not drawn here: they are overlays sized to a window, so they are
---drawn per window by `draw_labels` and only the text to draw is recorded.
---@param bufnr integer
---@param positions ConflictPosition[]
---@param lines string[]
local function highlight_conflicts(bufnr, positions, lines)
  M.clear(bufnr)

  for _, position in ipairs(positions) do
    local current_start = position.current.range_start
    local current_end = position.current.range_end
    local incoming_start = position.incoming.range_start
    local incoming_end = position.incoming.range_end

    hl_range(bufnr, CURRENT_HL, current_start, current_end + 1)
    hl_range(bufnr, INCOMING_HL, incoming_start, incoming_end + 1)

    -- Add one since the index access in lines is 1 based
    local current_label = lines[current_start + 1] .. ' (Current changes)'
    local incoming_label = lines[incoming_end + 1] .. ' (Incoming changes)'

    position.labels = {
      { lnum = current_start, hl = CURRENT_LABEL_HL, text = current_label },
      { lnum = incoming_end, hl = INCOMING_LABEL_HL, text = incoming_label },
    }
    if not vim.tbl_isempty(position.ancestor) then
      local ancestor_start = position.ancestor.range_start
      local ancestor_end = position.ancestor.range_end
      -- An empty base section has no content rows; highlighting it would spill onto the separator
      if ancestor_end > ancestor_start then
        hl_range(bufnr, ANCESTOR_HL, ancestor_start + 1, ancestor_end + 1)
      end
      position.labels[#position.labels + 1] = {
        lnum = ancestor_start,
        hl = ANCESTOR_LABEL_HL,
        text = lines[ancestor_start + 1] .. ' (Base changes)',
      }
    end
  end
end

---Cover each section heading with its label, padded out to fill the window it is drawn in.
---The marks are ephemeral because the padding is only correct for `winid`, and the same buffer
---can be on screen in windows of different widths.
---@param bufnr integer
---@param winid integer
---@param toprow integer
---@param botrow integer
local function draw_labels(bufnr, winid, toprow, botrow)
  local positions = visited_buffers[bufnr] and visited_buffers[bufnr].positions
  if not positions then return end
  local width = api.nvim_win_get_width(winid)
  for _, position in ipairs(positions) do
    for _, label in ipairs(position.labels or {}) do
      if label.lnum >= toprow and label.lnum <= botrow then
        local padding = string.rep(' ', math.max(width - api.nvim_strwidth(label.text), 0))
        api.nvim_buf_set_extmark(bufnr, NAMESPACE, label.lnum, 0, {
          virt_text = { { label.text .. padding, label.hl } },
          virt_text_pos = 'overlay',
          priority = PRIORITY,
          ephemeral = true,
        })
      end
    end
  end
end

---Iterate through the buffer line by line checking there is a matching conflict marker
---when we find a starting mark we collect the position details and add it to a list of positions
---@param lines string[]
---@return boolean
---@return ConflictPosition[]
local function detect_conflicts(lines)
  local positions = {}
  local position, has_start, has_middle, has_ancestor = nil, false, false, false
  for index, line in ipairs(lines) do
    local lnum = index - 1
    if line:match(conflict_start) then
      has_start = true
      position = {
        current = { range_start = lnum, content_start = lnum + 1 },
        middle = {},
        incoming = {},
        ancestor = {},
      }
    end
    if has_start and line:match(conflict_ancestor) then
      has_ancestor = true
      position.ancestor.range_start = lnum
      position.ancestor.content_start = lnum + 1
      position.current.range_end = lnum - 1
      position.current.content_end = lnum - 1
    end
    if has_start and line:match(conflict_middle) then
      has_middle = true
      if has_ancestor then
        position.ancestor.content_end = lnum - 1
        position.ancestor.range_end = lnum - 1
      else
        position.current.range_end = lnum - 1
        position.current.content_end = lnum - 1
      end
      position.middle.range_start = lnum
      position.middle.range_end = lnum + 1
      position.incoming.range_start = lnum + 1
      position.incoming.content_start = lnum + 1
    end
    if has_start and has_middle and line:match(conflict_end) then
      position.incoming.range_end = lnum
      position.incoming.content_end = lnum - 1
      positions[#positions + 1] = position

      position, has_start, has_middle, has_ancestor = nil, false, false, false
    end
  end
  return #positions > 0, positions
end

---Helper function to find a conflict position based on a comparator function
---@param bufnr integer
---@param comparator fun(string, integer): boolean
---@param opts table?
---@return ConflictPosition?
local function find_position(bufnr, comparator, opts)
  local match = visited_buffers[bufnr]
  if not match then return end
  local line = utils.get_cursor_pos()
  line = line - 1 -- Convert to 0-based for position comparison

  if opts and opts.reverse then
    for i = #match.positions, 1, -1 do
      local position = match.positions[i]
      if comparator(line, position) then return position end
    end
    if opts.wrap and match.positions[#match.positions] then
      return match.positions[#match.positions]
    end
    return nil
  end

  for _, position in ipairs(match.positions) do
    if comparator(line, position) then return position end
  end

  if opts and opts.wrap and match.positions[1] then return match.positions[1] end
  return nil
end

---Retrieves a conflict marker position by checking the visited buffers for a supported range
---@param bufnr integer
---@return ConflictPosition?
local function get_current_position(bufnr)
  return find_position(
    bufnr,
    function(line, position)
      return position.current.range_start <= line and position.incoming.range_end >= line
    end
  )
end

---@param position ConflictPosition?
---@param side ConflictSide
local function set_cursor(position, side)
  if not position then return end
  local target = side == SIDES.OURS and position.current or position.incoming
  api.nvim_win_set_cursor(0, { target.range_start + 1, 0 })
end

---Get the conflict marker positions for a buffer if any and update the buffers state
---@param bufnr integer
---@param range_start integer
---@param range_end integer
local function parse_buffer(bufnr, range_start, range_end)
  local lines = utils.get_buf_lines(range_start or 0, range_end or -1, bufnr)
  local prev_conflicts = visited_buffers[bufnr].positions ~= nil
      and #visited_buffers[bufnr].positions > 0
  local has_conflict, positions = detect_conflicts(lines)

  update_visited_buffers(bufnr, positions)
  if has_conflict then
    highlight_conflicts(bufnr, positions, lines)
  else
    M.clear(bufnr)
  end
  if vim.b[bufnr].git_conflict_active ~= has_conflict then
    vim.b[bufnr].git_conflict_active = has_conflict
    local pattern = has_conflict and 'GitConflictDetected' or 'GitConflictResolved'
    -- This can run inside the decoration provider, where a handler may not touch text or windows
    vim.schedule(function()
      if api.nvim_buf_is_valid(bufnr) then
        api.nvim_exec_autocmds('User', { pattern = pattern, data = { bufnr = bufnr } })
      end
    end)
  end
end

---Does this buffer contain conflict markers?
---@param bufnr integer
---@return boolean
local function has_markers(bufnr)
  for _, line in ipairs(api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:match(conflict_start) then return true end
  end
  return false
end

--- Start tracking a buffer that contains conflict markers, or stop tracking one that no
--- longer does. Detection is purely textual: a buffer is conflicted if it looks conflicted,
--- with no dependency on the cwd, the repository, or git being reachable at all.
---@param bufnr integer?
---@param force boolean? rescan even if the buffer has not changed since the last scan
local function track_buffer(bufnr, force)
  bufnr = bufnr or api.nvim_get_current_buf()
  if not api.nvim_buf_is_valid(bufnr) or not utils.is_valid_buf(bufnr) then return end
  -- Only what is on screen matters; a hidden buffer is scanned again when it is displayed
  if #fn.win_findbuf(bufnr) == 0 then return end
  local name = api.nvim_buf_get_name(bufnr)
  if name == '' then return end
  -- Scanning is O(lines) and this runs on every BufEnter, so skip untouched buffers
  if not force and vim.b[bufnr].git_conflict_scan == vim.b[bufnr].changedtick then return end
  vim.b[bufnr].git_conflict_scan = vim.b[bufnr].changedtick
  if not has_markers(bufnr) then
    if visited_buffers[name] then
      visited_buffers[name] = nil
      M.clear(bufnr)
    end
    return
  end
  visited_buffers[name] = visited_buffers[name] or {}
  parse_buffer(bufnr)
end

---Process a buffer if the changed tick has changed
---@param bufnr integer?
local function process(bufnr, range_start, range_end)
  bufnr = bufnr or api.nvim_get_current_buf()
  if visited_buffers[bufnr] and visited_buffers[bufnr].tick == vim.b[bufnr].changedtick then
    return
  end
  parse_buffer(bufnr, range_start, range_end)
end

-----------------------------------------------------------------------------//
-- Commands
-----------------------------------------------------------------------------//

local function set_commands()
  local command = api.nvim_create_user_command
  command('GitConflictRefresh', function() track_buffer(nil, true) end, { nargs = 0 })
  command('GitConflictChooseOurs', function() M.choose(SIDES.OURS) end, { nargs = 0 })
  command('GitConflictChooseTheirs', function() M.choose(SIDES.THEIRS) end, { nargs = 0 })
  command('GitConflictChooseBoth', function() M.choose(SIDES.BOTH) end, { nargs = 0 })
  command('GitConflictChooseBase', function() M.choose(SIDES.BASE) end, { nargs = 0 })
  command('GitConflictChooseNone', function() M.choose(SIDES.NONE) end, { nargs = 0 })
  command('GitConflictNextConflict', function() M.find_next(SIDES.OURS) end, { nargs = 0 })
  command('GitConflictPrevConflict', function() M.find_prev(SIDES.OURS) end, { nargs = 0 })
end

-----------------------------------------------------------------------------//
-- Mappings
-----------------------------------------------------------------------------//

local function set_plug_mappings()
  local function opts(desc) return { silent = true, desc = 'Git Conflict: ' .. desc } end

  map({ 'n', 'v' }, '<Plug>(git-conflict-ours)', function() M.choose('ours') end, opts('Choose Ours'))
  map({ 'n', 'v' }, '<Plug>(git-conflict-both)', function() M.choose('both') end, opts('Choose Both'))
  map({ 'n', 'v' }, '<Plug>(git-conflict-base)', function() M.choose('base') end, opts('Choose Base'))
  map({ 'n', 'v' }, '<Plug>(git-conflict-none)', function() M.choose('none') end, opts('Choose None'))
  map({ 'n', 'v' }, '<Plug>(git-conflict-theirs)', function() M.choose('theirs') end, opts('Choose Theirs'))
  map(
    'n',
    '<Plug>(git-conflict-next-conflict)',
    function() M.find_next('ours') end,
    opts('Next Conflict')
  )
  map(
    'n',
    '<Plug>(git-conflict-prev-conflict)',
    function() M.find_prev('ours') end,
    opts('Previous Conflict')
  )
end

--- Apply the user's `mappings` to a buffer, or remove them again.
---@param bufnr integer
---@param active boolean
local function set_buffer_mappings(bufnr, active)
  if not api.nvim_buf_is_valid(bufnr) then return end
  for _, spec in ipairs(config.mappings) do
    local mode = spec.mode or 'n'
    if not active then
      pcall(vim.keymap.del, mode, spec[1], { buffer = bufnr })
    else
      local opts = vim.tbl_extend('force', { silent = true }, spec, { buffer = bufnr })
      opts[1], opts[2], opts.mode = nil, nil, nil
      -- a malformed entry must not take the autocmd down with it
      local ok, err = pcall(map, mode, spec[1], spec[2], opts)
      if not ok then utils.notify(err, 'error', true) end
    end
  end
end

-----------------------------------------------------------------------------//
-- Highlights
-----------------------------------------------------------------------------//

---Derive the colour of the section label highlights based on each sections highlights
---@param highlights ConflictHighlights
local function set_highlights(highlights)
  local current_color = utils.get_hl(highlights.current)
  local incoming_color = utils.get_hl(highlights.incoming)
  local ancestor_color = utils.get_hl(highlights.ancestor)
  local current_bg = current_color.background or DEFAULT_CURRENT_BG_COLOR
  local incoming_bg = incoming_color.background or DEFAULT_INCOMING_BG_COLOR
  local ancestor_bg = ancestor_color.background or DEFAULT_ANCESTOR_BG_COLOR
  local current_label_bg = color.shade_color(current_bg, 60)
  local incoming_label_bg = color.shade_color(incoming_bg, 60)
  local ancestor_label_bg = color.shade_color(ancestor_bg, 60)
  api.nvim_set_hl(0, CURRENT_HL, { background = current_bg, bold = true, default = true })
  api.nvim_set_hl(0, INCOMING_HL, { background = incoming_bg, bold = true, default = true })
  api.nvim_set_hl(0, ANCESTOR_HL, { background = ancestor_bg, bold = true, default = true })
  api.nvim_set_hl(0, CURRENT_LABEL_HL, { background = current_label_bg, default = true })
  api.nvim_set_hl(0, INCOMING_LABEL_HL, { background = incoming_label_bg, default = true })
  api.nvim_set_hl(0, ANCESTOR_LABEL_HL, { background = ancestor_label_bg, default = true })
end

---@param user_config GitConflictUserConfig
function M.setup(user_config)
  local _user_config = user_config or {}

  config = vim.tbl_deep_extend('force', config, _user_config)

  set_highlights(config.highlights)

  if config.default_commands then set_commands() end

  set_plug_mappings()

  api.nvim_create_augroup(AUGROUP_NAME, { clear = true })
  api.nvim_create_autocmd('ColorScheme', {
    group = AUGROUP_NAME,
    callback = function() set_highlights(config.highlights) end,
  })

  api.nvim_create_autocmd({ 'BufEnter', 'BufWinEnter', 'FileChangedShellPost' }, {
    group = AUGROUP_NAME,
    callback = function(args) track_buffer(args.buf) end,
  })

  api.nvim_create_autocmd('User', {
    group = AUGROUP_NAME,
    pattern = 'GitConflictDetected',
    callback = function(args)
      local bufnr = args.data and args.data.bufnr or api.nvim_get_current_buf()
      if config.disable_diagnostics then vim.diagnostic.enable(false, { bufnr = bufnr }) end
      set_buffer_mappings(bufnr, true)
    end,
  })

  api.nvim_create_autocmd('User', {
    group = AUGROUP_NAME,
    pattern = 'GitConflictResolved',
    callback = function(args)
      local bufnr = args.data and args.data.bufnr or api.nvim_get_current_buf()
      if config.disable_diagnostics then vim.diagnostic.enable(true, { bufnr = bufnr }) end
      set_buffer_mappings(bufnr, false)
    end,
  })

  api.nvim_set_decoration_provider(NAMESPACE, {
    on_buf = function(_, bufnr, _) return utils.is_valid_buf(bufnr) end,
    on_win = function(_, winid, bufnr, toprow, botrow)
      if not visited_buffers[bufnr] then return end
      process(bufnr)
      draw_labels(bufnr, winid, toprow, botrow)
    end,
  })

  -- Whatever is already on screen missed its window event, e.g. when lazy loaded
  for _, win in ipairs(api.nvim_list_wins()) do
    track_buffer(api.nvim_win_get_buf(win))
  end
end

---@param bufnr integer?
function M.clear(bufnr)
  if bufnr and not api.nvim_buf_is_valid(bufnr) then return end
  bufnr = bufnr or 0
  api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
end

---@param side ConflictSide
function M.find_next(side)
  local pos = find_position(
    0,
    function(line, position) return line < position.current.range_start end,
    { wrap = true }
  )
  set_cursor(pos, side)
end

---@param side ConflictSide
function M.find_prev(side)
  local pos = find_position(
    0,
    function(line, position) return line > position.current.range_start end,
    { wrap = true, reverse = true }
  )
  set_cursor(pos, side)
end

---Select the changes to keep
---@param side ConflictSide
function M.choose(side)
  local bufnr = api.nvim_get_current_buf()
  if vim.fn.mode() == 'v' or vim.fn.mode() == 'V' or vim.fn.mode() == '' then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', true)
    -- have to defer so that the < and > marks are set
    vim.defer_fn(function()
      local start = vim.api.nvim_buf_get_mark(0, '<')[1]
      local finish = vim.api.nvim_buf_get_mark(0, '>')[1]
      local position = find_position(bufnr, function(line, pos)
        local left = pos.current.range_start >= start - 1
        local right = pos.incoming.range_end <= finish + 1
        return left and right
      end)
      while position ~= nil do
        local lines = {}
        if vim.tbl_contains({ SIDES.OURS, SIDES.THEIRS, SIDES.BASE }, side) then
          local data = position[name_map[side]]
          lines = utils.get_buf_lines(data.content_start, data.content_end + 1)
        elseif side == SIDES.BOTH then
          local first =
              utils.get_buf_lines(position.current.content_start, position.current.content_end + 1)
          local second =
              utils.get_buf_lines(position.incoming.content_start, position.incoming.content_end + 1)
          lines = vim.list_extend(first, second)
        elseif side == SIDES.NONE then
          lines = {}
        else
          return
        end

        local pos_start = position.current.range_start < 0 and 0 or position.current.range_start
        local pos_end = position.incoming.range_end + 1

        api.nvim_buf_set_lines(0, pos_start, pos_end, false, lines)
        parse_buffer(bufnr)
        position = find_position(bufnr, function(line, pos)
          local left = pos.current.range_start >= start - 1
          local right = pos.incoming.range_end <= finish + 1
          return left and right
        end)
      end
    end, 50)
    return
  end
  local position = get_current_position(bufnr)
  if not position then return end
  local lines = {}
  if vim.tbl_contains({ SIDES.OURS, SIDES.THEIRS, SIDES.BASE }, side) then
    local data = position[name_map[side]]
    lines = utils.get_buf_lines(data.content_start, data.content_end + 1)
  elseif side == SIDES.BOTH then
    local first =
        utils.get_buf_lines(position.current.content_start, position.current.content_end + 1)
    local second =
        utils.get_buf_lines(position.incoming.content_start, position.incoming.content_end + 1)
    lines = vim.list_extend(first, second)
  elseif side == SIDES.NONE then
    lines = {}
  else
    return
  end

  local pos_start = position.current.range_start < 0 and 0 or position.current.range_start
  local pos_end = position.incoming.range_end + 1

  api.nvim_buf_set_lines(0, pos_start, pos_end, false, lines)
  parse_buffer(bufnr)
end

function M.conflict_count(bufnr)
  if bufnr and not api.nvim_buf_is_valid(bufnr) then return 0 end
  local buf = visited_buffers[bufnr or api.nvim_get_current_buf()]
  return buf and buf.positions and #buf.positions or 0
end

return M
