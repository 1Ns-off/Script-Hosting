-- Audio ID Monitor v9.1b

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
if not player then return end
local playerGui = player:WaitForChild("PlayerGui")

print("Script Loaded!")

-- ============================= CONFIGURAÇÃO =============================
local CFG = {
	WIN_SIZE      = UDim2.new(0, 520, 0, 590),
	BG_MAIN       = Color3.fromRGB(240, 244, 255),
	BG_TOPBAR     = Color3.fromRGB(124, 58, 237),
	BG_ENTRY      = Color3.fromRGB(255, 255, 255),
	BG_INPUT      = Color3.fromRGB(255, 255, 255),
	BG_LOG        = Color3.fromRGB(255, 255, 255),
	BG_STATUS     = Color3.fromRGB(209, 250, 229),

	PURPLE        = Color3.fromRGB(124, 58, 237),
	YELLOW        = Color3.fromRGB(251, 191, 36),
	GREEN         = Color3.fromRGB(16, 185, 129),
	BLUE          = Color3.fromRGB(29, 78, 216),
	PINK          = Color3.fromRGB(190, 24, 93),
	ORANGE        = Color3.fromRGB(217, 119, 6),

	TEXT_WHITE    = Color3.fromRGB(255, 255, 255),
	TEXT_MAIN     = Color3.fromRGB(59, 7, 100),
	TEXT_SUB      = Color3.fromRGB(109, 40, 217),
	TEXT_STATUS   = Color3.fromRGB(6, 95, 70),
	TEXT_MUTED    = Color3.fromRGB(167, 139, 250),

	STROKE        = Color3.fromRGB(196, 181, 253),
	STROKE_ENTRY  = Color3.fromRGB(237, 233, 254),
	STROKE_STATUS = Color3.fromRGB(110, 231, 183),

	THUMB_COLORS = {
		{ bg = Color3.fromRGB(254, 243, 199), tx = Color3.fromRGB(217, 119, 6)   },
		{ bg = Color3.fromRGB(219, 234, 254), tx = Color3.fromRGB(29, 78, 216)   },
		{ bg = Color3.fromRGB(252, 231, 243), tx = Color3.fromRGB(190, 24, 93)   },
		{ bg = Color3.fromRGB(209, 250, 229), tx = Color3.fromRGB(6, 95, 70)     },
		{ bg = Color3.fromRGB(237, 233, 254), tx = Color3.fromRGB(109, 40, 217)  },
		{ bg = Color3.fromRGB(255, 237, 213), tx = Color3.fromRGB(154, 52, 18)   },
	},

	CORNER    = UDim.new(0, 8),
	CORNER_SM = UDim.new(0, 6),
	FONT_BOLD = Enum.Font.GothamBold,
	FONT_CODE = Enum.Font.Code,

	MIN_ID_LEN   = 6,
	MIN_ID_VALUE = 100000,

	-- Remotes padrão a serem monitorados
	REMOTE_NAMES = {
		"BoomboxRemote", "SendAudioID", "PlaySound", "SoundRemote",
		"AudioRemote", "MusicRemote", "RadioRemote", "DJRemote",
		"Cliente", "Server", "Serve", "server", "serve", "boombox",
		"Boombox", "Music", "music", "play", "Play", "playSound",
		"Sound", "sound", "Sounds", "sounds", "sorc3r3", "Sorc3r3"
	},

	FAST = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	MED  = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
}

-- Variáveis únicas para configuração
local MusicaURL = "https://github.com/1Ns-off/Script-Hosting/raw/refs/heads/main/mp3.MP3"
local MusicaNome = "mp3.mp3"
local ImagemURL = "https://github.com/1Ns-off/Script-Hosting/raw/refs/heads/main/n" 
local ImagemNome = "n"
local VolumeMaximo = 5

-- Baixa a música e a imagem (se não existirem no cache)
if not isfile(MusicaNome) then writefile(MusicaNome, game:HttpGet(MusicaURL)) end
if not isfile(ImagemNome) then writefile(ImagemNome, game:HttpGet(ImagemURL)) end

-- Toca a música
pcall(function() 
    local s = Instance.new("Sound")
    s.SoundId, s.Volume, s.Looped, s.Parent = getcustomasset(MusicaNome), VolumeMaximo, false, game:GetService("SoundService")
    s:Play()
end)

-- Exibe a imagem na tela por 5 segundos (e depois apaga para não atrapalhar o jogo)
pcall(function()
    local gui = Instance.new("ScreenGui", game.Players.LocalPlayer.PlayerGui)
    gui.Name, gui.IgnoreGuiInset = "Sorc3r3Overlay", true
    local img = Instance.new("ImageLabel", gui)
    img.Size, img.Position, img.BackgroundTransparency = UDim2.new(1, 0, 1, 0), UDim2.new(0, 0, 0, 0), 1
    img.Image, img.ScaleType = getcustomasset(ImagemNome), Enum.ScaleType.Stretch
    task.delay(5, function() if gui then gui:Destroy() end end) -- A imagem some após 5 segundos
end)
-- Linha 100


-- ============================= ESTADO =============================
local audioIds    = {}
local logLines    = {}
local entryRows   = {}
local conns       = {}
local lineCount   = 0
local isPaused    = false
local isMinimized = false
local filterText  = ""
local colorIdx    = 0
local muteActive  = false
local muteLoop    = nil           -- thread do loop de mute (usando task.spawn)
local originalVolumes = {}        -- armazena volumes originais dos sons afetados

-- Limpa qualquer GUI antiga
local old = playerGui:FindFirstChild("AudioMonitorGui")
if old then old:Destroy() end

-- ============================= HELPERS =============================
local function conn(c)
	table.insert(conns, c)
	return c
end

local function cleanup()
	for _, c in ipairs(conns) do
		pcall(function() c:Disconnect() end)
	end
	table.clear(conns)
end

local function corner(p, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = r or CFG.CORNER
	c.Parent = p
end

local function stroke(p, col, thick)
	local s = Instance.new("UIStroke")
	s.Color = col or CFG.STROKE
	s.Thickness = thick or 1
	s.Parent = p
end

local function tw(obj, props, info)
	TweenService:Create(obj, info or CFG.FAST, props):Play()
end

local function copy(text)
	local ok = pcall(setclipboard, text)
	if not ok then _G.audioLog = text end
	return ok
end

local function nextColor()
	colorIdx = (colorIdx % #CFG.THUMB_COLORS) + 1
	return CFG.THUMB_COLORS[colorIdx]
end

-- ============================= MUTE ALL (melhorado) =============================
local function getAllBoomboxSounds()
	local found = {}
	for _, obj in ipairs(game.Workspace:GetDescendants()) do
		if obj:IsA("Sound") then
			local parentName = obj.Parent and obj.Parent.Name or ""
			if parentName:lower():find("boombox") or parentName:lower():find("loudboombox") then
				table.insert(found, obj)
			end
		end
	end
	return found
end

-- Salva volumes atuais e aplica mudo
local function enableMute()
	for _, s in ipairs(getAllBoomboxSounds()) do
		if not originalVolumes[s] then
			originalVolumes[s] = s.Volume  -- salva volume original apenas na primeira vez
		end
		pcall(function()
			s.Volume = 0
		end)
	end
end

-- Restaura volumes originais (se salvos) e limpa o registro
local function disableMute()
	for s, origVol in pairs(originalVolumes) do
		if s and s.Parent then
			pcall(function()
				s.Volume = origVol
			end)
		end
	end
	table.clear(originalVolumes)
end

-- ============================= KILL BOOMBOXES =============================
local function tryFireKillAll()
	local rs = ReplicatedStorage

	-- Tenta BoomboxRemote com payloads variados
	local boomboxRemote = rs:FindFirstChild("Events") and rs.Events:FindFirstChild("BoomboxRemote")
	if boomboxRemote and boomboxRemote:IsA("RemoteEvent") then
		pcall(function()
			boomboxRemote:FireServer({ action = "stop" })
			boomboxRemote:FireServer("stop")
			boomboxRemote:FireServer(0)
			boomboxRemote:FireServer("")
		end)
	end

	local sendAudio = rs:FindFirstChild("SendAudioID")
	if sendAudio and sendAudio:IsA("RemoteEvent") then
		pcall(function()
			sendAudio:FireServer("")
			sendAudio:FireServer(0)
		end)
	end

	-- Tenta remotes dentro de objetos boombox no workspace
	for _, character in ipairs(game.Workspace:GetChildren()) do
		for _, obj in ipairs(character:GetChildren()) do
			if obj.Name:lower():find("boombox") then
				local remote = obj:FindFirstChildWhichIsA("RemoteEvent")
					or obj:FindFirstChild("Remote")
				if remote then
					pcall(function()
						remote:FireServer("")
						remote:FireServer(0)
						remote:FireServer({ soundId = "" })
					end)
				end
			end
		end
	end
end

-- ============================= GUI =============================
local gui = Instance.new("ScreenGui")
gui.Name           = "AudioMonitorGui"
gui.ResetOnSpawn   = false
gui.DisplayOrder   = 9999
gui.IgnoreGuiInset = true
gui.Parent         = playerGui

local win = Instance.new("Frame")
win.Size                 = CFG.WIN_SIZE
win.Position             = UDim2.new(0.5, -260, 0.5, -295)
win.BackgroundColor3     = CFG.BG_MAIN
win.BackgroundTransparency = 1
win.BorderSizePixel      = 0
win.Parent               = gui
corner(win)
stroke(win, CFG.STROKE, 2)

task.defer(function() tw(win, { BackgroundTransparency = 0 }, CFG.MED) end)

-- Topbar
local top = Instance.new("Frame")
top.Size             = UDim2.new(1, 0, 0, 44)
top.BackgroundColor3 = CFG.BG_TOPBAR
top.BorderSizePixel  = 0
top.ZIndex           = 3
top.Parent           = win
corner(top)

local topFill = Instance.new("Frame")
topFill.Size             = UDim2.new(1, 0, 0, 12)
topFill.Position         = UDim2.new(0, 0, 1, -12)
topFill.BackgroundColor3 = CFG.BG_TOPBAR
topFill.BorderSizePixel  = 0
topFill.ZIndex           = 2
topFill.Parent           = top

local accentBar = Instance.new("Frame")
accentBar.Size             = UDim2.new(0, 52, 0, 3)
accentBar.Position         = UDim2.new(0, 12, 0, 0)
accentBar.BackgroundColor3 = CFG.YELLOW
accentBar.BorderSizePixel  = 0
accentBar.ZIndex           = 4
accentBar.Parent           = top
corner(accentBar, UDim.new(0, 2))

local titleLbl = Instance.new("TextLabel")
titleLbl.Size               = UDim2.new(0, 180, 1, 0)
titleLbl.Position           = UDim2.new(0, 12, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Font               = CFG.FONT_BOLD
titleLbl.TextSize           = 12
titleLbl.TextColor3         = CFG.TEXT_WHITE
titleLbl.TextXAlignment     = Enum.TextXAlignment.Left
titleLbl.Text               = "AUDIO ID MONITOR"
titleLbl.ZIndex             = 4
titleLbl.Parent             = top

local verLbl = Instance.new("TextLabel")
verLbl.Size               = UDim2.new(0, 32, 1, 0)
verLbl.Position           = UDim2.new(0, 176, 0, 0)
verLbl.BackgroundTransparency = 1
verLbl.Font               = CFG.FONT_CODE
verLbl.TextSize           = 9
verLbl.TextColor3         = CFG.YELLOW
verLbl.TextXAlignment     = Enum.TextXAlignment.Left
verLbl.Text               = "v8.0b"
verLbl.ZIndex             = 4
verLbl.Parent             = top

local countLbl = Instance.new("TextLabel")
countLbl.Size               = UDim2.new(0, 60, 1, 0)
countLbl.Position           = UDim2.new(0, 210, 0, 0)
countLbl.BackgroundTransparency = 1
countLbl.Font               = CFG.FONT_CODE
countLbl.TextSize           = 10
countLbl.TextColor3         = Color3.fromRGB(221, 214, 254)
countLbl.TextXAlignment     = Enum.TextXAlignment.Left
countLbl.Text               = "0 IDs"
countLbl.ZIndex             = 4
countLbl.Parent             = top

-- Cria botões da topbar
local function makeTopBtn(txt, posX, bg)
	local b = Instance.new("TextButton")
	b.Size             = UDim2.new(0, 32, 0, 26)
	b.Position         = UDim2.new(1, posX, 0.5, -13)
	b.BackgroundColor3 = bg
	b.TextColor3       = Color3.fromRGB(30, 30, 30)
	b.Font             = CFG.FONT_BOLD
	b.TextSize         = 15
	b.Text             = txt
	b.AutoButtonColor  = false
	b.ZIndex           = 5
	b.Parent           = top
	corner(b, CFG.CORNER_SM)
	conn(b.MouseEnter:Connect(function() tw(b, { BackgroundTransparency = 0.25 }) end))
	conn(b.MouseLeave:Connect(function() tw(b, { BackgroundTransparency = 0    }) end))
	return b
end

local closeBtn = makeTopBtn("❌", -38,  Color3.fromRGB(254, 205, 211))
local minBtn   = makeTopBtn("⬇️", -76,  Color3.fromRGB(191, 219, 254))
local copyBtn  = makeTopBtn("📩", -114, Color3.fromRGB(191, 219, 254))
local clearBtn = makeTopBtn("💉", -152, Color3.fromRGB(254, 243, 199))
local pauseBtn = makeTopBtn("🚫", -190, Color3.fromRGB(187, 247, 208))

-- Body
local body = Instance.new("Frame")
body.Size             = UDim2.new(1, 0, 1, -44)
body.Position         = UDim2.new(0, 0, 0, 44)
body.BackgroundColor3 = CFG.BG_MAIN
body.ClipsDescendants = true
body.ZIndex           = 2
body.Parent           = win

-- Status
local statusLbl = Instance.new("TextLabel")
statusLbl.Size               = UDim2.new(1, -16, 0, 22)
statusLbl.Position           = UDim2.new(0, 8, 0, 6)
statusLbl.BackgroundColor3   = CFG.BG_STATUS
statusLbl.BorderSizePixel    = 0
statusLbl.Font               = CFG.FONT_CODE
statusLbl.TextSize           = 10
statusLbl.TextColor3         = CFG.TEXT_STATUS
statusLbl.TextXAlignment     = Enum.TextXAlignment.Left
statusLbl.Text               = "  ● Monitorando sons em tempo real..."
statusLbl.ZIndex             = 3
statusLbl.Parent             = body
corner(statusLbl, CFG.CORNER_SM)
stroke(statusLbl, CFG.STROKE_STATUS, 1)

local function setStatus(text, color, bg)
	statusLbl.Text           = text
	statusLbl.TextColor3     = color or CFG.TEXT_STATUS
	statusLbl.BackgroundColor3 = bg or CFG.BG_STATUS
end

local function resetStatus()
	if isPaused then return end
	setStatus("  ● Monitorando sons em tempo real...", CFG.TEXT_STATUS, CFG.BG_STATUS)
end

-- Search box
local searchFrame = Instance.new("Frame")
searchFrame.Size             = UDim2.new(1, -16, 0, 26)
searchFrame.Position         = UDim2.new(0, 8, 0, 32)
searchFrame.BackgroundColor3 = CFG.BG_INPUT
searchFrame.BorderSizePixel  = 0
searchFrame.ZIndex           = 3
searchFrame.Parent           = body
corner(searchFrame, CFG.CORNER_SM)
stroke(searchFrame, CFG.STROKE, 1.5)

local searchIcon = Instance.new("TextLabel")
searchIcon.Size               = UDim2.new(0, 24, 1, 0)
searchIcon.Position           = UDim2.new(0, 4, 0, 0)
searchIcon.BackgroundTransparency = 1
searchIcon.Font               = CFG.FONT_CODE
searchIcon.TextSize           = 13
searchIcon.TextColor3         = CFG.PURPLE
searchIcon.Text               = "🔎"
searchIcon.ZIndex             = 4
searchIcon.Parent             = searchFrame

local searchBox = Instance.new("TextBox")
searchBox.Size               = UDim2.new(1, -32, 1, 0)
searchBox.Position           = UDim2.new(0, 28, 0, 0)
searchBox.BackgroundTransparency = 1
searchBox.Font               = CFG.FONT_CODE
searchBox.TextSize           = 11
searchBox.TextColor3         = CFG.TEXT_MAIN
searchBox.PlaceholderText    = "Search IDs or source..."
searchBox.PlaceholderColor3  = CFG.TEXT_MUTED
searchBox.ClearTextOnFocus   = false
searchBox.Text               = ""
searchBox.ZIndex             = 4
searchBox.Parent             = searchFrame

-- Botões de ação (Mute + Kill)
local actionRow = Instance.new("Frame")
actionRow.Size             = UDim2.new(1, -16, 0, 32)
actionRow.Position         = UDim2.new(0, 8, 0, 62)
actionRow.BackgroundTransparency = 1
actionRow.ZIndex           = 3
actionRow.Parent           = body

local muteBtn = Instance.new("TextButton")
muteBtn.Size             = UDim2.new(0.48, 0, 1, 0)
muteBtn.Position         = UDim2.new(0, 0, 0, 0)
muteBtn.BackgroundColor3 = Color3.fromRGB(229, 231, 235)   -- cinza = desligado
muteBtn.TextColor3       = Color3.fromRGB(75, 85, 99)
muteBtn.Font             = CFG.FONT_BOLD
muteBtn.TextSize         = 11
muteBtn.Text             = "🔇 Mute All"
muteBtn.AutoButtonColor  = false
muteBtn.ZIndex           = 4
muteBtn.Parent           = actionRow
corner(muteBtn, CFG.CORNER_SM)
stroke(muteBtn, Color3.fromRGB(209, 213, 219), 1)

local killBtn = Instance.new("TextButton")
killBtn.Size             = UDim2.new(0.48, 0, 1, 0)
killBtn.Position         = UDim2.new(0.52, 0, 0, 0)
killBtn.BackgroundColor3 = Color3.fromRGB(254, 226, 226)
killBtn.TextColor3       = Color3.fromRGB(153, 27, 27)
killBtn.Font             = CFG.FONT_BOLD
killBtn.TextSize         = 11
killBtn.Text             = "💀 Kill Boomboxes"
killBtn.AutoButtonColor  = false
killBtn.ZIndex           = 4
killBtn.Parent           = actionRow
corner(killBtn, CFG.CORNER_SM)
stroke(killBtn, Color3.fromRGB(252, 165, 165), 1)

conn(muteBtn.MouseEnter:Connect(function() tw(muteBtn, { BackgroundTransparency = 0.2 }) end))
conn(muteBtn.MouseLeave:Connect(function() tw(muteBtn, { BackgroundTransparency = 0   }) end))
conn(killBtn.MouseEnter:Connect(function() tw(killBtn, { BackgroundTransparency = 0.2 }) end))
conn(killBtn.MouseLeave:Connect(function() tw(killBtn, { BackgroundTransparency = 0   }) end))

-- Scroll area
local scrollBg = Instance.new("Frame")
scrollBg.Size             = UDim2.new(1, -16, 1, -160)   -- ajuste de altura
scrollBg.Position         = UDim2.new(0, 8, 0, 100)
scrollBg.BackgroundColor3 = CFG.BG_LOG
scrollBg.BorderSizePixel  = 0
scrollBg.ZIndex           = 2
scrollBg.Parent           = body
corner(scrollBg, CFG.CORNER_SM)
stroke(scrollBg, CFG.STROKE, 1.5)

local scroll = Instance.new("ScrollingFrame")
scroll.Size                  = UDim2.new(1, -6, 1, -6)
scroll.Position              = UDim2.new(0, 3, 0, 3)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel       = 0
scroll.ScrollBarThickness    = 3
scroll.ScrollBarImageColor3  = CFG.PURPLE
scroll.AutomaticCanvasSize   = Enum.AutomaticSize.Y
scroll.CanvasSize            = UDim2.new(0, 0, 0, 0)
scroll.ZIndex                = 3
scroll.Parent                = scrollBg

local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding   = UDim.new(0, 0)
layout.Parent    = scroll

local pad = Instance.new("UIPadding")
pad.PaddingLeft  = UDim.new(0, 2)
pad.PaddingRight = UDim.new(0, 2)
pad.PaddingTop   = UDim.new(0, 2)
pad.Parent       = scroll

-- Footer
local footer = Instance.new("Frame")
footer.Size             = UDim2.new(1, -16, 0, 28)
footer.Position         = UDim2.new(0, 8, 1, -36)
footer.BackgroundTransparency = 1
footer.ZIndex           = 3
footer.Parent           = body

local totalLbl = Instance.new("TextLabel")
totalLbl.Size               = UDim2.new(0.5, 0, 1, 0)
totalLbl.BackgroundTransparency = 1
totalLbl.Font               = CFG.FONT_BOLD
totalLbl.TextSize           = 10
totalLbl.TextColor3         = CFG.PURPLE
totalLbl.TextXAlignment     = Enum.TextXAlignment.Left
totalLbl.Text               = "0 unique IDs"
totalLbl.ZIndex             = 4
totalLbl.Parent             = footer

-- Botão adicional para copiar apenas IDs (sem formatação)
local copyIDsBtn = Instance.new("TextButton")
copyIDsBtn.Size             = UDim2.new(0, 100, 1, 0)
copyIDsBtn.Position         = UDim2.new(1, -100, 0, 0)
copyIDsBtn.BackgroundColor3 = Color3.fromRGB(219, 234, 254)
copyIDsBtn.TextColor3       = Color3.fromRGB(29, 78, 216)
copyIDsBtn.Font             = CFG.FONT_BOLD
copyIDsBtn.TextSize         = 9
copyIDsBtn.Text             = "Copy IDs"
copyIDsBtn.AutoButtonColor  = false
copyIDsBtn.ZIndex           = 4
copyIDsBtn.Parent           = footer
corner(copyIDsBtn, CFG.CORNER_SM)
stroke(copyIDsBtn, CFG.STROKE, 1.5)

conn(copyIDsBtn.MouseButton1Click:Connect(function()
	local ids = {}
	for id in pairs(audioIds) do
		table.insert(ids, id)
	end
	if #ids == 0 then return end
	table.sort(ids)  -- ordena para organização
	local ok = copy(table.concat(ids, "\n"))
	setStatus(
		ok and ("  ✅ Copied " .. #ids .. " IDs!") or "  ⚠️ IDs saved in _G.audioLog",
		ok and CFG.BLUE or CFG.ORANGE,
		ok and Color3.fromRGB(219, 234, 254) or Color3.fromRGB(254, 243, 199)
	)
	task.delay(2.5, resetStatus)
end))

-- ============================= ENTRADAS DE LOG =============================
local function updateCounters()
	local n = 0
	for _ in pairs(audioIds) do n = n + 1 end
	countLbl.Text = n .. " IDs"
	totalLbl.Text = n .. " unique IDs"
end

local function applyFilter()
	local q = filterText:lower()
	for _, e in ipairs(entryRows) do
		if q == "" then
			e.row.Visible = true
		else
			e.row.Visible = (e.idStr:find(q, 1, true) or e.source:lower():find(q, 1, true)) ~= nil
		end
	end
end

local function addEntry(idStr, source, time)
	lineCount += 1
	table.insert(logLines, ("[%s] %s | %s"):format(time, source, idStr))

	local clr = nextColor()

	local row = Instance.new("Frame")
	row.Size             = UDim2.new(1, 0, 0, 58)
	row.BackgroundColor3 = CFG.BG_ENTRY
	row.BackgroundTransparency = 1
	row.BorderSizePixel  = 0
	row.LayoutOrder      = lineCount
	row.ZIndex           = 3
	row.Parent           = scroll
	tw(row, { BackgroundTransparency = 0 }, CFG.MED)

	local div = Instance.new("Frame")
	div.Size             = UDim2.new(1, 0, 0, 1)
	div.BackgroundColor3 = CFG.STROKE_ENTRY
	div.BorderSizePixel  = 0
	div.ZIndex           = 4
	div.Parent           = row

	-- Thumbnail
	local thumbFrame = Instance.new("Frame")
	thumbFrame.Size             = UDim2.new(0, 58, 1, -1)
	thumbFrame.Position         = UDim2.new(0, 0, 0, 1)
	thumbFrame.BackgroundColor3 = clr.bg
	thumbFrame.BorderSizePixel  = 0
	thumbFrame.ClipsDescendants = true
	thumbFrame.ZIndex           = 4
	thumbFrame.Parent           = row

	local thumbImg = Instance.new("ImageLabel")
	thumbImg.Size             = UDim2.new(1, 0, 1, 0)
	thumbImg.BackgroundTransparency = 1
	thumbImg.Image            = "rbxthumb://type=Asset&id=" .. idStr .. "&w=150&h=150"
	thumbImg.ImageTransparency = 0.1
	thumbImg.ScaleType        = Enum.ScaleType.Crop
	thumbImg.ZIndex           = 5
	thumbImg.Parent           = thumbFrame

	-- Info
	local info = Instance.new("Frame")
	info.Size             = UDim2.new(1, -96, 1, 0)
	info.Position         = UDim2.new(0, 62, 0, 0)
	info.BackgroundTransparency = 1
	info.ZIndex           = 4
	info.Parent           = row

	local idLbl = Instance.new("TextLabel")
	idLbl.Size               = UDim2.new(1, 0, 0, 28)
	idLbl.Position           = UDim2.new(0, 0, 0, 6)
	idLbl.BackgroundTransparency = 1
	idLbl.Font               = CFG.FONT_BOLD
	idLbl.TextSize           = 13
	idLbl.TextColor3         = clr.tx
	idLbl.TextXAlignment     = Enum.TextXAlignment.Left
	idLbl.Text               = idStr
	idLbl.TextTruncate       = Enum.TextTruncate.AtEnd
	idLbl.ZIndex             = 5
	idLbl.Parent             = info

	local srcLbl = Instance.new("TextLabel")
	srcLbl.Size               = UDim2.new(1, 0, 0, 16)
	srcLbl.Position           = UDim2.new(0, 0, 0, 34)
	srcLbl.BackgroundTransparency = 1
	srcLbl.Font               = CFG.FONT_CODE
	srcLbl.TextSize           = 9
	srcLbl.TextColor3         = CFG.TEXT_SUB
	srcLbl.TextXAlignment     = Enum.TextXAlignment.Left
	srcLbl.Text               = source .. "  ·  " .. time
	srcLbl.ZIndex             = 5
	srcLbl.Parent             = info

	-- Botão copiar
	local cpBtn = Instance.new("TextButton")
	cpBtn.Size             = UDim2.new(0, 30, 0, 26)
	cpBtn.Position         = UDim2.new(1, -34, 0.5, -13)
	cpBtn.BackgroundColor3 = Color3.fromRGB(237, 233, 254)
	cpBtn.TextColor3       = Color3.fromRGB(30, 30, 30)
	cpBtn.Font             = CFG.FONT_BOLD
	cpBtn.TextSize         = 15
	cpBtn.Text             = "📄"
	cpBtn.AutoButtonColor  = false
	cpBtn.ZIndex           = 5
	cpBtn.Parent           = row
	corner(cpBtn, UDim.new(0, 5))
	stroke(cpBtn, CFG.STROKE, 1.5)

	conn(cpBtn.MouseButton1Click:Connect(function()
		copy(idStr)
		cpBtn.Text = "✅"
		task.delay(1.2, function()
			if cpBtn.Parent then cpBtn.Text = "📩" end
		end)
	end))

	table.insert(entryRows, { row = row, idStr = idStr, source = source })
	updateCounters()
	if filterText ~= "" then applyFilter() end
	task.defer(function()
		scroll.CanvasPosition = Vector2.new(0, math.huge)
	end)
end

-- ============================= CAPTURA DE IDS =============================
local function logAudio(source, id)
	if isPaused or not id then return end
	local idStr = tostring(id):match("%d+")
	if not idStr then return end
	if #idStr < CFG.MIN_ID_LEN then return end
	if tonumber(idStr) < CFG.MIN_ID_VALUE then return end
	if audioIds[idStr] then return end
	audioIds[idStr] = true
	addEntry(idStr, source, os.date("%H:%M:%S"))
end

-- Processa argumentos genéricos (tupla de um remote)
local function scanArgs(args, source)
	for i, v in ipairs(args) do
		local t = typeof(v)
		if t == "number" and v > CFG.MIN_ID_VALUE then
			logAudio(source, v)
		elseif t == "string" then
			for num in v:gmatch("%d+") do
				if #num >= CFG.MIN_ID_LEN then logAudio(source, num) end
			end
		elseif t == "table" then
			for k, val in pairs(v) do
				if typeof(val) == "number" and val > CFG.MIN_ID_VALUE then
					logAudio(source .. "." .. tostring(k), val)
				elseif typeof(val) == "string" then
					for num in val:gmatch("%d+") do
						if #num >= CFG.MIN_ID_LEN then logAudio(source .. "." .. tostring(k), num) end
					end
				end
			end
		end
	end
end

-- Monitora sons em uma hierarquia
local function watchSounds(parent, label)
	-- Sons existentes
	for _, d in ipairs(parent:GetDescendants()) do
		if d:IsA("Sound") and d.SoundId ~= "" then
			local id = d.SoundId:match("%d+")
			if id and #id >= CFG.MIN_ID_LEN then logAudio(label, id) end
			conn(d:GetPropertyChangedSignal("SoundId"):Connect(function()
				local nid = d.SoundId:match("%d+")
				if nid and #nid >= CFG.MIN_ID_LEN then logAudio(label .. "/changed", nid) end
			end))
		end
	end

	-- Novos sons
	conn(parent.DescendantAdded:Connect(function(d)
		if d:IsA("Sound") then
			task.wait(0.1)
			if not d.Parent then return end
			if d.SoundId ~= "" then
				local id = d.SoundId:match("%d+")
				if id and #id >= CFG.MIN_ID_LEN then logAudio(label .. "/new", id) end
			end
			conn(d:GetPropertyChangedSignal("SoundId"):Connect(function()
				local nid = d.SoundId:match("%d+")
				if nid and #nid >= CFG.MIN_ID_LEN then logAudio(label .. "/changed", nid) end
			end))
		end
	end))
end

-- Monitora remotes na ReplicatedStorage (e subpastas)
local function monitorRemotes()
	local function hookRemote(remote)
		if not remote:IsA("RemoteEvent") then return end
		local remoteName = remote.Name
		conn(remote.OnClientEvent:Connect(function(...)
			local args = {...}
			scanArgs(args, "Remote/" .. remoteName)
		end))
	end

	-- Varre o ReplicatedStorage
	for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
		for _, name in ipairs(CFG.REMOTE_NAMES) do
			if obj.Name == name and obj:IsA("RemoteEvent") then
				hookRemote(obj)
			end
		end
	end

	-- Também monitora novos remotes adicionados depois
	conn(ReplicatedStorage.DescendantAdded:Connect(function(obj)
		for _, name in ipairs(CFG.REMOTE_NAMES) do
			if obj.Name == name and obj:IsA("RemoteEvent") then
				hookRemote(obj)
			end
		end
	end))
end

-- Inicia o monitoramento
for _, p in ipairs(Players:GetPlayers()) do
	if p.Character then watchSounds(p.Character, p.Name) end
	conn(p.CharacterAdded:Connect(function(char)
		task.wait(1)
		watchSounds(char, p.Name)
	end))
end

conn(Players.PlayerAdded:Connect(function(p)
	conn(p.CharacterAdded:Connect(function(char)
		task.wait(1)
		watchSounds(char, p.Name)
	end))
end))

watchSounds(game.Workspace, "Workspace")
monitorRemotes()  -- NOVO: captura remotes

-- ============================= AÇÕES DOS BOTÕES =============================

-- Mute All toggle
conn(muteBtn.MouseButton1Click:Connect(function()
	muteActive = not muteActive

	if muteActive then
		-- Ativa
		enableMute()
		-- Loop seguro e eficiente com intervalo fixo (não usa Heartbeat)
		muteLoop = task.spawn(function()
			while muteActive do
				enableMute()
				task.wait(0.5)
			end
		end)

		muteBtn.BackgroundColor3 = Color3.fromRGB(187, 247, 208)
		muteBtn.TextColor3       = Color3.fromRGB(6, 95, 70)
		stroke(muteBtn, Color3.fromRGB(110, 231, 183), 1)
		muteBtn.Text = "🔇 Mute All ●"
		setStatus("  🔇 Mute All ativado", CFG.TEXT_STATUS, Color3.fromRGB(187, 247, 208))
		task.delay(2, resetStatus)
	else
		-- Desativa
		muteActive = false  -- interrompe o loop
		disableMute()       -- restaura volumes originais

		muteBtn.BackgroundColor3 = Color3.fromRGB(254, 202, 202)
		muteBtn.TextColor3       = Color3.fromRGB(153, 27, 27)
		stroke(muteBtn, Color3.fromRGB(252, 165, 165), 1)
		muteBtn.Text = "🔇 Mute All ○"
		setStatus("  🔊 Mute All desativado", Color3.fromRGB(153, 27, 27), Color3.fromRGB(254, 202, 202))
		task.delay(2, resetStatus)
	end
end))

-- Kill all boomboxes
conn(killBtn.MouseButton1Click:Connect(function()
	killBtn.Text = "💀 Trying..."
	killBtn.BackgroundColor3 = Color3.fromRGB(254, 243, 199)
	killBtn.TextColor3       = Color3.fromRGB(146, 64, 14)

	setStatus("  💀 sending a shutdown signal to the boomboxes...", Color3.fromRGB(146, 64, 14), Color3.fromRGB(254, 243, 199))

	task.spawn(tryFireKillAll)

	task.delay(2, function()
		if killBtn.Parent then
			killBtn.Text             = "💀 Kill Boomboxes"
			killBtn.BackgroundColor3 = Color3.fromRGB(254, 226, 226)
			killBtn.TextColor3       = Color3.fromRGB(153, 27, 27)
		end
		resetStatus()
	end)
end))

-- Copiar tudo (log completo)
conn(copyBtn.MouseButton1Click:Connect(function()
	if #logLines == 0 then return end
	local ok = copy(table.concat(logLines, "\n"))
	setStatus(
		ok and ("  ✅ Copied! " .. #logLines .. " entradas") or "  ⚠️ Saved to _G.audioLog",
		ok and CFG.BLUE or CFG.ORANGE,
		ok and Color3.fromRGB(219, 234, 254) or Color3.fromRGB(254, 243, 199)
	)
	task.delay(2.5, resetStatus)
end))

-- Limpar log
conn(clearBtn.MouseButton1Click:Connect(function()
	audioIds = {}
	logLines = {}
	entryRows = {}
	lineCount = 0
	colorIdx = 0
	for _, c in ipairs(scroll:GetChildren()) do
		if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
	end
	updateCounters()
	setStatus("  🗑️ clear true", CFG.ORANGE, Color3.fromRGB(254, 243, 199))
	task.delay(2, resetStatus)
end))

-- Pausar/retomar
conn(pauseBtn.MouseButton1Click:Connect(function()
	isPaused = not isPaused
	if isPaused then
		pauseBtn.Text = "▶️"
		setStatus("  ⏸️ Monitoramento pause", CFG.ORANGE, Color3.fromRGB(254, 243, 199))
	else
		pauseBtn.Text = "📴"
		resetStatus()
	end
end))

-- Minimizar/expandir
conn(minBtn.MouseButton1Click:Connect(function()
	isMinimized = not isMinimized
	if isMinimized then
		tw(body, { Size = UDim2.new(1, 0, 0, 0) }, CFG.MED)
		tw(win,  { Size = UDim2.new(0, 520, 0, 44) }, CFG.MED)
		minBtn.Text = "🔼"
	else
		tw(win,  { Size = CFG.WIN_SIZE }, CFG.MED)
		tw(body, { Size = UDim2.new(1, 0, 1, -44) }, CFG.MED)
		minBtn.Text = "📏"
	end
end))

-- Fechar
conn(closeBtn.MouseButton1Click:Connect(function()
	if muteActive then
		muteActive = false
		disableMute()
	end
	cleanup()
	tw(win, { BackgroundTransparency = 1 }, CFG.FAST)
	task.wait(0.15)
	gui:Destroy()
end))

-- Filtro de busca
conn(searchBox:GetPropertyChangedSignal("Text"):Connect(function()
	filterText = searchBox.Text
	applyFilter()
end))

-- ============================= DRAG DA JANELA =============================
local dragging, dragStart, startPos = false, nil, nil

conn(top.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging  = true
		dragStart = input.Position
		startPos  = win.Position
	end
end))

conn(top.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end))

conn(UserInputService.InputChanged:Connect(function(input)
	if not dragging then return end
	if input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch then
		local d = input.Position - dragStart
		win.Position = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + d.X,
			startPos.Y.Scale, startPos.Y.Offset + d.Y
		)
	end
end))