local config = require("completion_tools.config")
local matcher = require("completion_tools.matcher")
local sources, files, passed = {}, {}, 0
local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end
local function source(name, opts)
  local provider =
    require("completion_tools.sources." .. name).new(config.validate({ [name] = opts or {} })[name])
  sources[#sources + 1] = provider
  return provider
end
local function ctx(query)
  return {
    prefix = query,
    before = query,
    start_col = 0,
    col = #query,
    bufnr = vim.api.nvim_get_current_buf(),
    winid = vim.api.nvim_get_current_win(),
    filetype = "text",
  }
end
local function complete(provider, query)
  local result
  provider.complete(ctx(query), function(value)
    result = value
  end)
  assert(
    vim.wait(8000, function()
      return result ~= nil
    end, 5),
    "word source timed out: " .. query
  )
  return result.items
end
local function resolve(provider, item)
  local result
  provider.resolve({ item = item, context = ctx(item.label) }, function(value)
    result = value
  end)
  assert(
    vim.wait(3000, function()
      return result ~= nil
    end, 5),
    "dictionary definition timed out"
  )
  return result
end
local function labels(items)
  return vim.tbl_map(function(item)
    return item.label
  end, items)
end
local function file(lines)
  local path = vim.fn.tempname() .. " dictionary.txt"
  vim.fn.writefile(lines, path)
  files[#files + 1] = path
  return path
end
local function test(name, run)
  local ok, err = xpcall(run, debug.traceback)
  assert(ok, name .. ": " .. tostring(err))
  passed = passed + 1
end
local notifications = {}
vim.notify = function(message)
  notifications[#notifications + 1] = message
end
local ok, err = xpcall(function()
  test("dictionary CRLF, BOM, deduplication, case and fuzzy/prefix queries", function()
    local path = file({ "\239\187\191apple\r", "apple", "apply\r", "AppKit", "中文词", "apple phrase" })
    local dict = source("dictionary", { files = { path, path } })
    local result = labels(complete(dict, "app"))
    eq({ "apple", "apply", "AppKit", "apple phrase" }, result)
    assert(vim.tbl_contains(labels(complete(dict, "apl")), "apple"))
    assert(vim.tbl_contains(labels(complete(dict, "APP")), "APPLE"))
    assert(vim.tbl_contains(labels(complete(dict, "App")), "Apple"))
    eq({ "中文词" }, labels(complete(dict, "中文")))
    local prefix = source("dictionary", { files = { path }, matching = "prefix" })
    eq({}, complete(prefix, "apl"))
    eq({}, complete(prefix, "zzz"))
    eq({}, complete(dict, "ap"))
    eq({}, complete(source("dictionary", { files = {} }), "app"))
  end)
  test("dictionary edits and dynamic file lists invalidate cached words", function()
    local first, second = file({ "alpha" }), file({ "alphabet" })
    local current = first
    local dict = source("dictionary", {
      files = function()
        return { current }
      end,
    })
    eq({ "alpha" }, labels(complete(dict, "alp")))
    vim.fn.writefile({ "alpine", "altered" }, first)
    eq({ "alpine" }, labels(complete(dict, "alp")))
    current = second
    eq({ "alphabet" }, labels(complete(dict, "alp")))
  end)
  test("dictionary result limits, missing file warnings and cancellation", function()
    local path = file({ "alpha", "alphabet", "alphanumeric" })
    local dict = source("dictionary", { files = { path }, max_items = 1 })
    eq(1, #complete(dict, "alp"))
    local calls = 0
    local cancel = dict.complete(ctx("alpha"), function()
      calls = calls + 1
    end)
    cancel()
    complete(dict, "alphabet")
    eq(0, calls)
    local missing = source("dictionary", { files = { path .. ".missing" } })
    local before = #notifications
    eq({}, complete(missing, "abc"))
    eq({}, complete(missing, "abc"))
    eq(before + 1, #notifications)
    local limited = source("dictionary", { files = { path }, max_words = 1 })
    eq(1, #complete(limited, "alp"))
    assert(notifications[#notifications]:find("limit", 1, true))
  end)
  local trace = file({})
  local previous_trace = vim.env.COMPLETION_DICTIONARY_TRACE
  vim.env.COMPLETION_DICTIONARY_TRACE = trace
  local command = vim.fn.getcwd() .. "/tests/dictionary_command.py"
  test("dictionary definitions are lazy, literal, cached and use the original word", function()
    local dict =
      source("dictionary", { files = { file({ "apple" }) }, documentation = { command = command } })
    local item = complete(dict, "APP")[1]
    eq("APPLE", item.label)
    eq("apple", item.data.dictionary_word)
    eq({}, vim.fn.readfile(trace))
    local result = resolve(dict, item)
    eq("APPLE", result.label)
    eq("plaintext", result.documentation.kind)
    assert(result.documentation.value:find("Meaning of apple.", 1, true))
    assert(not item.documentation, "resolve mutated a cached completion item")
    eq(result.documentation, resolve(dict, item).documentation)
    local calls = vim.fn.readfile(trace)
    eq(1, #calls)
    eq("apple", vim.json.decode(calls[1]).word)
    local literal = "word; `literal` $(literal)"
    assert(resolve(dict, { label = literal }).documentation.value:find(literal, 1, true))
  end)
  test("dictionary definitions degrade quietly for missing tools, empty results and failures", function()
    local item = { label = "apple" }
    local before = #vim.fn.readfile(trace)
    for _, options in ipairs({ { enabled = false }, { command = command .. ".missing" } }) do
      eq(item, resolve(source("dictionary", { documentation = options }), item))
    end
    eq(before, #vim.fn.readfile(trace))
    local dict = source("dictionary", { documentation = { command = command } })
    for _, word in ipairs({ "empty", "failed" }) do
      eq({ label = word }, resolve(dict, { label = word }))
      eq({ label = word }, resolve(dict, { label = word }))
    end
    eq(before + 3, #vim.fn.readfile(trace)) -- Empty results cached; errors may retry.
  end)
  test("dictionary definitions cancel and reap obsolete, timed-out and disposed queries", function()
    local dict = source("dictionary", { documentation = { command = command, timeout_ms = 80 } })
    local before = #vim.fn.readfile(trace)
    eq({ label = "timeout" }, resolve(dict, { label = "timeout" }))
    eq({ label = "timeout" }, resolve(dict, { label = "timeout" }))
    eq(before + 2, #vim.fn.readfile(trace))
    for _, dispose in ipairs({ false, true }) do
      local provider = source("dictionary", { documentation = { command = command, timeout_ms = 3000 } })
      local called = false
      local count = #vim.fn.readfile(trace)
      local cancel = provider.resolve({ item = { label = "slow" } }, function()
        called = true
      end)
      assert(vim.wait(1500, function()
        return #vim.fn.readfile(trace) > count
      end, 5))
      local pid = vim.json.decode(vim.fn.readfile(trace)[count + 1]).pid
      if dispose then
        provider.dispose()
      else
        cancel()
      end
      assert(
        vim.wait(1500, function()
          return not vim.uv.kill(pid, 0)
        end, 5),
        "obsolete definition process survived"
      )
      vim.wait(30)
      assert(not called, "cancelled definition callback was delivered")
    end
  end)
  vim.env.COMPLETION_DICTIONARY_TRACE = previous_trace
  test("spell obeys window spell, minimum length and context gate", function()
    local spell = source("spell", { debounce_ms = 0 })
    vim.wo.spell = false
    eq({}, complete(spell, "teh"))
    vim.wo.spell, vim.bo.spelllang = true, "en"
    eq({}, complete(spell, "t"))
    eq(
      {},
      complete(
        source("spell", {
          enable_in_context = function()
            return false
          end,
        }),
        "teh"
      )
    )
  end)
  test("disabling spell rejects pending results", function()
    local late
    source("spell", { debounce_ms = 5 }).complete(ctx("teh"), function(result)
      late = result.items
    end)
    vim.wo.spell = false
    assert(vim.wait(8000, function()
      return late ~= nil
    end, 5))
    eq({}, late)
    vim.wo.spell = true
  end)
  test("native spelling order and typo candidates survive the main matcher", function()
    local spell = source("spell", { debounce_ms = 0, sort = "suggestion" })
    local items = complete(spell, "teh")
    eq(vim.fn.spellsuggest("teh", 3), labels(items))
    assert(vim.tbl_contains(labels(items), "the"), vim.inspect(items))
    local ranked = matcher.filter({
      {
        items = items,
        start_col = 0,
        source_id = "spell",
        score_offset = 10,
        priority = 1,
        context = ctx("teh"),
      },
    }, ctx("teh"), 10)
    eq(
      labels(items),
      vim.tbl_map(function(entry)
        return entry.item.label
      end, ranked)
    )
    local sorted = labels(complete(source("spell", { debounce_ms = 0, sort = "match" }), "teh"))
    local expected = vim.deepcopy(labels(items))
    table.sort(expected, function(a, b)
      local sa, sb = matcher.score(a, "teh") or -math.huge, matcher.score(b, "teh") or -math.huge
      return sa == sb and a < b or sa > sb
    end)
    eq(expected, sorted)
    local correct = complete(spell, "hello")
    eq({ "hello" }, labels(correct))
    assert(correct[1].preselect)
    eq({}, complete(source("spell", { debounce_ms = 0, preselect_current_word = false }), "hello"))
  end)
  test("personal spell files reload after recompilation", function()
    local path = file({ "quuxwordzz" })
    local add = path .. ".add"
    assert(vim.fn.rename(path, add) == 0)
    files[#files] = add
    files[#files + 1] = add .. ".spl"
    vim.api.nvim_cmd({ cmd = "mkspell", bang = true, args = { vim.fn.fnameescape(add) } }, {})
    vim.bo.spellfile = add
    local spell = source("spell", { debounce_ms = 0 })
    local items = complete(spell, "quuxwordzz")
    eq({ "quuxwordzz" }, labels(items))
    assert(items[1].preselect)
    vim.fn.writefile({ "otherwordzz" }, add)
    vim.api.nvim_cmd({ cmd = "mkspell", bang = true, args = { vim.fn.fnameescape(add) } }, {})
    for _, item in ipairs(complete(spell, "quuxwordzz")) do
      assert(not item.preselect, "worker kept a removed personal word")
    end
    eq({ "otherwordzz" }, labels(complete(spell, "otherwordzz")))
    vim.bo.spellfile = ""
  end)
  test("debounced spell cancels stale input and preserves the latest query", function()
    local spell = source("spell", { debounce_ms = 40 })
    local called = false
    local cancel = spell.complete(ctx("teh"), function()
      called = true
    end)
    cancel()
    eq({ "hello" }, labels(complete(spell, "hello")))
    assert(not called)
  end)
  test("word source configuration rejects invalid options", function()
    for _, opts in ipairs({
      { spell = { sort = "bad" } },
      { dictionary = { matching = "bad" } },
      { dictionary = { files = { false } } },
      { dictionary = { documentation = { timeout_ms = 0 } } },
      { dictionary = { documentation = { command = "" } } },
      { dictionary = { documentation = { enabled = "yes" } } },
      { spell = { debounce_ms = -1 } },
    }) do
      assert(not pcall(config.validate, opts))
    end
  end)
end, debug.traceback)
for _, provider in ipairs(sources) do
  provider.dispose()
end
assert(
  vim.wait(2000, function()
    for _, channel in ipairs(vim.api.nvim_list_chans()) do
      if channel.argv and vim.tbl_contains(channel.argv, "--headless") then
        if vim.fn.jobwait({ channel.id }, 0)[1] == -1 then
          return false
        end
      end
    end
    return true
  end, 5),
  "background worker survived dispose"
)
for _, path in ipairs(files) do
  vim.fn.delete(path)
end
assert(ok, err)
print("word sources: " .. passed .. " passed (real background Neovim workers)")
vim.cmd("qa!")
