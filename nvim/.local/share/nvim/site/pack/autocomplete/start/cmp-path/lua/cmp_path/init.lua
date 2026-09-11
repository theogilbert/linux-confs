local cmp = require 'cmp'

local NAME_REGEX = '\\%([^/\\\\:\\*?<>\'"`\\|]\\)'
local PATH_REGEX = vim.regex(([[\%(\%(/PAT*[^/\\\\:\\*?<>\'"`\\| .~]\)\|\%(/\.\.\)\)*/\zePAT*$]]):gsub('PAT', NAME_REGEX))

local source = {}

local constants = {
  max_lines = 20,
  -- Above this many entries, cmp itself becomes the bottleneck (one Entry
  -- object + fuzzy match per item on the main thread). Past it we narrow by
  -- the typed prefix, then truncate and flag the result incomplete so cmp
  -- asks again as more characters are typed.
  max_candidates = 500,
}

---@class cmp_path.Option
---@field public trailing_slash boolean
---@field public label_trailing_slash boolean
---@field public get_cwd fun(): string

---@type cmp_path.Option
local defaults = {
  trailing_slash = false,
  label_trailing_slash = true,
  get_cwd = function(params)
    return vim.fn.expand(('#%d:p:h'):format(params.context.bufnr))
  end,
}

source.new = function()
  return setmetatable({}, { __index = source })
end

source.get_trigger_characters = function()
  return { '/', '.' }
end

source.get_keyword_pattern = function(self, params)
  return NAME_REGEX .. '*'
end

source.complete = function(self, params, callback)
  local option = self:_validate_option(params)

  local dirname = self:_dirname(params, option)
  if not dirname then
    return callback()
  end

  local include_hidden = string.sub(params.context.cursor_before_line, params.offset, params.offset) == '.'
  local typed = string.sub(params.context.cursor_before_line, params.offset)
  self:_candidates(dirname, include_hidden, typed, option, function(err, candidates, incomplete)
    if err then
      return callback()
    end
    callback({ items = candidates, isIncomplete = incomplete })
  end)
end

source.resolve = function(self, completion_item, callback)
  local data = completion_item.data
  if data.type == 'file' then
    local ok, documentation = pcall(function()
      return self:_get_documentation(data.path, constants.max_lines)
    end)
    if ok then
      completion_item.documentation = documentation
    end
  end
  callback(completion_item)
end

source._dirname = function(self, params, option)
  local s = PATH_REGEX:match_str(params.context.cursor_before_line)
  if not s then
    return nil
  end

  local dirname = string.gsub(string.sub(params.context.cursor_before_line, s + 2), '[^/]*$', '') -- exclude '/' and the name being typed
  local prefix = string.sub(params.context.cursor_before_line, 1, s + 1) -- include '/'

  local buf_dirname = option.get_cwd(params)
  if vim.api.nvim_get_mode().mode == 'c' then
    buf_dirname = vim.fn.getcwd()
  end
  if prefix:match('%.%./$') then
    return vim.fn.resolve(buf_dirname .. '/../' .. dirname)
  end
  if (prefix:match('%./$') or prefix:match('"$') or prefix:match('\'$')) then
    return vim.fn.resolve(buf_dirname .. '/' .. dirname)
  end
  if prefix:match('~/$') then
    return vim.fn.resolve(vim.fn.expand('~') .. '/' .. dirname)
  end
  local env_var_name = prefix:match('%$([%a_]+)/$')
  if env_var_name then
    local env_var_value = vim.fn.getenv(env_var_name)
    if env_var_value ~= vim.NIL then
      return vim.fn.resolve(env_var_value .. '/' .. dirname)
    end
  end
  if prefix:match('/$') then
    local accept = true
    -- Ignore URL components
    accept = accept and not prefix:match('%a/$')
    -- Ignore URL scheme
    accept = accept and not prefix:match('%a+:/$') and not prefix:match('%a+://$')
    -- Ignore HTML closing tags
    accept = accept and not prefix:match('</$')
    -- Ignore math calculation
    accept = accept and not prefix:match('[%d%)]%s*/$')
    -- Ignore / comment
    accept = accept and (not prefix:match('^[%s/]*$') or not self:_is_slash_comment())
    if accept then
      return vim.fn.resolve('/' .. dirname)
    end
  end
  return nil
end

source._candidates = function(_, dirname, include_hidden, typed, option, callback)
  local items = {}

  local function create_item(name, fs_type)
    local path = dirname .. '/' .. name
    -- scandir already reports the type on most filesystems; only stat when
    -- it could not (or for links, to follow them). Stat-ing every entry is
    -- what made huge directories block the UI.
    local stat = nil
    local lstat = nil
    if fs_type == nil or fs_type == 'link' then
      stat = vim.loop.fs_stat(path)
      if stat then
        fs_type = stat.type
      elseif fs_type == 'link' then
        -- Broken symlink
        lstat = vim.loop.fs_lstat(path)
        if not lstat then
          return
        end
      else
        return
      end
    end

    local item = {
      label = name,
      filterText = name,
      insertText = name,
      kind = cmp.lsp.CompletionItemKind.File,
      data = {
        path = path,
        type = fs_type,
        stat = stat,
        lstat = lstat,
      },
    }
    if fs_type == 'directory' then
      item.kind = cmp.lsp.CompletionItemKind.Folder
      if option.label_trailing_slash then
        item.label = name .. '/'
      else
        item.label = name
      end
      item.insertText = name .. '/'
      if not option.trailing_slash then
        item.word = name
      end
    end
    table.insert(items, item)
  end

  -- Async form: the readdir itself runs on libuv's threadpool, so a slow
  -- (network, huge) directory never blocks the editor.
  vim.loop.fs_scandir(dirname, function(err, fs)
    if err then
      return vim.schedule(function() callback(err, nil) end)
    end

    local names = {}
    while true do
      local name, fs_type, e = vim.loop.fs_scandir_next(fs)
      if e then
        return vim.schedule(function() callback(fs_type, nil) end)
      end
      if not name then
        break
      end
      if include_hidden or string.sub(name, 1, 1) ~= '.' then
        table.insert(names, { name, fs_type })
      end
    end

    local incomplete = false
    if #names > constants.max_candidates and typed ~= '' then
      -- Too many to hand to cmp: keep only what starts with the typed text.
      -- Fuzzy matching is lost for this directory, but cmp will re-query
      -- on each keystroke (isIncomplete) so narrowing still works.
      local narrowed = {}
      for _, entry in ipairs(names) do
        if vim.startswith(entry[1], typed) then
          table.insert(narrowed, entry)
        end
      end
      names = narrowed
      incomplete = true
    end
    if #names > constants.max_candidates then
      -- Still too many: give up on completeness rather than freeze.
      incomplete = true
      for i = #names, constants.max_candidates + 1, -1 do
        names[i] = nil
      end
    end

    for _, entry in ipairs(names) do
      create_item(entry[1], entry[2])
    end

    vim.schedule(function() callback(nil, items, incomplete) end)
  end)
end

source._is_slash_comment = function(_)
  local commentstring = vim.bo.commentstring or ''
  local no_filetype = vim.bo.filetype == ''
  local is_slash_comment = false
  is_slash_comment = is_slash_comment or commentstring:match('/%*')
  is_slash_comment = is_slash_comment or commentstring:match('//')
  return is_slash_comment and not no_filetype
end

---@return cmp_path.Option
source._validate_option = function(_, params)
  local option = vim.tbl_deep_extend('keep', params.option, defaults)
  vim.validate({
    trailing_slash = { option.trailing_slash, 'boolean' },
    label_trailing_slash = { option.label_trailing_slash, 'boolean' },
    get_cwd = { option.get_cwd, 'function' },
  })
  return option
end

source._get_documentation = function(_, filename, count)
  local binary = assert(io.open(filename, 'rb'))
  local first_kb = binary:read(1024)
  if first_kb:find('\0') then
    return { kind = cmp.lsp.MarkupKind.PlainText, value = 'binary file' }
  end

  local contents = {}
  for content in first_kb:gmatch("[^\r\n]+") do
    table.insert(contents, content)
    if count ~= nil and #contents >= count then
      break
    end
  end

  local filetype = vim.filetype.match({ filename = filename })
  if not filetype then
    return { kind = cmp.lsp.MarkupKind.PlainText, value = table.concat(contents, '\n') }
  end

  table.insert(contents, 1, '```' .. filetype)
  table.insert(contents, '```')
  return { kind = cmp.lsp.MarkupKind.Markdown, value = table.concat(contents, '\n') }
end

return source
