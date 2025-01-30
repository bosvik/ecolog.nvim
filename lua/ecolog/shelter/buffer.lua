local M = {}

local api = vim.api
local string_find = string.find
local string_sub = string.sub
local string_match = string.match
local table_insert = table.insert
local fn = vim.fn
local pcall = pcall

local state = require("ecolog.shelter.state")
local utils = require("ecolog.shelter.utils")
local lru_cache = require("ecolog.shelter.lru_cache")

local namespace = api.nvim_create_namespace("ecolog_shelter")
local CHUNK_SIZE = 1000
local line_cache = lru_cache.new(1000)

local active_buffers = setmetatable({}, {
  __mode = "k",
})

local COMMENT_PATTERN = "^#"
local KEY_PATTERN = "^%s*(.-)%s*$"
local VALUE_PATTERN = "^%s*(.-)%s*$"

local function find_next_key_value(text, start_pos)
  start_pos = start_pos or 1

  local eq_pos = string_find(text, "=", start_pos)
  if not eq_pos then
    return nil
  end

  local key_start = eq_pos
  while key_start > start_pos do
    local char = text:sub(key_start - 1, key_start - 1)
    if char:match("[%s#]") then
      break
    end
    key_start = key_start - 1
  end

  local key = string_match(string_sub(text, key_start, eq_pos - 1), KEY_PATTERN)
  if not key then
    return find_next_key_value(text, eq_pos + 1)
  end

  local pos = eq_pos + 1
  local value = ""
  local quote_char = text:sub(pos, pos)
  local in_quotes = quote_char == '"' or quote_char == "'"

  if in_quotes then
    pos = pos + 1
    local end_quote_pos = nil
    while pos <= #text do
      if text:sub(pos, pos) == quote_char and text:sub(pos - 1, pos - 1) ~= "\\" then
        end_quote_pos = pos
        break
      end
      pos = pos + 1
    end

    if end_quote_pos then
      value = text:sub(eq_pos + 2, end_quote_pos - 1)
      pos = end_quote_pos + 1
    else
      return find_next_key_value(text, eq_pos + 1)
    end
  else
    while pos <= #text do
      local char = text:sub(pos, pos)
      if char:match("[%s#]") then
        break
      end
      pos = pos + 1
    end
    value = string_match(text:sub(eq_pos + 1, pos - 1), VALUE_PATTERN)
  end

  if not value or #value == 0 then
    return find_next_key_value(text, eq_pos + 1)
  end

  return {
    key = key,
    value = value,
    quote_char = in_quotes and quote_char or nil,
    eq_pos = eq_pos,
    next_pos = pos,
  },
    pos
end

local function process_line(line)
  local results = {}
  local is_comment_line = string_find(line, COMMENT_PATTERN)
  local comment_start = string_find(line, "#")

  if not is_comment_line then
    local kv, pos = find_next_key_value(line)
    if kv then
      if not comment_start or kv.eq_pos < comment_start then
        table_insert(results, {
          key = kv.key,
          value = kv.value,
          quote_char = kv.quote_char,
          eq_pos = kv.eq_pos,
          is_comment = false,
        })
      end
    end
  end

  if comment_start then
    local comment_text = string_sub(line, comment_start + 1)
    local pos = 1

    while pos <= #comment_text do
      local kv, next_pos = find_next_key_value(comment_text, pos)
      if not kv then
        break
      end

      table_insert(results, {
        key = kv.key,
        value = kv.value,
        quote_char = kv.quote_char,
        eq_pos = comment_start + kv.eq_pos,
        is_comment = true,
      })

      pos = next_pos
    end
  end

  return results
end

local function get_cached_line(line, line_num, bufname)
  local cache_key = string.format("%s:%d:%s", bufname, line_num, line)
  return line_cache:get(cache_key)
end

local function cache_line(line, line_num, bufname, extmark)
  local cache_key = string.format("%s:%d:%s", bufname, line_num, line)
  local existing = line_cache:get(cache_key)
  if existing then
    if not existing.extmarks then
      existing.extmarks = {}
    end
    table_insert(existing.extmarks, extmark)
    line_cache:put(cache_key, existing)
  else
    line_cache:put(cache_key, { extmarks = { extmark } })
  end
end

local function cleanup_invalid_buffers()
  local current_time = vim.loop.now()
  for bufnr, timestamp in pairs(active_buffers) do
    if not api.nvim_buf_is_valid(bufnr) or (current_time - timestamp) > 3600000 then
      pcall(api.nvim_buf_clear_namespace, bufnr, namespace, 0, -1)

      line_cache:remove(bufnr)
      active_buffers[bufnr] = nil
    end
  end
end

function M.unshelter_buffer()
  local bufnr = api.nvim_get_current_buf()
  api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  state.reset_revealed_lines()
  active_buffers[bufnr] = nil

  if state.get_buffer_state().disable_cmp then
    vim.b.completion = true

    if utils.has_cmp() then
      require("cmp").setup.buffer({ enabled = true })
    end
  end
end

function M.shelter_buffer()
  local config = require("ecolog").get_config and require("ecolog").get_config() or {}
  local filename = fn.fnamemodify(fn.bufname(), ":t")

  if not utils.match_env_file(filename, config) then
    return
  end

  local bufnr = api.nvim_get_current_buf()
  active_buffers[bufnr] = vim.loop.now()

  if vim.loop.now() % 300000 == 0 then
    cleanup_invalid_buffers()
  end

  if state.get_buffer_state().disable_cmp then
    vim.b.completion = false

    if utils.has_cmp() then
      require("cmp").setup.buffer({ enabled = false })
    end
  end

  local bufname = api.nvim_buf_get_name(bufnr)
  local line_count = api.nvim_buf_line_count(bufnr)
  local extmarks = {}
  local config_partial_mode = state.get_config().partial_mode
  local config_highlight_group = state.get_config().highlight_group
  local skip_comments = state.get_buffer_state().skip_comments

  for chunk_start = 0, line_count - 1, CHUNK_SIZE do
    local chunk_end = math.min(chunk_start + CHUNK_SIZE - 1, line_count - 1)
    local lines = api.nvim_buf_get_lines(bufnr, chunk_start, chunk_end + 1, false)

    for i, line in ipairs(lines) do
      local line_num = chunk_start + i
      local is_comment_line = string_find(line, COMMENT_PATTERN)

      if is_comment_line and skip_comments then
        goto continue
      end

      local cached_data = get_cached_line(line, line_num, bufname)
      if cached_data and cached_data.extmarks then
        for _, extmark in ipairs(cached_data.extmarks) do
          table_insert(extmarks, extmark)
        end
        goto continue
      end

      local processed_items = process_line(line)
      for _, item in ipairs(processed_items) do
        if skip_comments and item.is_comment then
          goto continue_item
        end

        if item.value and #item.value > 0 then
          local is_revealed = state.is_line_revealed(line_num)
          local raw_value = item.quote_char and (item.quote_char .. item.value .. item.quote_char) or item.value
          local masked_value = is_revealed and raw_value
            or utils.determine_masked_value(raw_value, {
              partial_mode = config_partial_mode,
              key = item.key,
              source = bufname,
            })

          if masked_value and #masked_value > 0 then
            local extmark = {
              line_num - 1,
              item.eq_pos,
              {
                virt_text = {
                  { masked_value, (is_revealed or masked_value == raw_value) and "String" or config_highlight_group },
                },
                virt_text_pos = "overlay",
                hl_mode = "combine",
                priority = item.is_comment and 10000 or 9999,
                strict = true,
              },
            }

            table_insert(extmarks, extmark)
            cache_line(line, line_num, bufname, extmark)
          end
        end
        ::continue_item::
      end
      ::continue::
    end
  end

  if #extmarks > 0 then
    local temp_ns = api.nvim_create_namespace("")
    api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

    for _, mark in ipairs(extmarks) do
      api.nvim_buf_set_extmark(bufnr, temp_ns, mark[1], mark[2], mark[3])
    end

    for _, mark in ipairs(extmarks) do
      api.nvim_buf_set_extmark(bufnr, namespace, mark[1], mark[2], mark[3])
    end
    api.nvim_buf_clear_namespace(bufnr, temp_ns, 0, -1)
  end
end

function M.setup_file_shelter()
  local group = api.nvim_create_augroup("ecolog_shelter", { clear = true })

  local config = require("ecolog").get_config and require("ecolog").get_config() or {}
  local watch_patterns = {}

  local shelter_config = config.shelter and config.shelter.modules and config.shelter.modules.files or {}
  local buffer_state = {
    skip_comments = shelter_config.skip_comments == true,
    disable_cmp = shelter_config.disable_cmp == true,
    revealed_lines = {},
  }
  state.set_buffer_state(buffer_state)

  if not config.env_file_pattern then
    watch_patterns[1] = ".env*"
  else
    local patterns = type(config.env_file_pattern) == "string" and { config.env_file_pattern }
      or config.env_file_pattern
      or {}
    for _, pattern in ipairs(patterns) do
      if type(pattern) == "string" then
        local glob_pattern = pattern:gsub("^%^", ""):gsub("%$$", ""):gsub("%%.", "")
        watch_patterns[#watch_patterns + 1] = glob_pattern:gsub("^%.%+/", "")
      end
    end
  end

  if #watch_patterns == 0 then
    watch_patterns[1] = ".env*"
  end

  api.nvim_create_autocmd("BufReadCmd", {
    pattern = watch_patterns,
    group = group,
    callback = function(ev)
      local filename = vim.fn.fnamemodify(ev.file, ":t")
      if not utils.match_env_file(filename, config) then
        return
      end

      local lines = vim.fn.readfile(ev.file)
      local bufnr = ev.buf

      vim.bo[bufnr].buftype = ""

      local ft = vim.filetype.match({ filename = filename })
      if ft then
        vim.bo[bufnr].filetype = ft
      else
        vim.bo[bufnr].filetype = "sh"
      end

      local ok, err = pcall(function()
        vim.bo[bufnr].modifiable = true
        api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.bo[bufnr].modified = false
      end)

      if not ok then
        vim.notify("Failed to set buffer contents: " .. tostring(err), vim.log.levels.ERROR)
        return true
      end

      if state.is_enabled("files") then
        M.shelter_buffer()
      end

      return true
    end,
  })

  api.nvim_create_autocmd({ "BufWritePost", "BufEnter", "TextChanged", "TextChangedI", "TextChangedP" }, {
    pattern = watch_patterns,
    callback = function(ev)
      local filename = vim.fn.fnamemodify(ev.file, ":t")
      if utils.match_env_file(filename, config) then
        if state.is_enabled("files") then
          vim.cmd('noautocmd lua require("ecolog.shelter.buffer").shelter_buffer()')
        else
          M.unshelter_buffer()
        end
      end
    end,
    group = group,
  })

  api.nvim_create_autocmd("BufLeave", {
    pattern = watch_patterns,
    callback = function(ev)
      local filename = vim.fn.fnamemodify(ev.file, ":t")
      if utils.match_env_file(filename, config) and state.get_config().shelter_on_leave then
        state.set_feature_state("files", true)

        if state.get_state().features.initial.telescope_previewer then
          state.set_feature_state("telescope_previewer", true)
          require("ecolog.shelter.integrations.telescope").setup_telescope_shelter()
        end

        if state.get_state().features.initial.fzf_previewer then
          state.set_feature_state("fzf_previewer", true)
          require("ecolog.shelter.integrations.fzf").setup_fzf_shelter()
        end

        if state.get_state().features.initial.snacks_previewer then
          state.set_feature_state("snacks_previewer", true)
          require("ecolog.shelter.integrations.snacks").setup_snacks_shelter()
        end

        M.shelter_buffer()
      end
    end,
    group = group,
  })
end

return M
