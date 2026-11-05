--// Steal a Superpower! — Auto Farm Control Center (Red Theme)
--// GUI แกะจาก farm_control_center, ฟังก์ชันเป็นของเราเอง

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local VIM = game:GetService("VirtualInputManager")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Remotes = RS:WaitForChild("Remotes")

---------- CLEANUP OLD UIs & LOOPS ----------
if _G._autoFarmCleanup then pcall(_G._autoFarmCleanup) end
-- kill the old cheat-ui-v2 loops
if _G._cheatConns then for _, c in pairs(_G._cheatConns) do pcall(function() c:Disconnect() end) end end
if _G._cheatThreads then for _, t in pairs(_G._cheatThreads) do pcall(function() task.cancel(t) end) end end
_G._cheatConns, _G._cheatThreads = nil, nil
for _, n in ipairs({"AutoFarmHUD", "CheatUI", "CheatUIv2", "CodexFarmControlCenter", "AutoFarmCenter"}) do
    local g = playerGui:FindFirstChild(n)
    if g then g:Destroy() end
end

_G._autoFarmRunning = true
local conns, threads = {}, {}

---------- MODULES ----------
local Progression = require(RS.Shared.Rules.Progression)
local PowerConfig = require(RS.Shared.Config.PowerConfig)
local AbilityConfig = require(RS.Shared.Config.AbilityConfig)
local PredictedCast = require(RS.Client.Core.PredictedCast)
local PlayerState = require(RS.Client.Core.PlayerState)
local CardIndex = require(RS.Shared.Rules.CardIndex)
local EnemyUI = require(RS.Client.UI.World.EnemyUI)   -- client-authoritative PredictHit = instant kill + reward
local function getData() return PlayerState.Data end

---------- CONFIG ----------
local CFG = {
    SPEED = 150,
    BENCH_TIME = 20,
    FIGHT_TIME = 25,
    FIGHT_RANGE = 12,
    ATTACK_INTERVAL = 0.55,
    BENCH_POS = Vector3.new(66, 3, 26),
    ENEMY_AREA = Vector3.new(5, 4, -185),
    ATTACK_RANGE = 28,   -- abilities reach this far; no need to touch enemy
    PACK_PRIORITY = {"Elite", "Champion", "Fighter", "Hero", "Rookie"},
    PACK_PRICES = {Elite = 100000, Champion = 25000, Fighter = 6000, Hero = 1500, Rookie = 250},
    UPGRADE_PRIORITY = {"Cash", "Health", "Carry"},
}

---------- STATE (toggles) ----------
local state = {
    master = true,
    bench = true,
    fight = true,
    abilities = true,
    speed = true,
    noclip = true,
    buyPacks = true,
    manageCards = true,
    upgrades = true,
    rebirth = true,
    claimIndex = true,
    placeCards = true,
}
local stats = { startTime = tick(), startCash = tonumber(getData().Cash) or 0, packsBought = 0, upgrades = 0, rebirths = 0, mode = "init", target = "-", learned = 0 }

---------- SELF-LEARNING MEMORY (persists across reloads) ----------
-- [enemyType] = {attempts, kills, deaths, sumTime, reward, boss}
_G._afLearn = _G._afLearn or {}
local Learn = _G._afLearn
local function learnGet(et) Learn[et] = Learn[et] or {attempts=0, kills=0, deaths=0, sumTime=0, reward=0, boss=false}; return Learn[et] end
-- value = cash/sec if known; else optimistic estimate. returns -1 if known-deadly.
local function targetScore(et, isBoss, maxHp, dist, reward)
    local L = Learn[et]
    if L and L.deaths >= 2 and L.kills == 0 then return -1 end         -- keeps dying, avoid
    if L and L.unreachUntil and tick() < L.unreachUntil then return -1 end  -- couldn't reach recently
    if L and L.kills > 0 then
        local avg = L.sumTime / L.kills
        local r = (L.reward > 0 and L.reward) or reward or (isBoss and 400 or 30)
        return r / math.max(avg, 0.5) - dist * 0.02                    -- learned cash/sec, minus travel
    end
    local est = (isBoss and 400 or 30)
    return est / math.max(maxHp / 180, 0.6) - dist * 0.04              -- untested: optimistic, HP-weighted
end

---------- RED THEME ----------
local COLORS = {
    Bg     = Color3.fromRGB(14, 7, 8),
    Panel  = Color3.fromRGB(16, 8, 9),
    Card   = Color3.fromRGB(26, 13, 14),
    Card2  = Color3.fromRGB(38, 20, 21),
    Line   = Color3.fromRGB(96, 52, 54),
    Text   = Color3.fromRGB(247, 240, 241),
    Sub    = Color3.fromRGB(190, 150, 152),
    Red    = Color3.fromRGB(255, 74, 74),
    Green  = Color3.fromRGB(103, 223, 91),
    Orange = Color3.fromRGB(255, 160, 72),
    Blue   = Color3.fromRGB(120, 150, 255),
    Purple = Color3.fromRGB(190, 113, 255),
}

local function new(className, props, parent)
    local o = Instance.new(className)
    for k, v in pairs(props or {}) do o[k] = v end
    o.Parent = parent
    return o
end
local function corner(p, r) return new("UICorner", {CornerRadius = UDim.new(0, r or 10)}, p) end
local function stroke(p, c, t, th)
    return new("UIStroke", {Color = c or COLORS.Line, Transparency = t or 0, Thickness = th or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, p)
end

---------- HELPERS (farm) ----------
local function getChar()
    local c = player.Character
    if not c then return nil, nil, nil end
    return c, c:FindFirstChildOfClass("Humanoid"), c:FindFirstChild("HumanoidRootPart")
end
local function walkTo(pos, timeout)
    local _, hum, hrp = getChar()
    if not hum or not hrp then return false end
    hum.WalkSpeed = CFG.SPEED
    hum:MoveTo(pos)
    local t0 = tick()
    while (hrp.Position - pos).Magnitude > 10 and tick() - t0 < (timeout or 8) do
        if not _G._autoFarmRunning then return false end
        hum.WalkSpeed = CFG.SPEED
        hum:MoveTo(pos)
        task.wait(0.15)
    end
    return (hrp.Position - pos).Magnitude <= 10
end
local function getNearestEnemy(maxDist)
    local _, _, hrp = getChar()
    if not hrp then return nil, nil, 999 end
    local best, bestHrp, bestDist = nil, nil, maxDist or 200
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:GetAttribute("EnemyType") and obj:IsA("Model") and obj:GetAttribute("Dead") ~= true then
            local eHrp = obj:FindFirstChild("HumanoidRootPart") or obj.PrimaryPart
            local eHum = obj:FindFirstChildOfClass("Humanoid")
            if eHrp and eHum and eHum.Health > 0 then
                local d = (eHrp.Position - hrp.Position).Magnitude
                if d < bestDist then bestDist = d; best = obj; bestHrp = eHrp end
            end
        end
    end
    return best, bestHrp, bestDist
end

---------- GUI SHELL ----------
local gui = new("ScreenGui", {Name = "AutoFarmCenter", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 80}, playerGui)

local shadow = new("Frame", {Name = "Shadow", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(734, 474), BackgroundColor3 = Color3.new(), BackgroundTransparency = 0.45, BorderSizePixel = 0}, gui)
corner(shadow, 12)
local shadowScale = new("UIScale", {Scale = 1}, shadow)

local main = new("Frame", {Name = "Window", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(720, 460), BackgroundColor3 = COLORS.Bg, BackgroundTransparency = 0.1, BorderSizePixel = 0, ClipsDescendants = true}, gui)
corner(main, 11)
stroke(main, COLORS.Red, 0.35, 1.4)
local windowScale = new("UIScale", {Scale = 1}, main)
new("UIGradient", {Color = ColorSequence.new({ColorSequenceKeypoint.new(0, Color3.fromRGB(14, 7, 8)), ColorSequenceKeypoint.new(0.6, Color3.fromRGB(22, 10, 11)), ColorSequenceKeypoint.new(1, Color3.fromRGB(30, 12, 13))}), Rotation = 20}, main)

local function clampWindowPosition(pos)
    local canvas = gui.AbsoluteSize
    if canvas.X <= 0 or canvas.Y <= 0 then return pos end
    local hw, hh = 720 * windowScale.Scale / 2, 460 * windowScale.Scale / 2
    local x = pos.X.Scale * canvas.X + pos.X.Offset
    local y = pos.Y.Scale * canvas.Y + pos.Y.Offset
    return UDim2.fromOffset(math.clamp(x, hw + 8, math.max(hw + 8, canvas.X - hw - 8)), math.clamp(y, hh + 8, math.max(hh + 8, canvas.Y - hh - 8)))
end
local function fitWindow()
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    local scale = math.min(1, (vp.X - 32) / 734, (vp.Y - 70) / 474)
    windowScale.Scale = scale; shadowScale.Scale = scale
    main.Position = clampWindowPosition(main.Position); shadow.Position = main.Position
end
fitWindow()
if workspace.CurrentCamera then
    conns.vp = workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fitWindow)
end

-- Header
local header = new("Frame", {Name = "Header", Size = UDim2.new(1, 0, 0, 48), BackgroundColor3 = COLORS.Panel, BackgroundTransparency = 0.04, BorderSizePixel = 0, Active = true}, main)
new("UIGradient", {Color = ColorSequence.new({ColorSequenceKeypoint.new(0, Color3.fromRGB(20, 9, 10)), ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 15, 16))})}, header)
new("Frame", {Position = UDim2.new(0, 0, 1, -1), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = COLORS.Line, BackgroundTransparency = 0.5, BorderSizePixel = 0}, header)

local brandDot = new("Frame", {Position = UDim2.fromOffset(14, 15), Size = UDim2.fromOffset(18, 18), BackgroundColor3 = COLORS.Red, BorderSizePixel = 0}, header)
corner(brandDot, 5)
new("TextLabel", {Position = UDim2.fromOffset(44, 5), Size = UDim2.fromOffset(300, 20), BackgroundTransparency = 1, Text = "⚡ SUPERPOWER AUTO FARM", TextColor3 = COLORS.Text, TextSize = 14, Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left}, header)
local headerSub = new("TextLabel", {Position = UDim2.fromOffset(44, 25), Size = UDim2.fromOffset(300, 16), BackgroundTransparency = 1, Text = "ฟาร์มครบวงจร • Bench + Fight + Rebirth", TextColor3 = COLORS.Sub, TextSize = 9, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left}, header)

local headerStatus = new("TextLabel", {Position = UDim2.new(1, -300, 0, 9), Size = UDim2.fromOffset(210, 29), BackgroundColor3 = COLORS.Card, BackgroundTransparency = 0.12, BorderSizePixel = 0, Text = "● RUNNING", TextColor3 = COLORS.Green, TextSize = 10, Font = Enum.Font.GothamBold}, header)
corner(headerStatus, 7); stroke(headerStatus, COLORS.Line, 0.45, 1)

local function headerButton(text, x)
    local b = new("TextButton", {Position = UDim2.new(1, x, 0, 9), Size = UDim2.fromOffset(29, 29), BackgroundColor3 = COLORS.Card2, BackgroundTransparency = 0.2, BorderSizePixel = 0, Text = text, TextColor3 = COLORS.Sub, TextSize = 16, Font = Enum.Font.GothamBold, AutoButtonColor = false}, header)
    corner(b, 7)
    return b
end
local minimizeButton = headerButton("—", -78)
local closeButton = headerButton("×", -40)

-- Sidebar
local sidebar = new("Frame", {Name = "Sidebar", Position = UDim2.fromOffset(0, 48), Size = UDim2.new(0, 176, 1, -48), BackgroundColor3 = COLORS.Panel, BackgroundTransparency = 0.08, BorderSizePixel = 0}, main)
new("Frame", {Position = UDim2.new(1, -1, 0, 0), Size = UDim2.new(0, 1, 1, 0), BackgroundColor3 = COLORS.Line, BackgroundTransparency = 0.42, BorderSizePixel = 0}, sidebar)

local navHolder = new("Frame", {Position = UDim2.fromOffset(7, 14), Size = UDim2.new(1, -14, 0, 220), BackgroundTransparency = 1}, sidebar)
new("UIListLayout", {Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder}, navHolder)

local profile = new("Frame", {Position = UDim2.new(0, 8, 1, -70), Size = UDim2.new(1, -16, 0, 56), BackgroundColor3 = COLORS.Card, BackgroundTransparency = 0.14, BorderSizePixel = 0}, sidebar)
corner(profile, 8); stroke(profile, COLORS.Line, 0.6, 1)
local profileLevel = new("TextLabel", {Position = UDim2.fromOffset(11, 7), Size = UDim2.new(1, -22, 0, 22), BackgroundTransparency = 1, Text = "Lv. --", TextColor3 = COLORS.Text, TextSize = 15, Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left}, profile)
local profileInfo = new("TextLabel", {Position = UDim2.fromOffset(11, 30), Size = UDim2.new(1, -22, 0, 18), BackgroundTransparency = 1, Text = "โหลด...", TextColor3 = COLORS.Sub, TextSize = 11, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left}, profile)

-- Content
local content = new("Frame", {Name = "Content", Position = UDim2.fromOffset(176, 48), Size = UDim2.new(1, -176, 1, -48), BackgroundTransparency = 1}, main)
local pageTitle = new("TextLabel", {Position = UDim2.fromOffset(16, 9), Size = UDim2.new(1, -32, 0, 26), BackgroundTransparency = 1, Text = "STATUS", TextColor3 = COLORS.Text, TextSize = 15, Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left}, content)

local pages, navButtons, currentPage = {}, {}, "status"
local PAGE_TITLES = {status = "STATUS  /  ภาพรวม", combat = "COMBAT  /  การต่อสู้", economy = "ECONOMY  /  แพ็ค + อัปเกรด", progress = "PROGRESS  /  รีเบิร์ธ + การ์ด"}

local function makePage(id)
    local page = new("ScrollingFrame", {Name = id, Position = UDim2.fromOffset(14, 42), Size = UDim2.new(1, -28, 1, -50), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = COLORS.Red, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false}, content)
    new("UIListLayout", {Padding = UDim.new(0, 9), SortOrder = Enum.SortOrder.LayoutOrder}, page)
    new("UIPadding", {PaddingBottom = UDim.new(0, 8)}, page)
    pages[id] = page
    return page
end
local function selectPage(id)
    currentPage = id
    pageTitle.Text = PAGE_TITLES[id] or string.upper(id)
    for n, p in pairs(pages) do p.Visible = n == id end
    for n, b in pairs(navButtons) do
        local sel = n == id
        b.BackgroundColor3 = sel and COLORS.Card2 or COLORS.Card
        b.BackgroundTransparency = sel and 0.04 or 0.4
        local lbl = b:FindFirstChild("Label"); if lbl then lbl.TextColor3 = sel and COLORS.Text or COLORS.Sub end
        local mk = b:FindFirstChild("Marker"); if mk then mk.Visible = sel end
    end
end
local function makeNav(id, text, order)
    local b = new("TextButton", {Name = id, Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = COLORS.Card, BackgroundTransparency = 0.4, BorderSizePixel = 0, Text = "", AutoButtonColor = false, LayoutOrder = order}, navHolder)
    corner(b, 8)
    local mk = new("Frame", {Name = "Marker", Position = UDim2.fromOffset(0, 8), Size = UDim2.fromOffset(3, 22), BackgroundColor3 = COLORS.Red, BorderSizePixel = 0, Visible = false}, b)
    corner(mk, 3)
    new("TextLabel", {Name = "Label", Position = UDim2.fromOffset(16, 0), Size = UDim2.new(1, -30, 1, 0), BackgroundTransparency = 1, Text = text, TextColor3 = COLORS.Sub, TextSize = 13, Font = Enum.Font.GothamMedium, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd}, b)
    navButtons[id] = b
    conns["nav_" .. id] = b.MouseButton1Click:Connect(function() selectPage(id) end)
end

local function makeCard(parent, height)
    local f = new("Frame", {Size = UDim2.new(1, -4, 0, height), BackgroundColor3 = COLORS.Card, BackgroundTransparency = 0.32, BorderSizePixel = 0, LayoutOrder = #parent:GetChildren()}, parent)
    corner(f, 8); stroke(f, COLORS.Line, 0.68, 1)
    return f
end

-- toggle bound to a state key
local refreshers = {}
local function makeToggle(parent, title, subtitle, key)
    local f = makeCard(parent, 60)
    new("TextLabel", {Position = UDim2.fromOffset(14, 9), Size = UDim2.new(1, -90, 0, 20), BackgroundTransparency = 1, Text = title, TextColor3 = COLORS.Text, TextSize = 13, Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left}, f)
    new("TextLabel", {Position = UDim2.fromOffset(14, 30), Size = UDim2.new(1, -95, 0, 22), BackgroundTransparency = 1, Text = subtitle, TextColor3 = COLORS.Sub, TextSize = 10, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true}, f)
    local tg = new("TextButton", {Position = UDim2.new(1, -64, 0.5, -13), Size = UDim2.fromOffset(50, 26), BackgroundColor3 = Color3.fromRGB(40, 22, 23), BorderSizePixel = 0, Text = "OFF", TextColor3 = COLORS.Sub, TextSize = 11, Font = Enum.Font.GothamBold, AutoButtonColor = false}, f)
    corner(tg, 13); stroke(tg, COLORS.Line, 0.62, 1)
    local function refresh()
        local on = state[key] == true
        tg.Text = on and "ON" or "OFF"
        tg.BackgroundColor3 = on and COLORS.Red or Color3.fromRGB(40, 22, 23)
        tg.TextColor3 = on and Color3.new(1, 1, 1) or COLORS.Sub
    end
    refreshers[key] = refresh
    conns["tg_" .. key] = tg.MouseButton1Click:Connect(function()
        state[key] = not state[key]
        refresh()
    end)
    refresh()
    return f
end

-- live stat row
local function makeStat(parent, label, color)
    local f = makeCard(parent, 44)
    new("TextLabel", {Position = UDim2.fromOffset(14, 0), Size = UDim2.new(0.42, 0, 1, 0), BackgroundTransparency = 1, Text = label, TextColor3 = COLORS.Sub, TextSize = 12, Font = Enum.Font.GothamMedium, TextXAlignment = Enum.TextXAlignment.Left}, f)
    local val = new("TextLabel", {Position = UDim2.new(0.42, 0, 0, 0), Size = UDim2.new(0.58, -14, 1, 0), BackgroundTransparency = 1, Text = "--", TextColor3 = color or COLORS.Text, TextSize = 13, Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Right}, f)
    return val
end

-- Toast
local toastToken = 0
local toastLabel = new("TextLabel", {AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 88, 1, -12), Size = UDim2.fromOffset(380, 36), BackgroundColor3 = COLORS.Card2, BackgroundTransparency = 1, BorderSizePixel = 0, Text = "", TextColor3 = COLORS.Text, TextTransparency = 1, TextSize = 12, Font = Enum.Font.GothamBold, ZIndex = 30}, main)
corner(toastLabel, 10)
local function toast(msg)
    toastToken += 1; local tk = toastToken
    toastLabel.Text = tostring(msg)
    TweenService:Create(toastLabel, TweenInfo.new(0.18), {BackgroundTransparency = 0.08, TextTransparency = 0}):Play()
    task.delay(2.6, function()
        if _G._autoFarmRunning and tk == toastToken then
            TweenService:Create(toastLabel, TweenInfo.new(0.25), {BackgroundTransparency = 1, TextTransparency = 1}):Play()
        end
    end)
end
local function setAction(msg) toast(msg) end

---------- BUILD PAGES ----------
makePage("status"); makePage("combat"); makePage("economy"); makePage("progress"); makePage("brain")
makeNav("status", "สถานะ", 1)
makeNav("combat", "การต่อสู้", 2)
makeNav("economy", "แพ็ค / อัปเกรด", 3)
makeNav("progress", "รีเบิร์ธ / การ์ด", 4)
makeNav("brain", "สมอง AI", 5)

-- STATUS page: master toggle + live stats
makeToggle(pages.status, "MASTER — เปิดฟาร์มทั้งหมด", "ปิดอันนี้ = หยุดทุกระบบชั่วคราว", "master")
local stCash   = makeStat(pages.status, "Cash", COLORS.Green)
local stPower  = makeStat(pages.status, "Power", COLORS.Purple)
local stLevel  = makeStat(pages.status, "Level", COLORS.Text)
local stRebirth= makeStat(pages.status, "Rebirths", COLORS.Orange)
local stNext   = makeStat(pages.status, "Next Rebirth", COLORS.Red)
local stMode   = makeStat(pages.status, "Mode", COLORS.Blue)
local stTarget = makeStat(pages.status, "Target", COLORS.Orange)
local stRate   = makeStat(pages.status, "Cash / min", COLORS.Green)
local stSession= makeStat(pages.status, "Session", COLORS.Sub)

-- COMBAT page
makeToggle(pages.combat, "Bench (Power)", "อยู่ที่ bench ยก Power ตลอด", "bench")
makeToggle(pages.combat, "Instant Kill (Cash)", "ฆ่าศัตรู+บอสทุกตัวทั้งแมพทันที จากที่เดียว", "fight")
makeToggle(pages.combat, "Speed Hack 150", "วิ่งเร็ว", "speed")
makeToggle(pages.combat, "Noclip", "ทะลุกำแพง", "noclip")

-- ECONOMY page
makeToggle(pages.economy, "Auto Buy Packs", "ซื้อแพ็คดีสุดที่ซื้อได้", "buyPacks")
makeToggle(pages.economy, "Open / Fuse / Equip", "เปิดแพ็ค ฟิวส์ สวมการ์ดดีสุด", "manageCards")
makeToggle(pages.economy, "Auto Upgrade", "Cash > Health > Carry", "upgrades")

-- PROGRESS page
makeToggle(pages.progress, "Auto Rebirth", "รีเบิร์ธเมื่อถึง Level", "rebirth")
makeToggle(pages.progress, "Claim Index", "รับรางวัล Index ที่ครบ", "claimIndex")
makeToggle(pages.progress, "Place Cards at Base", "วางการ์ดที่บ้านสร้าง passive", "placeCards")

-- BRAIN page (self-learning readout)
local brainInfo = new("TextLabel", {Size = UDim2.new(1, -4, 0, 44), BackgroundTransparency = 1, Text = "ระบบเลือกเป้าหมายเอง: วัดเวลาฆ่า + cash/วิ ของศัตรูแต่ละชนิด แล้วเลือกตัวที่คุ้มสุดที่ฆ่าได้ ตัวที่ตายบ่อยจะเลี่ยง", TextColor3 = COLORS.Sub, TextSize = 11, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, LayoutOrder = 0}, pages.brain)
local brainReset = new("TextButton", {Size = UDim2.new(1, -4, 0, 30), BackgroundColor3 = COLORS.Card2, BorderSizePixel = 0, Text = "ล้างความจำ (เริ่มเรียนรู้ใหม่)", TextColor3 = COLORS.Red, TextSize = 11, Font = Enum.Font.GothamBold, AutoButtonColor = false, LayoutOrder = 1}, pages.brain)
corner(brainReset, 7); stroke(brainReset, COLORS.Line, 0.5, 1)
conns.brainReset = brainReset.MouseButton1Click:Connect(function() table.clear(_G._afLearn); toast("ล้างความจำแล้ว") end)
local brainRows = new("Frame", {Size = UDim2.new(1, -4, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 2}, pages.brain)
new("UIListLayout", {Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder}, brainRows)

selectPage("status")

---------- ORB + VISIBILITY + DRAG ----------
local orb = new("TextButton", {Name = "Orb", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.08, 0.5), Size = UDim2.fromOffset(50, 50), BackgroundColor3 = COLORS.Red, BorderSizePixel = 0, Text = "⚡", TextColor3 = Color3.new(1, 1, 1), TextSize = 22, Font = Enum.Font.GothamBlack, Visible = false, AutoButtonColor = false}, gui)
corner(orb, 15); stroke(orb, COLORS.Text, 0.3, 2)
local function setVisible(v) main.Visible = v; shadow.Visible = v; orb.Visible = not v end
conns.close = closeButton.MouseButton1Click:Connect(function() setVisible(false) end)
conns.min = minimizeButton.MouseButton1Click:Connect(function() setVisible(false) end)
conns.orb = orb.MouseButton1Click:Connect(function() setVisible(true) end)
conns.key = UserInputService.InputBegan:Connect(function(input, gpe)
    if not gpe and input.KeyCode == Enum.KeyCode.RightControl then setVisible(not main.Visible) end
end)
do
    local dragging, dragStart, startPos
    conns.dragB = header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = input.Position; startPos = main.Position
        end
    end)
    conns.dragC = UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            main.Position = clampWindowPosition(UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y))
            shadow.Position = main.Position
        end
    end)
    conns.dragE = UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)
end

---------- CLEANUP ----------
local function cleanup()
    _G._autoFarmRunning = false
    for _, c in pairs(conns) do pcall(function() c:Disconnect() end) end
    for _, t in pairs(threads) do pcall(task.cancel, t) end
    conns, threads = {}, {}
    if gui then gui:Destroy() end
    local _, hum = getChar()
    if hum then hum.WalkSpeed = 16 end
end
_G._autoFarmCleanup = cleanup

---------- SPEED + NOCLIP ----------
conns.speed = RunService.Heartbeat:Connect(function()
    if not _G._autoFarmRunning or not state.master or not state.speed then return end
    local _, hum = getChar()
    if hum then hum.WalkSpeed = CFG.SPEED end
end)
conns.noclip = RunService.Stepped:Connect(function()
    if not _G._autoFarmRunning or not state.master or not state.noclip then return end
    local char = getChar()
    if char then for _, p in ipairs(char:GetDescendants()) do if p:IsA("BasePart") then p.CanCollide = false end end end
end)

local function paused() return not _G._autoFarmRunning or not state.master end

---------- BENCH LOOP (Power) — stays at bench; kill sweep runs in parallel ----------
threads.mainLoop = task.spawn(function()
    task.wait(1)
    while _G._autoFarmRunning do
        if paused() or not state.bench then stats.mode = state.fight and "kill-only" or "idle"; task.wait(1); continue end
        stats.mode = "bench"
        if walkTo(CFG.BENCH_POS, 8) and not paused() then
            pcall(function() Remotes.BenchStart:FireServer() end)
            while _G._autoFarmRunning and state.master and state.bench do
                local _, hum, hrp = getChar()
                if hum and hum.Health <= 0 then break end
                if hrp and (hrp.Position - CFG.BENCH_POS).Magnitude > 18 then break end  -- drifted off bench, re-walk
                task.wait(1)
            end
            pcall(function() Remotes.BenchStop:FireServer() end)
        end
    end
end)

---------- KILL SWEEP (Cash) — EnemyUI.PredictHit = instant client-side kill from anywhere ----------
-- No walking/aiming: scan whole map, instakill every enemy, boss or not, and bank the reward.
threads.killSweep = task.spawn(function()
    task.wait(2)
    while _G._autoFarmRunning do
        if state.master and state.fight then
            local killedThisTick = 0
            -- gather alive enemies, bosses first (worth more), then nearest
            local _, _, hrp = getChar()
            local myPos = hrp and hrp.Position or Vector3.new()
            local list = {}
            for _, obj in ipairs(workspace:GetDescendants()) do
                local et = obj:GetAttribute("EnemyType")
                if et and obj:IsA("Model") and obj:GetAttribute("DeadLocal") ~= true and obj:GetAttribute("Dead") ~= true then
                    local eHum = obj:FindFirstChildOfClass("Humanoid")
                    local eHrp = obj:FindFirstChild("HumanoidRootPart") or obj.PrimaryPart
                    if eHum and eHrp and eHum.Health > 0 then
                        local isBoss = obj:GetAttribute("Boss") == true
                        list[#list + 1] = {obj = obj, et = et, boss = isBoss, dist = (eHrp.Position - myPos).Magnitude}
                    end
                end
            end
            table.sort(list, function(a, b)
                if a.boss ~= b.boss then return a.boss end   -- bosses first
                return a.dist < b.dist
            end)
            for _, item in ipairs(list) do
                if not (state.master and state.fight) then break end
                local cashStart = tonumber(getData().Cash) or 0
                local ok = pcall(function() return EnemyUI.PredictHit(item.obj, 1e9, nil, "Own", false) end)
                if ok then
                    local L = learnGet(item.et); L.boss = item.boss; L.attempts += 1; L.kills += 1; L.sumTime += 0.1
                    task.wait(0.05)   -- small stagger so kills aren't an instant whole-map wipe
                    local gained = (tonumber(getData().Cash) or 0) - cashStart
                    if gained > 0 then L.reward = gained end
                    killedThisTick += 1
                    stats.target = (item.boss and "★ " or "") .. item.et
                end
                if killedThisTick >= 15 then break end   -- cap per tick
            end
            stats.learned = 0
            for _ in pairs(Learn) do stats.learned += 1 end
            if killedThisTick == 0 then stats.target = "(no enemies)" end
        end
        task.wait(0.5)
    end
end)

---------- AUTO BUY PACKS ----------
threads.buyPacks = task.spawn(function()
    task.wait(5)
    while _G._autoFarmRunning do
        if state.master and state.buyPacks then
            local data = getData()
            if data then
                local cash = tonumber(data.Cash) or 0
                -- keep a 30% buffer so Auto Upgrade (higher ROI) wins first
                for _, pk in ipairs(CFG.PACK_PRIORITY) do
                    local price = CFG.PACK_PRICES[pk]
                    if price and cash >= price * 1.3 then
                        pcall(function() Remotes.BuyPack:InvokeServer(pk) end)
                        stats.packsBought += 1
                        break
                    end
                end
            end
        end
        task.wait(8)
    end
end)

---------- AUTO MANAGE CARDS (OpenPack per-pack; OpenAllPacks is dev-only) ----------
local MaxOpen = 10
pcall(function() MaxOpen = require(RS.Shared.Config.PackConfig).MaxOpenAtOnce or 10 end)
threads.manageCards = task.spawn(function()
    task.wait(8)
    while _G._autoFarmRunning do
        if state.master and state.manageCards then
            local data = getData()
            if data and data.Packs then
                for packId, count in pairs(data.Packs) do
                    if count and count > 0 then
                        pcall(function() Remotes.OpenPack:InvokeServer(packId, math.clamp(count, 1, MaxOpen)) end)
                        task.wait(0.35)
                    end
                end
            end
            task.wait(0.4)
            pcall(function() Remotes.FuseAll:InvokeServer() end); task.wait(0.6)
            pcall(function() Remotes.EquipBest:InvokeServer() end)
            -- keep best owned aura equipped (Emerald = best Cash aura)
            pcall(function()
                local d = getData()
                if d and d.Cosmetics and d.Cosmetics.Aura then
                    local best, bestM = nil, -1
                    local Cos = require(RS.Shared.Config.CosmeticConfig)
                    local AURAS = {}
                    for _, grp in pairs(Cos) do
                        if type(grp) == "table" then
                            for _, it in ipairs(grp) do if type(it)=="table" and it.Multiplier and it.Id then AURAS[it.Id] = it.Multiplier end end
                        end
                    end
                    for id in pairs(d.Cosmetics.Aura) do
                        local m = AURAS[id] or 0
                        if m > bestM then best, bestM = id, m end
                    end
                    if best and d.Aura ~= best then Remotes.EquipCosmetic:InvokeServer("Aura", best) end
                end
            end)
        end
        task.wait(10)
    end
end)

---------- AUTO UPGRADE ----------
threads.upgrades = task.spawn(function()
    task.wait(10)
    while _G._autoFarmRunning do
        if state.master and state.upgrades then
            local data = getData()
            if data then
                local cash = tonumber(data.Cash) or 0
                for _, up in ipairs(CFG.UPGRADE_PRIORITY) do
                    local lvl = (data.Upgrades or {})[up] or 0
                    local cost = nil
                    pcall(function() cost = Progression.UpgradeCost(up, lvl + 1) end)
                    if cost and cash >= cost then
                        pcall(function() Remotes.BuyUpgrade:InvokeServer(up) end)
                        stats.upgrades += 1
                        break
                    end
                end
            end
        end
        task.wait(10)
    end
end)

---------- AUTO REBIRTH ----------
threads.rebirth = task.spawn(function()
    task.wait(12)
    while _G._autoFarmRunning do
        if state.master and state.rebirth then
            local data = getData()
            if data then
                local power = tonumber(data.Power) or 0
                local lvl = 0; pcall(function() lvl = PowerConfig.Level(power) end)
                local need = Progression.RebirthLevels[(data.Rebirths or 0) + 1]
                if need and lvl >= need then
                    pcall(function() Remotes.Rebirth:InvokeServer() end)
                    stats.rebirths += 1; stats.startCash = 0
                    toast("REBIRTH #" .. ((data.Rebirths or 0) + 1) .. "!")
                    task.wait(2)
                    pcall(function() Remotes.EquipBest:InvokeServer() end)
                end
            end
        end
        task.wait(20)
    end
end)

---------- CLAIM INDEX ----------
threads.claimIndex = task.spawn(function()
    task.wait(15)
    while _G._autoFarmRunning do
        if state.master and state.claimIndex then
            pcall(function()
                local data = getData()
                if not data then return end
                local found = data.Index or {}
                local claimed = data.IndexClaimed or {}
                for _, sec in ipairs(CardIndex.Sections) do
                    if not claimed[sec.Rarity] then
                        local all = true
                        for _, c in ipairs(sec.Cards) do if not found[c] then all = false; break end end
                        if all then Remotes.ClaimIndex:InvokeServer(sec.Rarity); toast("Claimed Index: " .. sec.Rarity); task.wait(1) end
                    end
                end
            end)
        end
        task.wait(30)
    end
end)

---------- PLACE CARDS AT BASE ----------
threads.placeCards = task.spawn(function()
    task.wait(18)
    while _G._autoFarmRunning do
        if state.master and state.placeCards then
            pcall(function()
                local data = getData()
                if not data then return end
                local base = data.Base or {}
                local holders = base.Holders or {}
                local cards = data.Cards or {}
                local equipped = data.Equipped or {}
                local sorted = {}
                for id, info in pairs(cards) do table.insert(sorted, {id = id, level = info.Level or 1}) end
                table.sort(sorted, function(a, b) return a.level > b.level end)
                local used = {}
                for _, c in pairs(holders) do used[c] = true end
                for _, eq in ipairs(equipped) do used[eq] = true end
                for slot = 1, (base.Slots or 10) do
                    if not holders[tostring(slot)] then
                        for _, c in ipairs(sorted) do
                            if not used[c.id] then
                                Remotes.BasePlace:InvokeServer(slot, c.id)
                                used[c.id] = true; task.wait(0.4); break
                            end
                        end
                    end
                end
            end)
        end
        task.wait(30)
    end
end)

---------- LIVE STATUS LOOP ----------
threads.hud = task.spawn(function()
    while _G._autoFarmRunning do
        pcall(function()
            local data = getData()
            if not data then return end
            local cash = tonumber(data.Cash) or 0
            local power = tonumber(data.Power) or 0
            local lvl = 0; pcall(function() lvl = PowerConfig.Level(power) end)
            local rb = data.Rebirths or 0
            local need = Progression.RebirthLevels[rb + 1] or 999
            local elapsed = tick() - stats.startTime

            stCash.Text = "$" .. tostring(data.Cash)
            stPower.Text = tostring(data.Power)
            stLevel.Text = "Lv " .. lvl
            stRebirth.Text = tostring(rb)
            stNext.Text = string.format("Lv %d / %d (%d%%)", lvl, need, math.min(100, math.floor(lvl / need * 100)))
            stMode.Text = (state.master and stats.mode:upper()) or "PAUSED"
            stTarget.Text = stats.target or "-"
            if elapsed > 15 then stRate.Text = string.format("%.0f", (cash - stats.startCash) / elapsed * 60) end
            stSession.Text = string.format("%dp %du %drb • learn %d", stats.packsBought, stats.upgrades, stats.rebirths, stats.learned)

            profileLevel.Text = "Lv. " .. lvl .. "  •  RB " .. rb
            profileInfo.Text = "$" .. tostring(data.Cash)
            if state.master then headerStatus.Text = "● RUNNING"; headerStatus.TextColor3 = COLORS.Green
            else headerStatus.Text = "● PAUSED"; headerStatus.TextColor3 = COLORS.Orange end
        end)
        task.wait(1)
    end
end)

---------- BRAIN RENDER LOOP ----------
threads.brain = task.spawn(function()
    while _G._autoFarmRunning do
        if currentPage == "brain" then
            pcall(function()
                for _, c in ipairs(brainRows:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
                local list = {}
                for et, L in pairs(Learn) do
                    local avg = L.kills > 0 and (L.sumTime / L.kills) or 0
                    local cps = (L.kills > 0 and avg > 0) and (((L.reward > 0 and L.reward) or (L.boss and 400 or 30)) / avg) or 0
                    table.insert(list, {et = et, L = L, cps = cps, avg = avg})
                end
                table.sort(list, function(a, b) return a.cps > b.cps end)
                for i, item in ipairs(list) do
                    if i > 12 then break end
                    local L = item.L
                    local row = new("Frame", {Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = COLORS.Card, BackgroundTransparency = 0.32, BorderSizePixel = 0, LayoutOrder = i}, brainRows)
                    corner(row, 7); stroke(row, COLORS.Line, 0.7, 1)
                    local deadly = L.deaths >= 2 and L.kills == 0
                    new("TextLabel", {Position = UDim2.fromOffset(10, 0), Size = UDim2.new(0.5, 0, 1, 0), BackgroundTransparency = 1, Text = (L.boss and "★ " or "") .. item.et, TextColor3 = deadly and COLORS.Red or COLORS.Text, TextSize = 12, Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd}, row)
                    local info = deadly and "ตายบ่อย เลี่ยง" or string.format("%d kill • %.1fs • %.0f/s", L.kills, item.avg, item.cps)
                    new("TextLabel", {Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.new(0.5, -10, 1, 0), BackgroundTransparency = 1, Text = info, TextColor3 = deadly and COLORS.Red or COLORS.Green, TextSize = 11, Font = Enum.Font.GothamMedium, TextXAlignment = Enum.TextXAlignment.Right}, row)
                end
                if #list == 0 then
                    local row = new("Frame", {Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, LayoutOrder = 1}, brainRows)
                    new("TextLabel", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "ยังไม่มีข้อมูล — กำลังเก็บจากการสู้...", TextColor3 = COLORS.Sub, TextSize = 11, Font = Enum.Font.Gotham}, row)
                end
            end)
        end
        task.wait(1.5)
    end
end)

toast("Auto Farm Center loaded — RightControl ซ่อน/แสดง")
print("[AutoFarm] Red UI loaded, all systems running")
