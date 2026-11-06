local M = {}

-- Pure server negotiation: importing this module does not load the input engine.
function M.get_lsp_capabilities(base)
  return vim.tbl_deep_extend("force", vim.lsp.protocol.make_client_capabilities(), base or {}, {
    textDocument = {
      completion = {
        completionItem = {
          snippetSupport = true,
          insertReplaceSupport = true,
          insertTextModeSupport = { valueSet = { 1, 2 } },
          labelDetailsSupport = true,
          documentationFormat = { "markdown", "plaintext" },
          deprecatedSupport = true,
          preselectSupport = true,
          resolveSupport = { properties = { "documentation", "detail", "additionalTextEdits", "command" } },
        },
        completionList = { itemDefaults = { "editRange", "insertTextFormat", "insertTextMode", "data" } },
        contextSupport = true,
        insertTextMode = 2,
      },
    },
  })
end

return M
