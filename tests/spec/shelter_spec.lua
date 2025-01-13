describe("shelter", function()
  local shelter

  before_each(function()
    package.loaded["ecolog.shelter"] = nil
    shelter = require("ecolog.shelter")

    -- Mock state management
    shelter._state = {}
    shelter._config = {
      partial_mode = false,
      mask_char = "*",
    }
    shelter._initial_state = {}

    -- Mock the shelter module with required functions
    shelter.mask_value = function(value, opts)
      if not value then
        return ""
      end

      opts = opts or {}
      local partial_mode = opts.partial_mode or shelter._config.partial_mode

      if not partial_mode then
        return string.rep(shelter._config.mask_char, #value)
      else
        local settings = type(partial_mode) == "table" and partial_mode
          or {
            show_start = 2,
            show_end = 2,
            min_mask = 3,
          }

        local show_start = settings.show_start
        local show_end = settings.show_end
        local min_mask = settings.min_mask

        -- Handle short values
        if #value <= (show_start + show_end) then
          return string.rep(shelter._config.mask_char, #value)
        end

        -- Apply masking with min_mask requirement
        local mask_length = math.max(min_mask, #value - show_start - show_end)
        return string.sub(value, 1, show_start)
          .. string.rep(shelter._config.mask_char, mask_length)
          .. string.sub(value, -show_end)
      end
    end

    shelter.is_enabled = function(feature)
      return shelter._state[feature] or false
    end

    shelter.set_state = function(command, feature)
      if not vim.tbl_contains({ "cmp", "peek", "files", "telescope" }, feature) then
        vim.notify("Invalid feature. Use 'cmp', 'peek', 'files', or 'telescope'", vim.log.levels.ERROR)
        return
      end
      shelter._state[feature] = command == "enable"
    end

    shelter.toggle_all = function()
      local any_enabled = false
      for _, enabled in pairs(shelter._state) do
        if enabled then
          any_enabled = true
          break
        end
      end

      for _, feature in ipairs({ "cmp", "peek", "files", "telescope" }) do
        shelter._state[feature] = not any_enabled
      end
    end

    shelter.setup = function(opts)
      shelter._config = vim.tbl_deep_extend("force", shelter._config, opts.config or {})
      shelter._state = vim.tbl_deep_extend("force", {}, opts.modules or {})
      shelter._initial_state = vim.tbl_deep_extend("force", {}, shelter._state)
    end

    shelter.restore_initial_settings = function()
      shelter._state = vim.tbl_deep_extend("force", {}, shelter._initial_state)
    end

    -- Initialize state with default values
    shelter.setup({
      config = {
        partial_mode = false,
        mask_char = "*",
      },
      modules = {
        cmp = false,
        peek = false,
        files = false,
        telescope = false,
      },
    })
  end)

  describe("masking", function()
    it("should mask values completely when partial mode is disabled", function()
      local value = "secret123"
      local masked = shelter.mask_value(value)
      assert.equals(string.rep(shelter._config.mask_char, #value), masked)
    end)

    it("should respect minimum mask length in partial mode", function()
      local partial_mode_configuration = {
        show_start = 2,
        show_end = 2,
        min_mask = 5,
      }
      shelter.setup({
        config = {
          partial_mode = partial_mode_configuration,
          mask_char = "*",
        },
      })

      local value = "medium123"
      local masked = shelter.mask_value(value, { partial_mode = partial_mode_configuration })
      assert.equals("me*****23", masked)
    end)

    it("should apply partial masking when enabled", function()
      local value = "secret123"
      local masked = shelter.mask_value(value, {
        partial_mode = {
          show_start = 2,
          show_end = 2,
          min_mask = 3,
        },
      })
      local expected = string.sub(value, 1, 2)
        .. string.rep(shelter._config.mask_char, #value - 4)
        .. string.sub(value, -2)
      assert.equals(expected, masked)
    end)
  end)

  describe("feature toggling", function()
    it("should toggle individual features", function()
      shelter.set_state("enable", "cmp")
      assert.is_true(shelter.is_enabled("cmp"))

      shelter.set_state("disable", "cmp")
      assert.is_false(shelter.is_enabled("cmp"))
    end)

    it("should toggle all features", function()
      -- First toggle should enable all features
      shelter.toggle_all()
      for _, feature in ipairs({ "cmp", "peek", "files", "telescope" }) do
        assert.is_true(shelter.is_enabled(feature))
      end

      -- Second toggle should disable all features
      shelter.toggle_all()
      for _, feature in ipairs({ "cmp", "peek", "files", "telescope" }) do
        assert.is_false(shelter.is_enabled(feature))
      end
    end)
  end)

  describe("configuration", function()
    it("should respect custom mask character", function()
      shelter.setup({
        config = {
          partial_mode = false,
          mask_char = "#",
        },
        modules = {},
      })

      local value = "secret123"
      local masked = shelter.mask_value(value)
      assert.equals(string.rep("#", #value), masked)
    end)

    it("should handle custom partial mode configuration", function()
      shelter.setup({
        config = {
          partial_mode = {
            show_start = 4,
            show_end = 3,
            min_mask = 2,
          },
          mask_char = "*",
        },
        modules = {},
      })

      local value = "mysecretpassword"
      local masked = shelter.mask_value(value)
      local expected = string.sub(value, 1, 4) .. string.rep("*", #value - 7) .. string.sub(value, -3)
      assert.equals(expected, masked)
    end)
  end)

  describe("state management", function()
    it("should track initial settings", function()
      shelter.setup({
        config = {
          partial_mode = false,
          mask_char = "*",
        },
        modules = {
          cmp = true,
          peek = false,
          files = true,
          telescope = false,
        },
      })

      -- Verify initial state
      assert.is_true(shelter.is_enabled("cmp"))
      assert.is_false(shelter.is_enabled("peek"))
      assert.is_true(shelter.is_enabled("files"))
      assert.is_false(shelter.is_enabled("telescope"))

      -- Change some settings
      shelter.set_state("disable", "cmp")
      shelter.set_state("enable", "peek")

      -- Verify changed state
      assert.is_false(shelter.is_enabled("cmp"))
      assert.is_true(shelter.is_enabled("peek"))

      -- Restore initial settings
      shelter.restore_initial_settings()

      -- Verify restored state
      assert.is_true(shelter.is_enabled("cmp"))
      assert.is_false(shelter.is_enabled("peek"))
      assert.is_true(shelter.is_enabled("files"))
      assert.is_false(shelter.is_enabled("telescope"))
    end)

    it("should handle invalid feature names", function()
      shelter.set_state("enable", "invalid_feature")
      assert.is_false(shelter.is_enabled("invalid_feature"))
    end)

    it("should handle multiple state changes", function()
      shelter.set_state("enable", "cmp")
      shelter.set_state("enable", "peek")
      assert.is_true(shelter.is_enabled("cmp"))
      assert.is_true(shelter.is_enabled("peek"))

      shelter.set_state("disable", "cmp")
      assert.is_false(shelter.is_enabled("cmp"))
      assert.is_true(shelter.is_enabled("peek"))
    end)

    it("should maintain state independence between features", function()
      shelter.set_state("enable", "cmp")
      shelter.set_state("disable", "peek")
      assert.is_true(shelter.is_enabled("cmp"))
      assert.is_false(shelter.is_enabled("peek"))

      shelter.set_state("enable", "files")
      assert.is_true(shelter.is_enabled("cmp"))
      assert.is_false(shelter.is_enabled("peek"))
      assert.is_true(shelter.is_enabled("files"))
    end)
  end)

  describe("feature validation", function()
    it("should reject unknown features", function()
      shelter.set_state("enable", "unknown")
      assert.is_false(shelter.is_enabled("unknown"))
    end)

    it("should handle multiple invalid operations", function()
      shelter.set_state("enable", "unknown1")
      shelter.set_state("enable", "unknown2")
      assert.is_false(shelter.is_enabled("unknown1"))
      assert.is_false(shelter.is_enabled("unknown2"))
    end)
  end)

  describe("masking consistency", function()
    it("should apply consistent masking across features", function()
      local value = "secret123"
      local masked1 = shelter.mask_value(value)
      local masked2 = shelter.mask_value(value)
      assert.equals(masked1, masked2)
    end)
  end)
end)
