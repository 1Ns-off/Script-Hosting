-- GhostEye v2

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local MAX_PACKET_LOG = 500
local MAX_HISTORY = 20
local DEDUP_WINDOW = 0.05
local STORAGE_FLUSH_EVERY = 12
local AUTO_SCAN_COOLDOWN = 0.38

local fullPacketLog = {}
local remoteProfiles = {}
local packetHashes = {}
local spyStats = {}
local spyConnections = {}
local scanHistory = {}
local previousIndex = {}
local remoteCache = {}
local panicConnections = {}
local panicLog = {}
local spyEventLog = {}
local autoScan = false
local minimized = false
local argSpyEnabled = false
local panicTriggered = false
local lastLogText = ""
local argSpyMessage = "Spy not available (missing executor hooks)."
local nextAutoScanAt = 0

local conAdded, conRemoving, conRotate, conPanicHotkey

-- NSA easter eggs (search: NSA_EASTER_EGG)
-- NSA_EASTER_EGG_1: The NSA was officially formed in 1952 by a classified memo from President Harry S. Truman.
-- NSA_EASTER_EGG_2: NSA headquarters is at Fort Meade, Maryland, between Washington, D.C., and Baltimore.
-- NSA_EASTER_EGG_3: The public National Cryptologic Museum near Fort Meade preserves real SIGINT and crypto history.
-- NSA_EASTER_EGG_4: NSA contributed to modern public cryptography standards, including the SHA-2 family.
-- NSA_EASTER_EGG_5: Rare fact: In the 1960s, NSA funded and operated one of the earliest large-scale machine translation efforts (Project MATCH), long before modern AI translation.

local CLASSIFICATION_RULES = {
	{patterns = {"damage", "dmg", "hit", "attack", "kill", "hurt"}, category = "COMBAT_DAMAGE"},
	{patterns = {"heal", "health", "cure", "recover"}, category = "COMBAT_HEAL"},
	{patterns = {"shoot", "fire", "bullet", "weapon", "gun"}, category = "COMBAT_WEAPON"},
	{patterns = {"teleport", "tp", "warp", "move", "goto"}, category = "MOVEMENT_TELEPORT"},
	{patterns = {"spawn", "respawn", "revive", "loadchar"}, category = "MOVEMENT_SPAWN"},
	{patterns = {"money", "cash", "coins", "buy", "shop", "purchase"}, category = "ECONOMY"},
	{patterns = {"data", "save", "load", "sync", "profile"}, category = "DATA_SYNC"},
	{patterns = {"inventory", "item", "equip", "backpack"}, category = "DATA_INVENTORY"},
	{patterns = {"chat", "message", "say", "whisper", "msg"}, category = "SOCIAL_CHAT"},
	{patterns = {"kick", "ban", "mute", "admin", "mod"}, category = "ADMIN_MODERATION"},
	{patterns = {"anticheat", "ac", "detect", "flag", "security"}, category = "ADMIN_ANTICHEAT"},
	{patterns = {"ping", "heartbeat", "keepalive", "pong"}, category = "SYSTEM_NETWORK"},
}

local STORAGE_ENABLED = typeof(writefile) == "function" and typeof(readfile) == "function"
local STORAGE_DIR = "ghosteye_logs"
local sessionDate = os.date("!%Y-%m-%d")
local storageDayLog = nil
local storageInsertsSinceFlush = 0

local function dayLogPath()
	return STORAGE_DIR .. "/" .. sessionDate .. ".json"
end

local function ensureDayLogLoaded()
	if storageDayLog ~= nil then
		return
	end
	storageDayLog = {}
	if not STORAGE_ENABLED then
		return
	end
	pcall(function()
		local raw = readfile(dayLogPath())
		local decoded = HttpService:JSONDecode(raw)
		if typeof(decoded) == "table" then
			storageDayLog = decoded
		end
	end)
end

local function flushStorageLog()
	if not STORAGE_ENABLED or storageDayLog == nil or storageInsertsSinceFlush == 0 then
		return
	end
	pcall(function()
		writefile(dayLogPath(), HttpService:JSONEncode(storageDayLog))
	end)
	storageInsertsSinceFlush = 0
end

local function initStorage()
	if not STORAGE_ENABLED then
		return
	end
	pcall(function()
		makefolder(STORAGE_DIR)
	end)

	local indexPath = STORAGE_DIR .. "/index.json"
	local indexData = {}
	pcall(function()
		indexData = HttpService:JSONDecode(readfile(indexPath))
	end)
	if typeof(indexData) ~= "table" then
		indexData = {}
	end

	indexData[tostring(os.time())] = {
		date = sessionDate,
		placeId = game.PlaceId,
		placeName = game.Name,
	}

	pcall(function()
		writefile(indexPath, HttpService:JSONEncode(indexData))
	end)

	ensureDayLogLoaded()

	pcall(function()
		game:BindToClose(function()
			flushStorageLog()
		end)
	end)
end

local function saveToStorage(packet)
	if not STORAGE_ENABLED then
		return
	end
	ensureDayLogLoaded()
	table.insert(storageDayLog, packet)
	storageInsertsSinceFlush += 1
	if storageInsertsSinceFlush >= STORAGE_FLUSH_EVERY then
		flushStorageLog()
	end
end

local GhostEye = {}

GhostEye.Spy = {
	connect = function(remote, callback)
		if remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent") then
			return remote.OnClientEvent:Connect(function(...)
				local args = { ... }
				local path = safeGetFullName(remote)
				if not isDuplicatePacket(path, "receive", args) then
					local packet = capturePacket(path, remote.Name, "receive", args)
					classifyRemote(path, remote.Name, args)
					saveToStorage(packet)
				end
				if callback then
					callback(args)
				end
			end)
		end
	end,
	getLogs = function() return fullPacketLog end,
	getProfiles = function() return remoteProfiles end,
	clearLogs = function() fullPacketLog = {} end,
}

GhostEye.Panic = {
	trigger = function(reason)
		triggerPanic(reason or "api call")
	end,
}

GhostEye.Storage = {
	init = initStorage,
	save = saveToStorage,
	flush = flushStorageLog,
	isEnabled = function()
		return STORAGE_ENABLED
	end,
}

_G.GhostEye = GhostEye

-- helpers
local function safeGetFullName(inst)
	local ok, result = pcall(function()
		return inst:GetFullName()
	end)
	return ok and result or ("<UnknownPath>/" .. inst.Name)
end

local function isRemote(inst)
	return inst:IsA("RemoteEvent")
		or inst:IsA("RemoteFunction")
		or inst.ClassName == "UnreliableRemoteEvent"
end

local function countClientConnections(inst)
	local total = 0
	pcall(function()
		if typeof(getconnections) ~= "function" then
			return
		end
		if inst:IsA("RemoteEvent") or inst:IsA("UnreliableRemoteEvent") then
			total = #getconnections(inst.OnClientEvent)
		elseif inst:IsA("RemoteFunction") then
			total = #getconnections(inst.OnClientInvoke)
		end
	end)
	return total
end

local function tryCopy(text)
	if typeof(setclipboard) == "function" then
		setclipboard(text)
		return true, "Copied (setclipboard)."
	end
	if typeof(toclipboard) == "function" then
		toclipboard(text)
		return true, "Copied (toclipboard)."
	end
	return false, "No clipboard API — select text and Ctrl+C."
end

local function capturePacket(remotePath, remoteName, direction, args)
	local packet = {
		ts = os.date("%H:%M:%S") .. "." .. string.format("%03d", math.floor((tick() % 1) * 1000)),
		path = remotePath,
		name = remoteName,
		direction = direction,
		argCount = #args,
		args = {},
	}
	
	for i, arg in ipairs(args) do
		local t = typeof(arg)
		if t == "Instance" then
			packet.args[i] = {type = "Instance", class = arg.ClassName, name = arg.Name}
		elseif t == "table" then
			local ok, encoded = pcall(function() return HttpService:JSONEncode(arg) end)
			packet.args[i] = {type = "table", value = ok and encoded or "[unserializable]"}
		else
			packet.args[i] = {type = t, value = tostring(arg):sub(1, 100)}
		end
	end
	
	table.insert(fullPacketLog, 1, packet)
	if #fullPacketLog > MAX_PACKET_LOG then
		table.remove(fullPacketLog, #fullPacketLog)
	end
	
	return packet
end

local function isDuplicatePacket(remotePath, direction, args)
	local hashKey = remotePath .. "|" .. direction
	for i = 1, math.min(#args, 5) do
		hashKey = hashKey .. "|" .. tostring(args[i]):sub(1, 30)
	end
	
	local now = tick()
	if packetHashes[hashKey] and (now - packetHashes[hashKey]) < DEDUP_WINDOW then
		return true
	end
	packetHashes[hashKey] = now
	
	if math.random() < 0.01 then
		for k, t in pairs(packetHashes) do
			if now - t > 1 then packetHashes[k] = nil end
		end
	end
	
	return false
end

-- remote name heuristics
local function classifyRemote(remotePath, remoteName, args)
	if not remoteProfiles[remotePath] then
		remoteProfiles[remotePath] = {
			name = remoteName,
			callCount = 0,
			argPatterns = {},
			inferredCategory = nil,
		}
	end
	
	local profile = remoteProfiles[remotePath]
	profile.callCount += 1
	
	for i, arg in ipairs(args) do
		if not profile.argPatterns[i] then
			profile.argPatterns[i] = {types = {}, samples = {}}
		end
		local t = typeof(arg)
		profile.argPatterns[i].types[t] = (profile.argPatterns[i].types[t] or 0) + 1
		if #profile.argPatterns[i].samples < 5 then
			table.insert(profile.argPatterns[i].samples, t == "Instance" and arg.Name or tostring(arg):sub(1, 30))
		end
	end
	
	local nameLower = string.lower(remoteName)
	for _, rule in ipairs(CLASSIFICATION_RULES) do
		for _, pattern in ipairs(rule.patterns) do
			if string.find(nameLower, pattern, 1, true) then
				profile.inferredCategory = rule.category
				break
			end
		end
		if profile.inferredCategory then break end
	end
	
	return profile
end

-- UI
local gui = Instance.new("ScreenGui")
gui.Name = "GHOSTEYE_UI"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.IgnoreGuiInset = true
gui.DisplayOrder = 999999
gui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Name = "Main"
frame.Size = UDim2.fromOffset(700, 430)
frame.Position = UDim2.new(0.5, -350, 0.5, -215)
frame.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
frame.BorderSizePixel = 0
frame.ZIndex = 10
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = frame

local top = Instance.new("Frame")
top.Size = UDim2.new(1, 0, 0, 42)
top.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
top.BorderSizePixel = 0
top.ZIndex = 11
top.Parent = frame

local topCorner = Instance.new("UICorner")
topCorner.CornerRadius = UDim.new(0, 8)
topCorner.Parent = top

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Size = UDim2.new(1, -10, 1, 0)
title.Position = UDim2.fromOffset(10, 0)
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(240, 240, 245)
title.Text = "GhostEye v2 | Packets: 0"
title.ZIndex = 12
title.Parent = top

local sideToggle = Instance.new("Frame")
sideToggle.Name = "SideToggle"
sideToggle.Size = UDim2.fromOffset(180, 210)
sideToggle.Position = UDim2.new(0, 10, 1, -235)
sideToggle.BackgroundTransparency = 1
sideToggle.ZIndex = 50
sideToggle.Parent = gui

local sideLogoBtn = Instance.new("ImageButton")
sideLogoBtn.Name = "LogoButton"
sideLogoBtn.Size = UDim2.fromOffset(160, 160)
sideLogoBtn.AnchorPoint = Vector2.new(0.5, 0)
sideLogoBtn.Position = UDim2.new(0.5, 0, 0, 40)
sideLogoBtn.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
sideLogoBtn.Image = "rbxassetid://7155344186"
sideLogoBtn.ScaleType = Enum.ScaleType.Fit
sideLogoBtn.AutoButtonColor = true
sideLogoBtn.BorderSizePixel = 0
sideLogoBtn.ZIndex = 51
sideLogoBtn.Parent = sideToggle
local sideLogoAspect = Instance.new("UIAspectRatioConstraint")
sideLogoAspect.AspectType = Enum.AspectType.FitWithinMaxSize
sideLogoAspect.AspectRatio = 1
sideLogoAspect.Parent = sideLogoBtn
local sideLogoCorner = Instance.new("UICorner")
sideLogoCorner.CornerRadius = UDim.new(1, 0)
sideLogoCorner.Parent = sideLogoBtn

local logoMessage = Instance.new("TextLabel")
logoMessage.Name = "LogoMessage"
logoMessage.AnchorPoint = Vector2.new(0, 0.5)
logoMessage.Position = UDim2.new(1, 10, 0.5, 0)
logoMessage.Size = UDim2.fromOffset(220, 36)
logoMessage.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
logoMessage.BackgroundTransparency = 0.12
logoMessage.BorderSizePixel = 0
logoMessage.TextColor3 = Color3.fromRGB(240, 240, 245)
logoMessage.Font = Enum.Font.GothamSemibold
logoMessage.TextSize = 13
logoMessage.Text = "The National Security Agency"
logoMessage.Visible = false
logoMessage.ZIndex = 55
logoMessage.Parent = sideToggle
local logoMessageCorner = Instance.new("UICorner")
logoMessageCorner.CornerRadius = UDim.new(0, 8)
logoMessageCorner.Parent = logoMessage

local panicBtn = Instance.new("TextButton")
panicBtn.Name = "Panic"
panicBtn.Size = UDim2.fromOffset(130, 34)
panicBtn.Position = UDim2.new(1, -142, 0, 12)
panicBtn.BackgroundColor3 = Color3.fromRGB(165, 40, 40)
panicBtn.TextColor3 = Color3.fromRGB(250, 250, 250)
panicBtn.Font = Enum.Font.GothamBold
panicBtn.TextSize = 13
panicBtn.Text = "⚠ PANIC"
panicBtn.AutoButtonColor = true
panicBtn.BorderSizePixel = 0
panicBtn.ZIndex = 80
panicBtn.Parent = gui
local panicBtnCorner = Instance.new("UICorner")
panicBtnCorner.CornerRadius = UDim.new(0, 8)
panicBtnCorner.Parent = panicBtn

local controls = Instance.new("Frame")
controls.Name = "Controls"
controls.BackgroundTransparency = 1
controls.Size = UDim2.new(1, -20, 0, 44)
controls.Position = UDim2.fromOffset(10, 48)
controls.Parent = frame

local function makeButton(name, text, x, w, color)
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = UDim2.fromOffset(w, 32)
	b.Position = UDim2.fromOffset(x, 6)
	b.BackgroundColor3 = color
	b.TextColor3 = Color3.fromRGB(245, 245, 245)
	b.Font = Enum.Font.GothamSemibold
	b.TextSize = 13
	b.Text = text
	b.AutoButtonColor = true
	b.BorderSizePixel = 0
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = b
	b.Parent = controls
	return b
end

local scanBtn = makeButton("Scan", "Scan", 0, 80, Color3.fromRGB(42, 102, 255))
local autoBtn = makeButton("Auto", "Auto: OFF", 88, 100, Color3.fromRGB(90, 90, 95))
local copyBtn = makeButton("Copy", "Copy log", 196, 110, Color3.fromRGB(20, 140, 85))
local clearBtn = makeButton("Clear", "Clear", 314, 85, Color3.fromRGB(130, 55, 55))

local filterBox = Instance.new("TextBox")
filterBox.Size = UDim2.new(1, -520, 0, 32)
filterBox.Position = UDim2.fromOffset(512, 6)
filterBox.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
filterBox.TextColor3 = Color3.fromRGB(235, 235, 235)
filterBox.PlaceholderColor3 = Color3.fromRGB(160, 160, 170)
filterBox.PlaceholderText = "Filter (name or path)"
filterBox.Text = ""
filterBox.Font = Enum.Font.Gotham
filterBox.TextSize = 13
filterBox.ClearTextOnFocus = false
filterBox.BorderSizePixel = 0
local fc = Instance.new("UICorner")
fc.CornerRadius = UDim.new(0, 6)
fc.Parent = filterBox
filterBox.Parent = controls

local status = Instance.new("TextLabel")
status.BackgroundTransparency = 1
status.Size = UDim2.new(1, -20, 0, 22)
status.Position = UDim2.fromOffset(10, 92)
status.Font = Enum.Font.Gotham
status.TextSize = 12
status.TextColor3 = Color3.fromRGB(180, 185, 200)
status.TextXAlignment = Enum.TextXAlignment.Left
status.Text = "Ready | disk log: " .. (STORAGE_ENABLED and "on" or "off")
status.Parent = frame

local listHolder = Instance.new("ScrollingFrame")
listHolder.Name = "List"
listHolder.Size = UDim2.new(1, -20, 1, -126)
listHolder.Position = UDim2.fromOffset(10, 116)
listHolder.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
listHolder.BorderSizePixel = 0
listHolder.ScrollBarThickness = 6
listHolder.CanvasSize = UDim2.fromOffset(0, 0)
listHolder.Parent = frame

local listCorner = Instance.new("UICorner")
listCorner.CornerRadius = UDim.new(0, 6)
listCorner.Parent = listHolder

local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 4)
layout.Parent = listHolder

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 6)
padding.PaddingLeft = UDim.new(0, 6)
padding.PaddingRight = UDim.new(0, 6)
padding.PaddingBottom = UDim.new(0, 6)
padding.Parent = listHolder

-- draggable chrome
local dragging = false
local dragStart, startPos

top.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = true
		dragStart = input.Position
		startPos = frame.Position
	end
end)

top.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = false
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
		local delta = input.Position - dragStart
		frame.Position = UDim2.new(
			startPos.X.Scale,
			startPos.X.Offset + delta.X,
			startPos.Y.Scale,
			startPos.Y.Offset + delta.Y
		)
	end
end)

-- scan + spy core
local function makeRow(text, color)
	local row = Instance.new("TextLabel")
	row.BackgroundColor3 = Color3.fromRGB(26, 26, 32)
	row.BorderSizePixel = 0
	row.TextColor3 = color or Color3.fromRGB(235, 235, 240)
	row.Font = Enum.Font.Code
	row.TextSize = 13
	row.TextXAlignment = Enum.TextXAlignment.Left
	row.TextTruncate = Enum.TextTruncate.AtEnd
	row.Size = UDim2.new(1, -4, 0, 24)
	row.Text = "  " .. text
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 5)
	c.Parent = row
	return row
end

local function clearRows()
	for _, child in ipairs(listHolder:GetChildren()) do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
end

local function isScannable(inst)
	if isRemote(inst) then
		return true
	end
	return inst:IsA("BindableEvent")
		or inst:IsA("BindableFunction")
		or inst:IsA("Script")
		or inst:IsA("LocalScript")
		or inst:IsA("ModuleScript")
end

local function buildRecord(inst)
	local path = safeGetFullName(inst)
	local stat = spyStats[path]
	local profile = remoteProfiles[path]
	local record = {
		class = inst.ClassName,
		name = inst.Name,
		path = path,
		parent = inst.Parent and inst.Parent.Name or "nil",
		connections = countClientConnections(inst),
		disabled = inst:IsA("BaseScript") and inst.Disabled or nil,
		runContext = inst:IsA("BaseScript") and tostring(inst.RunContext) or nil,
		spyCount = stat and stat.count or 0,
		lastArgs = stat and stat.lastArgs or "",
		lastAt = stat and stat.lastAt or "",
		category = profile and profile.inferredCategory or nil,
		callCount = profile and profile.callCount or 0,
	}
	record.key = ("%s|%s"):format(record.class, record.path)
	return record
end

local function serializeArgs(args)
	local normalized = table.create(#args)
	for i, value in ipairs(args) do
		local t = typeof(value)
		if t == "Instance" then
			normalized[i] = ("<Instance:%s>"):format(safeGetFullName(value))
		elseif t == "Vector3" or t == "CFrame" or t == "Color3" or t == "UDim2" then
			normalized[i] = tostring(value)
		else
			normalized[i] = value
		end
	end
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(normalized)
	end)
	if ok then
		return encoded
	end
	return "<args not JSON-safe>"
end

local function touchSpy(inst, args)
	local path = safeGetFullName(inst)
	local stat = spyStats[path]
	if not stat then
		stat = { count = 0, lastArgs = "", lastAt = "" }
		spyStats[path] = stat
	end
	stat.count += 1
	stat.lastArgs = serializeArgs(args)
	stat.lastAt = os.date("%H:%M:%S")
	table.insert(spyEventLog, 1, ("[%s] %s -> %s"):format(stat.lastAt, inst.ClassName, path))
	if #spyEventLog > 120 then
		table.remove(spyEventLog, #spyEventLog)
	end
end

local function enableArgSpy()
	if argSpyEnabled then
		return
	end
	argSpyEnabled = true

	for _, inst in ipairs(game:GetDescendants()) do
		if inst:IsA("RemoteEvent") or inst:IsA("UnreliableRemoteEvent") then
			pcall(function()
				if spyConnections[inst] then
					return
				end
				spyConnections[inst] = inst.OnClientEvent:Connect(function(...)
					local args = { ... }
					if not isDuplicatePacket(safeGetFullName(inst), "receive", args) then
						capturePacket(safeGetFullName(inst), inst.Name, "receive", args)
						classifyRemote(safeGetFullName(inst), inst.Name, args)
					end
					touchSpy(inst, args)
				end)
			end)
		end
	end

	local namecallInstalled = false
	local okNamecall = pcall(function()
		if typeof(hookmetamethod) ~= "function" or typeof(getnamecallmethod) ~= "function" then
			return
		end
		local oldNamecall
		local handler = function(self, ...)
			local method = getnamecallmethod()
			local args = { ... }
			if typeof(self) == "Instance" then
				if (method == "FireServer" and (self:IsA("RemoteEvent") or self:IsA("UnreliableRemoteEvent")))
					or (method == "InvokeServer" and self:IsA("RemoteFunction")) then
					if not isDuplicatePacket(safeGetFullName(self), "send", args) then
						capturePacket(safeGetFullName(self), self.Name, "send", args)
						classifyRemote(safeGetFullName(self), self.Name, args)
					end
					touchSpy(self, args)
				end
			end
			return oldNamecall(self, ...)
		end

		if typeof(newcclosure) == "function" then
			handler = newcclosure(handler)
		end
		oldNamecall = hookmetamethod(game, "__namecall", handler)
		namecallInstalled = true
		argSpyMessage = "Spy on (inbound + upstream)"
	end)

	if not okNamecall or not namecallInstalled then
		argSpyMessage = "Spy on (inbound only — no __namecall hook)"
	end
end

local function computeDiff(records)
	local newIndex = {}
	for _, rec in ipairs(records) do
		newIndex[rec.key] = rec
	end

	local added, removed, changed = 0, 0, 0
	for key, newRec in pairs(newIndex) do
		local oldRec = previousIndex[key]
		if not oldRec then
			added += 1
		else
			if oldRec.connections ~= newRec.connections
				or oldRec.disabled ~= newRec.disabled
				or oldRec.spyCount ~= newRec.spyCount then
				changed += 1
			end
		end
	end
	for key, _ in pairs(previousIndex) do
		if not newIndex[key] then
			removed += 1
		end
	end

	previousIndex = newIndex
	return {
		added = added,
		removed = removed,
		changed = changed,
	}
end

local function pushHistory(total, diff, reason)
	local item = {
		ts = os.date("%H:%M:%S"),
		total = total,
		added = diff.added,
		removed = diff.removed,
		changed = diff.changed,
		reason = reason or "manual",
	}
	table.insert(scanHistory, 1, item)
	if #scanHistory > MAX_HISTORY then
		table.remove(scanHistory, #scanHistory)
	end
end

local function trimProfilesForExport(maxPaths)
	maxPaths = maxPaths or 72
	local out = {}
	local n = 0
	for path, prof in pairs(remoteProfiles) do
		n += 1
		if n > maxPaths then
			break
		end
		out[path] = {
			name = prof.name,
			callCount = prof.callCount,
			inferredCategory = prof.inferredCategory,
		}
	end
	return out
end

local function generateLog(records, diff)
	local payload = {
		timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		placeId = game.PlaceId,
		jobId = game.JobId,
		total = #records,
		diff = diff,
		history = scanHistory,
		artifacts = records,
		packetLog = #fullPacketLog,
		profiles = trimProfilesForExport(96),
	}
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if ok then
		return encoded
	end

	local lines = {}
	table.insert(lines, ("GhostEye v2 - %s"):format(payload.timestamp))
	table.insert(lines, ("PlaceId=%s JobId=%s Total=%d Packets=%d"):format(payload.placeId, payload.jobId, payload.total, #fullPacketLog))
	table.insert(lines, ("Diff: +%d -%d ~%d"):format(diff.added, diff.removed, diff.changed))
	table.insert(lines, "Recent history:")
	for i = 1, math.min(5, #scanHistory) do
		local h = scanHistory[i]
		table.insert(lines, ("  [%s] total=%d +%d -%d ~%d (%s)"):format(h.ts, h.total, h.added, h.removed, h.changed, h.reason))
	end
	for i, r in ipairs(records) do
		table.insert(lines, ("%d) [%s] %s | conn=%d | spy=%d | %s"):format(i, r.class, r.name, r.connections, r.spyCount, r.path))
	end
	return table.concat(lines, "\n")
end

local function runScan(reason)
	local t0 = os.clock()
	clearRows()
	enableArgSpy()
	remoteCache = {}

	local filter = string.lower(filterBox.Text or "")
	local records = {}

	for _, inst in ipairs(game:GetDescendants()) do
		if isScannable(inst) then
			local rec = buildRecord(inst)
			local searchable = string.lower(rec.name .. " " .. rec.path .. " " .. rec.class)
			if filter == "" or string.find(searchable, filter, 1, true) then
				table.insert(records, rec)
			end
			remoteCache[inst] = rec
		end
	end

	table.sort(records, function(a, b)
		if a.class == b.class then
			return a.path < b.path
		end
		return a.class < b.class
	end)

	local header = makeRow(
		("Found: %d | PlaceId: %s | Packets: %d"):format(#records, tostring(game.PlaceId), #fullPacketLog),
		Color3.fromRGB(255, 223, 120)
	)
	header.Size = UDim2.new(1, -4, 0, 28)
	header.Parent = listHolder

	local diff = computeDiff(records)
	pushHistory(#records, diff, reason)

	local diffRow = makeRow(
		("Diff: +%d  -%d  ~%d | %s"):format(diff.added, diff.removed, diff.changed, argSpyMessage),
		Color3.fromRGB(150, 220, 255)
	)
	diffRow.Parent = listHolder

	if #scanHistory > 0 then
		local histTitle = makeRow("History (last 3 scans):", Color3.fromRGB(190, 190, 210))
		histTitle.Parent = listHolder
		for i = 1, math.min(3, #scanHistory) do
			local h = scanHistory[i]
			local hrow = makeRow(("  [%s] total=%d +%d -%d ~%d (%s)"):format(h.ts, h.total, h.added, h.removed, h.changed, h.reason))
			hrow.Parent = listHolder
		end
	end

	for i, rec in ipairs(records) do
		local scriptInfo = ""
		if rec.disabled ~= nil then
			scriptInfo = (" | disabled=%s"):format(tostring(rec.disabled))
		end
		local catInfo = rec.category and (" [%s]"):format(rec.category) or ""
		local argInfo = rec.spyCount > 0 and (" | spy=%d @%s"):format(rec.spyCount, rec.lastAt) or ""
		local txt = ("%03d | [%s] %s%s | conn=%d%s%s | %s"):format(i, rec.class, rec.name, catInfo, rec.connections, argInfo, scriptInfo, rec.path)
		local color = rec.category and string.find(rec.category, "ADMIN") and Color3.fromRGB(255, 140, 60) or nil
		local row = makeRow(txt, color)
		row.Parent = listHolder
	end

	listHolder.CanvasSize = UDim2.fromOffset(0, layout.AbsoluteContentSize.Y + 12)
	lastLogText = generateLog(records, diff)

	local dt = (os.clock() - t0) * 1000
	status.Text = ("Scan %.1f ms | total=%d | packets=%d | diff +%d -%d ~%d"):format(dt, #records, #fullPacketLog, diff.added, diff.removed, diff.changed)
	title.Text = ("GhostEye v2 | Packets: %d"):format(#fullPacketLog)
end

local function attachAutoScan()
	if conAdded then conAdded:Disconnect() end
	if conRemoving then conRemoving:Disconnect() end

	conAdded = game.DescendantAdded:Connect(function(inst)
		if inst:IsA("RemoteEvent") or inst:IsA("UnreliableRemoteEvent") then
			pcall(function()
				if not spyConnections[inst] then
					spyConnections[inst] = inst.OnClientEvent:Connect(function(...)
						local args = { ... }
						if not isDuplicatePacket(safeGetFullName(inst), "receive", args) then
							capturePacket(safeGetFullName(inst), inst.Name, "receive", args)
							classifyRemote(safeGetFullName(inst), inst.Name, args)
						end
						touchSpy(inst, args)
					end)
				end
			end)
		end
		if autoScan and isScannable(inst) then
			status.Text = ("Added: [%s] %s"):format(inst.ClassName, safeGetFullName(inst))
			local now = tick()
			if now >= nextAutoScanAt then
				nextAutoScanAt = now + AUTO_SCAN_COOLDOWN
				task.defer(function()
					runScan("auto:add")
				end)
			end
		end
	end)

	conRemoving = game.DescendantRemoving:Connect(function(inst)
		if spyConnections[inst] then
			spyConnections[inst]:Disconnect()
			spyConnections[inst] = nil
		end
		if autoScan and remoteCache[inst] then
			status.Text = ("Removed: %s"):format(inst.Name)
			local now = tick()
			if now >= nextAutoScanAt then
				nextAutoScanAt = now + AUTO_SCAN_COOLDOWN
				task.defer(function()
					runScan("auto:remove")
				end)
			end
		end
	end)
end

attachAutoScan()

local function showLogoMessage(duration)
	logoMessage.Visible = true
	task.delay(duration or 2.2, function()
		if logoMessage and logoMessage.Parent then
			logoMessage.Visible = false
		end
	end)
end

conRotate = RunService.RenderStepped:Connect(function(dt)
	sideLogoBtn.Rotation = (sideLogoBtn.Rotation + (dt * 36)) % 360
end)

local function triggerPanic(reason)
	if panicTriggered then
		return
	end
	panicTriggered = true

	local panicReason = reason or "unknown"
	table.insert(panicLog, 1, ("[%s] %s"):format(os.date("%H:%M:%S"), panicReason))
	pcall(function()
		warn(("[GHOSTEYE PANIC] %s"):format(panicReason))
	end)

	pcall(function()
		if gui and gui.Parent then
			gui:Destroy()
		end
	end)

	task.spawn(function()
		local teleported = false
		pcall(function()
			TeleportService:Teleport(game.PlaceId, player)
			teleported = true
		end)
		if not teleported then
			pcall(function()
				player:Kick(("GhostEye panic (%s)"):format(panicReason))
			end)
		end
	end)
end

local function bindPanicMonitors()
	table.insert(panicConnections, player.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			triggerPanic("player ancestry removed")
		end
	end))

	table.insert(panicConnections, script.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			triggerPanic("script ancestry removed")
		end
	end))

end

-- input wiring

scanBtn.MouseButton1Click:Connect(function()
	runScan("manual")
end)

autoBtn.MouseButton1Click:Connect(function()
	autoScan = not autoScan
	autoBtn.Text = autoScan and "Auto: ON" or "Auto: OFF"
	autoBtn.BackgroundColor3 = autoScan and Color3.fromRGB(38, 132, 73) or Color3.fromRGB(90, 90, 95)
	status.Text = autoScan and "Auto-scan on." or "Auto-scan off."
end)

copyBtn.MouseButton1Click:Connect(function()
	if lastLogText == "" then
		status.Text = "Nothing to copy yet — run a scan first."
		return
	end
	local ok, msg = tryCopy(lastLogText)
	status.Text = msg
	if not ok then
		local popup = Instance.new("Frame")
		popup.Size = UDim2.fromOffset(620, 280)
		popup.Position = UDim2.new(0.5, -310, 0.5, -140)
		popup.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
		popup.BorderSizePixel = 0
		popup.Parent = gui
		Instance.new("UICorner", popup).CornerRadius = UDim.new(0, 8)

		local tb = Instance.new("TextBox")
		tb.MultiLine = true
		tb.ClearTextOnFocus = false
		tb.TextEditable = true
		tb.TextWrapped = false
		tb.TextXAlignment = Enum.TextXAlignment.Left
		tb.TextYAlignment = Enum.TextYAlignment.Top
		tb.Font = Enum.Font.Code
		tb.TextSize = 12
		tb.TextColor3 = Color3.fromRGB(235, 235, 240)
		tb.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
		tb.BorderSizePixel = 0
		tb.Size = UDim2.new(1, -20, 1, -56)
		tb.Position = UDim2.fromOffset(10, 10)
		tb.Text = lastLogText
		tb.Parent = popup
		Instance.new("UICorner", tb).CornerRadius = UDim.new(0, 6)

		local close = Instance.new("TextButton")
		close.Size = UDim2.fromOffset(110, 30)
		close.Position = UDim2.new(1, -120, 1, -40)
		close.BackgroundColor3 = Color3.fromRGB(140, 60, 60)
		close.Text = "Close"
		close.Font = Enum.Font.GothamSemibold
		close.TextSize = 13
		close.TextColor3 = Color3.fromRGB(245, 245, 245)
		close.BorderSizePixel = 0
		close.Parent = popup
		Instance.new("UICorner", close).CornerRadius = UDim.new(0, 6)

		close.MouseButton1Click:Connect(function()
			popup:Destroy()
		end)

		tb:CaptureFocus()
		tb.SelectionStart = 1
		tb.CursorPosition = #tb.Text + 1
	end
end)

clearBtn.MouseButton1Click:Connect(function()
	clearRows()
	lastLogText = ""
	fullPacketLog = {}
	remoteProfiles = {}
	packetHashes = {}
	spyStats = {}
	spyEventLog = {}
	scanHistory = {}
	previousIndex = {}
	status.Text = "Cleared in-memory stats and packet list."
	listHolder.CanvasSize = UDim2.fromOffset(0, 0)
end)

panicBtn.MouseButton1Click:Connect(function()
	triggerPanic("manual panic button")
end)

local function toggleMinimize()
	minimized = not minimized
	frame.Visible = not minimized
end

sideLogoBtn.MouseButton1Click:Connect(function()
	toggleMinimize()
end)

conPanicHotkey = UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	local shiftDown = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	if shiftDown and input.KeyCode == Enum.KeyCode.End then
		triggerPanic("hotkey shift+end")
	end
end)

filterBox.FocusLost:Connect(function(enterPressed)
	if enterPressed then
		runScan("manual:filter")
	end
end)

-- boot
initStorage()
task.defer(runScan)
task.delay(5, function()
	showLogoMessage(2.5)
end)
task.delay(10, function()
	showLogoMessage(2.5)
end)
bindPanicMonitors()

-- teardown
gui.AncestryChanged:Connect(function(_, parent)
	if not parent then
		flushStorageLog()
		if conAdded then conAdded:Disconnect() end
		if conRemoving then conRemoving:Disconnect() end
		if conRotate then conRotate:Disconnect() end
		if conPanicHotkey then conPanicHotkey:Disconnect() end
		for _, con in ipairs(panicConnections) do
			con:Disconnect()
		end
		for inst, con in pairs(spyConnections) do
			con:Disconnect()
			spyConnections[inst] = nil
		end
	end
end)
