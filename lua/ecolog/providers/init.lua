local M = {}
local utils = require("ecolog.utils")

-- Use utils lazy loading
M.providers = setmetatable({}, {
  __index = function(t, k)
    t[k] = {}
    return t[k]
  end,
})

-- Load providers
function M.load_providers()
  if M._providers_loaded then
    return
  end

  local providers_list = {
    typescript = "ecolog.providers.typescript",
    javascript = "ecolog.providers.javascript",
    python = "ecolog.providers.python",
    php = "ecolog.providers.php",
    lua = "ecolog.providers.lua",
    go = "ecolog.providers.go",
    rust = "ecolog.providers.rust",
  }

  for _, module_path in pairs(providers_list) do
    local ok, provider = pcall(require, module_path)
    if ok then
      if type(provider) == "table" then
        if provider.provider then
          M.register(provider.provider)
        else
          M.register_many(provider)
        end
      else
        M.register(provider)
      end
    end
  end

  M._providers_loaded = true
end

-- Optimized register function
function M.register(provider)
  if not provider.pattern or not provider.filetype or not provider.extract_var then
    return
  end

  local filetypes = type(provider.filetype) == "string" and { provider.filetype } or provider.filetype
  for _, ft in ipairs(filetypes) do
    M.providers[ft] = M.providers[ft] or {}
    table.insert(M.providers[ft], provider)
  end
end

-- Optimized register_many
function M.register_many(providers)
  if type(providers) ~= "table" then
    error("Providers must be a table")
  end

  for _, provider in ipairs(providers) do
    M.register(provider)
  end
end

-- Optimized get_providers
function M.get_providers(filetype)
  return M.providers[filetype]
end

return M
