require("luaerror");
if (not luaerror) then
	error("Please make sure you've installed gm_luaerror correctly")
end

local GetHostName = GetHostName;
local HTTP = HTTP;
local IsValid = IsValid;
local ServerLog = ServerLog;
local SysTime = SysTime;
local bit = bit;
local error = error;
local hook = hook;
local ipairs = ipairs;
local luaerror = luaerror;
local math = math;
local os = os;
local pairs = pairs;
local string = string;
local system = system;
local table = table;
local tonumber = tonumber;
local tostring = tostring;
local type = type;
local unpack = unpack;
local util = util;
local xpcall = xpcall;
-- debugging
local debug = debug
local print = print;
local PrintTable = PrintTable;

local g = _G;

module("sentry");

--
--    Global Config
--
local config = {
	endpoint = nil,
	privatekey = nil,
	publickey = nil,
	projectID = nil,
	tags = {},
	release = nil,
	environment = nil,
	server_name = nil,
}

--
--    Versioning
--
SDK_VALUE = {
	name = "GMSentry",
	version = "0.0.1",
}
-- LuaJIT Style
Version = string.format("%s %s", SDK_VALUE.name, SDK_VALUE.version);
VersionNum = string.format("%02d%02d%02d", string.match(SDK_VALUE.version, "(%d+).(%d+).(%d+)"))


--
--    Utility Functions
--
function UUID4()
	-- Copied from wirelib almost verbatim
	-- It would be easier to generate this by word rather than by byte, but
	-- MSVC's RAND_MAX = 0x7FFF, which means math.random(0, 0xFFFF) won't
	-- return all possible values.
	local bytes = {}
	for i = 1, 16 do bytes[i] = math.random(0, 0xFF) end
	bytes[7] = bit.bor(0x40, bit.band(bytes[7], 0x0F))
	bytes[9] = bit.bor(0x80, bit.band(bytes[7], 0x3F))
	return string.format("%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x", unpack(bytes))
end

function ISODate(time)
	return os.date("!%Y-%m-%dT%H:%M:%S", time);
end

function GetOSName()
	if (system.IsWindows()) then
		return "Windows";
	elseif (system.IsOSX()) then
		return "macOS";
	elseif (system.IsLinux()) then
		return "Linux";
	end
	return nil;
end

function WriteLog(message, ...)
	ServerLog(string.format("Sentry: %s\n", message:format(...)));
end


--
--    Module Detection
--
DetectedModules = {};
DetectionFuncs = {
	mysqloo = function(mysqloo)
		return string.format("%d.%d", mysqloo.VERSION, mysqloo.MINOR_VERSION);
	end;
	CPPI = function(CPPI)
		local name = CPPI:GetName();
		local version = CPPI:GetVersion();
		if (version == CPPI.CPPI_NOT_IMPLEMENTED) then
			-- ???
			return nil;
		end
		return version, name;
	end;
	ulx = function(ulx)
		-- Why is this better than ulx.version
		local ULib = g["ULib"];
		if (ULib and ULib.pluginVersionStr) then
			return ULib.pluginVersionStr("ULX");
		end
		return ulx.version or ulx.VERSION;
	end;
	ULib = function(ULib)
		if (ULib.pluginVersionStr) then
			return ULib.pluginVersionStr("ULib");
		end
		return ULib.version or ULib.VERSION;
	end;
	GM = function(GM)
		if (not GM.Version) then
			return nil;
		end
		return GM.Version, string.format("Gamemode: %s", GM.Name);
	end;
}
DetectionFuncs["GAMEMODE"] = DetectionFuncs["GM"];

local LUAJIT_VERSION = "(.+) (%d+%.%d+%.%d+)";
local function detectModules()
	local VERSION = g["VERSION"];

	for name, value in pairs(g) do
		local func = DetectionFuncs[name];
		if (func) then
			-- Overrides
			local _, version, override = xpcall(func, CaptureException, value);

			if (version) then
				DetectedModules[override or name] = tostring(version);
			end
		elseif (type(value) == "table" and name ~= "sentry") then
			-- Magic guessing game
			local version = value["version"] or value["Version"] or value["VERSION"];

			if (version and version ~= VERSION and type(version) ~= "function") then
				version = tostring(version);

				-- Try and deal with LuaJIT style version strings
				local override, realversion = string.match(version, LUAJIT_VERSION);
				if (override) then
					version = realversion
				end

				DetectedModules[override or name] = version;
			end
		end
	end
end


--
--    Rate Limiting
--
local retryAfter = nil;
local skipNext = nil;
local function shouldReport(err)
	if (not config.endpoint) then
		return false;
	elseif (retryAfter ~= nil) then
		local now = SysTime();
		if (retryAfter > now) then
			return false;
		end

		retryAfter = nil;
	end

	if (skipNext == err) then
		skipNext = nil;
		return false;
	end
	skipNext = nil;

	return true;
end

local function doBackoff(backoff)
	local expires = SysTime() + backoff;
	if (retryAfter == nil or retryAfter < expires) then
		WriteLog("Rate Limiting for %d seconds!", backoff);
		retryAfter = expires;
	end
end

local function detectRateLimiting(code, headers)
	local backoff = tonumber(headers["Retry-After"]);
	-- Shouldn't happen, but might
	if (code == 429 and not backoff) then
		backoff = 20;
	end

	if (not backoff) then
		return false;
	end

	doBackoff(backoff);

	return true;
end


--
--    File Identification
--
local ADDON_FILE_PATTERN = "^@addons/([^/]+)/lua/(.*).lua$"
local GAMEMODE_FILE_PATTERN = "^@gamemodes/([^/]+)/(.*).lua$"
local ADDON_GAMEMODE_FILE_PATTERN = "^@addons/[^/]+/gamemodes/([^/]+)/(.*).lua$"
local OTHER_FILE_PATTERN = "^@lua/(.*).lua$"
local function modulify(path)
	if (path == "=[C]") then
		return "engine";
	elseif (path == "@lua_run") then
		return "lua_run";
	end

	local addon, rest = string.match(path, ADDON_FILE_PATTERN);
	if (addon) then
		return addon .. "." .. rest:gsub("/", ".");
	end

	local gamemode, rest = string.match(path, GAMEMODE_FILE_PATTERN);
	if (not gamemode) then
		gamemode, rest = string.match(path, ADDON_GAMEMODE_FILE_PATTERN);
	end
	if (gamemode) then
		return gamemode .. "." .. rest:gsub("/", ".");
	end

	local rest = string.match(path, OTHER_FILE_PATTERN);
	if (not rest) then
		return "unknown";
	end

	local name, id = luaerror.FindWorkshopAddonFileOwner(path:sub(2))
	if (not name) then
		return "unknown." .. rest:gsub("/", ".")
	end

	-- Asciify name
	name = name:lower():gsub("[^%w]+", "-"):gsub("%-+", "-"):gsub("^%-*(.-)%-*$", "%1");
	-- Lua doesn't do unicode, so if the workshop name is in cyrilic or something, it'll now be empty
	if (name:len() < 3) then
		-- Heck
		name = "workshop-" .. id;
	end

	return name .. "." .. rest:gsub("/", ".")
end


--
--    Stack Reverse Engineering
--
local function sentrifyStack(stack)
	-- Sentry likes stacks in the oposite order to lua
	stack = table.Reverse(stack);

	-- The first entry from LuaError is sometimes useless
	if (stack[#stack]["source"] == "=[C]" and stack[#stack]["name"] == "") then
		table.remove(stack);
	end
	-- If someone has called `error`, remove it from the stack trace
	if (stack[#stack]["source"] == "=[C]" and stack[#stack]["name"] == "error" ) then
		table.remove(stack);
	end

	local ret = {}
	for i, frame in ipairs(stack) do
		ret[i] = {
			filename = frame["source"]:sub(2),
			["function"] = frame["name"] or "<unknown>",
			module = modulify(frame["source"]),
			lineno = frame["currentline"],
		}
	end
	return { frames = ret };
end

local function getStack()
	local level = 3; -- 1 = this, 2 = CaptureException

	local stack = {};
	while true do
		local info = debug.getinfo(level, "Sln");
		if (not info) then
			break;
		end

		stack[level - 2] = info;

		level = level + 1;
	end

	return stack;
end

local function stripFileData(err, stack)
	local match, file, line = string.match(err, "^((.+):(%d+): ).+$");
	if (not match) then
		return err;
	end

	for _, frame in pairs(stack) do
		if (frame["source"] == "@" .. file and tostring(frame["currentline"]) == tostring(line)) then
			err = err:sub(#match + 1);
			break;
		end
	end

	return err;
end

local ADDON_BLAME_PATTERN = "^addons/([^/]+)/";
local GAMEMODE_BLAME_PATTERN = "^gamemodes/([^/]+)/";
local function calculateBlame(stack)
	for _, frame in pairs(stack) do
		if (frame["source"] ~= "=[C]") then
			local source = frame["source"]:sub(2);

			local wsname, wsid = luaerror.FindWorkshopAddonFileOwner(source);
			if (wsname) then
				return {
					{ "addon", "workshop-" .. wsid },
					{ "addon-name", wsname },
				}
			end

			local addon = string.match(source, ADDON_BLAME_PATTERN);
			if (addon) then
				return {
					{ "addon", addon },
				}
			end

			local gamemode = string.match(source, GAMEMODE_BLAME_PATTERN);
			if (gamemode) then
				return {
					{ "gamemode", gamemode },
				}
			end
		end
	end

	return {};
end


--
--    Transaction Management
--
local transactionStack = {}
function IsInTransaction()
	return #transactionStack > 0;
end

-- If the root transaction was started inside an x?pcall, skipNext can get out of sync
-- This is one of those things where This Should Never Happen, but gmod is what it is :(
local function txnSkipHack()
	if (not IsInTransaction()) then
		skipNext = nil;
	end
end

local function pushTransaction(data)
	txnSkipHack();

	local txn = {
		data = data,
		ctx = {},
		id = UUID4(),
	}

	transactionStack[#transactionStack + 1] = txn;

	return txn.id;
end

local function popTransaction(id)
	for i, txn in pairs(transactionStack) do
		if (txn.id == id) then
			-- Nuke everything above this tranasction in the stack
			while transactionStack[i] do
				table.remove(transactionStack, i);
			end

			txnSkipHack();

			return txn.data;
		end
	end

	error("Unknown Transaction '".. tostring(id) .. "'!");
end

local function getTransactionData()
	local res = {}

	for _, txn in ipairs(transactionStack) do
		table.Merge(res, txn.data);
		table.Merge(res, txn.ctx);
	end

	return res;
end

local function getCurrentTransaction()
	return transactionStack[#transactionStack];
end


--
--    Context Management
--
local function getUserContext(extra)
	local ply = extra["user"]
	if (not IsValid(ply)) then
		return nil;
	end

	return {
		id = ply:SteamID(),
		username = ply:Nick(),
		ip_address = ply:IPAddress(),
		steamid64 = ply:SteamID64(),
	}
end

local function getContexts(extra)
	return {
		os = {
			name = GetOSName(),
		},
		runtime = {
			name = "Garry's Mod",
			version = g["VERSIONSTR"],
		},
		app = {
			app_start_time = math.floor(os.time() - SysTime()),
		},
		user = getUserContext(extra),
	}
end

local function getTags(extra)
	local tags = {};

	for name, value in pairs(config.tags) do
		table.insert(tags, {name, value});
	end

	-- These _suppliment_ rather than replace sdk tags
	if (extra["tags"]) then
		for name, value in pairs(extra.tags) do
			table.insert(tags, {name, value});
		end
	end

	return tags
end


--
--    Payload
--
local function buildPayload(err, stacktrace, extra)
	local txn = getTransactionData();
	table.Merge(txn, extra)

	local tags = getTags(txn);
	table.Add(tags, calculateBlame(stacktrace));

	return {
		event_id = UUID4(),
		timestamp = ISODate(os.time()),
		logger = "sentry",
		platform = "other",
		sdk = SDK_VALUE,
		exception = {{
			type = "error",
			value = err,
			stacktrace = sentrifyStack(stacktrace),
		}},
		modules = DetectedModules,
		contexts = getContexts(txn),
		tags = tags,
		environment = config["environment"],
		release = config["release"],
		server_name = config["server_name"],
		level = txn["level"],
		extra = txn["extra"],
		culprit = txn["culprit"],
	};
end


--
--    Actual HTTP Integration
--
local SENTRY_HEADER_FORMAT = (
	"Sentry sentry_version=7, " ..
	"sentry_client=%s/%s, " ..
	"sentry_timestamp=%d, " ..
	"sentry_key=%s, " ..
	"sentry_secret=%s"
);
local function sentryAuthHeader(now)
	return SENTRY_HEADER_FORMAT:format(
		SDK_VALUE.name,
		SDK_VALUE.version,
		os.time(),
		config.publickey,
		config.privatekey
	)
end

local function SendToServer(payload)
	HTTP({
		url = config.endpoint,
		method = "POST",
		body = util.TableToJSON(payload),
		type = "application/json; charset=utf-8",
		headers = {
			["X-Sentry-Auth"] = sentryAuthHeader(),
		},
		success = function(code, body, headers)
			local result = util.JSONToTable(body) or {};

			if (detectRateLimiting(code, headers)) then
				return;
			elseif (code ~= 200) then
				local error = headers["X-Sentry-Error"] or result["error"];

				if (code >= 500) then
					WriteLog("Server is offline (%s), trying later", error or code);
					doBackoff(2);
					return
				elseif (code == 401) then
					WriteLog("Access denied - shutting down: %s", error or body);
					-- If sentry tells us to go away, go away properly
					config.endpoint = nil;
					return;
				else
					WriteLog("Got HTTP %d from the server: %s", code, error or body)
					return;
				end
			end

			-- Debugging
			print("Success! Event stored with ID " .. (result["id"] or "?"))
		end,
		failed = function(reason)
			-- This is effectively useless
			WriteLog("HTTP request failed: %s", reason);
		end,
	})
end


--
--    Reporting Functions
--
local function proccessException(err, stack, extra)
	if (not extra) then
		extra = {};
	end

	local payload = buildPayload(err, stack, extra);

	SendToServer(payload);

	return payload.event_id;
end

local function OnLuaError(is_runtime, rawErr, file, lineno, err, stack)
	if (not shouldReport(rawErr)) then
		return;
	end

	if (#stack == 0) then
		stack[1] = {
			name = is_runtime and "<unknown>" or "<compile>",
			source = '@' .. file,
			currentline = lineno,
		}
	end

	proccessException(err, stack);
end

function CaptureException(err, extra)
	if (not shouldReport(err)) then
		return nil;
	end

	local stack = getStack();

	err = stripFileData(err, stack);

	return proccessException(err, stack, extra);
end

local function xpcallCB(err)
	if (not shouldReport(err)) then
		return err;
	end

	local stack = getStack();

	local msg = stripFileData(err, stack);

	proccessException(msg, stack);

	-- Return the unmodified error
	return err;
end

function pcall(func, ...)
	local args = { ... };
	local extra = {};

	-- If the first argument is a table, it's configuring the exception handler
	if (type(func) == "table") then
		extra = func;
		func = table.remove(args, 1);
	end

	local id = pushTransaction(extra);
	local res = { xpcall(func, xpcallCB, unpack(args)) };
	popTransaction(id);

	return unpack(res);
end


--
-- Transaction Management
--
function SkipNext(msg)
	skipNext = msg;
end

DISABLE_TXN_PCALL = "no pcall only txn";
function ExecuteInTransactionSANE(name, txn, func, ...)
	if (name) then
		txn["culprit"] = name;
	end

	local id = pushTransaction(txn);
	local res;
	-- Danger zone!
	if (txn[DISABLE_TXN_PCALL]) then
		res = { true, func(...) };
	else
		res = { xpcall(func, xpcallCB, ...) };
	end
	popTransaction(id);

	local success = table.remove(res, 1);
	if (not success) then
		local err = res[1];
		SkipNext(err);
		-- Boom
		error(err, 0);
	end

	return unpack(res);
end

function ExecuteInTransaction(func, ...)
	-- vulgar hellcode
	local name;
	local txn = {};
	local args = { ... }

	if (type(func) == "string") then
		name = func;
		func = table.remove(args, 1);
	end

	if (type(func) == "table") then
		txn = func;
		func = table.remove(args, 1);
	end

	return ExecuteInTransactionSANE(name, txn, func, unpack(args));
end

function MergeContext(data)
	local txn = getCurrentTransaction();
	-- This might be suprising behaviour, but I don't have any better ideas
	if (not txn) then
		return;
	end

	table.Merge(txn.ctx, data);
end

function ClearContext()
	local txn = getCurrentTransaction();
	-- This might be suprising behaviour, but I don't have any better ideas
	if (not txn) then
		return;
	end

	txn.ctx = {};
end

function TagsContext(tags)
	MergeContext({ tags = tags });
end

function ExtraContext(exta)
	MergeContext({ extra = extra });
end

function UserContext(user)
	MergeContext({ user = user });
end


--
-- Initial Configuration
--
local DSN_FORMAT = "^(https?://)(%w+):(%w+)@([%w.:]+)/(%w+)$";
local function parseDSN(dsn)
	local scheme, publickey, privatekey, host, project = string.match(dsn, DSN_FORMAT);
	if (not (scheme and publickey and privatekey and host and project)) then
		error("Malformed DSN!")
	end
	config.privatekey = privatekey;
	config.publickey = publickey;
	config.projectID = project;
	config.endpoint = scheme .. host .. "/api/" .. project .. "/store/";
end

local settables = { "tags", "release", "environment", "server_name" }
function Setup(dsn, extra)
	parseDSN(dsn)

	if (extra) then
		for _, key in pairs(settables) do
			if (extra[key] ~= nil) then
				config[key] = extra[key];
			end
		end
	end

	if (not config["server_name"]) then
		config["server_name"] = GetHostName();
	end

	luaerror.EnableRuntimeDetour(true);
	luaerror.EnableCompiletimeDetour(true);

	hook.Add("LuaError", "Sentry Integration", OnLuaError);

	-- Once the server has initialised, get all the things with a "version" field
	hook.Add("Initialize", "Sentry Integration", detectModules)
	-- Just in case we're being called in the Initialize hook, also get them now.
	detectModules();
end
