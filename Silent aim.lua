--[[=================================================================
   ░█▀▀░▀█▀░█░░░█▀▀░█▀█░▀█▀░░░█▀█░▀█▀░█▄█  ░▀▀█
   ░▄▄█░░█░░█░░░█▀▀░█░█░░█░░░░█▀█░░█░░█░█  ░▄▀░
   ░▀▀▀░▀▀▀░▀▀▀░▀▀▀░▀░▀░░▀░░░░▀░▀░▀▀▀░▀░▀  ░▀▀▀
   SILENT AIM v2.0.0 — UNIVERSAL • UNDETECTED • MOBILE READY
   Silent/Camera/Both • Prediction • Triggerbot • Anti-Kick
   Anti-AFK • Anti-Void • Anti-Fling • Save Config • Auto-Update
=================================================================]]

--=============================================================
-- [0] CONFIG  <-- EDIT THESE 4 LINES ONLY
--=============================================================
local CONFIG = {
    GitHubUser   = "YOUR_USERNAME",   -- your GitHub username
    GitHubRepo   = "YOUR_REPO",       -- your repository name
    GitHubBranch = "main",            -- main / master
    ScriptFile   = "silentaim.lua",   -- file name in the repo

    Version      = "2.0.0",
    AutoUpdate   = true,              -- pull newer builds from GitHub
    AutoQueue    = true,              -- re-inject on rejoin / teleport
    SaveConfig   = true,              -- remember settings between sessions
    Debug        = false,
}

--=============================================================
-- [1] COMPAT + SERVICES
--=============================================================
local getgenv   = getgenv   or function() return _G end
local gethui    = gethui    or function() return game:GetService("CoreGui") end
local newC      = newcclosure or function(f) return f end
local getRawMT  = getrawmetatable or function(o) return getmetatable(o) end
local setRO     = setreadonly or function() end
local getNCM    = getnamecallmethod or function() return "" end
local isfileF   = isfile or function() return false end

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")
local VirtualUser      = game:GetService("VirtualUser")
local HttpService      = game:GetService("HttpService")
local TweenService     = game:GetService("TweenService")
local HapticService    = game:GetService("HapticService")
local VirtualInput     = game:GetService("VirtualInputManager")

local LP     = Players.LocalPlayer
local Mouse  = LP:GetMouse()
local Camera = Workspace.CurrentCamera

local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local S = isMobile and 1.25 or 1.0

local FILTER_TYPE
do
    local ok, v = pcall(function() return Enum.RaycastFilterType.Exclude end)
    FILTER_TYPE = ok and v or Enum.RaycastFilterType.Blacklist
end

--=============================================================
-- [2] PROTECTION LAYER (sandboxes every module)
--=============================================================
local Cleanup = {}
local function track(o) table.insert(Cleanup, o); return o end

local function safe(fn, ...)
    local ok, a, b = pcall(fn, ...)
    if not ok and CONFIG.Debug then warn("[SilentAim] " .. tostring(a)) end
    return ok, a, b
end

local function restoreHooks()
    local h = getgenv().SilentAimHook
    if not h then return end
    safe(function()
        local mt = getRawMT(game)
        setRO(mt, false)
        if mt.__index == h.index        then mt.__index = h.oldIndex end
        if mt.__namecall == h.namecall  then mt.__namecall = h.oldNamecall end
        setRO(mt, true)
    end)
    getgenv().SilentAimHook = nil
end

local function cleanup()
    for _, c in ipairs(Cleanup) do
        safe(function()
            if typeof(c) == "RBXScriptConnection" then c:Disconnect() else c:Destroy() end
        end)
    end
    Cleanup = {}
    safe(restoreHooks)
    if getgenv().SilentAimGui then safe(function() getgenv().SilentAimGui:Destroy() end) end
    getgenv().SilentAimGui = nil
    getgenv().SilentAimRunning = false
end

--=============================================================
-- [3] SETTINGS + PERSISTENCE
--=============================================================
local DEFAULTS = {
    Enabled     = false,
    AimMethod   = "Silent",     -- Silent | Camera | Both
    SelectMode  = "Crosshair",  -- Crosshair | Mouse | Distance | Health
    TargetPart  = "Head",       -- Head | Torso | Nearest
    FOV         = 90,
    Prediction  = true,
    BulletSpeed = 300,
    HitChance   = 100,
    Smoothness  = 0.25,
    TeamCheck   = false,
    WallCheck   = false,
    Triggerbot  = false,
    TriggerFOV  = 3,
    AntiKick    = true,
    AntiAFK     = true,
    AntiVoid    = true,
    AntiFling   = false,
    ShowFOV     = true,
    ShowLine    = true,
}

local CFG_FILE = "silentaim_v2_config.json"
local State = {}

local function loadSettings()
    for k, v in pairs(DEFAULTS) do State[k] = v end
    local data
    if CONFIG.SaveConfig and isfileF() and isfile(CFG_FILE) then
        local ok, d = pcall(function() return HttpService:JSONDecode(readfile(CFG_FILE)) end)
        if ok then data = d end
    end
    data = data or getgenv().SilentAimSaved
    if type(data) == "table" then
        for k, v in pairs(data) do
            if DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then State[k] = v end
        end
    end
end

local function saveSettings()
    if not CONFIG.SaveConfig then return end
    local out = {}
    for k in pairs(DEFAULTS) do out[k] = State[k] end
    getgenv().SilentAimSaved = out
    if writefile then safe(function() writefile(CFG_FILE, HttpService:JSONEncode(out)) end) end
end

loadSettings()
State.Target = nil

--=============================================================
-- [4] TARGET ACQUISITION
--=============================================================
local function getPartFor(char, head, torso)
    if State.TargetPart == "Head" then return head end
    if State.TargetPart == "Torso" then return torso or head end
    local cam = Workspace.CurrentCamera
    if not cam then return head end
    local look = cam.CFrame.LookVector
    local best, bestAng = head, 1e9
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") then
            local dir = d.Position - cam.CFrame.Position
            local ang = math.deg(math.acos(math.clamp(look:Dot(dir.Unit), -1, 1)))
            if ang < bestAng then bestAng = ang; best = d end
        end
    end
    return best
end

local function predict(part, pos)
    if not State.Prediction or not part then return pos end
    local cam = Workspace.CurrentCamera
    if not cam then return pos end
    local dist = (pos - cam.CFrame.Position).Magnitude
    return pos + part.AssemblyLinearVelocity * (dist / math.max(State.BulletSpeed, 1))
end

local function updateTarget()
    State.Target = nil
    if not State.Enabled then return end
    local cam = Workspace.CurrentCamera
    if not cam then return end

    local camPos = cam.CFrame.Position
    local look   = cam.CFrame.LookVector
    local vp     = cam.ViewportSize
    local center = Vector2.new(vp.X / 2, vp.Y / 2)
    local mousePos = UserInputService:GetMouseLocation()

    local best, bestScore = nil, math.huge

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP then
            local char = plr.Character
            local head = char and char:FindFirstChild("Head")
            local torso = char and char:FindFirstChild("HumanoidRootPart")
            local hum  = char and char:FindFirstChildOfClass("Humanoid")
            if head and hum and hum.Health > 0 then
                local skip = State.TeamCheck and LP.Team ~= nil and plr.Team == LP.Team
                if not skip then
                    local part = getPartFor(char, head, torso)
                    local pos  = predict(part, part.Position)
                    local dir  = pos - camPos
                    local ang  = math.deg(math.acos(math.clamp(look:Dot(dir.Unit), -1, 1)))

                    if ang <= State.FOV then
                        local blocked = false
                        if State.WallCheck then
                            local params = RaycastParams.new()
                            params.FilterType = FILTER_TYPE
                            params.FilterDescendantsInstances = { LP.Character, char }
                            if Workspace:Raycast(camPos, dir, params) then blocked = true end
                        end
                        if not blocked then
                            local score
                            if State.SelectMode == "Distance" then
                                score = dir.Magnitude
                            elseif State.SelectMode == "Health" then
                                score = hum.Health
                            elseif State.SelectMode == "Mouse" then
                                local sp = cam:WorldToViewportPoint(pos)
                                score = (Vector2.new(sp.X, sp.Y) - mousePos).Magnitude
                            else
                                score = ang
                            end
                            if score < bestScore then
                                bestScore = score
                                best = { Pos = pos, Part = part, Player = plr, Angle = ang }
                            end
                        end
                    end
                end
            end
        end
    end
    State.Target = best
end

--=============================================================
-- [5] HOOKS (silent aim + anti-kick)
--=============================================================
local function installHooks()
    local mt = getRawMT(game)
    if not mt then return end
    local oldIndex, oldNamecall = mt.__index, mt.__namecall

    local newIndex = newC(function(self, key)
        local t = State.Target
        if State.AimMethod ~= "Camera" and State.Enabled and t and self == Mouse then
            if key == "Hit" then
                return CFrame.new(t.Pos)
            elseif key == "Target" then
                return t.Part
            elseif key == "UnitRay" then
                local cam = Workspace.CurrentCamera
                local o = cam and cam.CFrame.Position or Vector3.zero
                return Ray.new(o, (t.Pos - o).Unit * 1000)
            elseif key == "X" or key == "Y" then
                local cam = Workspace.CurrentCamera
                if cam then
                    local v = cam:WorldToViewportPoint(t.Pos)
                    return key == "X" and v.X or v.Y
                end
            end
        end
        return oldIndex(self, key)
    end)

    local newNamecall = newC(function(self, ...)
        if getNCM() == "Kick" and State.AntiKick and (self == LP or self == Players) then
            return
        end
        return oldNamecall(self, ...)
    end)

    setRO(mt, false)
    mt.__index, mt.__namecall = newIndex, newNamecall
    setRO(mt, true)

    getgenv().SilentAimHook = {
        index = newIndex, namecall = newNamecall,
        oldIndex = oldIndex, oldNamecall = oldNamecall,
    }
end

--=============================================================
-- [6] SUPPORT MODULES (anti-afk / anti-void / anti-fling / trigger)
--=============================================================
local function startAntiAFK()
    track(LP.Idled:Connect(function()
        if not State.AntiAFK then return end
        safe(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end))
end

local lastSafe = nil
local function startSurvival()
    track(RunService.Heartbeat:Connect(function()
        local char = LP.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum or hum.Health <= 0 then return end

        if hrp.Position.Y > -50 then
            lastSafe = hrp.Position
        elseif State.AntiVoid and hrp.Position.Y < -150 and lastSafe then
            safe(function() hrp.CFrame = CFrame.new(lastSafe + Vector3.new(0, 5, 0)) end)
        end

        if State.AntiFling then
            local v = hrp.AssemblyLinearVelocity
            if v.Magnitude > 400 then
                safe(function() hrp.AssemblyLinearVelocity = Vector3.new(0, v.Y, 0) end)
            end
        end
    end))
end

local triggerClock = 0
local function fire()
    if mouse1click then safe(mouse1click)
    else
        safe(function()
            VirtualInput:SendMouseButtonEvent(0, 0, 0, true,  game, 1)
            VirtualInput:SendMouseButtonEvent(0, 0, 0, false, game, 1)
        end)
    end
end

local function updateTrigger(dt)
    if not State.Triggerbot or not State.Target then return end
    if State.Target.Angle > State.TriggerFOV then return end
    triggerClock = triggerClock - dt
    if triggerClock <= 0 then
        triggerClock = 0.08
        fire()
    end
end

--=============================================================
-- [7] VISUALS
--=============================================================
local fovCircle, targetLine

local function updateVisuals()
    local cam = Workspace.CurrentCamera
    if not cam then return end

    if fovCircle then
        fovCircle.Visible = State.Enabled and State.ShowFOV
        if fovCircle.Visible then
            local vp = cam.ViewportSize
            local rad = math.tan(math.rad(State.FOV / 2)) / math.tan(math.rad(cam.FieldOfView / 2)) * (vp.Y / 2)
            fovCircle.Size = UDim2.fromOffset(rad * 2, rad * 2)
        end
    end

    if targetLine then
        local t = State.Target
        targetLine.Visible = State.Enabled and State.ShowLine and t ~= nil
        if targetLine.Visible then
            local vp = cam.ViewportSize
            local sp = cam:WorldToViewportPoint(t.Pos)
            if sp.Z > 0 then
                local a = Vector2.new(vp.X / 2, vp.Y / 2)
                local b = Vector2.new(sp.X, sp.Y)
                local d = b - a
                targetLine.Size = UDim2.fromOffset(d.Magnitude, 1)
                targetLine.Position = UDim2.fromOffset(a.X, a.Y)
                targetLine.Rotation = math.deg(math.atan2(d.Y, d.X))
            else
                targetLine.Visible = false
            end
        end
    end
end

local function applyCameraLock(dt)
    if State.AimMethod == "Silent" then return end
    local t = State.Target
    if not t then return end
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local goal = CFrame.new(cam.CFrame.Position, t.Pos)
    local a = State.Smoothness <= 0 and 1 or (1 - math.exp(-dt / State.Smoothness))
    cam.CFrame = cam.CFrame:Lerp(goal, a)
end

--=============================================================
-- [8] GUI (touch + keyboard, collapsible)
--=============================================================
local W      = math.floor(272 * S)
local HDR    = math.floor(32 * S)
local BTN    = math.floor(26 * S)
local TOGH   = math.floor(46 * S)
local SETTH  = math.floor(226 * S)

local function buildGui()
    local parent
    safe(function() parent = gethui() end)
    parent = parent or LP:WaitForChild("PlayerGui")

    local gui = Instance.new("ScreenGui")
    gui.Name = "SilentAimUI"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 999
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    safe(function() gui.Parent = parent end)
    if not gui.Parent then gui.Parent = LP:WaitForChild("PlayerGui") end
    getgenv().SilentAimGui = gui

    -- FOV ring
    fovCircle = Instance.new("Frame")
    fovCircle.AnchorPoint = Vector2.new(0.5, 0.5)
    fovCircle.Position = UDim2.fromScale(0.5, 0.5)
    fovCircle.BackgroundTransparency = 1
    fovCircle.BorderSizePixel = 0
    fovCircle.ZIndex = 0
    fovCircle.Parent = gui
    local cs = Instance.new("UIStroke"); cs.Color = Color3.fromRGB(150, 120, 255)
    cs.Thickness = 1.5; cs.Transparency = 0.45; cs.Parent = fovCircle
    local cc = Instance.new("UICorner"); cc.CornerRadius = UDim.new(1, 0); cc.Parent = fovCircle

    -- target line
    targetLine = Instance.new("Frame")
    targetLine.AnchorPoint = Vector2.new(0, 0.5)
    targetLine.BackgroundColor3 = Color3.fromRGB(150, 120, 255)
    targetLine.BorderSizePixel = 0
    targetLine.BackgroundTransparency = 0.35
    targetLine.ZIndex = 0
    targetLine.Parent = gui

    -- main panel
    local main = Instance.new("Frame")
    main.Name = "Main"
    main.Size = UDim2.fromOffset(W, HDR + TOGH + math.floor(18 * S))
    main.Position = UDim2.new(0, math.floor(16 * S), 0, math.floor(50 * S))
    main.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
    main.BorderSizePixel = 0
    main.Active = true
    main.Parent = gui
    local mc = Instance.new("UICorner"); mc.CornerRadius = UDim.new(0, 12); mc.Parent = main
    local ms = Instance.new("UIStroke"); ms.Color = Color3.fromRGB(150, 120, 255)
    ms.Thickness = 1; ms.Transparency = 0.35; ms.Parent = main
    local gr = Instance.new("UIGradient")
    gr.Rotation = 90
    gr.Color = ColorSequence.new(Color3.fromRGB(28, 28, 36), Color3.fromRGB(11, 11, 15))
    gr.Parent = main

    -- header
    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, HDR)
    header.BackgroundTransparency = 1
    header.Parent = main

    local title = Instance.new("TextLabel")
    title.Text = "Silent Aim"
    title.Font = Enum.Font.GothamBold
    title.TextSize = math.floor(14 * S)
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.BackgroundTransparency = 1
    title.Position = UDim2.new(0, math.floor(12 * S), 0, 0)
    title.Size = UDim2.new(0.55, 0, 1, 0)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = header

    local function mkIcon(text, idx, color)
        local b = Instance.new("TextButton")
        b.Text = text
        b.Font = Enum.Font.GothamBold
        b.TextSize = math.floor(13 * S)
        b.TextColor3 = Color3.fromRGB(235, 235, 240)
        b.BackgroundColor3 = color or Color3.fromRGB(42, 42, 52)
        b.BorderSizePixel = 0
        b.Size = UDim2.fromOffset(BTN, BTN)
        b.Position = UDim2.new(1, -(math.floor(8 * S) + (BTN + math.floor(6 * S)) * idx), 0, math.floor((HDR - BTN) / 2))
        b.Parent = header
        local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 7); c.Parent = b
        return b
    end

    local closeBtn = mkIcon("X", 0, Color3.fromRGB(215, 58, 58))
    local minBtn   = mkIcon("-", 1)
    local gearBtn  = mkIcon("O", 2)

    -- ON / OFF toggle
    local toggle = Instance.new("TextButton")
    toggle.Text = "OFF"
    toggle.Font = Enum.Font.GothamBold
    toggle.TextSize = math.floor(19 * S)
    toggle.TextColor3 = Color3.fromRGB(255, 255, 255)
    toggle.BackgroundColor3 = Color3.fromRGB(200, 55, 55)
    toggle.BorderSizePixel = 0
    toggle.Size = UDim2.new(1, -math.floor(20 * S), 0, TOGH)
    toggle.Position = UDim2.new(0, math.floor(10 * S), 0, HDR + math.floor(4 * S))
    toggle.Parent = main
    local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(0, 10); tc.Parent = toggle

    -- settings drawer
    local settings = Instance.new("ScrollingFrame")
    settings.Size = UDim2.new(1, -math.floor(16 * S), 0, SETTH)
    settings.Position = UDim2.new(0, math.floor(8 * S), 0, HDR + TOGH + math.floor(12 * S))
    settings.BackgroundTransparency = 1
    settings.BorderSizePixel = 0
    settings.ScrollBarThickness = 4
    settings.ScrollBarImageColor3 = Color3.fromRGB(150, 120, 255)
    settings.CanvasSize = UDim2.new()
    settings.AutomaticCanvasSize = Enum.AutomaticSize.Y
    settings.Visible = false
    settings.Parent = main

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, math.floor(5 * S))
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = settings

    local refreshers = {}
    local order = 0

    local function addRow(label, key, values)
        order += 1
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, -math.floor(6 * S), 0, math.floor(30 * S))
        row.BackgroundColor3 = Color3.fromRGB(24, 24, 31)
        row.BorderSizePixel = 0
        row.LayoutOrder = order
        row.Parent = settings
        local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, 7); rc.Parent = row

        local lbl = Instance.new("TextLabel")
        lbl.Text = label
        lbl.Font = Enum.Font.GothamMedium
        lbl.TextSize = math.floor(12 * S)
        lbl.TextColor3 = Color3.fromRGB(212, 212, 224)
        lbl.BackgroundTransparency = 1
        lbl.Position = UDim2.new(0, math.floor(10 * S), 0, 0)
        lbl.Size = UDim2.new(0.58, 0, 1, 0)
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Parent = row

        local val = Instance.new("TextButton")
        val.Font = Enum.Font.GothamBold
        val.TextSize = math.floor(11 * S)
        val.TextColor3 = Color3.fromRGB(255, 255, 255)
        val.BorderSizePixel = 0
        val.Size = UDim2.new(0, math.floor(74 * S), 0, math.floor(22 * S))
        val.Position = UDim2.new(1, -(math.floor(10 * S) + math.floor(74 * S)), 0.5, -math.floor(11 * S))
        val.Parent = row
        local vc = Instance.new("UICorner"); vc.CornerRadius = UDim.new(0, 6); vc.Parent = val

        local function refresh()
            if values then
                val.Text = tostring(State[key])
                val.BackgroundColor3 = Color3.fromRGB(60, 60, 76)
            else
                local on = State[key]
                val.Text = on and "ON" or "OFF"
                val.BackgroundColor3 = on and Color3.fromRGB(45, 190, 95) or Color3.fromRGB(150, 50, 50)
            end
        end
        refreshers[key] = refresh
        refresh()

        track(val.MouseButton1Click:Connect(function()
            if values then
                local i = table.find(values, State[key]) or 1
                State[key] = values[(i % #values) + 1]
            else
                State[key] = not State[key]
            end
            refresh()
            saveSettings()
        end))
    end

    addRow("Aim Method",   "AimMethod",   { "Silent", "Camera", "Both" })
    addRow("Select Mode",  "SelectMode",  { "Crosshair", "Mouse", "Distance", "Health" })
    addRow("Target Part",  "TargetPart",  { "Head", "Torso", "Nearest" })
    addRow("FOV",          "FOV",         { 30, 45, 60, 75, 90, 120, 180, 360 })
    addRow("Smoothness",   "Smoothness",  { 0, 0.1, 0.25, 0.5, 1 })
    addRow("Hit Chance",   "HitChance",   { 25, 50, 75, 90, 100 })
    addRow("Prediction",   "Prediction")
    addRow("Triggerbot",   "Triggerbot")
    addRow("Trigger FOV",  "TriggerFOV",  { 1, 2, 3, 5, 10, 20 })
    addRow("Team Check",   "TeamCheck")
    addRow("Wall Check",   "WallCheck")
    addRow("FOV Circle",   "ShowFOV")
    addRow("Target Line",  "ShowLine")
    addRow("Anti Kick",    "AntiKick")
    addRow("Anti AFK",     "AntiAFK")
    addRow("Anti Void",    "AntiVoid")
    addRow("Anti Fling",   "AntiFling")

    -- refresh toggle look
    local function refreshToggle()
        if State.Enabled then
            toggle.Text = "ON"
            toggle.BackgroundColor3 = Color3.fromRGB(45, 190, 95)
        else
            toggle.Text = "OFF"
            toggle.BackgroundColor3 = Color3.fromRGB(200, 55, 55)
        end
    end
    refreshToggle()
    getgenv().SilentAimRefresh = function()
        refreshToggle()
        for _, f in pairs(refreshers) do safe(f) end
    end

    -- panel state
    local expanded, minimized = false, false
    local collapsedH = HDR + TOGH + math.floor(18 * S)

    local function applySize()
        local h
        if minimized then h = HDR
        elseif expanded then h = collapsedH + SETTH + math.floor(12 * S)
        else h = collapsedH end
        TweenService:Create(main, TweenInfo.new(0.16), { Size = UDim2.fromOffset(W, h) }):Play()
        toggle.Visible   = not minimized
        settings.Visible = expanded and not minimized
        title.Text       = minimized and "SA" or "Silent Aim"
    end

    track(toggle.MouseButton1Click:Connect(function()
        State.Enabled = not State.Enabled
        refreshToggle()
        saveSettings()
        if isMobile then
            safe(function() HapticService:SetMotor(Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Small, 1) end)
        end
    end))

    track(gearBtn.MouseButton1Click:Connect(function()
        expanded = not expanded
        if minimized then minimized = false end
        applySize()
    end))

    track(minBtn.MouseButton1Click:Connect(function()
        minimized = not minimized
        applySize()
    end))

    track(closeBtn.MouseButton1Click:Connect(function()
        cleanup()
    end))

    -- drag from header (works with finger or mouse)
    local dragging, dragStart, startPos
    track(header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging  = true
            dragStart = input.Position
            startPos  = main.Position
        end
    end))
    track(header.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
    track(header.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            local nx = startPos.X.Offset + d.X
            local ny = startPos.Y.Offset + d.Y
            local vp = Camera and Camera.ViewportSize or Vector2.new(1280, 720)
            nx = math.clamp(nx, -W + 60, vp.X - 60)
            ny = math.clamp(ny, 0, vp.Y - HDR)
            main.Position = UDim2.new(0, nx, 0, ny)
        end
    end))
end

--=============================================================
-- [9] SELF-ADAPT (re-queue + auto-update)
--=============================================================
local function rawURL()
    return string.format("https://raw.githubusercontent.com/%s/%s/%s/%s",
        CONFIG.GitHubUser, CONFIG.GitHubRepo, CONFIG.GitHubBranch, CONFIG.ScriptFile)
end

local function queueSelf()
    if not CONFIG.AutoQueue then return end
    local code = string.format('loadstring(game:HttpGet("%s"))()', rawURL())
    if queue_on_teleport then safe(queue_on_teleport, code)
    elseif queueonteleport then safe(queueonteleport, code)
    elseif syn and syn.queue_on_teleport then safe(syn.queue_on_teleport, code) end
end

local function selfUpdate()
    if not CONFIG.AutoUpdate or getgenv().SilentAimUpdating then return end
    local ok, body = pcall(game.HttpGet, game, rawURL() .. "?t=" .. os.time())
    if not ok or type(body) ~= "string" then return end
    local remote = body:match("Version%s*=%s*\"([%d%.]+)\"")
    if remote and remote ~= CONFIG.Version then
        getgenv().SilentAimUpdating = true
        cleanup()
        local fn = loadstring(body)
        if fn then safe(fn) end
        getgenv().SilentAimUpdating = false
    end
end

--=============================================================
-- [10] BOOT
--=============================================================
local function init()
    if getgenv().SilentAimRunning then cleanup() end
    getgenv().SilentAimRunning = true

    LP     = Players.LocalPlayer
    Mouse  = LP:GetMouse()
    Camera = Workspace.CurrentCamera

    cleanup()
    installHooks()
    startAntiAFK()
    startSurvival()
    buildGui()

    track(RunService.RenderStepped:Connect(function(dt)
        safe(updateTarget)
        safe(applyCameraLock, dt)
        safe(updateVisuals)
        safe(updateTrigger, dt)
    end))

    track(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        Camera = Workspace.CurrentCamera
    end))

    -- keyboard shortcuts (ignored on mobile, harmless if absent)
    track(UserInputService.InputBegan:Connect(function(input, gp)
        if gp then return end
        if input.KeyCode == Enum.KeyCode.RightShift then
            State.Enabled = not State.Enabled
            if getgenv().SilentAimRefresh then getgenv().SilentAimRefresh() end
            saveSettings()
        end
    end))

    queueSelf()
    selfUpdate()
end

safe(init)
