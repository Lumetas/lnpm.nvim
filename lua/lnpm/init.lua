local M = {}
local plugins_b_installing = 0
local wait_installing = 0
M.config = {
	install_path = vim.fn.stdpath('config') .. '/pack/plugin/start/',
	git = true,
	name = false,
	alias = false,
	lrule = false
}

local after_install_plugins_list = {}


function M.setup(config)
	M.config = vim.tbl_deep_extend('force', M.config, config or {})
end

-- Таблица для отслеживания загруженных плагинов
M.loaded_plugins = {}
M.plugin_objects = {}
M.registered_plugins = {}
M.make_cache = {} -- Кэш для созданных объектов
M.installation_status = {} -- Кэш статуса установки плагинов

-- Вспомогательные функции
local function ensure_dir(path)
	local success = vim.fn.mkdir(path, 'p')
	if success == 0 then
		error('Failed to create directory: ' .. path)
	end
end

local function plugin_installed(plugin_name)
	if M.installation_status[plugin_name] ~= nil then
		return M.installation_status[plugin_name]
	end

	local plugin_path = M.config.install_path .. plugin_name
	local is_installed = vim.fn.isdirectory(plugin_path) == 1
	M.installation_status[plugin_name] = is_installed
	return is_installed
end

local function extract_plugin_name(repo)
	return repo:match("([^/]+)$")
end

local function install_plugin(repo, opts, callback)
	plugins_b_installing = 1
	local plugin_name = extract_plugin_name(repo)
	local install_dir = M.config.install_path .. plugin_name
	local repo_url = 'https://github.com/' .. repo .. '.git'

	-- Создаем директорию если не существует
	ensure_dir(M.config.install_path)

	-- Клонируем репозиторий безопасно
	local cmd = {'git', 'clone', '--depth=1', repo_url, install_dir}
	wait_installing = wait_installing + 1
	vim.fn.jobstart(cmd, {
		on_exit = function(_, code)
			if code == 0 then
				-- Удаляем .git если требуется
				if opts.git == false then
					local git_dir = install_dir .. '/.git'
					vim.fn.delete(git_dir, 'rf')
				end

				-- Обновляем кэш статуса
				M.installation_status[plugin_name] = true

				vim.schedule(function()
					callback(true)
				end)
				wait_installing = wait_installing - 1
			else
				vim.schedule(function()
					callback(false, 'Installation failed with code: ' .. code)
				end)
			end
		end
	})

end

-- Основная функция
function M.load(repo, setup_callback, opts)
	opts = vim.tbl_extend('force', M.config, opts or {})
	local plugin_name = extract_plugin_name(repo)

	-- Регистрируем плагин
	M.registered_plugins[repo] = {
		name = plugin_name,
		repo = repo,
		opts = opts,
		loaded = false,
		lrule = opts.lrule or false
	}

	if not plugin_installed(plugin_name) then

		install_plugin(repo, opts, function(success, err)
			if success then
				table.insert(after_install_plugins_list, {repo, setup_callback, opts})
				-- print('Plugin installed: ' .. plugin_name)
				-- M.finalize_load(repo, setup_callback, opts)
			else
				error('Failed to install plugin ' .. repo .. ': ' .. (err or 'unknown error'))
			end
		end)
	else
		M.finalize_load(repo, setup_callback, opts)
	end
end

function M.finalize_load(repo, setup_callback, opts)
	local plugin_name = extract_plugin_name(repo)
	local plugin_path = M.config.install_path .. plugin_name

	if opts.name ~= false then
		plugin_name = opts.name
	end

	-- Добавляем путь в runtimepath если его там нет
	local rtp_list = vim.opt.rtp:get()
	local found = false
	for _, path in ipairs(rtp_list) do
		if path == plugin_path then
			found = true
			break
		end
	end

	if not found then
		vim.opt.rtp:prepend(plugin_path)
	end


	
	local load_callback = function()
		local ok, plugin = pcall(require, plugin_name)
		if ok and plugin then
			if opts.alias ~= false then
				M.plugin_objects[opts.alias] = plugin
			else 
				M.plugin_objects[repo] = plugin
			end

			if setup_callback then
				setup_callback(plugin)
			elseif plugin.setup then
				plugin.setup()
			end

			M.registered_plugins[repo].loaded = true
			M.loaded_plugins[plugin_name] = true
		else
			-- Загружаем файлы плагина
			vim.cmd('runtime! plugin/**/*.vim')
			vim.cmd('runtime! plugin/**/*.lua')

			if setup_callback then
				local minimal_plugin = {
					setup = function(config) end
				}
				setup_callback(minimal_plugin)
			end

			M.registered_plugins[repo].loaded = true
		end
	end
	if opts.lrule then
		opts.lrule(load_callback)
	else
		load_callback()
	end
end

-- Новая функция make для создания объектов плагинов
function M.make(identifier, opts)
	opts = opts or {}
	local force_recreate = opts.force or false
	local custom_name = opts.name or identifier
	local module_name = opts.name or extract_plugin_name(identifier)

	-- Если force_recreate = false и объект уже в кэше, возвращаем его
	if not force_recreate and M.make_cache[custom_name] then
		return M.make_cache[custom_name]
	end

	-- Проверяем, является ли identifier репозиторием (содержит /)
	if identifier:match("/") then
		local plugin_name = extract_plugin_name(identifier)

		-- Это репозиторий, нужно установить плагин
		if not plugin_installed(plugin_name) then
			print('Installing plugin: ' .. identifier)

			-- Синхронная установка для make
			local install_dir = M.config.install_path .. plugin_name
			local repo_url = 'https://github.com/' .. identifier .. '.git'
			ensure_dir(M.config.install_path)

			-- Безопасное выполнение команды
			local cmd = {'git', 'clone', '--depth=1', repo_url, install_dir}
			local result = vim.fn.system(cmd)

			if vim.v.shell_error ~= 0 then
				error('Failed to install plugin ' .. identifier .. ': ' .. (result or 'unknown error'))
			end

			-- Удаляем .git если требуется
			if opts.git == false then
				local git_dir = install_dir .. '/.git'
				vim.fn.delete(git_dir, 'rf')
			end

			-- Обновляем кэш статуса
			M.installation_status[plugin_name] = true
		end

		-- Добавляем путь в runtimepath
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
			vim.opt.rtp:prepend(plugin_path)
		end
	end

	-- Пытаемся загрузить модуль
	local ok, plugin_obj = pcall(require, module_name)

	if ok and plugin_obj then
		M.make_cache[custom_name] = plugin_obj
		return plugin_obj
	else
		-- Если require не сработал, проверяем зарегистрированные плагины
		if M.plugin_objects[identifier] then
			M.make_cache[custom_name] = M.plugin_objects[identifier]
			return M.plugin_objects[identifier]
		elseif M.plugin_objects[custom_name] then
			M.make_cache[custom_name] = M.plugin_objects[custom_name]
			return M.plugin_objects[custom_name]
		else
			local err_msg = 'Failed to create object for: ' .. identifier
			if not ok then
				err_msg = err_msg .. ' (require error: ' .. tostring(plugin_obj) .. ')'
			end
			error(err_msg)
		end
	end
end

-- Функция для вывода списка плагинов
function M.list()
	local all_plugins = {}
	local installed_plugins = {}

	-- Получаем все установленные плагины безопасно
	local handle = io.popen('ls -1 "' .. M.config.install_path .. '" 2>/dev/null')
	if handle then
		for plugin_name in handle:lines() do
			installed_plugins[plugin_name] = true
			-- Обновляем кэш статуса
			M.installation_status[plugin_name] = true
		end
		handle:close()
	end

	-- Собираем информацию
	print("═"..string.rep("═", 60))
	print("📦 LNPM - PLUGIN MANAGER STATUS")
	print("═"..string.rep("═", 60))

	-- Зарегистрированные плагины
	if next(M.registered_plugins) ~= nil then
		print("\n📍 REGISTERED PLUGINS:")
		for repo, info in pairs(M.registered_plugins) do
			local status = info.loaded and "✅ LOADED" or "❌ NOT LOADED"
			print(string.format("  %s - %s", repo, status))
			all_plugins[info.name] = true
		end
	else
		print("\n⚠️  No plugins registered via lnpm.load()")
	end

	-- Незарегистрированные установленные плагины
	local orphan_plugins = {}
	for plugin_name, _ in pairs(installed_plugins) do
		if not all_plugins[plugin_name] then
			if plugin_name ~= 'lnpm.nvim' then
				table.insert(orphan_plugins, plugin_name)
			end
		end
	end

	if #orphan_plugins > 0 then
		print("\n🗑️  ORPHAN PLUGINS (not registered via lnpm.load()):")
		for _, plugin_name in ipairs(orphan_plugins) do
			print("  ❓ " .. plugin_name)
		end
	end

	-- Статистика
	local total_installed = 0
	for _ in pairs(installed_plugins) do total_installed = total_installed + 1 end

	local total_registered = 0
	for _ in pairs(M.registered_plugins) do total_registered = total_registered + 1 end

	local loaded_count = 0
	for _, info in pairs(M.registered_plugins) do
		if info.loaded then loaded_count = loaded_count + 1 end
	end

	print("\n📊 STATISTICS:")
	print(string.format("  Total installed: %d", total_installed))
	print(string.format("  Registered via lnpm: %d", total_registered))
	print(string.format("  Currently loaded: %d", loaded_count))
	print(string.format("  Orphan plugins: %d", #orphan_plugins))

	-- Информация о make кэше
	local make_count = 0
	for _ in pairs(M.make_cache) do make_count = make_count + 1 end

	print(string.format("  Objects in make cache: %d", make_count))
	print("═"..string.rep("═", 60))

	return {
		installed = installed_plugins,
		registered = M.registered_plugins,
		orphan = orphan_plugins,
		make_cache = M.make_cache
	}
end

-- Функция для очистки неиспользуемых плагинов
function M.clean(confirm)
	local status = M.list()
	local orphan_plugins = status.orphan

	if #orphan_plugins == 0 then
		print("🎉 No orphan plugins to clean!")
		return
	end

	if not confirm then
		print(string.format("\n⚠️  Found %d orphan plugins. Run :LnpmClean! to remove them", #orphan_plugins))
		print("Orphan plugins: " .. table.concat(orphan_plugins, ", "))
		return
	end

	print("\n🧹 REMOVING ORPHAN PLUGINS...")
	local removed_count = 0

	for _, plugin_name in ipairs(orphan_plugins) do
		local plugin_path = M.config.install_path .. plugin_name

		-- Безопасное удаление
		local success = vim.fn.delete(plugin_path, 'rf')
		if success == 0 then
			print("✅ Removed: " .. plugin_name)
			removed_count = removed_count + 1
			-- Обновляем кэш статуса
			M.installation_status[plugin_name] = false
		else
			print("❌ Failed to remove: " .. plugin_name)
		end
	end

	print(string.format("\n🎉 Removed %d orphan plugins", removed_count))
end

-- Функция для массовой загрузки
function M.load_all(plugins)
	for _, plugin_spec in ipairs(plugins) do
		local repo = plugin_spec[1]
		local setup_cb = plugin_spec[2]
		local opts = plugin_spec[3] or {}

		M.load(repo, setup_cb, opts)
	end
end

-- Функция для обновления плагинов
function M.update()
	print("🔄 Updating plugins...")
	local plugins_dir = M.config.install_path

	-- Безопасное получение списка git репозиториев
	local handle = io.popen('find "' .. plugins_dir .. '" -name ".git" -type d 2>/dev/null')

	local updated_count = 0

	if handle then
		for git_dir in handle:lines() do
			local plugin_dir = git_dir:gsub('/.git$', '')
			local plugin_name = plugin_dir:match("([^/]+)$")

			-- Пропускаем плагины без .git (если git = false)
			if vim.fn.isdirectory(git_dir) == 1 then
				print('Updating: ' .. plugin_name)

				-- Безопасное обновление
				local update_cmd = {'git', '-C', plugin_dir, 'pull', '--rebase'}
				local result = vim.fn.system(update_cmd)

				if vim.v.shell_error == 0 then
					updated_count = updated_count + 1
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

	print(string.format("\n🎉 Updated %d plugins", updated_count))
end

function M.load_after_install()
	if plugins_b_installing == 0 then
		return
	end
	while wait_installing > 0 do
		vim.wait(100)
	end
	for _, plugin_spec in ipairs(after_install_plugins_list) do
		local repo = plugin_spec[1]
		local callback = plugin_spec[2]
		local opts = plugin_spec[3] or {}

		M.finalize_load(repo, callback, opts)
		if opts.onInstall then
			opts.onInstall()
		end

	end
	print("✅ All plugins installed")
end

-- Создаем команды Neovim
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
			local identifier = opts.args
			local plugin_obj = M.make(identifier)
			if plugin_obj then
				print('Created object for: ' .. identifier)
			end
		else
			print("Usage: LnpmMake <plugin_identifier>")
		end
	end, {desc = 'Create plugin object', nargs = 1})
end

-- Автоматически создаем команды при загрузке
M.setup_commands()

return M
