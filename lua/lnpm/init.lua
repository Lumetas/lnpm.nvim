local M = {}

-- Конфигурация по умолчанию
M.config = {
    install_path = vim.fn.stdpath('config') .. '/pack/plugin/opt/',
    git = true,
    name = false,
    alias = false,
    lrule = false
}

-- Кэшированные данные
local installation_cache = {}      -- Кэш статуса установки плагинов
local make_cache = {}              -- Кэш созданных объектов
local loaded_plugins = {}          -- Загруженные плагины
local plugin_objects = {}          -- Объекты плагинов
local registered_plugins = {}      -- Зарегистрированные плагины
local pending_installations = {}   -- Ожидающие установки плагины

-- Вспомогательные функции
local function ensure_dir(path)
    if vim.fn.isdirectory(path) == 0 then
        local success, err = pcall(vim.fn.mkdir, path, 'p')
        if not success then
            error('Failed to create directory: ' .. path .. ' - ' .. err)
        end
    end
end

local function get_plugin_name(repo)
    return repo:match("([^/]+)$") or repo
end

local function is_plugin_installed(plugin_name)
    if installation_cache[plugin_name] ~= nil then
        return installation_cache[plugin_name]
    end
    
    local plugin_path = M.config.install_path .. plugin_name
    local installed = vim.fn.isdirectory(plugin_path) == 1
    installation_cache[plugin_name] = installed
    return installed
end

local function normalize_repo_url(repo)
    if not repo:match("^https?://") then
        return 'https://github.com/' .. repo .. '.git'
    end
    return repo
end

local function get_lock_file_path()
    return vim.fn.stdpath('config') .. '/lnpm.lock.json'
end

local function read_lock_file()
    local path = get_lock_file_path()
    local file = io.open(path, 'r')
    if not file then
        return {}
    end
    local content = file:read('*all')
    file:close()
    if content == nil or content == '' then
        return {}
    end
    local ok, data = pcall(vim.json.decode, content)
    if not ok then
        vim.notify('Failed to parse lock file: ' .. tostring(data), vim.log.levels.WARN)
        return {}
    end
    return data.plugins or {}
end

local function write_lock_file(plugins)
    local path = get_lock_file_path()
    local data = {
        version = 1,
        plugins = plugins
    }
    local file = io.open(path, 'w')
    if not file then
        vim.notify('Failed to write lock file: ' .. path, vim.log.levels.ERROR)
        return
    end
    local ok, json = pcall(vim.json.encode, data)
    if not ok then
        vim.notify('Failed to encode lock file: ' .. tostring(json), vim.log.levels.ERROR)
        file:close()
        return
    end
    file:write(json)
    file:close()
end

local function get_commit_hash(plugin_dir)
    local cmd = string.format('git -C "%s" rev-parse HEAD', plugin_dir)
    local result = vim.fn.system(cmd):gsub('%s+', '')
    if vim.v.shell_error ~= 0 or result == '' then
        return nil
    end
    return result
end

local function finish_install(plugin_name, install_dir, opts, callback)
    vim.notify('Installed ' .. plugin_name, vim.log.levels.INFO)
    if opts.git == false then
        local git_dir = install_dir .. '/.git'
        vim.fn.delete(git_dir, 'rf')
    end
    installation_cache[plugin_name] = true
    callback(true, plugin_name)
end

-- Установка плагина
local function install_plugin(repo, opts, callback)
    local plugin_name = get_plugin_name(repo)
    local install_dir = M.config.install_path .. plugin_name
    local repo_url = normalize_repo_url(repo)

    ensure_dir(M.config.install_path)

    local lock = read_lock_file()
    local lock_key = repo
    local locked_hash = lock[lock_key] and lock[lock_key].hash or nil

    local cmd = {'git', 'clone', '--depth=1', repo_url, install_dir}

    vim.fn.jobstart(cmd, {
        on_exit = function(_, code)
            if code == 0 then
                if locked_hash then
                    local fetch_cmd = {'git', '-C', install_dir, 'fetch', '--depth=1', 'origin', locked_hash}
                    vim.fn.jobstart(fetch_cmd, {
                        on_exit = function(_, fetch_code)
                            if fetch_code == 0 then
                                local checkout_cmd = {'git', '-C', install_dir, 'checkout', locked_hash}
                                vim.fn.jobstart(checkout_cmd, {
                                    on_exit = function(_, checkout_code)
                                        if checkout_code == 0 then
                                            finish_install(plugin_name, install_dir, opts, callback)
                                        else
                                            vim.schedule(function()
                                                vim.notify('Failed to checkout locked hash ' .. locked_hash .. ' for ' .. plugin_name, vim.log.levels.WARN)
                                            end)
                                            finish_install(plugin_name, install_dir, opts, callback)
                                        end
                                    end
                                })
                            else
                                vim.schedule(function()
                                    vim.notify('Failed to fetch locked hash ' .. locked_hash .. ' for ' .. plugin_name, vim.log.levels.WARN)
                                end)
                                finish_install(plugin_name, install_dir, opts, callback)
                            end
                        end
                    })
                else
                    finish_install(plugin_name, install_dir, opts, callback)
                end
            else
                callback(false, 'Installation failed with exit code: ' .. code)
            end
        end,
        on_stderr = function(_, data)
            if data and #data > 0 then
                vim.schedule(function()
                    vim.notify('Installing ' .. plugin_name .. ': ' .. table.concat(data, ' '), vim.log.levels.WARN)
                end)
            end
        end
    })
end

-- Загрузка плагина в runtime
local function load_plugin_module(plugin_path, plugin_name, repo, opts, setup_callback)
    -- Добавляем путь в runtimepath
    local rtp_list = vim.opt.rtp:get()
    local found = false
    
    for _, path in ipairs(rtp_list) do
        if path == plugin_path then
            found = true
            break
        end
    end
    
    if not found then
        vim.opt.rtp:append(plugin_path)
    end
    
	local plugin_files = {
		vim.fn.glob(plugin_path .. '/plugin/**/*.vim', true, true),
		vim.fn.glob(plugin_path .. '/plugin/**/*.lua', true, true),
		vim.fn.glob(plugin_path .. '/after/plugin/**/*.lua', true, true),
		vim.fn.glob(plugin_path .. '/after/plugin/**/*.vim', true, true)
	}
	
	for _, files in ipairs(plugin_files) do
		for _, file in ipairs(files) do
			vim.cmd('source ' .. vim.fn.fnameescape(file))
		end
	end
    
    -- Пытаемся загрузить как модуль Lua
    local module_name = opts.name or plugin_name
    local ok, plugin = pcall(require, module_name)
    
    if ok and plugin then
        local alias = opts.alias or repo
        plugin_objects[alias] = plugin
        loaded_plugins[plugin_name] = true
        
        if setup_callback then
            setup_callback(plugin)
        end
        return plugin
    else
        -- Если require не сработал, создаем минимальный объект
        local minimal_plugin = {
            setup = function(config) end,
            _name = plugin_name,
            _repo = repo
        }
        
        if setup_callback then
            setup_callback(minimal_plugin)
        end
        
        loaded_plugins[plugin_name] = true
        return minimal_plugin
    end
end

-- Основной API
function M.setup(config)
    M.config = vim.tbl_deep_extend('force', M.config, config or {})
    ensure_dir(M.config.install_path)
end

function M.load(repo, setup_callback, opts)
    opts = vim.tbl_deep_extend('force', M.config, opts or {})
    local plugin_name = get_plugin_name(repo)
    
    -- Регистрируем плагин
    registered_plugins[repo] = {
        name = plugin_name,
        repo = repo,
        opts = opts,
        loaded = false,
        lrule = opts.lrule or false
    }
    
    if not is_plugin_installed(plugin_name) then
        table.insert(pending_installations, {
            repo = repo,
            callback = setup_callback,
            opts = opts
        })
        
        install_plugin(repo, opts, function(success, err)
            if success then
                M._finalize_load(repo, setup_callback, opts)
                
                -- Вызываем onInstall если есть
                if opts.onInstall then
                    opts.onInstall()
                end
                
                -- Убираем из ожидающих
                for i, pending in ipairs(pending_installations) do
                    if pending.repo == repo then
                        table.remove(pending_installations, i)
                        break
                    end
                end
            else
                vim.schedule(function()
                    vim.notify('Failed to install ' .. repo .. ': ' .. (err or 'unknown error'), vim.log.levels.ERROR)
                end)
            end
        end)
    else
        M._finalize_load(repo, setup_callback, opts)
    end
end

function M._finalize_load(repo, setup_callback, opts)
    local plugin_name = get_plugin_name(repo)
    local plugin_path = M.config.install_path .. plugin_name
    
    local load_function = function()
        local plugin = load_plugin_module(plugin_path, plugin_name, repo, opts, setup_callback)
        registered_plugins[repo].loaded = true
        return plugin
    end
    
    if opts.lrule and type(opts.lrule) == "function" then
        opts.lrule(load_function)
    else
        load_function()
    end
end

function M.make(identifier, opts)
    opts = opts or {}
    local force_recreate = opts.force or false
    local custom_name = opts.name or identifier
    local module_name = opts.name or get_plugin_name(identifier)
    
    -- Проверяем кэш
    if not force_recreate and make_cache[custom_name] then
        return make_cache[custom_name]
    end
    
    -- Проверяем, является ли identifier репозиторием
    if identifier:match("/") then
        local plugin_name = get_plugin_name(identifier)
        
        if not is_plugin_installed(plugin_name) then
            vim.notify('Installing plugin: ' .. identifier, vim.log.levels.INFO)

            local install_dir = M.config.install_path .. plugin_name
            local repo_url = normalize_repo_url(identifier)

            ensure_dir(M.config.install_path)

            local lock = read_lock_file()
            local locked_hash = lock[identifier] and lock[identifier].hash or nil

            local cmd = string.format('git clone --depth=1 %s %s', repo_url, install_dir)
            local result = vim.fn.system(cmd)

            if vim.v.shell_error ~= 0 then
                error('Failed to install ' .. identifier .. ': ' .. (result or 'unknown error'))
            end

            if locked_hash then
                local fetch_cmd = string.format('git -C "%s" fetch --depth=1 origin %s', install_dir, locked_hash)
                local fetch_result = vim.fn.system(fetch_cmd)
                if vim.v.shell_error == 0 then
                    local checkout_cmd = string.format('git -C "%s" checkout %s', install_dir, locked_hash)
                    local checkout_result = vim.fn.system(checkout_cmd)
                    if vim.v.shell_error ~= 0 then
                        vim.notify('Failed to checkout locked hash ' .. locked_hash .. ' for ' .. plugin_name, vim.log.levels.WARN)
                    end
                else
                    vim.notify('Failed to fetch locked hash ' .. locked_hash .. ' for ' .. plugin_name, vim.log.levels.WARN)
                end
            end

            if opts.git == false then
                local git_dir = install_dir .. '/.git'
                vim.fn.delete(git_dir, 'rf')
            end
            
            installation_cache[plugin_name] = true
        end
        
        -- Добавляем в runtimepath
        local plugin_path = M.config.install_path .. plugin_name
        local rtp_list = vim.opt.rtp:get()
        local found = false
        
        for _, path in ipairs(rtp_list) do
            if path == plugin_path then
                found = true
                break
            end
        end
        
        if not found then
            vim.opt.rtp:append(plugin_path)
        end
    end
    
    -- Пытаемся загрузить модуль
    local ok, plugin_obj = pcall(require, module_name)
    
    if ok and plugin_obj then
        make_cache[custom_name] = plugin_obj
        return plugin_obj
    elseif plugin_objects[identifier] then
        make_cache[custom_name] = plugin_objects[identifier]
        return plugin_objects[identifier]
    elseif plugin_objects[custom_name] then
        make_cache[custom_name] = plugin_objects[custom_name]
        return plugin_objects[custom_name]
    else
        local err_msg = 'Failed to create object for: ' .. identifier
        if not ok then
            err_msg = err_msg .. ' (require error: ' .. tostring(plugin_obj) .. ')'
        end
        error(err_msg)
    end
end

function M.list()
    -- Получаем установленные плагины
    local installed_plugins = {}
    local handle = io.popen('ls -1 "' .. M.config.install_path .. '" 2>/dev/null')
    
    if handle then
        for plugin_name in handle:lines() do
            installed_plugins[plugin_name] = true
            installation_cache[plugin_name] = true
        end
        handle:close()
    end
    
    -- Собираем информацию
    local orphan_plugins = {}
    local all_registered = {}
    
    for _, info in pairs(registered_plugins) do
        all_registered[info.name] = true
    end
    
    for plugin_name, _ in pairs(installed_plugins) do
        if not all_registered[plugin_name] and plugin_name ~= 'lnpm.nvim' then
            table.insert(orphan_plugins, plugin_name)
        end
    end
    
    -- Вывод информации
    local lines = {
        "═" .. string.rep("═", 60),
        "📦 LNPM - PLUGIN MANAGER STATUS",
        "═" .. string.rep("═", 60),
        ""
    }
    
    -- Зарегистрированные плагины
    if next(registered_plugins) ~= nil then
        table.insert(lines, "📍 REGISTERED PLUGINS:")
        for repo, info in pairs(registered_plugins) do
            local status = info.loaded and "✅ LOADED" or "❌ NOT LOADED"
            table.insert(lines, string.format("  %s - %s", repo, status))
        end
        table.insert(lines, "")
    else
        table.insert(lines, "⚠️  No plugins registered via lnpm.load()")
        table.insert(lines, "")
    end
    
    -- Незарегистрированные плагины
    if #orphan_plugins > 0 then
        table.insert(lines, "🗑️  ORPHAN PLUGINS (not registered via lnpm.load()):")
        for _, plugin_name in ipairs(orphan_plugins) do
            table.insert(lines, "  ❓ " .. plugin_name)
        end
        table.insert(lines, "")
    end
    
    -- Статистика
    local total_installed = 0
    for _ in pairs(installed_plugins) do total_installed = total_installed + 1 end
    
    local total_registered = 0
    for _ in pairs(registered_plugins) do total_registered = total_registered + 1 end
    
    local loaded_count = 0
    for _, info in pairs(registered_plugins) do
        if info.loaded then loaded_count = loaded_count + 1 end
    end
    
    table.insert(lines, "📊 STATISTICS:")
    table.insert(lines, string.format("  Total installed: %d", total_installed))
    table.insert(lines, string.format("  Registered via lnpm: %d", total_registered))
    table.insert(lines, string.format("  Currently loaded: %d", loaded_count))
    table.insert(lines, string.format("  Orphan plugins: %d", #orphan_plugins))
    
    local make_count = 0
    for _ in pairs(make_cache) do make_count = make_count + 1 end
    table.insert(lines, string.format("  Objects in make cache: %d", make_count))
    
    table.insert(lines, "═" .. string.rep("═", 60))
    
    print(table.concat(lines, "\n"))
    
    return {
        installed = installed_plugins,
        registered = registered_plugins,
        orphan = orphan_plugins,
        make_cache = make_cache,
        loaded = loaded_plugins,
        pending = #pending_installations
    }
end

function M.clean(confirm)
    local status = M.list()
    local orphan_plugins = status.orphan
    
    if #orphan_plugins == 0 then
        print("🎉 No orphan plugins to clean!")
        return 0
    end
    
    if not confirm then
        print(string.format("\n⚠️  Found %d orphan plugins. Run :LnpmClean! to remove them", #orphan_plugins))
        print("Orphan plugins: " .. table.concat(orphan_plugins, ", "))
        return 0
    end
    
    print("\n🧹 REMOVING ORPHAN PLUGINS...")
    local removed_count = 0
    
    for _, plugin_name in ipairs(orphan_plugins) do
        local plugin_path = M.config.install_path .. plugin_name
        
        local success = vim.fn.delete(plugin_path, 'rf')
        if success == 0 then
            print("✅ Removed: " .. plugin_name)
            removed_count = removed_count + 1
            installation_cache[plugin_name] = false
        else
            print("❌ Failed to remove: " .. plugin_name)
        end
    end
    
    print(string.format("\n🎉 Removed %d orphan plugins", removed_count))
    return removed_count
end

function M.load_all(plugins)
    for _, plugin_spec in ipairs(plugins) do
        local repo = plugin_spec[1]
        local setup_cb = plugin_spec[2]
        local opts = plugin_spec[3] or {}
        
        M.load(repo, setup_cb, opts)
    end
end

function M.update()
    print("🔄 Updating plugins...")
    local plugins_dir = M.config.install_path
    local updated_count = 0
    local lock = read_lock_file()

    local handle = io.popen('find "' .. plugins_dir .. '" -name ".git" -type d 2>/dev/null')

    if handle then
        for git_dir in handle:lines() do
            local plugin_dir = git_dir:gsub('/.git$', '')
            local plugin_name = plugin_dir:match("([^/]+)$")

            if vim.fn.isdirectory(git_dir) == 1 then
                print('Updating: ' .. plugin_name)

                local update_cmd = string.format('git -C "%s" pull --rebase', plugin_dir)
                local result = vim.fn.system(update_cmd)

                if vim.v.shell_error == 0 then
                    updated_count = updated_count + 1
                    local hash = get_commit_hash(plugin_dir)
                    if hash then
                        local found = false
                        for repo, info in pairs(lock) do
                            if get_plugin_name(repo) == plugin_name then
                                lock[repo].hash = hash
                                found = true
                                break
                            end
                        end
                        if not found then
                            local remote_cmd = string.format('git -C "%s" remote get-url origin', plugin_dir)
                            local remote = vim.fn.system(remote_cmd):gsub('%s+', '')
                            local repo_url = plugin_name
                            if remote ~= '' and vim.v.shell_error == 0 then
                                repo_url = remote:gsub('^https://github.com/', ''):gsub('%.git$', '')
                            end
                            lock[repo_url] = {
                                name = plugin_name,
                                hash = hash
                            }
                        end
                    end
                    print('✅ Updated: ' .. plugin_name)
                else
                    print('❌ Failed to update: ' .. plugin_name .. ': ' .. result)
                end
            else
                print('⏭️  Skipping (no git): ' .. plugin_name)
            end
        end
        handle:close()
    end

    write_lock_file(lock)
    print(string.format("\n🎉 Updated %d plugins", updated_count))
    return updated_count
end

function M.lock()
    print("🔒 Generating lock file...")
    local lock = {}

    local handle = io.popen('find "' .. M.config.install_path .. '" -name ".git" -type d 2>/dev/null')

    if handle then
        for git_dir in handle:lines() do
            local plugin_dir = git_dir:gsub('/.git$', '')
            local plugin_name = plugin_dir:match("([^/]+)$")

            if vim.fn.isdirectory(git_dir) == 1 then
                local hash = get_commit_hash(plugin_dir)
                if hash then
                    local repo_url = plugin_name
                    local remote_cmd = string.format('git -C "%s" remote get-url origin', plugin_dir)
                    local remote = vim.fn.system(remote_cmd):gsub('%s+', '')
                    if remote ~= '' then
                        repo_url = remote:gsub('^https://github.com/', ''):gsub('%.git$', '')
                    end
                    lock[repo_url] = {
                        name = plugin_name,
                        hash = hash
                    }
                    print('  Locked: ' .. repo_url .. ' @ ' .. hash:sub(1, 7))
                end
            end
        end
        handle:close()
    end

    local lock_count = 0
    for _ in pairs(lock) do lock_count = lock_count + 1 end
    write_lock_file(lock)
    print(string.format("🔒 Locked %d plugins in %s", lock_count, get_lock_file_path()))
    return lock
end

function M.get_plugin(name_or_repo)
    return plugin_objects[name_or_repo] or make_cache[name_or_repo]
end

function M.is_loaded(plugin_name)
    return loaded_plugins[plugin_name] == true
end

function M.get_lock_file_path()
    return get_lock_file_path()
end

-- Настройка команд
function M.setup_commands()
    vim.api.nvim_create_user_command('LnpmList', function()
        M.list()
    end, {desc = 'Show lnpm plugin status'})
    
    vim.api.nvim_create_user_command('LnpmClean', function(opts)
        M.clean(opts.bang)
    end, {desc = 'Clean orphan plugins', bang = true})
    
    vim.api.nvim_create_user_command('LnpmUpdate', function()
        M.update()
    end, {desc = 'Update all plugins'})
    
    vim.api.nvim_create_user_command('LnpmInstall', function(opts)
        if opts.args and opts.args ~= "" then
            M.load(opts.args, function() end, {})
        else
            print("Usage: LnpmInstall <user/repo>")
        end
    end, {desc = 'Install a plugin', nargs = '?'})
    
    vim.api.nvim_create_user_command('LnpmMake', function(opts)
        if opts.args and opts.args ~= "" then
            local plugin_obj = M.make(opts.args)
            if plugin_obj then
                print('Created object for: ' .. opts.args)
            end
        else
            print("Usage: LnpmMake <plugin_identifier>")
        end
    end, {desc = 'Create plugin object', nargs = 1})
    
    vim.api.nvim_create_user_command('LnpmStatus', function()
        local status = M.list()
        local pending = #pending_installations

        if pending > 0 then
            print(string.format("\n⏳ %d plugin(s) pending installation", pending))
        end
    end, {desc = 'Show installation status'})

    vim.api.nvim_create_user_command('LnpmLock', function()
        M.lock()
    end, {desc = 'Generate lock file with plugin hashes'})

    vim.api.nvim_create_user_command('LnpmLockStatus', function()
        local lock = read_lock_file()
        local count = 0
        for _ in pairs(lock) do count = count + 1 end
        if count == 0 then
            print('No lock file found. Run :LnpmLock to generate one.')
            return
        end
        local lines = {
            '🔒 LOCK FILE STATUS',
            'Path: ' .. get_lock_file_path(),
            'Locked plugins: ' .. count,
            ''
        }
        for repo, info in pairs(lock) do
            lines[#lines + 1] = '  ' .. repo .. ' @ ' .. info.hash:sub(1, 7)
        end
        print(table.concat(lines, '\n'))
    end, {desc = 'Show lock file status'})
end

-- Экспортируемые данные для отладки
M._state = {
    installation_cache = installation_cache,
    make_cache = make_cache,
    loaded_plugins = loaded_plugins,
    plugin_objects = plugin_objects,
    registered_plugins = registered_plugins,
    pending_installations = pending_installations,
    get_lock = read_lock_file,
    lock_file_path = get_lock_file_path()
}

-- Автоматическая настройка
M.setup_commands()

return M
