local vim = vim
local api = vim.api
local uv = vim.loop
local cache = require'impatient.cache'

local get_option, set_option = api.nvim_get_option, api.nvim_set_option
local get_runtime_file = api.nvim_get_runtime_file

local impatient_start = uv.hrtime()
local impatient_dur

local M = {
  cache = {},
  profile = nil,
  dirty = false,
  path = vim.fn.stdpath('cache')..'/luacache',
  log = {}
}

if _G.use_cachepack == nil then
  _G.use_cachepack = not vim.mpack
end

_G.__luacache = M

local function load_mpack()
  if vim.mpack then
    return vim.mpack
  end

  local has_packer, packer_luarocks = pcall(require, 'packer.luarocks')
  if has_packer then
    packer_luarocks.setup_paths()
  end

  return require('mpack')
end

local mpack = _G.use_cachepack and require('impatient.cachepack') or load_mpack()

local function log(...)
  M.log[#M.log+1] = table.concat({string.format(...)}, ' ')
end

function M.print_log()
  for _, l in ipairs(M.log) do
    print(l)
  end
end

function M.enable_profile()
  local ip = require('impatient.profile')

  M.profile = {}
  ip.mod_require(M.profile)

  M.print_profile = function()
    M.profile['impatient'] = {
      resolve = 0,
      load    = 0,
      exec    = impatient_dur,
      loader  = 'standard'
    }
    ip.print_profile(M.profile)
  end

  vim.cmd[[command! LuaCacheProfile lua _G.__luacache.print_profile()]]
end

local function hash(modpath)
  local stat = uv.fs_stat(modpath)
  if stat then
    return stat.mtime.sec
  end
end

local function hrtime()
  if M.profile then
    return uv.hrtime()
  end
end

local appdir = os.getenv('APPDIR')

local function modpath_mangle(modpath)
  if appdir then
    modpath = modpath:gsub(appdir, '/$APPDIR')
  end
  return modpath
end

local function modpath_unmangle(modpath)
  if appdir then
    modpath = modpath:gsub('/$APPDIR', appdir)
  end
  return modpath
end

local function load_package_with_cache(name, loader)
  local resolve_start = hrtime()

  local basename = name:gsub('%.', '/')
  local paths = {"lua/"..basename..".lua", "lua/"..basename.."/init.lua"}

  for _, path in ipairs(paths) do
    local modpath = get_runtime_file(path, false)[1]
    if modpath then
      local load_start = hrtime()
      local chunk, err = loadfile(modpath)

      if M.profile then
        local mp = M.profile
        mp[basename].resolve = load_start - resolve_start
        mp[basename].load    = hrtime() - load_start
        mp[basename].loader  = loader or 'standard'
      end

      if chunk == nil then return err end

      log('Creating cache for module %s', basename)
      M.cache[basename] = {modpath_mangle(modpath), hash(modpath), string.dump(chunk)}
      M.dirty = true

      return chunk
    end
  end

  -- Copied from neovim/src/nvim/lua/vim.lua
  for _, trail in ipairs(vim._so_trails) do
    local path = "lua"..trail:gsub('?', basename) -- so_trails contains a leading slash
    local found = vim.api.nvim_get_runtime_file(path, false)
    if #found > 0 then
      -- Making function name in Lua 5.1 (see src/loadlib.c:mkfuncname) is
      -- a) strip prefix up to and including the first dash, if any
      -- b) replace all dots by underscores
      -- c) prepend "luaopen_"
      -- So "foo-bar.baz" should result in "luaopen_bar_baz"
      local dash = name:find("-", 1, true)
      local modname = dash and name:sub(dash + 1) or name
      local f, err = package.loadlib(found[1], "luaopen_"..modname:gsub("%.", "_"))
      return f or error(err)
    end
  end

  return nil
end

local reduced_rtp
local rtp

-- Speed up non-cached loads by reducing the rtp path during requires
local function update_reduced_rtp()
  local luadirs = get_runtime_file('lua/', true)

  for i = 1, #luadirs do
    luadirs[i] = luadirs[i]:sub(1, -6)
  end

  reduced_rtp = table.concat(luadirs, ',')
end

local function load_package_with_cache_reduced_rtp(name)
  if vim.in_fast_event() then
    -- Can't set/get options in the fast handler
    return load_package_with_cache(name, 'fast')
  end

  local orig_rtp = get_option('runtimepath')
  local orig_ei  = get_option('eventignore')

  if orig_rtp ~= rtp then
    log('Updating reduced rtp')
    rtp = orig_rtp
    update_reduced_rtp()
  end

  set_option('eventignore', 'all')
  set_option('rtp', reduced_rtp)

  local found = load_package_with_cache(name, 'reduced')

  set_option('rtp', orig_rtp)
  set_option('eventignore', orig_ei)

  return found
end

local function load_from_cache(name)
  local basename = name:gsub('%.', '/')

  local resolve_start = hrtime()
  if M.cache[basename] == nil then
    log('No cache for module %s', basename)
    return 'No cache entry'
  end

  local modpath, mhash, codes = unpack(M.cache[basename])

  if mhash ~= hash(modpath_unmangle(modpath)) then
    log('Stale cache for module %s', basename)
    M.cache[basename] = nil
    M.dirty = true
    return 'Stale cache'
  end

  local load_start = hrtime()
  local chunk = loadstring(codes)

  if M.profile then
    local mp = M.profile
    mp[basename].resolve = load_start - resolve_start
    mp[basename].load    = hrtime() - load_start
    mp[basename].loader  = 'cache'
  end

  if not chunk then
    M.cache[basename] = nil
    M.dirty = true
    log('Error loading cache for module. Invalidating', basename)
    return 'Cache error'
  end

  return chunk
end

function M.save_cache()
  if M.dirty then
    log('Updating cache')
    cache:__insert(mpack.pack(M.cache))
    M.dirty = false
  end
end


function M.clear_cache()
  cache:__clear()
end

-- -- run a crude hash on vim._load_package to make sure it hasn't changed.
-- local function verify_vim_loader()
--   local expected_sig = 31172

--   local dump = {string.byte(string.dump(vim._load_package), 1, -1)}
--   local actual_sig = #dump
--   for i = 1, #dump do
--     actual_sig = actual_sig + dump[i]
--   end

--   if actual_sig ~= expected_sig then
--     print(string.format('warning: vim._load_package has an unexpected value, impatient might not behave properly (%d)', actual_sig))
--   end
-- end

local function setup()
  M.cache = mpack.unpack(cache:__get())

  local insert = table.insert
  local package = package

  -- verify_vim_loader()

  -- Fix the position of the preloader. This also makes loading modules like 'ffi'
  -- and 'bit' quicker
  if package.loaders[1] == vim._load_package then
    -- Remove vim._load_package and replace with our version
    table.remove(package.loaders, 1)
  end

  insert(package.loaders, 2, load_from_cache)
  insert(package.loaders, 3, load_package_with_cache_reduced_rtp)

  vim.cmd[[
    augroup impatient
      autocmd VimEnter,VimLeave * lua _G.__luacache.save_cache()
    augroup END

    command! LuaCacheClear lua _G.__luacache.clear_cache()
    command! LuaCacheLog   lua _G.__luacache.print_log()
  ]]

end

setup()

impatient_dur = uv.hrtime() - impatient_start

return M
