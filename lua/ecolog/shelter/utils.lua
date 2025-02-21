local M = {}

local config = require("ecolog.shelter.state").get_config
local utils = require("ecolog.utils")
local string_sub = string.sub
local string_rep = string.rep

---@param key string|nil
---@param source string|nil
---@param patterns table|nil
---@param sources table|nil
---@param default_mode string|nil
---@return "none"|"partial"|"full"
function M.determine_masking_mode(key, source, patterns, sources, default_mode)
  local conf = config()
  patterns = patterns or conf.patterns
  sources = sources or conf.sources
  default_mode = default_mode or conf.default_mode

  if key and patterns then
    for pattern, mode in pairs(patterns) do
      local lua_pattern = utils.convert_to_lua_pattern(pattern)
      if key:match("^" .. lua_pattern .. "$") then
        return mode
      end
    end
  end

  if source and sources then
    for pattern, mode in pairs(sources) do
      local lua_pattern = utils.convert_to_lua_pattern(pattern)
      local source_to_match = source
      -- TODO: This has to be refactored not to match the hardcoded source pattern for vault/asm
      if source ~= "vault" and source ~= "asm" then
        source_to_match = vim.fn.fnamemodify(source, ":t")
      end
      if source_to_match:match("^" .. lua_pattern .. "$") then
        return mode
      end
    end
  end

  return default_mode or "partial"
end

---@param value string
---@param settings table
function M.determine_masked_value(value, settings)
  if not value then
    return ""
  end

  local patterns = settings.patterns or config().patterns
  local sources = settings.sources or config().sources
  local default_mode = settings.default_mode or config().default_mode

  local mode = M.determine_masking_mode(settings.key, settings.source, patterns, sources, default_mode)
  if mode == "none" then
    if settings.quote_char then
      return settings.quote_char .. value .. settings.quote_char
    end
    return value
  end

  local mask_length = config().mask_length
  if mask_length and mask_length > 0 then
    local masked = string_rep(config().mask_char, mask_length)
    if mode == "partial" and config().partial_mode then
      local partial_mode = type(config().partial_mode) == "table" and config().partial_mode
        or {
          show_start = 3,
          show_end = 3,
          min_mask = 3,
        }
      local show_start = math.max(0, settings.show_start or partial_mode.show_start or 0)
      local show_end = math.max(0, settings.show_end or partial_mode.show_end or 0)

      if #value <= (show_start + show_end) then
        masked = string_rep(config().mask_char, #value)
        if settings.quote_char then
          masked = settings.quote_char .. masked .. settings.quote_char
        end
        return masked
      end

      local total_length = show_start + mask_length + show_end
      local full_value_length = #value
      if settings.quote_char then
        full_value_length = full_value_length + 2
      end

      if #value <= mask_length then
        masked = string_rep(config().mask_char, #value)
        if settings.quote_char then
          masked = settings.quote_char .. masked .. settings.quote_char
        end
        return masked
      end

      masked = string_sub(value, 1, show_start) .. masked .. string_sub(value, -show_end)

      if total_length < full_value_length and not settings.no_padding then
        if settings.quote_char then
          masked = settings.quote_char
            .. masked
            .. settings.quote_char
            .. string_rep(" ", full_value_length - total_length - 2)
        else
          masked = masked .. string_rep(" ", full_value_length - total_length)
        end
      else
        if settings.quote_char then
          masked = settings.quote_char .. masked .. settings.quote_char
        end
      end
    else
      local full_value_length = #value
      if settings.quote_char then
        full_value_length = full_value_length + 2
      end
      if #masked < full_value_length and not settings.no_padding then
        if settings.quote_char then
          masked = settings.quote_char
            .. masked
            .. settings.quote_char
            .. string_rep(" ", full_value_length - #masked - 2)
        else
          masked = masked .. string_rep(" ", full_value_length - #masked)
        end
      else
        if settings.quote_char then
          masked = settings.quote_char .. masked .. settings.quote_char
        end
      end
    end
    return masked
  end

  if mode == "full" or not config().partial_mode then
    local masked = string_rep(config().mask_char, #value)
    if settings.quote_char then
      return settings.quote_char .. masked .. settings.quote_char
    end
    return masked
  end

  local partial_mode = config().partial_mode
  if type(partial_mode) ~= "table" then
    partial_mode = {
      show_start = 3,
      show_end = 3,
      min_mask = 3,
    }
  end

  local show_start = math.max(0, settings.show_start or partial_mode.show_start or 0)
  local show_end = math.max(0, settings.show_end or partial_mode.show_end or 0)
  local min_mask = math.max(1, settings.min_mask or partial_mode.min_mask or 1)

  if #value <= (show_start + show_end) or #value < (show_start + show_end + min_mask) then
    local masked = string_rep(config().mask_char, #value)
    if settings.quote_char then
      return settings.quote_char .. masked .. settings.quote_char
    end
    return masked
  end

  local mask_length = math.max(min_mask, #value - show_start - show_end)
  local masked = string_sub(value, 1, show_start)
    .. string_rep(config().mask_char, mask_length)
    .. string_sub(value, -show_end)

  if settings.quote_char then
    return settings.quote_char .. masked .. settings.quote_char
  end
  return masked
end

---@param value string
---@return string, string|nil
function M.extract_value(value_part)
  if not value_part then
    return "", nil
  end

  local value = vim.trim(value_part)

  local first_char = value:sub(1, 1)
  local last_char = value:sub(-1)

  if (first_char == '"' or first_char == "'") and first_char == last_char then
    return value:sub(2, -2), first_char
  end

  return value, nil
end

---@param filename string
---@param config table
---@return boolean
function M.match_env_file(filename, config)
  return utils.match_env_file(filename, config)
end

function M.has_cmp()
  return vim.fn.exists(":CmpStatus") > 0
end

return M
